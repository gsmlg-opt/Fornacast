defmodule ForgeImports.GitHub.ClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForgeImports.GitHub.{
    Client,
    Error,
    HostPolicy,
    Organization,
    Repository,
    RequestGate,
    User
  }

  setup {Req.Test, :verify_on_exit!}

  test "authenticated_user uses the fixed endpoint and required headers" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.scheme == :https
      assert conn.host == "api.github.com"
      assert conn.port == 443
      assert conn.request_path == "/user"
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
      assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2026-03-10"]
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["Fornacast/0.2.0"]
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer github_pat_test"]

      Req.Test.json(conn, user_json())
    end)

    assert {:ok,
            %User{
              id: 9_000_000_001,
              login: "octocat",
              name: "The Octocat",
              avatar_url: "https://avatars.githubusercontent.com/u/9",
              html_url: "https://github.com/octocat"
            }} = Client.authenticated_user("github_pat_test", client_opts(stub))
  end

  test "repository and organization return bounded typed values" do
    stub = stub_name()

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/repos/octocat/hello-world" -> Req.Test.json(conn, repository_json())
        "/orgs/github" -> Req.Test.json(conn, organization_json())
      end
    end)

    assert {:ok,
            %Repository{
              id: 12_345,
              name: "hello-world",
              full_name: "octocat/hello-world",
              owner_login: "octocat",
              visibility: :public,
              default_branch: "main",
              has_issues: true,
              allow_merge_commit: true,
              fork: false,
              archived: false
            }} = Client.repository("github_pat_test", "octocat", "hello-world", client_opts(stub))

    assert {:ok,
            %Organization{
              id: 99,
              login: "github",
              name: "GitHub",
              description: "How people build software"
            }} = Client.organization("github_pat_test", "github", client_opts(stub, 2))
  end

  test "repository list payloads preserve an omitted merge-commit setting as unknown" do
    list_payload = Map.delete(repository_json(), "allow_merge_commit")

    assert {:ok, %Repository{allow_merge_commit: nil} = listed} =
             Repository.from_json(list_payload)

    assert inspect(listed) =~ "allow_merge_commit: nil"

    assert {:ok, %Repository{allow_merge_commit: false}} =
             list_payload
             |> Map.put("allow_merge_commit", false)
             |> Repository.from_json()

    for invalid <- [nil, "false", 0] do
      assert {:error, :invalid_response} =
               list_payload
               |> Map.put("allow_merge_commit", invalid)
               |> Repository.from_json()
    end
  end

  test "organization repositories follow only an authenticated validated next link" do
    stub = stub_name()
    parent = self()

    Req.Test.expect(stub, 3, fn conn ->
      send(parent, {:request, conn.request_path, conn.query_string})

      case conn.request_path do
        "/orgs/github" ->
          Req.Test.json(conn, organization_json())

        "/orgs/github/repos" ->
          conn
          |> Plug.Conn.put_resp_header(
            "link",
            ~s(<https://api.github.com/organizations/99/repos?per_page=100&page=2>; rel="prev next", <https://api.github.com/organizations/99/repos?per_page=100&page=2>; rel="last")
          )
          |> Req.Test.json([repository_json(12_345, "one") |> Map.delete("allow_merge_commit")])

        "/organizations/99/repos" ->
          Req.Test.json(conn, [
            repository_json(12_346, "two") |> Map.delete("allow_merge_commit")
          ])
      end
    end)

    assert {:ok,
            [
              %Repository{name: "one", allow_merge_commit: nil},
              %Repository{name: "two", allow_merge_commit: nil}
            ]} =
             Client.organization_repositories("github_pat_test", "github", client_opts(stub))

    assert_received {:request, "/orgs/github", ""}
    assert_received {:request, "/orgs/github/repos", "per_page=100&type=all"}
    assert_received {:request, "/organizations/99/repos", query}
    assert URI.decode_query(query) == %{"page" => "2", "per_page" => "100"}
  end

  test "rejects an untrusted next link without making a second request" do
    stub = stub_name()

    Req.Test.expect(stub, 2, fn conn ->
      case conn.request_path do
        "/orgs/github" ->
          Req.Test.json(conn, organization_json())

        "/orgs/github/repos" ->
          conn
          |> Plug.Conn.put_resp_header(
            "link",
            ~s(<https://api.github.com.evil.example/orgs/github/repos?page=2>; rel="next")
          )
          |> Req.Test.json([])
      end
    end)

    assert {:error, %Error{kind: :invalid_pagination}} =
             Client.organization_repositories("github_pat_test", "github", client_opts(stub))
  end

  test "rejects malformed, duplicate, invalid-UTF8, and route-pivoting Link entries" do
    next = "https://api.github.com/orgs/github/repos?per_page=100&page=2"

    links = [
      ~s(<#{next}>; rel="next", garbage),
      ~s(<#{next}>; rel="next", <#{next}>; rel="next"),
      ~s(<https://api.github.com/user?page=2>; rel="next"),
      ~s(<https://api.github.com/organizations/100/repos?page=2>; rel="next"),
      ~s(<#{next}>; rel="next"; rel="last"),
      ~s(<#{next}>; rel="next", <not a URL>; rel="last"),
      <<"<", next::binary, ">; rel=\"next\", ", 0xFF>>
    ]

    for {link, key} <- Enum.with_index(links, 1_000) do
      stub = stub_name()

      Req.Test.expect(stub, 2, fn conn ->
        case conn.request_path do
          "/orgs/github" ->
            Req.Test.json(conn, organization_json())

          "/orgs/github/repos" ->
            conn
            |> Plug.Conn.put_resp_header("link", link)
            |> Req.Test.json([])
        end
      end)

      assert {:error, %Error{kind: :invalid_pagination}} =
               Client.organization_repositories(
                 "github_pat_test",
                 "github",
                 client_opts(stub, key)
               )
    end
  end

  test "does not follow redirects or retry failed responses" do
    redirect_stub = stub_name()

    Req.Test.expect(redirect_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://api.github.com/user")
      |> Plug.Conn.send_resp(302, "redirect")
    end)

    assert {:error, %Error{kind: :unexpected_status}} =
             Client.authenticated_user("github_pat_test", client_opts(redirect_stub))

    unavailable_stub = stub_name()
    Req.Test.expect(unavailable_stub, &Plug.Conn.send_resp(&1, 503, "try again"))

    assert {:error, %Error{kind: :upstream_unavailable}} =
             Client.authenticated_user("github_pat_test", client_opts(unavailable_stub, 2))
  end

  test "host policy accepts public addresses and rejects non-public IPv4 and IPv6" do
    public_addresses = [
      {140, 82, 114, 5},
      {0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}
    ]

    assert {:ok, ^public_addresses} =
             HostPolicy.resolve_public(
               resolver: fn "api.github.com" -> {:ok, public_addresses} end
             )

    assert :ok =
             HostPolicy.validate(resolver: fn "api.github.com" -> {:ok, public_addresses} end)

    for address <- [
          {127, 0, 0, 1},
          {10, 0, 0, 1},
          {169, 254, 1, 1},
          {192, 168, 1, 1},
          {224, 0, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0xFF00, 0, 0, 0, 0, 0, 0, 1}
        ] do
      assert {:error, :unsafe_host} =
               HostPolicy.validate(resolver: fn "api.github.com" -> {:ok, [address]} end)
    end
  end

  test "host policy rejects a mixed public and private resolver answer" do
    assert {:error, :unsafe_host} =
             HostPolicy.validate(
               resolver: fn "api.github.com" ->
                 {:ok, [{140, 82, 114, 5}, {10, 0, 0, 1}]}
               end
             )
  end

  test "an unsafe or failed DNS resolution prevents the HTTP request" do
    stub = stub_name()
    Req.Test.stub(stub, fn _conn -> flunk("unsafe host reached transport") end)

    assert {:error, %Error{kind: :unsafe_host}} =
             Client.authenticated_user(
               "github_pat_test",
               client_opts(stub, 1, resolver: fn "api.github.com" -> {:ok, [{192, 0, 2, 1}]} end)
             )

    assert {:error, %Error{kind: :host_unavailable}} =
             Client.authenticated_user(
               "github_pat_test",
               client_opts(stub, 2, resolver: fn "api.github.com" -> {:error, :nxdomain} end)
             )
  end

  test "DNS resolution is inside the request deadline and cannot finish late or hold the gate" do
    slow_stub = stub_name()
    Req.Test.stub(slow_stub, fn _conn -> flunk("timed-out resolution reached HTTP") end)
    parent = self()
    gate_key = {:one_time_run, System.unique_integer([:positive])}

    slow_resolver = fn "api.github.com" ->
      send(parent, {:resolver_started, self()})
      Process.sleep(200)
      send(parent, :resolver_finished_late)
      {:ok, [{140, 82, 114, 5}]}
    end

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :timeout}} =
             Client.authenticated_user(
               "github_pat_test",
               client_opts(slow_stub, 14,
                 gate_key: gate_key,
                 resolver: slow_resolver,
                 request_timeout: 50
               )
             )

    assert System.monotonic_time(:millisecond) - started_at < 180
    assert_receive {:resolver_started, resolver_pid}
    resolver_monitor = Process.monitor(resolver_pid)
    assert_receive {:DOWN, ^resolver_monitor, :process, ^resolver_pid, _reason}, 200
    refute_receive :resolver_finished_late, 220

    success_stub = stub_name()
    Req.Test.expect(success_stub, &Req.Test.json(&1, user_json()))

    assert {:ok, %User{login: "octocat"}} =
             Client.authenticated_user(
               "github_pat_test",
               client_opts(success_stub, 15,
                 gate_key: gate_key,
                 request_timeout: 100
               )
             )
  end

  test "a resolver worker is terminated when its caller dies" do
    parent = self()

    resolver = fn "api.github.com" ->
      send(parent, {:caller_death_resolver_started, self()})

      receive do
        :finish_resolution ->
          send(parent, :caller_death_resolver_finished_late)
          {:ok, [{140, 82, 114, 5}]}
      end
    end

    caller =
      spawn(fn ->
        HostPolicy.resolve_public(
          resolver: resolver,
          deadline: System.monotonic_time(:millisecond) + 5_000
        )
      end)

    assert_receive {:caller_death_resolver_started, resolver_pid}, 1_000
    resolver_monitor = Process.monitor(resolver_pid)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^resolver_monitor, :process, ^resolver_pid, _reason}, 500
    send(resolver_pid, :finish_resolution)
    refute_receive :caller_death_resolver_finished_late, 100
  end

  test "halts a response whose body exceeds the fixed bound" do
    stub = stub_name()
    oversized = String.duplicate("x", 2_100_000)

    Req.Test.expect(stub, fn conn ->
      Plug.Conn.send_resp(conn, 200, JSON.encode!(Map.put(user_json(), "name", oversized)))
    end)

    assert {:error, %Error{kind: :response_too_large}} =
             Client.authenticated_user("github_pat_test", client_opts(stub))
  end

  test "rejects any non-identity content encoding" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Req.Test.json(user_json())
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             Client.authenticated_user("github_pat_test", client_opts(stub))
  end

  test "rejects malformed, over-complex, and wrong-shaped JSON" do
    malformed_stub = stub_name()
    Req.Test.expect(malformed_stub, &Plug.Conn.send_resp(&1, 200, "{not-json"))

    assert {:error, %Error{kind: :invalid_json}} =
             Client.authenticated_user("github_pat_test", client_opts(malformed_stub))

    bounded_stub = stub_name()

    Req.Test.expect(bounded_stub, fn conn ->
      Req.Test.json(conn, Map.put(user_json(), "login", String.duplicate("x", 256)))
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             Client.authenticated_user("github_pat_test", client_opts(bounded_stub, 2))

    shape_stub = stub_name()
    Req.Test.expect(shape_stub, &Req.Test.json(&1, []))

    assert {:error, %Error{kind: :invalid_response}} =
             Client.authenticated_user("github_pat_test", client_opts(shape_stub, 3))
  end

  test "classifies authentication, access, missing, rate-limit, and upstream statuses" do
    now = ~U[2030-01-01 00:00:00Z]
    reset = DateTime.to_unix(now) + 600

    cases = [
      {401, [], :invalid_credential, nil},
      {403, [], :forbidden, nil},
      {404, [], :not_found, nil},
      {403, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", Integer.to_string(reset)}],
       :primary_rate_limit, DateTime.from_unix!(reset)},
      {429, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", Integer.to_string(reset)}],
       :primary_rate_limit, DateTime.from_unix!(reset)},
      {403, [{"retry-after", "120"}], :secondary_rate_limit, DateTime.add(now, 120)},
      {429, [], :secondary_rate_limit, DateTime.add(now, 60)},
      {500, [], :upstream_unavailable, nil}
    ]

    for {status, headers, kind, retry_at} <- cases do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        conn =
          Enum.reduce(headers, conn, fn {key, value}, conn ->
            Plug.Conn.put_resp_header(conn, key, value)
          end)

        Plug.Conn.send_resp(conn, status, ~s({"message":"github_pat_test must never escape"}))
      end)

      assert {:error, %Error{kind: ^kind, retry_at: ^retry_at} = error} =
               Client.authenticated_user(
                 "github_pat_test",
                 client_opts(stub, status, now: fn -> now end)
               )

      refute error.detail =~ "github_pat_test"
    end
  end

  test "rate-limit retry times are always bounded and strictly in the future" do
    now = ~U[2030-01-01 00:00:00Z]
    fallback = DateTime.add(now, 60)
    maximum = DateTime.add(now, 24 * 60 * 60)
    far_future = DateTime.add(now, 7 * 24 * 60 * 60)
    past = DateTime.add(now, -60)

    cases = [
      {403,
       [
         {"x-ratelimit-remaining", "0"},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(past))}
       ], :primary_rate_limit, fallback},
      {429,
       [
         {"x-ratelimit-remaining", "0"},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(far_future))}
       ], :primary_rate_limit, maximum},
      {429, [{"retry-after", Integer.to_string(7 * 24 * 60 * 60)}], :secondary_rate_limit,
       maximum},
      {429, [{"retry-after", http_date(far_future)}], :secondary_rate_limit, maximum},
      {429, [{"retry-after", http_date(past)}], :secondary_rate_limit, fallback}
    ]

    for {status, headers, kind, expected_retry_at} <- cases do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        conn =
          Enum.reduce(headers, conn, fn {key, value}, conn ->
            Plug.Conn.put_resp_header(conn, key, value)
          end)

        Plug.Conn.send_resp(conn, status, "")
      end)

      assert {:error, %Error{kind: ^kind, retry_at: ^expected_retry_at}} =
               Client.authenticated_user(
                 "github_pat_test",
                 client_opts(stub, System.unique_integer([:positive]), now: fn -> now end)
               )
    end
  end

  test "invalid and overflowing rate-limit headers fall back without raising" do
    now = ~U[2030-01-01 00:00:00Z]

    cases = [
      {403, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", String.duplicate("9", 200)}],
       :primary_rate_limit},
      {429, [{"retry-after", String.duplicate("9", 200)}], :secondary_rate_limit},
      {429, [{"retry-after", "not-a-date"}], :secondary_rate_limit}
    ]

    for {status, headers, kind} <- cases do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        conn =
          Enum.reduce(headers, conn, fn {key, value}, conn ->
            Plug.Conn.put_resp_header(conn, key, value)
          end)

        Plug.Conn.send_resp(conn, status, "")
      end)

      assert {:error, %Error{kind: ^kind, retry_at: retry_at}} =
               Client.authenticated_user(
                 "github_pat_test",
                 client_opts(stub, status + System.unique_integer([:positive]),
                   now: fn -> now end
                 )
               )

      assert retry_at == DateTime.add(now, 60)
    end
  end

  test "an invalid UTF-8 error body is classified without being inspected" do
    stub = stub_name()
    Req.Test.expect(stub, &Plug.Conn.send_resp(&1, 403, <<0xFF>>))

    assert {:error, %Error{kind: :forbidden}} =
             Client.authenticated_user("github_pat_test", client_opts(stub))
  end

  test "rejects test injections without a test adapter and arbitrary Req options" do
    assert {:error, %Error{kind: :invalid_request}} =
             Client.authenticated_user(
               "github_pat_test",
               gate_key: {:one_time_run, 1},
               resolver: fn _host -> {:ok, [{140, 82, 114, 5}]} end
             )

    assert {:error, %Error{kind: :invalid_request}} =
             Client.authenticated_user(
               "github_pat_test",
               gate_key: {:one_time_run, 1},
               base_url: "https://example.com"
             )
  end

  test "transport and HTTP errors never expose PATs through logs, messages, or Inspect" do
    stub = stub_name()
    Req.Test.expect(stub, &Req.Test.transport_error(&1, :timeout))

    log =
      capture_log(fn ->
        assert {:error, %Error{kind: :transport} = error} =
                 Client.authenticated_user("github_pat_super_secret", client_opts(stub))

        refute Exception.message(error) =~ "github_pat_super_secret"
        refute inspect(error) =~ "github_pat_super_secret"
        refute inspect(error) =~ error.detail
      end)

    refute log =~ "github_pat_super_secret"
  end

  test "the production adapter bypasses Finch telemetry and uses the policy-validated address" do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:finch, :request, :start],
        fn _event, _measurements, _metadata, _config -> send(parent, :finch_request_started) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %User{login: "octocat"}} =
             Client.authenticated_user(
               "github_pat_no_telemetry",
               gate_key: {:one_time_run, 811},
               resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
               transport_api: __MODULE__.ClientMint
             )

    assert_receive {:custom_connect, {140, 82, 114, 5}}
    refute_receive :finch_request_started
  end

  test "the production adapter preserves bounded typed transport failures" do
    cases = [
      {__MODULE__.ClientOversizedMint, :response_too_large, 812},
      {__MODULE__.ClientTimeoutMint, :timeout, 813}
    ]

    for {transport_api, kind, run_id} <- cases do
      pat = "github_pat_typed_transport"

      assert {:error, %Error{kind: ^kind} = error} =
               Client.authenticated_user(
                 pat,
                 gate_key: {:one_time_run, run_id},
                 resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
                 transport_api: transport_api
               )

      refute Exception.message(error) =~ pat
      refute inspect(error) =~ pat
    end
  end

  test "a gate serializes the complete request for the same credential key" do
    stub = stub_name()
    owner = self()

    Req.Test.stub(stub, fn conn ->
      send(owner, {:entered, self()})
      receive do: (:release -> Req.Test.json(conn, user_json()))
    end)

    first =
      Task.async(fn ->
        receive do: (:go -> :ok)
        Client.authenticated_user("first_pat", client_opts(stub, 70))
      end)

    Req.Test.allow(stub, self(), first.pid)
    send(first.pid, :go)
    assert_receive {:entered, first_request}, 1_000

    second =
      Task.async(fn ->
        receive do: (:go -> :ok)
        Client.authenticated_user("second_pat", client_opts(stub, 70))
      end)

    Req.Test.allow(stub, self(), second.pid)
    send(second.pid, :go)
    refute_receive {:entered, _second_request}, 100
    send(first_request, :release)
    assert {:ok, %User{}} = Task.await(first)

    assert_receive {:entered, second_request}, 2_000
    send(second_request, :release)
    assert {:ok, %User{}} = Task.await(second)
  end

  test "gate keys are explicit non-secret identifiers" do
    assert {:error, :invalid_gate_key} = RequestGate.run("github_pat_secret", fn -> :ok end)
    assert :ok = RequestGate.run({:saved_credential, 1}, fn -> :ok end)
    assert :ok = RequestGate.run({:one_time_run, 1}, fn -> :ok end)
  end

  test "gate body failures release the lock and preserve failure semantics" do
    key = {:saved_credential, System.unique_integer([:positive])}

    assert_raise RuntimeError, "boom", fn ->
      RequestGate.run(key, fn -> raise "boom" end)
    end

    assert :ok = RequestGate.run(key, fn -> :ok end)
    assert catch_throw(RequestGate.run(key, fn -> throw(:boom) end)) == :boom
    assert :ok = RequestGate.run(key, fn -> :ok end)
    assert catch_exit(RequestGate.run(key, fn -> exit(:boom) end)) == :boom
    assert :ok = RequestGate.run(key, fn -> :ok end)
  end

  test "different gate keys can overlap" do
    parent = self()

    tasks =
      for id <- [1, 2] do
        Task.async(fn ->
          RequestGate.run({:one_time_run, id + System.unique_integer([:positive])}, fn ->
            send(parent, {:different_key_entered, self()})
            receive do: (:release -> :ok)
          end)
        end)
      end

    assert_receive {:different_key_entered, first}, 1_000
    assert_receive {:different_key_entered, second}, 1_000
    send(first, :release)
    send(second, :release)
    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
  end

  test "caller death promptly terminates workers blocked before acquisition" do
    key = {:saved_credential, System.unique_integer([:positive])}
    parent = self()

    holder =
      spawn(fn ->
        :global.trans(
          {{RequestGate, key}, self()},
          fn ->
            send(parent, :caller_death_gate_held)
            receive do: (:release_gate -> :ok)
          end,
          [node()],
          :infinity
        )
      end)

    caller =
      spawn(fn ->
        receive do: (:go -> RequestGate.run(key, fn -> :never end))
      end)

    on_exit(fn ->
      Process.exit(caller, :kill)
      send(holder, :release_gate)
      Process.exit(holder, :kill)
    end)

    assert_receive :caller_death_gate_held, 1_000
    :erlang.trace(caller, true, [:procs, :set_on_spawn])
    send(caller, :go)

    assert_receive {:trace, ^caller, :spawn, first_child, _mfa}, 1_000
    assert_receive {:trace, ^caller, :spawn, second_child, _mfa}, 1_000

    first_monitor = Process.monitor(first_child)
    second_monitor = Process.monitor(second_child)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^first_monitor, :process, ^first_child, _reason}, 500
    assert_receive {:DOWN, ^second_monitor, :process, ^second_child, _reason}, 500
  end

  test "gate acquisition is bounded and a timed-out callback never starts later" do
    gate_key = {:saved_credential, System.unique_integer([:positive])}
    parent = self()

    holder =
      spawn(fn ->
        lock = {{RequestGate, gate_key}, self()}

        :global.trans(
          lock,
          fn ->
            send(parent, :gate_held)
            receive do: (:release_gate -> :ok)
          end,
          [node()],
          :infinity
        )
      end)

    on_exit(fn ->
      send(holder, :release_gate)
      Process.exit(holder, :kill)
    end)

    assert_receive :gate_held, 1_000
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :busy} =
             RequestGate.run(gate_key, fn ->
               send(parent, :late_callback_started)
             end)

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed in 1_800..3_000
    refute_receive :late_callback_started

    send(holder, :release_gate)
    refute_receive :late_callback_started, 100
  end

  test "pagination stops at the fixed page bound" do
    stub = stub_name()
    counter = :counters.new(1, [])

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/orgs/github" ->
          Req.Test.json(conn, organization_json())

        path when path in ["/orgs/github/repos", "/organizations/99/repos"] ->
          :counters.add(counter, 1, 1)
          page = :counters.get(counter, 1)

          conn
          |> Plug.Conn.put_resp_header(
            "link",
            ~s(<https://api.github.com/organizations/99/repos?per_page=100&page=#{page + 1}>; rel="next")
          )
          |> Req.Test.json([])
      end
    end)

    assert {:error, %Error{kind: :pagination_limit}} =
             Client.organization_repositories("github_pat_test", "github", client_opts(stub))

    assert :counters.get(counter, 1) == 100
  end

  defp client_opts(stub, key_id \\ 1, extra \\ []) do
    Keyword.merge(
      [
        plug: {Req.Test, stub},
        gate_key: {:saved_credential, key_id},
        resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
      ],
      extra
    )
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defp http_date(datetime), do: Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")

  defp user_json do
    %{
      "id" => 9_000_000_001,
      "login" => "octocat",
      "name" => "The Octocat",
      "avatar_url" => "https://avatars.githubusercontent.com/u/9",
      "html_url" => "https://github.com/octocat"
    }
  end

  defp organization_json do
    %{
      "id" => 99,
      "login" => "github",
      "name" => "GitHub",
      "description" => "How people build software",
      "avatar_url" => "https://avatars.githubusercontent.com/u/99",
      "html_url" => "https://github.com/github"
    }
  end

  defp repository_json(id \\ 12_345, name \\ "hello-world") do
    %{
      "id" => id,
      "name" => name,
      "full_name" => "octocat/#{name}",
      "owner" => %{"login" => "octocat"},
      "description" => "A repository",
      "visibility" => "public",
      "default_branch" => "main",
      "has_issues" => true,
      "allow_merge_commit" => true,
      "fork" => false,
      "archived" => false,
      "html_url" => "https://github.com/octocat/#{name}",
      "updated_at" => "2030-01-01T00:00:00Z",
      "pushed_at" => "2030-01-01T00:00:00Z"
    }
  end

  defmodule ClientMint do
    def connect(:https, address, 443, _options) do
      owner = Process.get(:"$callers") |> List.last()
      send(owner, {:custom_connect, address})
      {:ok, %{owner: owner, ref: nil}}
    end

    def request(state, "GET", "/user", _headers, nil) do
      ref = make_ref()
      {:ok, %{state | ref: ref}, ref}
    end

    def recv(state, 0, _timeout) do
      body =
        JSON.encode!(%{
          "id" => 9_000_000_001,
          "login" => "octocat",
          "name" => "The Octocat",
          "avatar_url" => "https://avatars.githubusercontent.com/u/9",
          "html_url" => "https://github.com/octocat"
        })

      {:ok, state,
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-type", "application/json"}]},
         {:data, state.ref, body},
         {:done, state.ref}
       ]}
    end

    def close(state), do: {:ok, state}
  end

  defmodule ClientOversizedMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.ClientTest.ClientMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.ClientTest.ClientMint

    defdelegate close(state), to: ForgeImports.GitHub.ClientTest.ClientMint

    def recv(state, 0, _timeout) do
      {:ok, state,
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-type", "application/json"}]},
         {:data, state.ref, String.duplicate("x", 2_000_001)},
         {:done, state.ref}
       ]}
    end
  end

  defmodule ClientTimeoutMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.ClientTest.ClientMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.ClientTest.ClientMint

    defdelegate close(state), to: ForgeImports.GitHub.ClientTest.ClientMint

    def recv(state, 0, _timeout) do
      {:error, state, %Mint.TransportError{reason: :timeout}, []}
    end
  end
end
