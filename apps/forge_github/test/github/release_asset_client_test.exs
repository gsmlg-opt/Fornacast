defmodule ForgeGitHub.ReleaseAssetClientTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, ReleaseAssetClient}

  setup {Req.Test, :verify_on_exit!}

  test "paginates asset descriptors and preserves nullable labels and historical metadata" do
    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/releases/41/assets"
      assert URI.decode_query(conn.query_string) == %{"page" => "1", "per_page" => "100"}

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/acme/widgets/releases/41/assets?page=2&per_page=100>; rel=\"next\""
      )
      |> Req.Test.json([asset()])
    end)

    assert {:ok, %{assets: [descriptor], next_cursor: 2}} =
             ReleaseAssetClient.list_assets_page("token", "acme", "widgets", 41, nil,
               plug: {Req.Test, stub},
               gate_key: {:saved_credential, System.unique_integer([:positive])},
               resolver: fn _ -> {:ok, [{140, 82, 114, 5}]} end
             )

    assert descriptor["label"] == nil
    assert descriptor["size"] == 7
    assert descriptor["download_count"] == 12
    assert descriptor["digest"] == nil
    refute Map.has_key?(descriptor, "browser_download_url")
  end

  test "rejects hostile names, invalid digests and negative byte sizes" do
    for invalid <- [
          Map.put(asset(), "name", "../secret"),
          Map.put(asset(), "digest", "sha256:not-a-digest"),
          Map.put(asset(), "size", -1)
        ] do
      assert {:error, :invalid_response} = ReleaseAssetClient.decode_asset(invalid, "token")
    end
  end

  test "streams a legacy asset without a provider digest and strips credentials on redirects" do
    consumer = fn reader, state ->
      case reader.(state, length: 64, read_timeout: 1_000) do
        {:ok, "payload", state} ->
          assert {:eof, state} = reader.(state, length: 64, read_timeout: 1_000)
          {:ok, :stored, state}

        {:error, reason, state} ->
          {:error, reason, state}
      end
    end

    assert {:ok, :stored} =
             ReleaseAssetClient.download("secret-token", "acme", "widgets", asset(), consumer,
               gate_key: {:saved_credential, System.unique_integer([:positive])},
               resolver: fn _ -> {:ok, [{140, 82, 114, 5}]} end,
               transport_api: __MODULE__.RedirectMint
             )

    assert_received {:asset_request, "api.github.com", headers}
    assert {"authorization", "Bearer secret-token"} in headers
    assert_received {:asset_request, "release-assets.githubusercontent.com", redirected_headers}
    refute Enum.any?(redirected_headers, fn {key, _} -> key == "authorization" end)
  end

  test "refuses a redirect outside GitHub asset hosts" do
    assert {:error, %Error{kind: :unsafe_redirect}} =
             ReleaseAssetClient.download(
               "secret-token",
               "acme",
               "widgets",
               asset(),
               fn reader, state ->
                 {:error, reason, state} = reader.(state, length: 64, read_timeout: 1_000)
                 {:error, reason, state}
               end,
               gate_key: {:saved_credential, System.unique_integer([:positive])},
               resolver: fn _ -> {:ok, [{140, 82, 114, 5}]} end,
               transport_api: __MODULE__.UnsafeRedirectMint
             )
  end

  test "preserves an aborted asset consumer error while refusing unfinished success" do
    options = [
      gate_key: {:saved_credential, System.unique_integer([:positive])},
      resolver: fn _ -> {:ok, [{140, 82, 114, 5}]} end,
      transport_api: __MODULE__.DirectMint
    ]

    assert {:error, :lost_lease} =
             ReleaseAssetClient.download(
               "secret-token",
               "acme",
               "widgets",
               asset(),
               fn reader, state ->
                 assert {:ok, "pay", state} = reader.(state, length: 3, read_timeout: 1_000)
                 {:error, :lost_lease, state}
               end,
               options
             )

    assert {:error, %Error{kind: :sink}} =
             ReleaseAssetClient.download(
               "secret-token",
               "acme",
               "widgets",
               asset(),
               fn _reader, state -> {:ok, :unconsumed, state} end,
               options
             )
  end

  test "consumes batched TLS frames through bounded chunks and keeps byte integrity checks" do
    payload = String.duplicate("a", 40_000) <> String.duplicate("b", 40_000)
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
    descriptor = asset() |> Map.put("size", byte_size(payload)) |> Map.put("digest", digest)

    options = [
      gate_key: {:saved_credential, System.unique_integer([:positive])},
      resolver: fn _ -> {:ok, [{140, 82, 114, 5}]} end,
      transport_api: __MODULE__.BatchedMint
    ]

    consumer = fn reader, state ->
      consume = fn consume, source, chunks ->
        case reader.(source, length: 1_048_576, read_timeout: 1_000) do
          {:ok, chunk, source} ->
            assert byte_size(chunk) <= 65_536
            consume.(consume, source, [chunk | chunks])

          {:eof, source} ->
            {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), source}

          {:error, reason, source} ->
            {:error, reason, source}
        end
      end

      consume.(consume, state, [])
    end

    assert {:ok, ^payload} =
             ReleaseAssetClient.download(
               "token",
               "acme",
               "widgets",
               descriptor,
               consumer,
               options
             )

    assert {:error, %ForgeGitHub.LFS.Transport.Error{kind: :response_too_large}} =
             ForgeGitHub.LFS.Transport.request(
               :get,
               "https://api.github.com/asset",
               [],
               {:consume_download, consumer, byte_size(payload),
                String.replace_prefix(digest, "sha256:", "")},
               options
             )

    assert {:error, %Error{kind: :integrity_mismatch}} =
             ReleaseAssetClient.download(
               "token",
               "acme",
               "widgets",
               Map.put(descriptor, "size", byte_size(payload) - 1),
               consumer,
               options
             )
  end

  defp asset do
    %{
      "id" => 51,
      "node_id" => "RA_51",
      "name" => "widgets.tar.gz",
      "label" => nil,
      "content_type" => "application/gzip",
      "state" => "uploaded",
      "size" => 7,
      "digest" => nil,
      "download_count" => 12,
      "created_at" => "2026-08-26T01:00:00Z",
      "updated_at" => "2026-08-28T01:00:00Z",
      "uploader" => %{"id" => 99, "node_id" => "U_99", "login" => "octocat"},
      "browser_download_url" =>
        "https://github.com/acme/widgets/releases/download/v1/widgets.tar.gz"
    }
  end

  defmodule RedirectMint do
    def connect(_scheme, _address, _port, options) do
      [owner | _] = Process.get(:"$callers")
      {:ok, %{host: options[:hostname], owner: owner, ref: nil, sent: false}}
    end

    def request(state, _method, _target, headers, _body) do
      send(state.owner, {:asset_request, state.host, headers})
      ref = make_ref()
      {:ok, %{state | ref: ref}, ref}
    end

    def recv(%{sent: false, host: "api.github.com"} = state, 0, _timeout) do
      {:ok, %{state | sent: true},
       [
         {:status, state.ref, 302},
         {:headers, state.ref,
          [{"location", "https://release-assets.githubusercontent.com/download?signature=secret"}]},
         {:done, state.ref}
       ]}
    end

    def recv(%{sent: false} = state, 0, _timeout) do
      {:ok, %{state | sent: true},
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-length", "7"}]},
         {:data, state.ref, "payload"},
         {:done, state.ref}
       ]}
    end

    def close(state), do: {:ok, state}
  end

  defmodule DirectMint do
    defdelegate connect(scheme, address, port, options), to: RedirectMint
    defdelegate request(state, method, target, headers, body), to: RedirectMint

    def recv(state, 0, timeout),
      do: RedirectMint.recv(%{state | host: "release-assets.githubusercontent.com"}, 0, timeout)

    defdelegate close(state), to: RedirectMint
  end

  defmodule BatchedMint do
    defdelegate connect(scheme, address, port, options), to: RedirectMint
    defdelegate request(state, method, target, headers, body), to: RedirectMint

    def recv(state, 0, _timeout) do
      {:ok, %{state | sent: true},
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-length", "80000"}]},
         {:data, state.ref, String.duplicate("a", 40_000)},
         {:data, state.ref, String.duplicate("b", 40_000)},
         {:done, state.ref}
       ]}
    end

    defdelegate close(state), to: RedirectMint
  end

  defmodule UnsafeRedirectMint do
    defdelegate connect(scheme, address, port, options), to: RedirectMint
    defdelegate request(state, method, target, headers, body), to: RedirectMint

    def recv(state, 0, _timeout) do
      {:ok, %{state | sent: true},
       [
         {:status, state.ref, 302},
         {:headers, state.ref, [{"location", "https://evil.example/download"}]},
         {:done, state.ref}
       ]}
    end

    defdelegate close(state), to: RedirectMint
  end
end
