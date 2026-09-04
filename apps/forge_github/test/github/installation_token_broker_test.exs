defmodule ForgeGitHub.InstallationTokenBrokerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{InstallationToken, InstallationTokenBroker}

  test "concurrent callers share one refresh and canonical equivalent scopes" do
    parent = self()
    counter = :counters.new(1, [])
    now = ~U[2026-09-04 10:00:00Z]

    broker =
      start_broker!(
        now: fn -> now end,
        fetcher: fn installation_id, scope ->
          :counters.add(counter, 1, 1)
          send(parent, {:fetch, self(), installation_id, scope})
          receive do: (:release -> token("shared", DateTime.add(now, 3_600)))
        end
      )

    callers =
      for scope <- [
            %{
              permissions: %{"issues" => "write", "contents" => "read"},
              repository_ids: [2, 1, 2]
            },
            %{repository_ids: [1, 2], permissions: %{"contents" => "read", "issues" => "write"}}
          ] do
        Task.async(fn -> InstallationTokenBroker.fetch(broker, 44, scope) end)
      end

    assert_receive {:fetch, fetch_task, 44,
                    %{
                      permissions: %{"contents" => "read", "issues" => "write"},
                      repository_ids: [1, 2]
                    }}

    refute_receive {:fetch, _, _, _}, 100
    send(fetch_task, :release)

    assert Enum.map(callers, &Task.await/1) ==
             List.duplicate(token("shared", DateTime.add(now, 3_600)), 2)

    assert token("shared", DateTime.add(now, 3_600)) ==
             InstallationTokenBroker.fetch(broker, 44, %{
               permissions: %{"contents" => "read", "issues" => "write"},
               repository_ids: [2, 1]
             })

    assert :counters.get(counter, 1) == 1
  end

  test "refreshes shortly before expiry and distinguishes defaults from explicit subsets" do
    parent = self()
    now_agent = start_supervised!({Agent, fn -> ~U[2026-09-04 10:00:00Z] end})

    broker =
      start_broker!(
        now: fn -> Agent.get(now_agent, & &1) end,
        fetcher: fn _installation_id, scope ->
          send(parent, {:scope, scope})
          token(inspect(scope), DateTime.add(Agent.get(now_agent, & &1), 600))
        end
      )

    assert %InstallationToken{} = InstallationTokenBroker.fetch(broker, 44)
    assert_receive {:scope, %{}}

    assert %InstallationToken{} =
             InstallationTokenBroker.fetch(broker, 44, %{permissions: %{}, repository_ids: []})

    assert_receive {:scope, %{permissions: %{}, repository_ids: []}}

    Agent.update(now_agent, &DateTime.add(&1, 301))
    assert %InstallationToken{} = InstallationTokenBroker.fetch(broker, 44)
    assert_receive {:scope, %{}}
  end

  test "invalidation retires the stale task and the next fetch starts a new generation" do
    parent = self()
    now = ~U[2026-09-04 10:00:00Z]
    counter = :counters.new(1, [])

    broker =
      start_broker!(
        now: fn -> now end,
        fetcher: fn _installation_id, _scope ->
          :counters.add(counter, 1, 1)
          generation = :counters.get(counter, 1)
          send(parent, {:fetch_started, generation, self()})

          receive do
            :release -> token("generation-#{generation}", DateTime.add(now, 3_600))
          end
        end
      )

    caller = Task.async(fn -> InstallationTokenBroker.fetch(broker, 44) end)
    assert_receive {:fetch_started, 1, stale_fetch_task}
    stale_monitor = Process.monitor(stale_fetch_task)
    assert :ok = InstallationTokenBroker.invalidate(broker, 44)
    assert {:error, :invalidated} = Task.await(caller)
    assert_receive {:DOWN, ^stale_monitor, :process, ^stale_fetch_task, _reason}

    fresh = Task.async(fn -> InstallationTokenBroker.fetch(broker, 44) end)
    assert_receive {:fetch_started, 2, fresh_fetch_task}
    send(fresh_fetch_task, :release)
    assert %InstallationToken{token: "generation-2"} = Task.await(fresh)

    assert :ok = InstallationTokenBroker.revoke(broker, 44)
    assert {:error, :revoked} = InstallationTokenBroker.fetch(broker, 44)
    assert :ok = InstallationTokenBroker.invalidate_unauthorized(broker, 44)
    assert {:error, :revoked} = InstallationTokenBroker.fetch(broker, 44)
  end

  test "task and cache capacities are bounded and status redacts token values" do
    parent = self()
    now = ~U[2026-09-04 10:00:00Z]

    broker =
      start_broker!(
        max_inflight: 1,
        max_entries: 1,
        now: fn -> now end,
        fetcher: fn installation_id, _scope ->
          send(parent, {:fetch, installation_id, self()})

          if installation_id == 1 do
            receive do: (:release -> token("secret-one", DateTime.add(now, 3_600)))
          else
            token("secret-#{installation_id}", DateTime.add(now, 3_600))
          end
        end
      )

    first = Task.async(fn -> InstallationTokenBroker.fetch(broker, 1) end)
    assert_receive {:fetch, 1, fetch_task}
    assert {:error, :busy} = InstallationTokenBroker.fetch(broker, 2)
    send(fetch_task, :release)
    assert %InstallationToken{} = Task.await(first)

    assert %InstallationToken{} = InstallationTokenBroker.fetch(broker, 2)
    assert_receive {:fetch, 2, _}

    status = :sys.get_status(broker) |> inspect()
    refute status =~ "secret-one"
    refute status =~ "secret-2"
    assert status =~ "cache_entries"
  end

  test "rejects oversized scopes without starting tasks" do
    broker = start_broker!(fetcher: fn _, _ -> flunk("invalid scope reached fetcher") end)

    assert {:error, :invalid_scope} =
             InstallationTokenBroker.fetch(broker, 44, %{
               repository_ids: Enum.to_list(1..501)
             })

    assert {:error, :invalid_scope} =
             InstallationTokenBroker.fetch(broker, 44, %{permissions: %{"contents" => "owner"}})
  end

  test "bounds an adversarial two hundred and first waiter on one key" do
    parent = self()
    now = ~U[2026-09-04 10:00:00Z]

    broker =
      start_broker!(
        max_waiters_per_key: 200,
        max_waiters: 200,
        now: fn -> now end,
        fetcher: fn _, _ ->
          send(parent, {:bounded_fetch, self()})
          receive do: (:release -> token("bounded-secret", DateTime.add(now, 3_600)))
        end
      )

    callers =
      for _ <- 1..201 do
        Task.async(fn ->
          result = InstallationTokenBroker.fetch(broker, 44)
          send(parent, {:bounded_result, result})
          result
        end)
      end

    assert_receive {:bounded_fetch, fetch_task}
    assert_receive {:bounded_result, {:error, :busy}}, 2_000
    refute_receive {:bounded_result, _other}, 100

    status = :sys.get_status(broker) |> inspect()
    assert status =~ "waiter_count: 200"
    refute status =~ "bounded-secret"

    send(fetch_task, :release)
    results = Enum.map(callers, &Task.await(&1, 2_000))
    assert Enum.count(results, &match?(%InstallationToken{}, &1)) == 200
    assert Enum.count(results, &(&1 == {:error, :busy})) == 1
  end

  test "caller death removes its waiter and retires an unobserved fetch" do
    parent = self()

    broker =
      start_broker!(
        fetcher: fn _, _ ->
          send(parent, {:dead_caller_fetch, self()})
          receive do: (:never -> :unexpected)
        end
      )

    caller = spawn(fn -> InstallationTokenBroker.fetch(broker, 44) end)
    assert_receive {:dead_caller_fetch, fetch_task}
    fetch_monitor = Process.monitor(fetch_task)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^fetch_monitor, :process, ^fetch_task, _reason}, 1_000

    replacement = Task.async(fn -> InstallationTokenBroker.fetch(broker, 44) end)
    assert_receive {:dead_caller_fetch, replacement_fetch}
    assert :ok = InstallationTokenBroker.invalidate(broker, 44)
    assert {:error, :invalidated} = Task.await(replacement)
    refute Process.alive?(replacement_fetch)
  end

  test "waiters expire before the public call timeout and release the task" do
    parent = self()

    broker =
      start_broker!(
        waiter_timeout_ms: 50,
        fetcher: fn _, _ ->
          send(parent, {:expiring_fetch, self()})
          receive do: (:never -> :unexpected)
        end
      )

    started_at = System.monotonic_time(:millisecond)
    caller = Task.async(fn -> InstallationTokenBroker.fetch(broker, 44) end)
    assert_receive {:expiring_fetch, fetch_task}
    fetch_monitor = Process.monitor(fetch_task)
    assert {:error, :timeout} = Task.await(caller, 1_000)
    assert System.monotonic_time(:millisecond) - started_at < 1_000
    assert_receive {:DOWN, ^fetch_monitor, :process, ^fetch_task, _reason}, 1_000

    status = :sys.get_status(broker) |> inspect()
    assert status =~ "waiter_count: 0"
    assert status =~ "inflight_entries: 0"
  end

  test "the total waiter cap applies across different cache keys" do
    parent = self()

    broker =
      start_broker!(
        max_inflight: 3,
        max_waiters_per_key: 2,
        max_waiters: 2,
        fetcher: fn installation_id, _ ->
          send(parent, {:total_cap_fetch, installation_id, self()})
          receive do: (:never -> :unexpected)
        end
      )

    first = Task.async(fn -> InstallationTokenBroker.fetch(broker, 1) end)
    second = Task.async(fn -> InstallationTokenBroker.fetch(broker, 2) end)

    started =
      for _ <- 1..2 do
        assert_receive {:total_cap_fetch, installation_id, _}
        installation_id
      end

    assert Enum.sort(started) == [1, 2]
    assert {:error, :busy} = InstallationTokenBroker.fetch(broker, 3)
    assert :ok = InstallationTokenBroker.invalidate(broker, 1)
    assert :ok = InstallationTokenBroker.invalidate(broker, 2)
    assert {:error, :invalidated} = Task.await(first)
    assert {:error, :invalidated} = Task.await(second)
  end

  defp start_broker!(opts) do
    task_supervisor = Module.concat(__MODULE__, "Tasks#{System.unique_integer([:positive])}")
    start_supervised!({Task.Supervisor, name: task_supervisor, max_children: 2})

    name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")

    start_supervised!(
      {InstallationTokenBroker,
       Keyword.merge([name: name, task_supervisor: task_supervisor], opts)}
    )

    name
  end

  defp token(value, expires_at) do
    %InstallationToken{token: value, expires_at: expires_at, permissions: %{}}
  end
end
