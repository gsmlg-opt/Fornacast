defmodule ForgeImports.DiscoveryDispatchTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeImports.{ImportRun, Reconciler, RecoverySupervisor, RunView}
  alias ForgeImports.GitHub.{Repository, User}
  alias Fornacast.Repo

  @saved_pat "opaque-saved-value-QWERTYUIOP"
  @one_time_pat "opaque-onetime-value-ASDFGHJKL"

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()

    {:ok, account} =
      ForgeAccounts.save_github_account(
        actor,
        %{
          github_user_id: 79_001,
          login: "saved-dispatch",
          avatar_url: nil,
          profile_url: "https://github.com/saved-dispatch"
        },
        @saved_pat,
        request_metadata()
      )

    {:ok, state} =
      Agent.start_link(fn ->
        %{active: 0, max_active: 0, started: 0, completed: 0}
      end)

    %{account: account, actor: actor, state: state}
  end

  test "async admissions coalesce behind one serial reconciler scan", %{
    account: account,
    actor: actor,
    state: state
  } do
    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.RecoverySupervisor,
       task_supervisor: __MODULE__.TaskSupervisor,
       reconciler_name: __MODULE__.Reconciler,
       enabled: true,
       interval_ms: 60_000,
       batch_size: 100,
       lease_seconds: 60,
       client: __MODULE__.SerialClient,
       client_options: [state: state, test_pid: self()]}
    )

    assert {:ok, %RunView{id: first_run_id, state: :discovering}} =
             create_one_time(actor, 1, state)

    assert_receive {:repository_started, provider_pid}, 2_000

    remaining_run_ids =
      for index <- 2..10 do
        result =
          if rem(index, 2) == 0 do
            create_saved(actor, account.identity_id, index, state)
          else
            create_one_time(actor, index, state)
          end

        assert {:ok, %RunView{id: run_id, state: :discovering}} = result
        run_id
      end

    for _ <- 1..50, do: ForgeImports.Reconciler.kick(__MODULE__.Reconciler)

    assert %{active: 1, max_active: 1, started: 1} = Agent.get(state, & &1)
    assert %{active: 1} = Supervisor.count_children(__MODULE__.TaskSupervisor)

    assert {:error, :max_children} =
             Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fn -> :ok end)

    send(provider_pid, :release_repository)

    run_ids = [first_run_id | remaining_run_ids]

    assert eventually(fn ->
             Enum.all?(run_ids, fn run_id ->
               match?(
                 {:ok, %RunView{state: :awaiting_resolution}},
                 ForgeImports.get_run(actor, run_id)
               )
             end)
           end)

    assert %{active: 0, max_active: 1, started: 10, completed: 10} =
             Agent.get(state, & &1)

    assert 5 ==
             Repo.aggregate(
               from(run in ImportRun, where: run.credential_source == :saved),
               :count
             )

    assert 5 ==
             Repo.aggregate(
               from(run in ImportRun, where: run.credential_source == :one_time),
               :count
             )
  end

  test "a full task supervisor defers a scan without restarting the reconciler", %{
    account: account,
    actor: actor,
    state: state
  } do
    start_supervised!({Task.Supervisor, name: __MODULE__.CapacityTaskSupervisor, max_children: 1})

    assert {:ok, blocker} =
             Task.Supervisor.start_child(__MODULE__.CapacityTaskSupervisor, fn ->
               receive do
                 :release_capacity -> :ok
               end
             end)

    reconciler =
      start_supervised!(
        {Reconciler,
         name: __MODULE__.CapacityReconciler,
         enabled: true,
         interval_ms: 60_000,
         task_supervisor: __MODULE__.CapacityTaskSupervisor,
         client: __MODULE__.SerialClient,
         client_options: [state: state, test_pid: self()]},
        restart: :temporary
      )

    Process.sleep(100)
    assert Process.alive?(reconciler)

    assert {:ok, %RunView{id: run_id, state: :discovering}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "sourcehub/queue-11",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :async,
               reconciler: __MODULE__.CapacityReconciler,
               client: __MODULE__.SerialClient,
               client_options: [state: state, test_pid: self()]
             )

    send(blocker, :release_capacity)

    assert eventually(fn ->
             Supervisor.count_children(__MODULE__.CapacityTaskSupervisor).active == 0
           end)

    Reconciler.kick(__MODULE__.CapacityReconciler)

    assert_receive {:repository_started, provider_pid}, 2_000
    send(provider_pid, :release_repository)

    assert eventually(fn ->
             match?(
               {:ok, %RunView{state: :awaiting_resolution}},
               ForgeImports.get_run(actor, run_id)
             )
           end)

    assert Process.alive?(reconciler)
  end

  defmodule SerialClient do
    def authenticated_user(_pat, _opts) do
      {:ok,
       %User{
         id: 79_002,
         login: "onetime-dispatch",
         name: nil,
         avatar_url: nil,
         html_url: "https://github.com/onetime-dispatch"
       }}
    end

    def repository(_pat, owner, repository, opts) do
      state = Keyword.fetch!(opts, :state)

      started =
        Agent.get_and_update(state, fn current ->
          active = current.active + 1

          {current.started + 1,
           %{
             current
             | active: active,
               max_active: max(current.max_active, active),
               started: current.started + 1
           }}
        end)

      try do
        if started == 1 do
          send(Keyword.fetch!(opts, :test_pid), {:repository_started, self()})

          receive do
            :release_repository -> :ok
          after
            5_000 -> raise "repository test gate timed out"
          end
        else
          Process.sleep(20)
        end

        {:ok, repository(owner, repository)}
      after
        Agent.update(state, fn current ->
          %{current | active: current.active - 1, completed: current.completed + 1}
        end)
      end
    end

    defp repository(owner, name) do
      suffix = name |> String.split("-") |> List.last() |> String.to_integer()

      %Repository{
        id: 99_000 + suffix,
        owner_id: 89_000,
        name: name,
        full_name: "#{owner}/#{name}",
        owner_login: owner,
        description: nil,
        visibility: :private,
        default_branch: "main",
        has_issues: true,
        allow_merge_commit: true,
        fork: false,
        archived: false,
        html_url: "https://github.com/#{owner}/#{name}",
        updated_at: ~U[2026-08-26 09:00:00Z],
        pushed_at: ~U[2026-08-26 09:00:00Z]
      }
    end
  end

  defp create_one_time(actor, index, state) do
    ForgeImports.create_repository_discovery(
      actor,
      %{
        source: "sourcehub/queue-#{index}",
        credential_source: :one_time,
        pat: @one_time_pat
      },
      request_metadata(),
      dispatch: :async,
      reconciler: __MODULE__.Reconciler,
      client: __MODULE__.SerialClient,
      client_options: [state: state, test_pid: self()]
    )
  end

  defp create_saved(actor, identity_id, index, state) do
    ForgeImports.create_repository_discovery(
      actor,
      %{
        source: "sourcehub/queue-#{index}",
        credential_source: :saved,
        github_identity_id: identity_id
      },
      request_metadata(),
      dispatch: :async,
      reconciler: __MODULE__.Reconciler,
      client: __MODULE__.SerialClient,
      client_options: [state: state, test_pid: self()]
    )
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "dispatch-user-#{suffix}",
        email: "dispatch-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    actor
  end

  defp request_metadata do
    suffix = System.unique_integer([:positive])

    %{
      "request_id" => "dispatch-request-#{suffix}",
      "operation_id" => "dispatch-operation-#{suffix}",
      "ip_address" => "203.0.113.10",
      "user_agent" => "Fornacast dispatch test"
    }
  end

  defp eventually(fun, attempts \\ 160)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "api_keys",
          "ssh_keys",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
