defmodule ForgeGitHub.ClientGraphQLDeadlineTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Client, Error, RequestGate}

  setup {Req.Test, :verify_on_exit!}

  test "an exhausted absolute deadline returns timeout before DNS or HTTP" do
    stub = stub_name()
    parent = self()
    Req.Test.stub(stub, fn _conn -> flunk("exhausted deadline reached HTTP") end)

    opts =
      client_opts(stub,
        deadline_monotonic_ms: System.monotonic_time(:millisecond) - 1,
        resolver: fn "api.github.com" ->
          send(parent, :resolver_called)
          {:ok, [{140, 82, 114, 5}]}
        end
      )

    assert {:error, %Error{kind: :timeout}} =
             Client.pull_graphql_request("token", %{"query" => "query { viewer { id } }"}, opts)

    refute_receive :resolver_called
  end

  test "a shorter absolute deadline reaches DNS and bounds the transport" do
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 3_000

    opts = [
      gate_key: {:github_installation, System.unique_integer([:positive])},
      deadline_monotonic_ms: deadline,
      resolver: fn "api.github.com" ->
        send(parent, :resolver_called)
        {:ok, [{140, 82, 114, 5}]}
      end,
      transport_api: __MODULE__.DeadlineMint
    ]

    assert {:ok, %{"data" => %{}}} =
             Client.pull_graphql_request("token", %{"query" => "query { viewer { id } }"}, opts)

    assert_receive :resolver_called
    assert_receive {:transport_send_timeout, timeout}
    assert timeout in 1..3_000
  end

  test "waiting for the installation gate cannot reset the caller deadline" do
    stub = stub_name()
    parent = self()
    gate_key = {:github_installation, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn _conn -> flunk("expired post-gate budget reached HTTP") end)

    holder =
      Task.async(fn ->
        RequestGate.run(gate_key, fn ->
          send(parent, :gate_held)

          receive do
            :release_gate -> :ok
          end
        end)
      end)

    assert_receive :gate_held
    deadline = System.monotonic_time(:millisecond) + 2_300

    caller =
      Task.async(fn ->
        Client.pull_graphql_request(
          "token",
          %{"query" => "query { viewer { id } }"},
          client_opts(stub,
            gate_key: gate_key,
            deadline_monotonic_ms: deadline,
            resolver: fn "api.github.com" ->
              send(parent, {:delayed_resolver_started, self()})
              Process.sleep(1_700)
              send(parent, :delayed_resolver_finished)
              {:ok, [{140, 82, 114, 5}]}
            end
          )
        )
      end)

    Process.sleep(900)
    send(holder.pid, :release_gate)
    assert :ok = Task.await(holder)

    assert {:error, %Error{kind: :timeout}} = Task.await(caller, 4_000)
    assert_receive {:delayed_resolver_started, resolver_pid}
    resolver_monitor = Process.monitor(resolver_pid)
    assert_receive {:DOWN, ^resolver_monitor, :process, ^resolver_pid, _reason}, 500
    refute_receive :delayed_resolver_finished
  end

  test "too-short, malformed, duplicate, and non-GraphQL deadline options fail before HTTP" do
    stub = stub_name()
    Req.Test.stub(stub, fn _conn -> flunk("invalid deadline reached HTTP") end)
    future = System.monotonic_time(:millisecond) + 4_000

    assert {:error, %Error{kind: :timeout}} =
             Client.pull_graphql_request(
               "token",
               %{"query" => "query { viewer { id } }"},
               client_opts(stub, deadline_monotonic_ms: future - 2_100)
             )

    assert {:error, %Error{kind: :invalid_request}} =
             Client.pull_graphql_request(
               "token",
               %{"query" => "query { viewer { id } }"},
               client_opts(stub, deadline_monotonic_ms: "later")
             )

    duplicate_opts =
      client_opts(stub, deadline_monotonic_ms: future) ++ [deadline_monotonic_ms: future + 1]

    assert {:error, %Error{kind: :invalid_request}} =
             Client.pull_graphql_request(
               "token",
               %{"query" => "query { viewer { id } }"},
               duplicate_opts
             )

    assert {:error, %Error{kind: :invalid_request}} =
             Client.request(
               "token",
               :get,
               "/user",
               client_opts(stub, deadline_monotonic_ms: future)
             )
  end

  defp client_opts(stub, overrides) do
    Keyword.merge(
      [
        plug: {Req.Test, stub},
        gate_key: {:github_installation, System.unique_integer([:positive])}
      ],
      overrides
    )
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defmodule DeadlineMint do
    def connect(:https, address, 443, options) do
      owner = Process.get(:"$callers") |> List.last()
      send_timeout = options |> Keyword.fetch!(:transport_opts) |> Keyword.fetch!(:send_timeout)
      send(owner, {:transport_send_timeout, send_timeout})
      {:ok, %{address: address, ref: nil}}
    end

    def request(state, "POST", "/graphql", _headers, body) when is_binary(body) do
      reference = make_ref()
      {:ok, %{state | ref: reference}, reference}
    end

    def recv(state, 0, _timeout) do
      {:ok, state,
       [
         {:status, state.ref, 200},
         {:headers, state.ref, [{"content-type", "application/json"}]},
         {:data, state.ref, JSON.encode!(%{"data" => %{}})},
         {:done, state.ref}
       ]}
    end

    def close(state), do: {:ok, state}
  end
end
