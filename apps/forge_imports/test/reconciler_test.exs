defmodule ForgeImports.ReconcilerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, Reconciler, RepositoryItem, Scheduler}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @now ~U[2026-08-25 10:00:00Z]
  @pat "github_pat_reconciler_recovery_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<8>>, 32)}}

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

  test "bounded concurrency keeps only configured worker tasks active", context do
    second = queued_item_fixture(context.run, context.actor, 9_200_000_002, "demo-two")
    third = queued_item_fixture(context.run, context.actor, 9_200_000_003, "demo-three")
    attempt_fixture(second)
    attempt_fixture(third)
    mark_staging_metadata!(context.item, context.actor)
    mark_staging_metadata!(second, context.actor)
    mark_staging_metadata!(third, context.actor)

    start_supervised!({Task.Supervisor, name: __MODULE__.BoundedTaskSupervisor, max_children: 2})

    start_supervised!(
      {Reconciler,
       name: __MODULE__.BoundedReconciler,
       enabled: true,
       interval_ms: 60_000,
       max_concurrency: 2,
       batch_size: 10,
       task_supervisor: __MODULE__.BoundedTaskSupervisor,
       repository_worker: __MODULE__.CountingWorker,
       repository_worker_options: [test_pid: self()]}
    )

    send(Process.whereis(__MODULE__.BoundedReconciler), :tick)

    assert_receive {:worker_started, _first_id, first_pid}, 2_000
    assert_receive {:worker_started, _second_id, _second_pid}, 2_000
    refute_receive {:worker_started, _, _}, 200

    assert %{active: 2} = Supervisor.count_children(__MODULE__.BoundedTaskSupervisor)

    send(first_pid, :release)
    assert_receive {:worker_started, _third_id, _third_pid}, 2_000
  end

  test "expired item leases are claimable and live leases are skipped", context do
    mark_staging_metadata!(context.item, context.actor)

    assert context.item.id in Scheduler.claimable_item_ids(@now, 10)

    live_until = DateTime.add(@now, 120, :second)

    assert {1, _} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^context.item.id),
               set: [lease_owner: "live-owner", lease_expires_at: live_until]
             )

    refute context.item.id in Scheduler.claimable_item_ids(@now, 10)

    assert {1, _} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^context.item.id),
               set: [
                 lease_owner: "expired-owner",
                 lease_expires_at: DateTime.add(@now, -1, :second)
               ]
             )

    assert context.item.id in Scheduler.claimable_item_ids(@now, 10)
  end

  test "task completion does not treat worker return values as SQL completion", context do
    mark_staging_metadata!(context.item, context.actor)
    before = Repo.get!(RepositoryItem, context.item.id)

    start_supervised!({Task.Supervisor, name: __MODULE__.ReturnValueTaskSupervisor, max_children: 1})

    start_supervised!(
      {Reconciler,
       name: __MODULE__.ReturnValueReconciler,
       enabled: true,
       interval_ms: 60_000,
       max_concurrency: 1,
       batch_size: 10,
       task_supervisor: __MODULE__.ReturnValueTaskSupervisor,
       repository_worker: __MODULE__.FakePublishedWorker,
       repository_worker_options: [test_pid: self()]}
    )

    send(Process.whereis(__MODULE__.ReturnValueReconciler), :tick)
    assert_receive {:fake_published, item_id}, 2_000
    assert item_id == context.item.id

    assert eventually(fn ->
             item = Repo.get!(RepositoryItem, context.item.id)
             item.state == before.state and item.lease_owner == before.lease_owner
           end)
  end

  test "a crashed worker task leaves durable SQL state for recovery", context do
    mark_staging_metadata!(context.item, context.actor)

    start_supervised!({Task.Supervisor, name: __MODULE__.CrashTaskSupervisor, max_children: 1})

    start_supervised!(
      {Reconciler,
       name: __MODULE__.CrashReconciler,
       enabled: true,
       interval_ms: 60_000,
       max_concurrency: 1,
       batch_size: 10,
       task_supervisor: __MODULE__.CrashTaskSupervisor,
       repository_worker: __MODULE__.CrashWorker,
       repository_worker_options: [test_pid: self()]}
    )

    send(Process.whereis(__MODULE__.CrashReconciler), :tick)
    assert_receive {:worker_started, worker_pid}, 2_000
    assert is_pid(worker_pid)

    Process.exit(worker_pid, :kill)

    assert eventually(fn ->
             item = Repo.get!(RepositoryItem, context.item.id)
             item.state == :staging_metadata and is_nil(item.lease_owner)
           end)

    send(Process.whereis(__MODULE__.CrashReconciler), :tick)
    assert_receive {:worker_started, _restarted_pid}, 2_000
  end

  defmodule CountingWorker do
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

  defmodule FakePublishedWorker do
    def stage(item_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:fake_published, item_id})
      {:ok, %RepositoryItem{id: item_id, state: :published}}
    end
  end

  defmodule CrashWorker do
    def stage(_item_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:worker_started, self()})
      Process.sleep(:infinity)
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
        source_owner_github_id: 8_800_000_102,
        source_owner_login: "acme",
        source_repository_github_id: 9_800_000_102,
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

  defp queued_item_fixture(run, actor, github_repository_id \\ 9_200_000_001, slug \\ "demo") do
    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/#{slug}",
      source_name: slug,
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: slug,
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
          github_user_id: 81_002,
          login: "reconciler-actor",
          avatar_url: nil,
          profile_url: "https://github.com/reconciler-actor"
        },
        @now
      )

    {:ok, linked} = ForgeAccounts.link_github_identity(actor, identity)
    linked
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      username: "reconciler-#{suffix}",
      email: "reconciler-#{suffix}@example.test",
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
      "request_id" => "reconciler-#{System.unique_integer([:positive])}",
      "operation_id" => "reconciler-operation-#{System.unique_integer([:positive])}",
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
