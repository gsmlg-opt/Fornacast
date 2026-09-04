defmodule ForgeImports.RecoverySupervisorTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    Persistence,
    Reconciler,
    RecoverySupervisor,
    RepositoryItem,
    Scheduler
  }

  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @now ~U[2026-08-25 10:00:00Z]
  @pat "github_pat_recovery_scheduling_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<9>>, 32)}}

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      ForgeImports.RecoveryTestHelper.mark_sandbox_owner!()
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    run = running_run_fixture(actor, identity)
    item = queued_item_fixture(run, actor)
    attempt_fixture(item)

    %{actor: actor, identity: identity, run: run, item: item}
  end

  test "startup reconciliation claims a durable staging_metadata item", context do
    mark_staging_metadata!(context.item, context.actor)

    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.StartupRecoverySupervisor,
       task_supervisor: __MODULE__.StartupTaskSupervisor,
       reconciler_name: __MODULE__.StartupReconciler,
       enabled: true,
       interval_ms: 60_000,
       max_concurrency: 2,
       batch_size: 10,
       lease_seconds: 60,
       repository_worker: __MODULE__.ClaimProbeWorker,
       repository_worker_options: [test_pid: self()]}
    )

    assert_receive {:worker_claimed, item_id, owner}, 2_000
    assert item_id == context.item.id
    assert is_binary(owner)
    assert String.starts_with?(owner, "github-import-")

    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "task supervisor max_children matches configured concurrency", _context do
    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.ConcurrencyRecoverySupervisor,
       task_supervisor: __MODULE__.ConcurrencyTaskSupervisor,
       reconciler_name: __MODULE__.ConcurrencyReconciler,
       enabled: false,
       max_concurrency: 3}
    )

    assert eventually(fn ->
             is_pid(Process.whereis(__MODULE__.ConcurrencyTaskSupervisor))
           end)

    tasks =
      for index <- 1..3 do
        Task.Supervisor.async_nolink(__MODULE__.ConcurrencyTaskSupervisor, fn ->
          Process.sleep(200)
          index
        end)
      end

    assert_raise RuntimeError, fn ->
      Task.Supervisor.async_nolink(__MODULE__.ConcurrencyTaskSupervisor, fn -> :overflow end)
    end

    Enum.each(tasks, &Task.await(&1, 1_000))
    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "reconciler pair restart keeps durable item state and resumes scheduling", context do
    mark_staging_metadata!(context.item, context.actor)

    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.RestartRecoverySupervisor,
       task_supervisor: __MODULE__.RestartTaskSupervisor,
       reconciler_name: __MODULE__.RestartReconciler,
       enabled: true,
       interval_ms: 60_000,
       max_concurrency: 1,
       batch_size: 10,
       lease_seconds: 60,
       repository_worker: __MODULE__.BlockingWorker,
       repository_worker_options: [test_pid: self()]}
    )

    assert_receive {:worker_started, item_id, worker_pid}, 2_000
    assert item_id == context.item.id

    old_reconciler = Process.whereis(__MODULE__.RestartReconciler)
    old_task_supervisor = Process.whereis(__MODULE__.RestartTaskSupervisor)
    assert is_pid(old_reconciler)
    assert is_pid(old_task_supervisor)

    Process.exit(old_reconciler, :kill)

    assert eventually(fn ->
             case Process.whereis(__MODULE__.RestartReconciler) do
               pid when is_pid(pid) -> pid != old_reconciler
               _ -> false
             end
           end)

    assert Process.whereis(__MODULE__.RestartTaskSupervisor) != old_task_supervisor
    refute Process.alive?(worker_pid)

    assert %RepositoryItem{state: :staging_metadata, lease_owner: nil} =
             Repo.get!(RepositoryItem, context.item.id)

    send(Process.whereis(__MODULE__.RestartReconciler), :tick)

    assert_receive {:worker_started, ^item_id, _restarted_pid}, 2_000
    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "Scheduler claimable helpers match reconciler query surface", context do
    mark_staging_metadata!(context.item, context.actor)
    now = DateTime.utc_now(:second)

    assert Scheduler.claimable_item_ids(now, 10) ==
             Reconciler.runnable_repository_item_ids(10, now)

    assert context.item.id in Scheduler.claimable_item_ids(now, 10)
  end

  defmodule ClaimProbeWorker do
    def stage(item_id, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:worker_claimed, item_id, Keyword.fetch!(opts, :owner)}
      )

      {:ok, :busy}
    end
  end

  defmodule BlockingWorker do
    def stage(item_id, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:worker_started, item_id, self()})

      receive do
        :release -> {:ok, :ignored}
      after
        5_000 -> {:ok, :ignored}
      end
    end
  end

  defp mark_staging_metadata!(item, actor) do
    shadow = importing_shadow_fixture!(actor, item)
    staged_storage_path = ForgeRepos.absolute_storage_path(shadow)

    assert {1, _} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :staging_metadata,
                 hidden_repository_id: shadow.id,
                 staged_storage_path: staged_storage_path,
                 checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"},
                 source_git: %{
                   "empty" => false,
                   "default_branch" => "main",
                   "refs" => 1,
                   "bytes" => 10,
                   "lfs_detected" => false,
                   "submodules_detected" => false,
                   "scan_truncated" => false
                 },
                 updated_at: @now
               ]
             )

    Repo.get!(RepositoryItem, item.id)
  end

  defp importing_shadow_fixture!(actor, item) do
    %Repository{}
    |> Repository.import_changeset(%{
      owner_user_id: actor.id,
      slug: "shadow-#{item.id}-#{System.unique_integer([:positive])}",
      name: "Shadow #{item.id}",
      visibility: :private,
      storage_path: "@test/shadow-#{item.id}.git",
      lifecycle: :importing,
      generation: 1
    })
    |> Repo.insert!()
  end

  defp running_run_fixture(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_800_000_101,
        source_owner_login: "acme",
        source_repository_github_id: 9_800_000_101,
        source_repository_full_name: "acme/demo",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: request_metadata()
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()
  end

  defp queued_item_fixture(run, actor) do
    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: 9_200_000_001,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: "demo",
      destination_visibility: :private,
      state: :queued,
      attempt_count: 1
    })
    |> unwrap!()
  end

  defp attempt_fixture(item) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: @now
    })
    |> Repo.insert!()

    item
  end

  defp identity_fixture(actor) do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 81_001,
          login: "recovery-actor",
          avatar_url: nil,
          profile_url: "https://github.com/recovery-actor"
        },
        @now
      )

    {:ok, linked} = ForgeAccounts.link_github_identity(actor, identity)
    linked
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      username: "recovery-#{suffix}",
      email: "recovery-#{suffix}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, %Ecto.Changeset{} = changeset}) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

  defp request_metadata do
    %{
      "request_id" => "recovery-supervisor-#{System.unique_integer([:positive])}",
      "operation_id" => "recovery-supervisor-operation-#{System.unique_integer([:positive])}",
      "ip_address" => "203.0.113.90",
      "user_agent" => "forge-imports-test"
    }
  end

  defp eventually(fun, attempts \\ 80)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp reset_database! do
    Fornacast.DataCase.reset_database!()
  rescue
    UndefinedFunctionError -> :ok
  end
end
