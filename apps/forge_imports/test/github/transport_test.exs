defmodule ForgeImports.GitHub.TransportTest do
  use ExUnit.Case, async: true

  alias ForgeImports.GitHub.Transport

  test "connects to the pinned address with GitHub hostname verification and closes the socket" do
    address = {140, 82, 114, 5}

    request =
      request(address, __MODULE__.SuccessMint)
      |> Req.Request.put_header("host", "attacker.example")

    assert {^request, %Req.Response{status: 200, body: ~s({"ok":true})}} =
             Transport.run(request)

    assert_receive {:connect, :https, ^address, 443, options}
    assert options[:hostname] == "api.github.com"
    assert options[:mode] == :passive
    assert options[:protocols] == [:http1]
    assert options[:log] == false
    assert options[:max_header_list_size] == 65_536
    assert options[:transport_opts][:verify] == :verify_peer
    assert is_list(options[:transport_opts][:cacerts])
    assert options[:transport_opts][:timeout] in 1..5_000

    assert_receive {:request, "GET", "/user?mode=test", headers, nil}
    assert {"host", "api.github.com"} in headers
    assert {"authorization", "Bearer github_pat_transport_secret"} in headers
    assert_receive :closed
  end

  test "enforces a total deadline and passes only the remaining time to each receive" do
    request =
      request(
        {0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154},
        __MODULE__.DeadlineMint,
        timeout: 500
      )

    started_at = System.monotonic_time(:millisecond)

    assert {^request, %Transport.Error{kind: :timeout} = error} = Transport.run(request)

    assert System.monotonic_time(:millisecond) - started_at < 750
    assert_receive {:first_recv_timeout, first_timeout}
    assert_receive {:second_recv_timeout, second_timeout}
    assert first_timeout in 1..500
    assert second_timeout in 1..first_timeout
    assert_receive :closed
    refute inspect(error) =~ "github_pat_transport_secret"
  end

  test "stops at the hard raw body cap and closes the connection" do
    request = request({140, 82, 114, 5}, __MODULE__.OversizedMint)

    assert {^request, %Transport.Error{kind: :response_too_large}} = Transport.run(request)
    assert_receive :closed
  end

  test "maps Mint failures to PAT-free exceptions and closes connected sockets" do
    request = request({140, 82, 114, 5}, __MODULE__.SecretFailureMint)

    assert {^request, %Transport.Error{kind: :receive} = error} = Transport.run(request)
    refute Exception.message(error) =~ "github_pat_transport_secret"
    refute inspect(error) =~ "github_pat_transport_secret"
    assert_receive :closed
  end

  test "rejects any request outside the fixed method and host before connecting" do
    request =
      request({140, 82, 114, 5}, __MODULE__.SuccessMint)
      |> Map.put(:url, URI.new!("https://example.com/user"))

    assert {^request, %Transport.Error{kind: :invalid_request}} = Transport.run(request)
    refute_receive {:connect, _, _, _, _}
  end

  test "tries validated addresses in order only until one connects" do
    first = {140, 82, 114, 5}
    second = {0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}
    request = request([first, second], __MODULE__.FallbackMint)

    assert {^request, %Req.Response{status: 200}} = Transport.run(request)
    assert_receive {:connect, :https, ^first, 443, _options}
    assert_receive {:connect, :https, ^second, 443, options}
    assert options[:transport_opts][:inet6]
    assert_receive {:request, "GET", "/user?mode=test", _headers, nil}
    assert_receive :closed
  end

  test "returns a bounded error after all addresses fail to connect" do
    addresses = [{140, 82, 114, 5}, {20, 205, 243, 166}]
    request = request(addresses, __MODULE__.AllFailMint)

    assert {^request, %Transport.Error{kind: :connect}} = Transport.run(request)

    for address <- addresses do
      assert_receive {:connect, :https, ^address, 443, _options}
    end

    refute_receive :closed
  end

  test "does not try another address after the total deadline is exhausted" do
    first = {140, 82, 114, 5}
    second = {20, 205, 243, 166}
    request = request([first, second], __MODULE__.SlowConnectMint, timeout: 200)

    started_at = System.monotonic_time(:millisecond)
    assert {^request, %Transport.Error{kind: :timeout}} = Transport.run(request)
    assert System.monotonic_time(:millisecond) - started_at < 500
    assert_receive {:connect, :https, ^first, 443, _options}
    refute_receive {:connect, :https, ^second, 443, _options}
    refute_receive :closed
  end

  test "never falls back to another address after connect when send or receive fails" do
    addresses = [{140, 82, 114, 5}, {20, 205, 243, 166}]

    for {mint, kind} <- [
          {__MODULE__.SendFailureMint, :send},
          {__MODULE__.ReceiveFailureMint, :receive}
        ] do
      request = request(addresses, mint)

      assert {^request, %Transport.Error{kind: ^kind}} = Transport.run(request)
      assert_receive {:connect, :https, {140, 82, 114, 5}, 443, _options}
      refute_receive {:connect, :https, {20, 205, 243, 166}, 443, _options}
      assert_receive :closed
    end
  end

  test "a blocking send is killed at the hard outer deadline" do
    _ = :public_key.cacerts_get()

    request =
      request({140, 82, 114, 5}, __MODULE__.BlockingSendMint, timeout: 20)

    started_at = System.monotonic_time(:millisecond)
    assert {^request, %Transport.Error{kind: :timeout} = error} = Transport.run(request)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 150
    assert_receive {:blocking_send_started, worker}
    worker_monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 100
    refute_receive :blocking_send_finished_late, 220
    refute inspect(error) =~ "github_pat_transport_secret"
  end

  test "a blocking close is killed at the hard outer deadline" do
    _ = :public_key.cacerts_get()

    request =
      request({140, 82, 114, 5}, __MODULE__.BlockingCloseMint, timeout: 20)

    started_at = System.monotonic_time(:millisecond)
    assert {^request, %Transport.Error{kind: :timeout} = error} = Transport.run(request)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 150
    assert_receive {:blocking_close_started, worker}
    worker_monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 100
    refute_receive :blocking_close_finished_late, 220
    refute Exception.message(error) =~ "github_pat_transport_secret"
  end

  defp request(address_or_addresses, mint, opts \\ []) do
    addresses =
      if is_list(address_or_addresses), do: address_or_addresses, else: [address_or_addresses]

    Req.new(
      method: :get,
      url: "https://api.github.com/user?mode=test",
      headers: [{"authorization", "Bearer github_pat_transport_secret"}],
      adapter: Transport
    )
    |> Req.Request.put_private(:forge_imports_github_addresses, addresses)
    |> Req.Request.put_private(:forge_imports_transport_api, mint)
    |> Req.Request.put_private(
      :forge_imports_transport_timeout,
      Keyword.get(opts, :timeout, 20_000)
    )
  end

  defmodule SuccessMint do
    def connect(scheme, address, port, options) do
      owner = owner()
      send(owner, {:connect, scheme, address, port, options})
      {:ok, %{owner: owner, ref: nil}}
    end

    def request(state, method, path, headers, body) do
      ref = make_ref()
      send(state.owner, {:request, method, path, headers, body})
      {:ok, %{state | ref: ref}, ref}
    end

    def recv(state, 0, _timeout) do
      {:ok, state,
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-type", "application/json"}]},
         {:data, state.ref, ~s({"ok":true})},
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

  defmodule DeadlineMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint

    def recv(%{stage: :second} = state, 0, timeout) do
      send(state.owner, {:second_recv_timeout, timeout})
      {:error, state, %Mint.TransportError{reason: :timeout}, []}
    end

    def recv(state, 0, timeout) do
      send(state.owner, {:first_recv_timeout, timeout})
      Process.sleep(15)
      {:ok, Map.put(state, :stage, :second), [{:status, state.ref, 200}]}
    end
  end

  defmodule OversizedMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint

    def recv(state, 0, _timeout) do
      {:ok, state,
       [
         {:status, state.ref, 200},
         {:headers, state.ref, []},
         {:data, state.ref, String.duplicate("x", 2_000_001)},
         {:done, state.ref}
       ]}
    end
  end

  defmodule SecretFailureMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint

    def recv(state, 0, _timeout) do
      {:error, state, {:wire_error, "github_pat_transport_secret"}, []}
    end
  end

  defmodule FallbackMint do
    def connect(:https, {_a, _b, _c, _d} = address, 443, options) do
      send(owner(), {:connect, :https, address, 443, options})
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    def connect(scheme, address, port, options),
      do: ForgeImports.GitHub.TransportTest.SuccessMint.connect(scheme, address, port, options)

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate recv(state, bytes, timeout), to: ForgeImports.GitHub.TransportTest.SuccessMint
    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint

    defp owner do
      case Process.get(:"$callers", []) do
        [owner | _rest] -> owner
        [] -> self()
      end
    end
  end

  defmodule AllFailMint do
    def connect(scheme, address, port, options) do
      send(owner(), {:connect, scheme, address, port, options})
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    defp owner do
      case Process.get(:"$callers", []) do
        [owner | _rest] -> owner
        [] -> self()
      end
    end
  end

  defmodule SlowConnectMint do
    def connect(scheme, address, port, options) do
      send(owner(), {:connect, scheme, address, port, options})
      Process.sleep(options[:transport_opts][:timeout] + 5)
      {:error, %Mint.TransportError{reason: :timeout}}
    end

    defp owner do
      case Process.get(:"$callers", []) do
        [owner | _rest] -> owner
        [] -> self()
      end
    end
  end

  defmodule SendFailureMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    def request(state, _method, _path, _headers, _body) do
      {:error, state, %Mint.TransportError{reason: :closed}}
    end

    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint
  end

  defmodule ReceiveFailureMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    def recv(state, 0, _timeout) do
      {:error, state, %Mint.TransportError{reason: :closed}, []}
    end

    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint
  end

  defmodule BlockingSendMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    def request(state, _method, _path, _headers, _body) do
      send(state.owner, {:blocking_send_started, self()})
      Process.sleep(200)
      send(state.owner, :blocking_send_finished_late)
      {:error, state, %Mint.TransportError{reason: :closed}}
    end

    defdelegate close(state), to: ForgeImports.GitHub.TransportTest.SuccessMint
  end

  defmodule BlockingCloseMint do
    defdelegate connect(scheme, address, port, options),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate request(state, method, path, headers, body),
      to: ForgeImports.GitHub.TransportTest.SuccessMint

    defdelegate recv(state, bytes, timeout), to: ForgeImports.GitHub.TransportTest.SuccessMint

    def close(state) do
      send(state.owner, {:blocking_close_started, self()})
      Process.sleep(200)
      send(state.owner, :blocking_close_finished_late)
      {:ok, state}
    end
  end
end
