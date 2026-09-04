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

  test "invalidation rejects stale in-flight results and revocation is terminal" do
    parent = self()
    now = ~U[2026-09-04 10:00:00Z]

    broker =
      start_broker!(
        now: fn -> now end,
        fetcher: fn _installation_id, _scope ->
          send(parent, {:fetch_started, self()})
          receive do: (:release -> token("stale", DateTime.add(now, 3_600)))
        end
      )

    caller = Task.async(fn -> InstallationTokenBroker.fetch(broker, 44) end)
    assert_receive {:fetch_started, fetch_task}
    assert :ok = InstallationTokenBroker.invalidate(broker, 44)
    send(fetch_task, :release)
    assert {:error, :invalidated} = Task.await(caller)

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
