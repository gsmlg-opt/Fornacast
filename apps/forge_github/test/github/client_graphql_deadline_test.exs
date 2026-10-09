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
          owner_monitor = Process.monitor(parent)
          send(parent, :gate_held)

          receive do
            :release_gate -> :ok
            {:DOWN, ^owner_monitor, :process, ^parent, _reason} -> :ok
          end

          Process.demonitor(owner_monitor, [:flush])
          :ok
        end)
      end)

    caller =
      Task.async(fn ->
        receive do: (:start_caller -> :ok)
        deadline = System.monotonic_time(:millisecond) + 3_000
        send(parent, {:caller_deadline, deadline})

        Client.pull_graphql_request(
          "token",
          %{"query" => "query { viewer { id } }"},
          client_opts(stub,
            gate_key: gate_key,
            deadline_monotonic_ms: deadline,
            resolver: fn "api.github.com" ->
              send(parent, :resolver_called)
              {:ok, [{140, 82, 114, 5}]}
            end
          )
        )
      end)

    try do
      assert_receive :gate_held, 5_000
      :erlang.trace(caller.pid, true, [:procs, :send, :set_on_spawn])
      send(caller.pid, :start_caller)

      assert_receive {:caller_deadline, deadline}, 5_000
      caller_pid = caller.pid
      assert_receive {:trace, ^caller_pid, :spawn, lock_worker, _mfa}, 5_000
      assert_receive {:trace, ^caller_pid, :spawn, watchdog, _mfa}, 5_000
      :erlang.suspend_process(caller_pid)

      send(holder.pid, :release_gate)
      assert :ok = Task.await(holder)

      assert_receive {:trace, ^lock_worker, :send, {_reference, :acquired, ^lock_worker},
                      ^caller_pid},
                     5_000

      for pid <- [caller_pid, lock_worker, watchdog], do: :erlang.trace(pid, false, [:all])

      # Keep the acquisition acknowledgement queued until the original budget is exhausted.
      timer = make_ref()
      Process.send_after(self(), timer, max(deadline - System.monotonic_time(:millisecond), 0))
      assert_receive ^timer, 5_000
      assert System.monotonic_time(:millisecond) >= deadline
      :erlang.resume_process(caller_pid)

      assert {:error, %Error{kind: :timeout}} = Task.await(caller, 5_000)
      refute_receive :resolver_called
    after
      resume_if_suspended(caller.pid)
      Task.shutdown(caller, :brutal_kill)
      send(holder.pid, :release_gate)
      Task.shutdown(holder, 5_000)
    end
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

  defp resume_if_suspended(pid) do
    if Process.info(pid, :status) == {:status, :suspended}, do: :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end

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
