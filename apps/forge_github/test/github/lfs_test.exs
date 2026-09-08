defmodule ForgeGitHub.LFSTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, LFS}
  alias ForgeGitHub.LFS.{Action, Object}

  @oid String.duplicate("a", 64)

  test "Batch rechecks authority after waiting for its installation gate" do
    parent = self()
    gate_key = {:github_installation, System.unique_integer([:positive])}
    {:ok, authority} = Agent.start_link(fn -> :ok end)

    holder =
      Task.async(fn ->
        ForgeGitHub.RequestGate.run(gate_key, fn ->
          send(parent, :gate_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :gate_held

    options =
      test_options(lfs_response(%{"objects" => []}))
      |> Keyword.put(:gate_key, gate_key)
      |> Keyword.put(:authorize, fn ->
        result = Agent.get(authority, & &1)
        send(parent, :authority_checked)
        result
      end)

    caller =
      Task.async(fn ->
        LFS.batch("token", "octocat", "repo", :upload, [%{oid: @oid, size: 3}], options)
      end)

    assert_receive :authority_checked
    Agent.update(authority, fn _ -> {:error, :lease_expired} end)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert {:error, :lease_expired} = Task.await(caller)
    refute_received {:request, _, _, _, _, _}
    Agent.stop(authority)
  end

  test "requests Basic transfers from the fixed GitHub repository Batch endpoint" do
    response =
      lfs_response(%{
        "transfer" => "basic",
        "hash_algo" => "sha256",
        "objects" => [
          %{
            "oid" => @oid,
            "size" => 3,
            "authenticated" => true,
            "actions" => %{
              "download" => %{
                "href" => "https://objects.example.test/download?signature=secret",
                "header" => %{"Authorization" => "Signed secret"},
                "expires_in" => 60
              }
            }
          }
        ]
      })

    assert {:ok,
            [
              %Object{
                oid: @oid,
                size: 3,
                authenticated: true,
                actions: %{download: %Action{operation: :download}}
              }
            ]} =
             LFS.batch(
               "installation-token",
               "octocat",
               "hello-world",
               :download,
               [%{oid: @oid, size: 3}],
               test_options(response)
             )

    assert_received {:request, :post,
                     "https://github.com/octocat/hello-world.git/info/lfs/objects/batch", headers,
                     {:buffer, body, 2_000_000}, _options}

    assert {"authorization", authorization} = List.keyfind(headers, "authorization", 0)
    assert authorization == "Basic " <> Base.encode64("x-access-token:installation-token")
    assert {"accept", "application/vnd.git-lfs+json"} in headers
    assert {"content-type", "application/vnd.git-lfs+json"} in headers

    assert %{
             "hash_algo" => "sha256",
             "objects" => [%{"oid" => @oid, "size" => 3}],
             "operation" => "download",
             "transfers" => ["basic"]
           } = JSON.decode!(body)

    assert inspect(action(:download)) == "#ForgeGitHub.LFS.Action<redacted>"
  end

  test "rejects untrusted repository names and duplicate object ids before HTTP" do
    options = test_options(lfs_response(%{"objects" => []}))
    object = %{oid: @oid, size: 3}

    for {owner, repository} <- [
          {"octocat/attacker", "repo"},
          {"octocat", "../repo"},
          {"octocat", "repo.git/info/lfs"}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               LFS.batch("token", owner, repository, :download, [object], options)
    end

    assert {:error, %Error{kind: :invalid_request}} =
             LFS.batch("token", "octocat", "repo", :download, [object, object], options)

    refute_received {:request, _, _, _, _, _}
  end

  test "rejects non-Basic, mismatched, malformed, and unsafe Batch actions" do
    base_object = %{"oid" => @oid, "size" => 3}

    responses = [
      %{"transfer" => "tus", "objects" => [base_object]},
      %{"transfer" => "basic", "objects" => [%{base_object | "size" => 4}]},
      %{
        "transfer" => "basic",
        "objects" => [
          Map.put(base_object, "actions", %{
            "download" => %{"href" => "http://objects.example.test/object"}
          })
        ]
      },
      %{
        "transfer" => "basic",
        "objects" => [
          Map.put(base_object, "actions", %{
            "download" => %{
              "href" => "https://objects.example.test/object",
              "header" => %{"Host" => "metadata.internal"}
            }
          })
        ]
      }
    ]

    for response <- responses do
      assert {:error, %Error{kind: kind}} =
               LFS.batch(
                 "token",
                 "octocat",
                 "repo",
                 :download,
                 [%{oid: @oid, size: 3}],
                 test_options(lfs_response(response))
               )

      assert kind in [:invalid_lfs_response, :unsafe_action_url]
    end
  end

  test "classifies per-object absence without accepting an action" do
    response =
      lfs_response(%{
        "transfer" => "basic",
        "objects" => [
          %{
            "oid" => @oid,
            "size" => 3,
            "error" => %{"code" => 404, "message" => "Object does not exist"}
          }
        ]
      })

    assert {:ok, [%Object{actions: %{}, error: %Error{kind: :object_missing}}]} =
             LFS.batch(
               "token",
               "octocat",
               "repo",
               :download,
               [%{oid: @oid, size: 3}],
               test_options(response)
             )
  end

  test "streams and verifies a download without exposing signed action data" do
    action = action(:download)
    parent = self()

    assert {:ok, "payload"} =
             LFS.download(
               action,
               %{oid: sha256("payload"), size: 7},
               fn chunk, state ->
                 send(parent, {:chunk, chunk})
                 {:ok, state <> chunk}
               end,
               "",
               test_options({:stream, ["pay", "load"]})
             )

    assert_received {:chunk, "pay"}
    assert_received {:chunk, "load"}

    assert_received {:request, :get, "https://objects.example.test/object?signature=secret",
                     [{"authorization", "Signed secret"}], {:download, _writer, _state, 7},
                     _options}

    refute inspect(action) =~ "signature"
    refute inspect(action) =~ "Signed secret"
  end

  test "fails a corrupt download while returning the latest writer state" do
    assert {:error, %Error{kind: :integrity_mismatch}, "corrupt"} =
             LFS.download(
               action(:download),
               %{oid: @oid, size: 7},
               fn chunk, state -> {:ok, state <> chunk} end,
               "",
               test_options({:stream, ["corrupt"]})
             )
  end

  test "offers a state-first pull reader compatible with blob staging" do
    object = %{oid: sha256("payload"), size: 7}

    consumer = fn reader, source ->
      assert {:ok, "pay", source} = reader.(source, length: 3, read_timeout: 1_000)
      assert {:ok, "load", source} = reader.(source, length: 4, read_timeout: 1_000)
      assert {:eof, source} = reader.(source, length: 4, read_timeout: 1_000)
      {:ok, :staged, source}
    end

    assert {:ok, :staged} =
             LFS.consume_download(
               action(:download),
               object,
               consumer,
               test_options({:pull_stream, ["pay", "load"]})
             )

    assert_received {:request, :get, _url, _headers, {:consume_download, _consumer, 7, oid},
                     _options}

    assert oid == object.oid
  end

  test "uploads an exact verified source then calls an optional verify action" do
    upload = action(:upload)
    verify = action(:verify)
    oid = sha256("payload")

    reader = fn
      _length, [chunk | rest] -> {:ok, chunk, rest}
      _length, [] -> {:eof, []}
    end

    assert {:ok, []} =
             LFS.upload(
               upload,
               %{oid: oid, size: 7},
               reader,
               ["pay", "load"],
               test_options(lfs_response(%{}))
             )

    assert_received {:request, :put, _url, headers, {:upload, _reader, _state, 7}, _options}
    assert {"content-type", "application/octet-stream"} in headers

    assert :ok = LFS.verify(verify, %{oid: oid, size: 7}, test_options(lfs_response(%{})))
    assert_received {:request, :post, _url, headers, {:buffer, body, 65_536}, _options}
    assert {"accept", "application/vnd.git-lfs+json"} in headers
    assert %{"oid" => ^oid, "size" => 7} = JSON.decode!(body)
  end

  test "does not use expired or nearly-expired action URLs" do
    now = ~U[2026-09-06 00:00:00Z]

    for expires_at <- [now, DateTime.add(now, 5)] do
      action = %{action(:download) | expires_at: expires_at}

      assert {:error, %Error{kind: :action_expired}, :initial} =
               LFS.download(
                 action,
                 %{oid: @oid, size: 3},
                 fn _chunk, state -> {:ok, state} end,
                 :initial,
                 test_options(lfs_response(%{}), now: fn -> now end)
               )
    end

    refute_received {:request, _, _, _, _, _}
  end

  test "rejects redirects and classifies GitHub rate limits" do
    now = ~U[2026-09-06 00:00:00Z]

    assert {:error, %Error{kind: :unsafe_redirect}} =
             LFS.batch(
               "token",
               "octocat",
               "repo",
               :download,
               [%{oid: @oid, size: 3}],
               test_options(lfs_response(%{}, 302, [{"location", "https://example.test"}]))
             )

    retry_at = DateTime.add(now, 120)

    assert {:error, %Error{kind: :secondary_rate_limit, retry_at: ^retry_at}} =
             LFS.batch(
               "token",
               "octocat",
               "repo",
               :download,
               [%{oid: @oid, size: 3}],
               test_options(lfs_response(%{}, 429, [{"retry-after", "120"}]),
                 now: fn -> now end
               )
             )
  end

  test "classifies Batch authentication, authorization, absence, and upstream failures" do
    now = ~U[2026-09-06 00:00:00Z]
    reset = now |> DateTime.add(300) |> DateTime.to_unix() |> Integer.to_string()

    cases = [
      {401, [], :invalid_credential, nil},
      {403, [], :forbidden, nil},
      {404, [], :not_found, nil},
      {503, [], :upstream_unavailable, nil},
      {429, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", reset}], :primary_rate_limit,
       DateTime.add(now, 300)}
    ]

    for {status, headers, kind, retry_at} <- cases do
      assert {:error, %Error{kind: ^kind, retry_at: ^retry_at}} =
               LFS.batch(
                 "token",
                 "octocat",
                 "repo",
                 :download,
                 [%{oid: @oid, size: 3}],
                 test_options(lfs_response(%{}, status, headers), now: fn -> now end)
               )
    end
  end

  defp action(operation) do
    Action.new!(
      operation,
      "https://objects.example.test/object?signature=secret",
      %{"Authorization" => "Signed secret"},
      nil
    )
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp lfs_response(json, status \\ 200, headers \\ []) do
    %{
      status: status,
      headers: [{"content-type", "application/vnd.git-lfs+json"} | headers],
      body: JSON.encode!(json)
    }
  end

  defp test_options(response, extra \\ []) do
    [
      gate_key: {:github_installation, System.unique_integer([:positive])},
      transport: {__MODULE__.FakeTransport, response},
      resolver: fn _host -> {:ok, [{203, 0, 114, 10}]} end,
      now: fn -> ~U[2026-09-06 00:00:00Z] end,
      test_pid: self()
    ]
    |> Keyword.merge(extra)
  end

  defmodule FakeTransport do
    def request(method, url, headers, body, options) do
      send(options[:test_pid], {:request, method, url, headers, body, options})

      case options[:transport] do
        {__MODULE__, {:stream, chunks}} -> stream(chunks, body)
        {__MODULE__, {:pull_stream, chunks}} -> pull_stream(chunks, body)
        {__MODULE__, response} when elem(body, 0) == :upload -> upload(body, response)
        {__MODULE__, response} -> {:ok, response}
      end
    end

    defp stream(chunks, {:download, writer, {writer_state, hash}, _expected_size}) do
      {writer_state, hash} =
        Enum.reduce(chunks, {writer_state, hash}, fn chunk, {writer_state, hash} ->
          {:ok, writer_state} = writer.(chunk, writer_state)
          {writer_state, :crypto.hash_update(hash, chunk)}
        end)

      {:ok, %{status: 200, headers: [], body: ""}, {writer_state, hash}}
    end

    defp upload({:upload, reader, state, _expected_size}, response) do
      state = read_all(reader, state)
      {:ok, response, state}
    end

    defp pull_stream(chunks, {:consume_download, consumer, _expected_size, _oid}) do
      reader = fn
        [chunk | rest], options ->
          length = Keyword.fetch!(options, :length)
          <<value::binary-size(^length), tail::binary>> = chunk
          next = if tail == "", do: rest, else: [tail | rest]
          {:ok, value, next}

        [], _options ->
          {:eof, []}
      end

      case consumer.(reader, chunks) do
        {:ok, value, []} ->
          {:ok, %{status: 200, headers: [], body: ""}, {:ok, value}}

        {:error, reason, []} ->
          {:ok, %{status: 200, headers: [], body: ""}, {:error, reason}}
      end
    end

    defp read_all(reader, state) do
      case reader.(65_536, state) do
        {:ok, _chunk, state} -> read_all(reader, state)
        {:eof, state} -> state
      end
    end
  end
end
