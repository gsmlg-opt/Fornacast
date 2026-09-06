defmodule ForgeGitHub.LFS.TransportTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.LFS.Transport

  test "pins a public address while retaining the action hostname for TLS and Host" do
    address = {203, 0, 114, 10}
    parent = self()

    assert {:ok, %{status: 200}, "payload"} =
             Transport.request(
               :get,
               "https://objects.example.test/object?signature=secret",
               [{"authorization", "Signed secret"}],
               {:download, fn chunk, state -> {:ok, state <> chunk} end, "", 7},
               resolver: fn "objects.example.test" -> {:ok, [address]} end,
               transport_api: __MODULE__.DownloadMint,
               test_pid: parent
             )

    assert_received {:connect, :https, ^address, 443, options}
    assert options[:hostname] == "objects.example.test"
    assert options[:transport_opts][:verify] == :verify_peer
    assert_received {:request, "GET", "/object?signature=secret", headers, nil}
    assert {"host", "objects.example.test"} in headers
    assert {"authorization", "Signed secret"} in headers
    assert_received :closed
  end

  test "streams an exact upload without buffering its source" do
    reader = fn
      _length, [chunk | rest] -> {:ok, chunk, rest}
      _length, [] -> {:eof, []}
    end

    assert {:ok, %{status: 200}, []} =
             Transport.request(
               :put,
               "https://upload.example.test/object",
               [{"content-type", "application/octet-stream"}],
               {:upload, reader, ["pay", "load"], 7},
               transport_options(__MODULE__.UploadMint)
             )

    assert_received {:request, "PUT", "/object", headers, :stream}
    assert {"content-length", "7"} in headers
    assert_received {:upload_chunk, "pay"}
    assert_received {:upload_chunk, "load"}
    assert_received {:upload_chunk, :eof}
  end

  test "lets a staging consumer pull bounded chunks and verifies the final digest" do
    oid = :crypto.hash(:sha256, "payload") |> Base.encode16(case: :lower)

    consumer = fn reader, source ->
      assert {:ok, "pay", source} = reader.(source, length: 3, read_timeout: 1_000)
      assert {:ok, "load", source} = reader.(source, length: 4, read_timeout: 1_000)
      assert {:eof, source} = reader.(source, length: 4, read_timeout: 1_000)
      {:ok, :staged, source}
    end

    assert {:ok, %{status: 200}, {:ok, :staged}} =
             Transport.request(
               :get,
               "https://objects.example.test/object",
               [],
               {:consume_download, consumer, 7, oid},
               transport_options(__MODULE__.DownloadMint)
             )
  end

  test "rejects a non-public resolution before opening a socket" do
    assert {:error, %Transport.Error{kind: :unsafe_host}} =
             Transport.request(
               :get,
               "https://objects.example.test/object",
               [],
               {:buffer, nil, 65_536},
               resolver: fn _host -> {:ok, [{127, 0, 0, 1}]} end,
               transport_api: __MODULE__.DownloadMint,
               test_pid: self()
             )

    refute_received {:connect, _, _, _, _}
  end

  test "stops a download before delivering more than the declared object size" do
    assert {:error, %Transport.Error{kind: :integrity_mismatch}, ""} =
             Transport.request(
               :get,
               "https://objects.example.test/object",
               [],
               {:download, fn chunk, state -> {:ok, state <> chunk} end, "", 3},
               transport_options(__MODULE__.DownloadMint)
             )
  end

  defp transport_options(api) do
    [
      resolver: fn _host -> {:ok, [{203, 0, 114, 10}]} end,
      transport_api: api,
      test_pid: self()
    ]
  end

  defmodule DownloadMint do
    def connect(scheme, address, port, options) do
      send(owner(), {:connect, scheme, address, port, options})
      {:ok, %{owner: owner(), ref: nil, sent?: false}}
    end

    def request(state, method, target, headers, body) do
      ref = make_ref()
      send(state.owner, {:request, method, target, headers, body})
      {:ok, %{state | ref: ref}, ref}
    end

    def recv(%{sent?: false} = state, 0, _timeout) do
      {:ok, %{state | sent?: true},
       [
         {:status, state.ref, 200},
         {:headers, state.ref,
          [{"content-type", "application/octet-stream"}, {"content-length", "7"}]},
         {:data, state.ref, "payload"},
         {:done, state.ref}
       ]}
    end

    def close(state) do
      send(state.owner, :closed)
      {:ok, state}
    end

    defp owner do
      case Process.get(:"$callers", []) do
        [owner | _rest] -> owner
        [] -> self()
      end
    end
  end

  defmodule UploadMint do
    defdelegate connect(scheme, address, port, options), to: DownloadMint

    def request(state, method, target, headers, body) do
      ref = make_ref()
      send(state.owner, {:request, method, target, headers, body})
      {:ok, %{state | ref: ref}, ref}
    end

    def stream_request_body(state, _reference, chunk) do
      send(state.owner, {:upload_chunk, chunk})
      {:ok, state}
    end

    def recv(%{sent?: false} = state, 0, _timeout) do
      {:ok, %{state | sent?: true},
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-length", "0"}]},
         {:done, state.ref}
       ]}
    end

    defdelegate close(state), to: DownloadMint
  end
end
