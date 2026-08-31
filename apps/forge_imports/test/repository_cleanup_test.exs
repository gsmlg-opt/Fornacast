defmodule ForgeImports.RepositoryCleanupTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeImports.{
    CleanupOperation,
    CleanupReconciler,
    ImportAttempt,
    ImportRun,
    RecoverySupervisor,
    RepositoryItem
  }

  alias ForgeImports.RepositoryCleanup
  alias ForgeRepos.{GitWriteOperation, Repository}
  alias Fornacast.{Audit, AuditEvent, Repo}

  @moduletag :persistence

  setup context do
    keys = ~w(repository_cleanup_grace_seconds repository_cleanup_interval_ms
              repository_cleanup_deadline_ms repository_cleanup_lease_seconds
              repository_cleanup_backoff_min_seconds repository_cleanup_backoff_max_seconds)a
    original = Map.new(keys, &{&1, Application.get_env(:forge_imports, &1, :missing)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, :missing} -> Application.delete_env(:forge_imports, key)
        {key, value} -> Application.put_env(:forge_imports, key, value)
      end)
    end)

    if postgres?() and context[:independent_connections] != true do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      if postgres?() do
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &reset_database!/0) end)
      else
        reset_database!()
        on_exit(&reset_database!/0)
      end
    end

    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    unless Process.whereis(GitCore.RepositoryReadLimiter) do
      start_supervised!({GitCore.RepositoryReadLimiter, server: GitCore.RepositoryReadLimiter})
    end

    unless Process.whereis(GitCore.RepositoryWriteLimiter) do
      start_supervised!(
        {GitCore.RepositoryWriteLimiter,
         server: GitCore.RepositoryWriteLimiter,
         capacity: GitCore.Limits.get(:repository_writer_concurrency)}
      )
    end

    :ok
  end

  test "retry backoff is bounded and exponential" do
    assert RepositoryCleanup.backoff_seconds(1, 30, 21_600) == 30
    assert RepositoryCleanup.backoff_seconds(2, 30, 21_600) == 60
    assert RepositoryCleanup.backoff_seconds(11, 30, 21_600) == 21_600
    assert RepositoryCleanup.backoff_seconds(100, 30, 21_600) == 21_600
  end

  test "persisted cleanup paths must be canonical contained segments" do
    assert {:ok, ["owner", "repo.git"]} =
             RepositoryCleanup.relative_segments("owner/repo.git")

    for path <- [
          "",
          "/repo.git",
          "owner//repo.git",
          "owner/./repo.git",
          "owner/../repo.git",
          "owner\\repo.git",
          "owner/\0repo.git"
        ] do
      assert {:error, :path_mismatch} = RepositoryCleanup.relative_segments(path)
    end
  end

  test "live storage root must exactly match persisted storage root" do
    root = Path.expand("tmp/test/repos")
    assert :ok = RepositoryCleanup.validate_storage_root(root, root)

    assert {:error, :storage_root_mismatch} =
             RepositoryCleanup.validate_storage_root(root, root <> "-other")
  end

  test "cleanup configuration validates every bounded relationship" do
    assert %{
             grace_seconds: 86_400,
             interval_ms: 30_000,
             deadline_ms: 60_000,
             lease_seconds: 120,
             backoff_min_seconds: 30,
             backoff_max_seconds: 21_600
           } = valid = Fornacast.Config.repository_cleanup()

    valid_env = [
      repository_cleanup_grace_seconds: valid.grace_seconds,
      repository_cleanup_interval_ms: valid.interval_ms,
      repository_cleanup_deadline_ms: valid.deadline_ms,
      repository_cleanup_lease_seconds: valid.lease_seconds,
      repository_cleanup_backoff_min_seconds: valid.backoff_min_seconds,
      repository_cleanup_backoff_max_seconds: valid.backoff_max_seconds
    ]

    for {key, invalid} <- [
          repository_cleanup_grace_seconds:
            GitCore.Limits.minimum_repository_cleanup_grace_seconds() - 1,
          repository_cleanup_interval_ms: 999,
          repository_cleanup_deadline_ms: 300_001,
          repository_cleanup_lease_seconds: 60,
          repository_cleanup_lease_seconds: 3_601,
          repository_cleanup_backoff_min_seconds: 29,
          repository_cleanup_backoff_max_seconds: 21_601
        ] do
      Enum.each(valid_env, fn {valid_key, value} ->
        Application.put_env(:forge_imports, valid_key, value)
      end)

      Application.put_env(:forge_imports, key, invalid)
      assert_raise ArgumentError, fn -> Fornacast.Config.repository_cleanup() end
    end

    Enum.each(valid_env, fn {key, value} -> Application.put_env(:forge_imports, key, value) end)
    Application.put_env(:forge_imports, :repository_cleanup_backoff_min_seconds, 61)
    Application.put_env(:forge_imports, :repository_cleanup_backoff_max_seconds, 60)
    assert_raise ArgumentError, fn -> Fornacast.Config.repository_cleanup() end
  end

  test "import and cleanup recovery use independent one-slot task supervisors" do
    recovery =
      start_supervised!(
        Supervisor.child_spec(
          {RecoverySupervisor,
           name: __MODULE__.IndependentRecoverySupervisor,
           task_supervisor: __MODULE__.IndependentImportTaskSupervisor,
           reconciler_name: __MODULE__.IndependentImportReconciler,
           cleanup_enabled: true,
           cleanup_task_supervisor: __MODULE__.IndependentCleanupTaskSupervisor,
           cleanup_reconciler_name: __MODULE__.IndependentCleanupReconciler,
           enabled: false,
           interval_ms: 60_000},
          id: make_ref()
        )
      )

    import_supervisor = Process.whereis(__MODULE__.IndependentImportTaskSupervisor)
    cleanup_supervisor = Process.whereis(__MODULE__.IndependentCleanupTaskSupervisor)
    assert is_pid(import_supervisor)
    assert is_pid(cleanup_supervisor)
    assert import_supervisor != cleanup_supervisor

    wait_until!(fn -> Supervisor.count_children(cleanup_supervisor).active == 0 end)

    {:ok, import_task} =
      Task.Supervisor.start_child(import_supervisor, fn -> Process.sleep(:infinity) end)

    assert {:error, :max_children} =
             Task.Supervisor.start_child(import_supervisor, fn -> :unexpected end)

    {:ok, cleanup_task} =
      Task.Supervisor.start_child(cleanup_supervisor, fn -> Process.sleep(:infinity) end)

    assert {:error, :max_children} =
             Task.Supervisor.start_child(cleanup_supervisor, fn -> :unexpected end)

    assert Process.alive?(import_task)
    assert Process.alive?(cleanup_task)

    Process.exit(import_supervisor, :kill)

    wait_until!(fn ->
      replacement = Process.whereis(__MODULE__.IndependentImportTaskSupervisor)
      is_pid(replacement) and replacement != import_supervisor
    end)

    assert Process.whereis(__MODULE__.IndependentCleanupTaskSupervisor) == cleanup_supervisor
    assert Process.alive?(cleanup_task)
    assert Process.alive?(recovery)
  end

  test "reconciler death restarts only its task-supervisor pair and kills hung work" do
    recovery =
      start_supervised!(
        Supervisor.child_spec(
          {RecoverySupervisor,
           name: __MODULE__.PairRecoverySupervisor,
           task_supervisor: __MODULE__.PairImportTaskSupervisor,
           reconciler_name: __MODULE__.PairImportReconciler,
           cleanup_enabled: true,
           cleanup_task_supervisor: __MODULE__.PairCleanupTaskSupervisor,
           cleanup_reconciler_name: __MODULE__.PairCleanupReconciler,
           enabled: false,
           interval_ms: 60_000},
          id: make_ref()
        )
      )

    assert Process.alive?(recovery)
    wait_until!(fn -> :sys.get_state(__MODULE__.PairCleanupReconciler).task == nil end)

    import_supervisor = Process.whereis(__MODULE__.PairImportTaskSupervisor)
    import_reconciler = Process.whereis(__MODULE__.PairImportReconciler)
    cleanup_supervisor = Process.whereis(__MODULE__.PairCleanupTaskSupervisor)
    cleanup_reconciler = Process.whereis(__MODULE__.PairCleanupReconciler)

    {:ok, import_task} =
      Task.Supervisor.start_child(import_supervisor, fn ->
        receive do
          :stop_pair_task -> :ok
        end
      end)

    {:ok, cleanup_task} =
      Task.Supervisor.start_child(cleanup_supervisor, fn ->
        receive do
          :stop_pair_task -> :ok
        end
      end)

    import_task_ref = Process.monitor(import_task)
    cleanup_task_ref = Process.monitor(cleanup_task)
    Process.exit(import_reconciler, :kill)

    assert_receive {:DOWN, ^import_task_ref, :process, ^import_task, _reason}, 1_000
    refute_receive {:DOWN, ^cleanup_task_ref, :process, ^cleanup_task, _reason}, 100
    assert Process.alive?(cleanup_task)

    wait_until!(fn ->
      Process.whereis(__MODULE__.PairImportTaskSupervisor) not in [nil, import_supervisor] and
        Process.whereis(__MODULE__.PairImportReconciler) not in [nil, import_reconciler]
    end)

    restarted_import_supervisor = Process.whereis(__MODULE__.PairImportTaskSupervisor)
    restarted_import_reconciler = Process.whereis(__MODULE__.PairImportReconciler)
    assert Process.whereis(__MODULE__.PairCleanupTaskSupervisor) == cleanup_supervisor
    assert Process.whereis(__MODULE__.PairCleanupReconciler) == cleanup_reconciler

    {:ok, restarted_import_task} =
      Task.Supervisor.start_child(restarted_import_supervisor, fn ->
        receive do
          :stop_pair_task -> :ok
        end
      end)

    restarted_import_task_ref = Process.monitor(restarted_import_task)
    Process.exit(cleanup_reconciler, :kill)

    assert_receive {:DOWN, ^cleanup_task_ref, :process, ^cleanup_task, _reason}, 1_000

    refute_receive {
                     :DOWN,
                     ^restarted_import_task_ref,
                     :process,
                     ^restarted_import_task,
                     _reason
                   },
                   100

    assert Process.alive?(restarted_import_task)

    wait_until!(fn ->
      Process.whereis(__MODULE__.PairCleanupTaskSupervisor) not in [nil, cleanup_supervisor] and
        Process.whereis(__MODULE__.PairCleanupReconciler) not in [nil, cleanup_reconciler]
    end)

    assert Process.whereis(__MODULE__.PairImportTaskSupervisor) == restarted_import_supervisor
    assert Process.whereis(__MODULE__.PairImportReconciler) == restarted_import_reconciler
    send(restarted_import_task, :stop_pair_task)
  end

  @tag :tmp_dir
  test "cleanup scheduler brutally cancels a task that exceeds its hard runtime", %{
    tmp_dir: tmp_dir
  } do
    _fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    probe = ForgeImports.CleanupReconcilerRuntimeProbe
    Process.register(self(), probe)

    on_exit(fn ->
      if Process.whereis(probe) == self(), do: Process.unregister(probe)
    end)

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: make_ref()))

    reconciler =
      start_supervised!(
        Supervisor.child_spec(
          {CleanupReconciler,
           name: ForgeImports.CleanupReconcilerRuntimeTest,
           task_supervisor: task_supervisor,
           runtime_ms: 50,
           interval_ms: 60_000,
           cleanup_options: [git_core: __MODULE__.BlockingGitCore]},
          id: make_ref()
        )
      )

    assert_receive {:cleanup_observation_started, task_pid}, 1_000
    monitor = Process.monitor(task_pid)

    assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}, 1_000

    state = :sys.get_state(reconciler)
    assert state.task == nil
    assert state.timer != nil
    assert state.last_kind == :unpublished_shadow
  end

  @tag :tmp_dir
  test "one cleanup scheduler tick performs exactly one due effect", %{tmp_dir: tmp_dir} do
    other = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    chosen = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    now = DateTime.utc_now(:second)
    Application.put_env(:fornacast, :repo_storage_root, chosen.root)

    Repo.update_all(
      from(operation in CleanupOperation, where: operation.id == ^chosen.operation.id),
      set: [next_attempt_at: DateTime.add(now, -1, :second)]
    )

    Repo.update_all(
      from(operation in CleanupOperation, where: operation.id == ^other.operation.id),
      set: [next_attempt_at: now]
    )

    Process.put({__MODULE__.TrackingGitCore, :test_pid}, self())
    on_exit(fn -> Process.delete({__MODULE__.TrackingGitCore, :test_pid}) end)

    assert :unpublished_shadow =
             CleanupReconciler.reconcile_once(:remote_quarantine,
               now: now,
               git_core: __MODULE__.TrackingGitCore
             )

    assert_receive :remove_contained_tree
    refute_received :remove_contained_tree
    assert Repo.reload!(chosen.operation).state == :cleanup_complete
    assert Repo.reload!(other.operation).state == :cleanup_pending
    refute File.exists?(chosen.target)
    assert File.dir?(other.target)
  end

  @tag :tmp_dir
  test "due journal ordering wins over raw discovery and is keyset exact", %{tmp_dir: tmp_dir} do
    [first, second, third, fourth] =
      for _index <- 1..4,
          do: cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    raw =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    now = DateTime.utc_now(:second)

    schedules = [
      {first, DateTime.add(now, -3, :second), now},
      {second, DateTime.add(now, -2, :second), DateTime.add(now, -2, :second)},
      {third, DateTime.add(now, -2, :second), DateTime.add(now, -1, :second)},
      {fourth, DateTime.add(now, -2, :second), DateTime.add(now, -1, :second)}
    ]

    Enum.each(schedules, fn {fixture, next_attempt_at, eligible_at} ->
      Repo.update_all(
        from(operation in CleanupOperation, where: operation.id == ^fixture.operation.id),
        set: [next_attempt_at: next_attempt_at, eligible_at: eligible_at]
      )
    end)

    expected = [first, second, third]

    Enum.each(expected, fn selected ->
      assert :unpublished_shadow =
               CleanupReconciler.reconcile_once(:remote_quarantine,
                 now: now,
                 read_limiter: __MODULE__.FailingReadLimiter,
                 write_limiter: __MODULE__.UnexpectedWriteLimiter
               )

      assert %CleanupOperation{attempt_count: 1, last_error: "limiter_unavailable"} =
               Repo.reload!(selected.operation)
    end)

    assert Repo.reload!(fourth.operation).attempt_count == 0
    assert Repo.reload!(raw.repository).lifecycle == :importing

    refute Repo.get_by(CleanupOperation,
             repository_item_id: raw.item.id,
             kind: :unpublished_shadow
           )
  end

  @tag :tmp_dir
  test "due unpublished journal removes a contained tree and commits marker audit and journal",
       %{tmp_dir: tmp_dir} do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    assert {:ok, :cached_cleanup_probe} =
             GitCore.Cache.fetch(
               {fixture.target, :cleanup_probe},
               fn -> {:ok, :cached_cleanup_probe} end
             )

    refute cache_keys_for(fixture.target) == MapSet.new()

    assert :attempted = reconcile(:unpublished_shadow)
    refute File.exists?(fixture.target)
    assert cache_keys_for(fixture.target) == MapSet.new()

    assert %Repository{storage_reclaimed_at: %DateTime{}} = Repo.reload!(fixture.repository)

    assert %CleanupOperation{
             state: :cleanup_complete,
             effect_started_at: %DateTime{},
             effect_finished_at: %DateTime{},
             completed_at: %DateTime{}
           } =
             Repo.reload!(fixture.operation)

    assert [%AuditEvent{action: "repository.storage_reclaimed", metadata: metadata}] =
             Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^fixture.operation.operation_id
             )

    assert metadata["effect"] == "removed"
    assert metadata["kind"] == "unpublished_shadow"
  end

  @tag :tmp_dir
  test "initial anchored absence needs a second matching observation before finalization", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: false)

    Process.put({__MODULE__.TrackingGitCore, :test_pid}, self())
    on_exit(fn -> Process.delete({__MODULE__.TrackingGitCore, :test_pid}) end)

    assert :attempted = reconcile(:unpublished_shadow, git_core: __MODULE__.TrackingGitCore)
    refute_received :remove_contained_tree

    operation = Repo.reload!(fixture.operation)
    assert operation.last_error == nil
    assert operation.state == :cleanup_pending
    assert operation.attempt_count == 0
    assert operation.lease_owner == nil
    assert operation.lease_expires_at == nil
    assert %DateTime{} = operation.effect_started_at
    assert %DateTime{} = operation.effect_finished_at
    assert is_map(operation.evidence["anchored_absence"])
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert Repo.all(
             from event in AuditEvent,
               where: event.operation_id == ^fixture.operation.operation_id
           ) == []

    assert :attempted = reconcile(:unpublished_shadow, git_core: __MODULE__.TrackingGitCore)
    refute_received :remove_contained_tree

    assert %CleanupOperation{state: :cleanup_complete} = Repo.reload!(fixture.operation)

    assert [%AuditEvent{metadata: %{"effect" => "missing"}}] =
             Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^fixture.operation.operation_id
             )
  end

  @tag :tmp_dir
  test "a target appearing after the first anchored absence blocks the second pass", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: false)

    assert :attempted = reconcile(:unpublished_shadow)
    assert Repo.reload!(fixture.operation).state == :cleanup_pending

    {_, 0} = System.cmd("git", ["init", "--bare", fixture.target], stderr_to_stdout: true)
    File.chmod!(fixture.target, 0o700)

    assert :attempted = reconcile(:unpublished_shadow)
    assert File.dir?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{state: :cleanup_blocked, last_error: "identity_mismatch"} =
             Repo.reload!(fixture.operation)
  end

  @tag :tmp_dir
  test "strict cache failure never deletes or publishes a reclaimed marker", %{tmp_dir: tmp_dir} do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.CacheFailureGitCore)

    assert File.dir?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{
             state: :cleanup_pending,
             attempt_count: 1,
             last_error: "cache_unavailable"
           } = Repo.reload!(fixture.operation)

    assert Repo.all(
             from event in AuditEvent,
               where: event.operation_id == ^fixture.operation.operation_id
           ) == []
  end

  @tag :tmp_dir
  test "live root drift immediately before cache or removal blocks the next effect", %{
    tmp_dir: tmp_dir
  } do
    Process.put({__MODULE__.EffectTrackingGitCore, :test_pid}, self())
    on_exit(fn -> Process.delete({__MODULE__.EffectTrackingGitCore, :test_pid}) end)

    for hook <- [:before_cache_hook, :before_remove_hook] do
      fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
      live_root = fixture.root
      drifted_root = live_root <> "-drift"

      opts = [
        {:git_core, __MODULE__.EffectTrackingGitCore},
        {hook,
         fn _operation ->
           Application.put_env(:fornacast, :repo_storage_root, drifted_root)
           :ok
         end}
      ]

      assert :attempted = reconcile(:unpublished_shadow, opts)

      Application.put_env(:fornacast, :repo_storage_root, live_root)

      assert File.dir?(fixture.target)
      assert_receive {:cleanup_effect, :observe}

      case hook do
        :before_cache_hook -> refute_receive {:cleanup_effect, :cache}
        :before_remove_hook -> assert_receive {:cleanup_effect, :cache}
      end

      refute_receive {:cleanup_effect, :remove}
      assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

      assert %CleanupOperation{
               state: :cleanup_blocked,
               last_error: "storage_root_mismatch"
             } = Repo.reload!(fixture.operation)
    end
  end

  @tag :tmp_dir
  test "cleanup and writer limiter failures back off the due journal exactly once", %{
    tmp_dir: tmp_dir
  } do
    for {read_limiter, write_limiter} <- [
          {__MODULE__.FailingReadLimiter, __MODULE__.UnexpectedWriteLimiter},
          {__MODULE__.PassingReadLimiter, __MODULE__.FailingWriteLimiter}
        ] do
      fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
      now = DateTime.utc_now(:second)

      assert :attempted =
               reconcile_at(:unpublished_shadow, now,
                 read_limiter: read_limiter,
                 write_limiter: write_limiter
               )

      assert File.dir?(fixture.target)

      assert %CleanupOperation{
               state: :cleanup_pending,
               attempt_count: 1,
               last_error: "limiter_unavailable",
               next_attempt_at: next_attempt_at,
               lease_owner: nil,
               lease_expires_at: nil
             } = Repo.reload!(fixture.operation)

      assert next_attempt_at == DateTime.add(now, 30, :second)
    end
  end

  @tag :tmp_dir
  test "raw limiter failure checkpoints the selected keyset before returning", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    item = Repo.reload!(fixture.item)
    now = DateTime.utc_now(:second)
    sort_at = item.cleanup_eligible_at || item.updated_at

    assert {:error, :limiter_unavailable} =
             RepositoryCleanup.reconcile_kind(
               :unpublished_shadow,
               now,
               System.monotonic_time(:millisecond) + 5_000,
               read_limiter: __MODULE__.FailingReadLimiter,
               write_limiter: __MODULE__.UnexpectedWriteLimiter,
               raw_cursor_observer: fn kind, cursor ->
                 send(self(), {:raw_limiter_cursor, kind, cursor})
               end
             )

    assert_receive {:raw_limiter_cursor, :unpublished_shadow, {^sort_at, item_id}}
    assert item_id == item.id
    refute_received {:raw_limiter_cursor, :unpublished_shadow, nil}
    assert Repo.reload!(fixture.repository).lifecycle == :importing
    assert File.dir?(fixture.target)

    refute Repo.get_by(CleanupOperation,
             repository_item_id: item.id,
             kind: :unpublished_shadow
           )

    assert :none =
             RepositoryCleanup.reconcile_kind(
               :unpublished_shadow,
               now,
               System.monotonic_time(:millisecond) + 5_000,
               raw_cursor: {sort_at, item.id},
               selection_observer: fn kind -> send(self(), {:repeated_raw, kind}) end
             )

    refute_received {:repeated_raw, :unpublished_shadow}
  end

  @tag :tmp_dir
  test "delete followed by a reported I/O failure replays missing with durable identity", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.DeleteThenFailGitCore)

    refute File.exists?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil
    assert Repo.reload!(fixture.operation).state == :cleanup_pending

    make_due!(fixture.operation)
    assert :attempted = reconcile(:unpublished_shadow)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at
    assert Repo.reload!(fixture.operation).state == :cleanup_complete
  end

  @tag :tmp_dir
  test "an old repository reader blocks cleanup until its permit is released", %{tmp_dir: tmp_dir} do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    deadline = System.monotonic_time(:millisecond) + 5_000

    assert {:ok, reader} =
             GitCore.RepositoryReadLimiter.acquire_read(fixture.repository.id, deadline)

    task = Task.async(fn -> reconcile(:unpublished_shadow, deadline_ms: 4_000) end)
    Process.sleep(50)
    assert File.dir?(fixture.target)
    refute Task.yield(task, 0)

    assert :ok = GitCore.RepositoryReadLimiter.release(reader)
    assert :attempted = Task.await(task, 5_000)
    refute File.exists?(fixture.target)
  end

  @tag :tmp_dir
  test "cleanup holds the real writer permit across Git-write and pull-merge effect paths", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    probe = ForgeImports.CleanupPermitProbe
    Process.register(self(), probe)

    on_exit(fn ->
      if Process.whereis(probe) == self(), do: Process.unregister(probe)
    end)

    cleanup =
      Task.async(fn ->
        reconcile(:unpublished_shadow, git_core: __MODULE__.PermitGateGitCore)
      end)

    assert_receive {:cleanup_effect_gate, cleanup_pid}, 1_000

    writers =
      for class <- [:ref, :merge] do
        Task.async(fn ->
          {class,
           ForgeRepos.with_write_fence(fixture.repository, class, fn _path, _remaining ->
             send(probe, {:unexpected_writer_effect, class})
             :unexpected
           end)}
        end)
      end

    Enum.each(writers, fn writer -> refute Task.yield(writer, 0) end)
    refute_received {:unexpected_writer_effect, _class}

    send(cleanup_pid, :continue_cleanup)
    assert :attempted = Task.await(cleanup, 5_000)

    assert [
             ref: {:error, {:unavailable, :stale_repository}},
             merge: {:error, {:unavailable, :stale_repository}}
           ] = Enum.map(writers, &Task.await(&1, 5_000))

    refute_received {:unexpected_writer_effect, _class}
  end

  @tag :tmp_dir
  test "successor intent blocks cleanup before cache or filesystem effects", %{tmp_dir: tmp_dir} do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    successor =
      %RepositoryItem{}
      |> RepositoryItem.discovery_changeset(%{
        import_run_id: fixture.run.id,
        predecessor_item_id: fixture.item.id,
        github_repository_id: 8_800_000_000 + System.unique_integer([:positive]),
        source_full_name: "acme/successor",
        source_name: "successor",
        source_metadata: %{},
        source_observed_at: fixture.now
      })
      |> Repo.insert()

    assert {:ok, %RepositoryItem{}} = successor
    assert :attempted = reconcile(:unpublished_shadow)
    assert File.dir?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil
    assert Repo.reload!(fixture.operation).state == :cleanup_blocked
  end

  @tag :tmp_dir
  test "unpublished cleanup revalidates every eligibility fact before filesystem effects", %{
    tmp_dir: tmp_dir
  } do
    Process.put({__MODULE__.EffectTrackingGitCore, :test_pid}, self())
    on_exit(fn -> Process.delete({__MODULE__.EffectTrackingGitCore, :test_pid}) end)

    mutations = [
      lifecycle: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(lifecycle: :ready, deleted_at: nil)
        |> Repo.update!()
      end,
      grace: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      visibility: fn fixture ->
        fixture.repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()
      end,
      write_version: fn fixture ->
        fixture.repository |> Ecto.Changeset.change(write_version: 1) |> Repo.update!()
      end,
      last_push: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(last_pushed_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      reclaimed: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(storage_reclaimed_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      item_state: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(state: :completed, failure_kind: nil)
        |> Repo.update!()
      end,
      run_state: fn fixture ->
        fixture.run
        |> Ecto.Changeset.change(state: :completed, failure_kind: nil)
        |> Repo.update!()
      end,
      attempt_state: fn fixture ->
        Repo.get_by!(ImportAttempt,
          repository_item_id: fixture.item.id,
          attempt_number: fixture.item.attempt_count
        )
        |> Ecto.Changeset.change(state: :canceled, failure_kind: nil)
        |> Repo.update!()
      end,
      publication: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(publication_evidence: %{"drift" => true})
        |> Repo.update!()
      end
    ]

    for {dimension, mutate} <- mutations do
      fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
      mutate.(fixture)
      reclaimed_before = Repo.reload!(fixture.repository).storage_reclaimed_at

      assert :attempted =
               reconcile(:unpublished_shadow, git_core: __MODULE__.EffectTrackingGitCore),
             "expected #{dimension} drift to be selected and blocked"

      assert File.dir?(fixture.target), "#{dimension} drift reached filesystem removal"
      assert Repo.reload!(fixture.repository).storage_reclaimed_at == reclaimed_before
      assert Repo.reload!(fixture.operation).state == :cleanup_blocked
      refute_received {:cleanup_effect, _phase}
    end
  end

  @tag :tmp_dir
  test "a live import lease reschedules just after expiry without consuming an attempt", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    now = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, 90, :second)

    operation = git_write_operation!(fixture)

    Repo.update_all(
      from(candidate in GitWriteOperation, where: candidate.id == ^operation.id),
      set: [lease_owner: "live-writer", lease_expires_at: expires_at]
    )

    assert :attempted = reconcile_at(:unpublished_shadow, now)
    assert File.dir?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{
             state: :cleanup_pending,
             attempt_count: 0,
             last_error: "live_lease",
             lease_owner: nil,
             lease_expires_at: nil,
             next_attempt_at: next_attempt_at
           } = Repo.reload!(fixture.operation)

    assert DateTime.compare(next_attempt_at, expires_at) == :gt
    assert DateTime.diff(next_attempt_at, expires_at, :second) in 1..30
  end

  @tag :tmp_dir
  test "a claimable write operation retries after thirty seconds without deletion", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    now = DateTime.utc_now(:second)
    _operation = git_write_operation!(fixture)

    assert :attempted = reconcile_at(:unpublished_shadow, now)
    assert File.dir?(fixture.target)

    assert %CleanupOperation{
             state: :cleanup_pending,
             attempt_count: 0,
             last_error: "claimable_operation",
             next_attempt_at: next_attempt_at
           } = Repo.reload!(fixture.operation)

    assert next_attempt_at == DateTime.add(now, 30, :second)
  end

  @tag :tmp_dir
  test "ordinary observation I/O is retryable rather than terminal cleanup evidence", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    now = DateTime.utc_now(:second)

    assert :attempted =
             reconcile_at(:unpublished_shadow, now,
               git_core: __MODULE__.ObservationFailureGitCore
             )

    assert File.dir?(fixture.target)

    assert %CleanupOperation{
             state: :cleanup_pending,
             attempt_count: 1,
             last_error: "storage_unavailable",
             next_attempt_at: next_attempt_at
           } = Repo.reload!(fixture.operation)

    assert next_attempt_at == DateTime.add(now, 30, :second)
  end

  @tag :tmp_dir
  test "finalization blocks when successor intent appears after the anchored removal", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    probe = ForgeImports.CleanupFinalizationProbe
    Process.register(self(), probe)

    on_exit(fn ->
      if Process.whereis(probe) == self(), do: Process.unregister(probe)
    end)

    task =
      Task.async(fn ->
        reconcile(:unpublished_shadow, git_core: __MODULE__.DeleteThenPauseGitCore)
      end)

    assert_receive {:cleanup_removed, cleanup_pid}, 1_000

    %RepositoryItem{}
    |> RepositoryItem.discovery_changeset(%{
      import_run_id: fixture.run.id,
      predecessor_item_id: fixture.item.id,
      github_repository_id: 8_820_000_000 + System.unique_integer([:positive]),
      source_full_name: "acme/finalization-successor",
      source_name: "finalization-successor",
      source_metadata: %{},
      source_observed_at: fixture.now
    })
    |> Repo.insert!()

    send(cleanup_pid, :continue_finalization)
    assert :attempted = Task.await(task, 5_000)
    refute File.exists?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{state: :cleanup_blocked, last_error: "successor_or_adopter"} =
             Repo.reload!(fixture.operation)

    assert Repo.all(
             from event in AuditEvent,
               where: event.operation_id == ^fixture.operation.operation_id
           ) == []
  end

  @tag :tmp_dir
  test "unpublished cleanup revalidates every eligibility fact in the final CAS", %{
    tmp_dir: tmp_dir
  } do
    probe = ForgeImports.CleanupFinalizationProbe
    Process.register(self(), probe)

    on_exit(fn ->
      if Process.whereis(probe) == self(), do: Process.unregister(probe)
    end)

    for {dimension, mutate} <- unpublished_final_drift_mutations() do
      fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

      task =
        Task.async(fn ->
          reconcile(:unpublished_shadow, git_core: __MODULE__.DeleteThenPauseGitCore)
        end)

      assert_receive {:cleanup_removed, cleanup_pid}, 1_000
      mutate.(fixture)
      reclaimed_before = Repo.reload!(fixture.repository).storage_reclaimed_at
      send(cleanup_pid, :continue_finalization)

      assert :attempted = Task.await(task, 5_000), "final #{dimension} drift did not settle"
      assert Repo.reload!(fixture.repository).storage_reclaimed_at == reclaimed_before
      assert Repo.reload!(fixture.operation).state == :cleanup_blocked

      assert Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^fixture.operation.operation_id
             ) == [],
             "final #{dimension} drift emitted an audit"
    end
  end

  @tag :tmp_dir
  test "finalization rejects replacement of the anchored storage root after removal", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    probe = ForgeImports.CleanupFinalizationProbe
    Process.register(self(), probe)

    on_exit(fn ->
      if Process.whereis(probe) == self(), do: Process.unregister(probe)
    end)

    task =
      Task.async(fn ->
        reconcile(:unpublished_shadow, git_core: __MODULE__.DeleteThenPauseGitCore)
      end)

    assert_receive {:cleanup_removed, cleanup_pid}, 1_000
    displaced_root = fixture.root <> "-displaced"
    File.rename!(fixture.root, displaced_root)
    File.mkdir!(fixture.root)
    File.chmod!(fixture.root, 0o700)

    send(cleanup_pid, :continue_finalization)
    assert :attempted = Task.await(task, 5_000)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    blocked = Repo.reload!(fixture.operation)
    assert blocked.state == :cleanup_blocked
    assert blocked.last_error in ["root_identity_mismatch", "evidence_mismatch"]

    assert Repo.all(
             from event in AuditEvent,
               where: event.operation_id == ^fixture.operation.operation_id
           ) == []
  end

  @tag :tmp_dir
  test "journal-less unpublished cleanup tombstones atomically and waits through the grace boundary",
       %{
         tmp_dir: tmp_dir
       } do
    fixture =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    now = DateTime.utc_now(:second)
    grace = Fornacast.Config.repository_cleanup().grace_seconds

    assert :attempted = reconcile_at(:unpublished_shadow, now)
    assert File.dir?(fixture.target)

    assert %Repository{lifecycle: :tombstoned, deleted_at: ^now, storage_reclaimed_at: nil} =
             Repo.reload!(fixture.repository)

    assert %CleanupOperation{
             state: :cleanup_pending,
             eligible_at: eligible_at,
             next_attempt_at: next_attempt_at,
             effect_started_at: nil,
             effect_finished_at: nil
           } =
             operation =
             Repo.get_by!(CleanupOperation,
               repository_item_id: fixture.item.id,
               kind: :unpublished_shadow
             )

    assert next_attempt_at == eligible_at
    assert eligible_at == DateTime.add(now, grace, :second)
    assert :none = reconcile_at(:unpublished_shadow, DateTime.add(eligible_at, -1, :second))
    assert File.dir?(fixture.target)

    assert :attempted = reconcile_at(:unpublished_shadow, eligible_at)
    refute File.exists?(fixture.target)
    assert Repo.reload!(operation).state == :cleanup_complete
  end

  @tag :tmp_dir
  test "an invalid oldest raw candidate cannot starve the next valid candidate", %{
    tmp_dir: tmp_dir
  } do
    invalid =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    invalid.repository
    |> Ecto.Changeset.change(name: "not a canonical import shadow")
    |> Repo.update!()

    valid =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    now = DateTime.utc_now(:second)
    assert :attempted = reconcile_at(:unpublished_shadow, now)

    assert Repo.reload!(invalid.repository).lifecycle == :importing
    assert Repo.reload!(valid.repository).lifecycle == :tombstoned

    assert %CleanupOperation{state: :cleanup_pending} =
             Repo.get_by!(CleanupOperation,
               repository_item_id: valid.item.id,
               kind: :unpublished_shadow
             )

    refute Repo.get_by(CleanupOperation,
             repository_item_id: invalid.item.id,
             kind: :unpublished_shadow
           )
  end

  @tag independent_connections: true
  @tag :tmp_dir
  test "independent PostgreSQL materializers load one exact winning cleanup journal", %{
    tmp_dir: tmp_dir
  } do
    if postgres?() do
      fixture =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          reset_database!()
          valid_remote_raw_fixture(tmp_dir)
        end)

      parent = self()
      ready_ref = make_ref()

      tasks =
        for label <- [:first, :second] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[backend_pid]]} =
                Ecto.Adapters.SQL.query!(Repo, "select pg_backend_pid()", [])

              send(parent, {ready_ref, self(), backend_pid})

              receive do
                {:race_materialization, ^ready_ref} -> :ok
              end

              RepositoryCleanup.reconcile_kind(
                :remote_quarantine,
                fixture.now,
                System.monotonic_time(:millisecond) + 5_000,
                read_limiter: __MODULE__.PassingReadLimiter,
                write_limiter: __MODULE__.PassingWriteLimiter,
                after_claim_hook: fn operation ->
                  send(parent, {:materialization_winner, self(), label, operation})

                  receive do
                    :release_materialization_winner -> {:error, :test_stop}
                  end
                end
              )
            end)
          end)
        end

      backends =
        Enum.map(tasks, fn _task ->
          assert_receive {^ready_ref, worker, backend_pid}
          {worker, backend_pid}
        end)

      assert MapSet.new(Enum.map(backends, &elem(&1, 0))) ==
               MapSet.new(Enum.map(tasks, & &1.pid))

      assert MapSet.size(MapSet.new(Enum.map(backends, &elem(&1, 1)))) == 2
      Enum.each(tasks, &send(&1.pid, {:race_materialization, ready_ref}))

      assert_receive {:materialization_winner, winner_pid, _label, winner}
      loser = Enum.find(tasks, &(&1.pid != winner_pid))
      assert :attempted = Task.await(loser, 5_000)

      send(winner_pid, :release_materialization_winner)
      winning_task = Enum.find(tasks, &(&1.pid == winner_pid))
      assert {:error, :test_stop} = Task.await(winning_task, 5_000)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert [operation] =
                 Repo.all(
                   from operation in CleanupOperation,
                     where:
                       operation.repository_item_id == ^fixture.item.id and
                         operation.kind == :remote_quarantine
                 )

        assert operation.id == winner.id
        assert operation.repository_id == fixture.repository.id
        assert operation.source_lock_version == fixture.item.lock_version

        assert operation.operation_id ==
                 CleanupOperation.deterministic_operation_id(
                   :remote_quarantine,
                   fixture.repository.id,
                   fixture.item.id,
                   fixture.item.lock_version
                 )

        assert operation.evidence["item_id"] == fixture.item.id
        assert operation.evidence["repository_id"] == fixture.repository.id
      end)
    end
  end

  @tag :tmp_dir
  test "raw scan checkpoints completed invalid rows before a deterministic deadline", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    now = DateTime.utc_now(:second)

    [first, second, third] =
      for index <- 1..3 do
        insert_invalid_remote_candidate!(fixture, now, index)
      end

    parent = self()
    observer = raw_candidate_barrier(parent)
    clock = :atomics.new(1, [])
    absolute_deadline = System.monotonic_time(:millisecond) + 5_000
    :atomics.put(clock, 1, absolute_deadline - 1)

    task =
      Task.async(fn ->
        RepositoryCleanup.reconcile_kind(
          :remote_quarantine,
          now,
          absolute_deadline,
          monotonic_ms: fn -> :atomics.get(clock, 1) end,
          raw_candidate_observer: observer,
          raw_cursor_observer: fn kind, cursor ->
            send(parent, {:incremental_raw_cursor, kind, cursor})
          end
        )
      end)

    assert_receive {:raw_candidate_barrier, worker, first_id}
    assert first_id == first.id
    send(worker, {:release_raw_candidate, first.id})

    assert_receive {:incremental_raw_cursor, :remote_quarantine, {^now, first_id}}
    assert first_id == first.id

    assert_receive {:raw_candidate_barrier, ^worker, second_id}
    assert second_id == second.id
    :atomics.put(clock, 1, absolute_deadline)
    send(worker, {:release_raw_candidate, second.id})

    third_id = third.id
    refute_receive {:raw_candidate_barrier, ^worker, ^third_id}, 100
    assert :none = Task.await(task, 1_000)
    refute_receive {:incremental_raw_cursor, :remote_quarantine, {^now, ^second_id}}

    :atomics.put(clock, 1, absolute_deadline - 1)

    resumed =
      Task.async(fn ->
        RepositoryCleanup.reconcile_kind(
          :remote_quarantine,
          now,
          absolute_deadline,
          monotonic_ms: fn -> :atomics.get(clock, 1) end,
          raw_cursor: {now, first.id},
          raw_candidate_observer: observer
        )
      end)

    assert_receive {:raw_candidate_barrier, resumed_worker, resumed_id}
    assert resumed_id == second.id
    :atomics.put(clock, 1, absolute_deadline)
    send(resumed_worker, {:release_raw_candidate, second.id})
    assert :none = Task.await(resumed, 1_000)
  end

  @tag :tmp_dir
  test "bounded invalid first-kind backlog yields to valid later-kind work", %{tmp_dir: tmp_dir} do
    valid_later =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: true,
        raw_unpublished?: true
      )

    now = DateTime.utc_now(:second)

    invalid =
      for index <- 1..101 do
        insert_invalid_remote_candidate!(valid_later, now, index)
      end

    parent = self()
    frozen_monotonic = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        CleanupReconciler.reconcile_once(:replacement_tombstone,
          now: now,
          deadline_ms: 5_000,
          monotonic_ms: fn -> frozen_monotonic end,
          raw_candidate_observer: raw_candidate_barrier(parent, :remote_quarantine),
          raw_cursor_observer: fn kind, cursor ->
            send(parent, {:backlog_raw_cursor, kind, cursor})
          end
        )
      end)

    [deferred | processed] = Enum.reverse(invalid)

    for item <- Enum.reverse(processed) do
      assert_receive {:raw_candidate_barrier, worker, item_id}
      assert item_id == item.id
      send(worker, {:release_raw_candidate, item.id})
      assert_receive {:backlog_raw_cursor, :remote_quarantine, {^now, cursor_id}}
      assert cursor_id == item.id
    end

    deferred_id = deferred.id
    refute_receive {:raw_candidate_barrier, _worker, ^deferred_id}, 100
    assert :unpublished_shadow = Task.await(task, 5_000)
    assert Repo.reload!(valid_later.repository).lifecycle == :tombstoned

    assert %CleanupOperation{state: :cleanup_pending} =
             Repo.get_by!(CleanupOperation,
               repository_item_id: valid_later.item.id,
               kind: :unpublished_shadow
             )
  end

  @tag :tmp_dir
  test "raw-SQL evidence cannot redirect cleanup into another repository tree", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)
    suffix = System.unique_integer([:positive])

    {:ok, other_repository} =
      ForgeRepos.create_repository(fixture.actor, %{
        name: "cleanup-bystander-#{suffix}",
        slug: "cleanup-bystander-#{suffix}",
        visibility: :private
      })

    other_target = Path.join(fixture.root, other_repository.storage_path)
    assert_safe_cleanup_target!(other_target, fixture.root)
    {_, 0} = System.cmd("git", ["init", "--bare", other_target], stderr_to_stdout: true)
    File.chmod!(other_target, 0o700)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      update github_import_repository_cleanups
      set evidence = jsonb_set(
        jsonb_set(evidence, '{relative_path}', to_jsonb($1::text), false),
        '{repository_storage_path}', to_jsonb($1::text), false
      )
      where id = $2
      """,
      [other_repository.storage_path, fixture.operation.id]
    )

    assert :attempted = reconcile(:unpublished_shadow)
    assert File.dir?(fixture.target)
    assert File.dir?(other_target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{state: :cleanup_blocked, last_error: "evidence_mismatch"} =
             Repo.reload!(fixture.operation)
  end

  @tag :tmp_dir
  test "removal proof must exactly equal the persisted root and target proof", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.ForgedRemovalProofGitCore)

    refute File.exists?(fixture.target)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{state: :cleanup_blocked, last_error: "identity_mismatch"} =
             Repo.reload!(fixture.operation)

    assert Repo.all(
             from event in AuditEvent,
               where: event.operation_id == ^fixture.operation.operation_id
           ) == []
  end

  @tag :tmp_dir
  test "a mismatched cleanup audit blocks before cache invalidation or filesystem effect", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    Process.put({__MODULE__.EffectTrackingGitCore, :test_pid}, self())
    on_exit(fn -> Process.delete({__MODULE__.EffectTrackingGitCore, :test_pid}) end)

    assert {:ok, %AuditEvent{}} =
             Audit.record(
               fixture.actor,
               "repository.cleanup_collision",
               "repository",
               fixture.repository.id,
               %{"classification" => "test_collision"},
               operation_id: fixture.operation.operation_id
             )

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.EffectTrackingGitCore)

    assert File.dir?(fixture.target)
    refute_received {:cleanup_effect, :observe}
    refute_received {:cleanup_effect, :cache}
    refute_received {:cleanup_effect, :remove}
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    blocked = Repo.reload!(fixture.operation)
    assert blocked.state == :cleanup_blocked
    assert blocked.last_error == "audit_mismatch"

    assert [] ==
             Repo.all(
               from event in AuditEvent,
                 where:
                   event.operation_id == ^fixture.operation.operation_id and
                     event.action == "repository.storage_reclaimed"
             )
  end

  @tag :tmp_dir
  test "an exact cleanup audit without durable effect proof blocks before filesystem effect", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    Process.put({__MODULE__.EffectTrackingGitCore, :test_pid}, self())
    on_exit(fn -> Process.delete({__MODULE__.EffectTrackingGitCore, :test_pid}) end)

    assert {:ok, %AuditEvent{}} =
             Audit.record(
               fixture.actor,
               "repository.storage_reclaimed",
               "repository",
               fixture.repository.id,
               cleanup_audit_metadata(fixture.operation, :removed),
               operation_id: fixture.operation.operation_id
             )

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.EffectTrackingGitCore)

    assert File.dir?(fixture.target)
    refute_received {:cleanup_effect, :observe}
    refute_received {:cleanup_effect, :cache}
    refute_received {:cleanup_effect, :remove}
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{state: :cleanup_blocked, last_error: "audit_mismatch"} =
             Repo.reload!(fixture.operation)
  end

  @tag :tmp_dir
  test "an exact cleanup audit replays only with durable completed removal proof", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.DeleteThenFailGitCore)

    refute File.exists?(fixture.target)

    operation =
      fixture.operation
      |> Repo.reload!()
      |> Ecto.Changeset.change(effect_finished_at: DateTime.utc_now(:second))
      |> Repo.update!()

    assert is_map(operation.evidence["root_identity"])
    assert is_map(operation.evidence["anchored_identity"])
    assert %DateTime{} = operation.effect_started_at
    assert %DateTime{} = operation.effect_finished_at

    assert {:ok, %AuditEvent{}} =
             Audit.record(
               fixture.actor,
               "repository.storage_reclaimed",
               "repository",
               fixture.repository.id,
               cleanup_audit_metadata(operation, :removed),
               operation_id: operation.operation_id
             )

    make_due!(operation)
    assert :attempted = reconcile(:unpublished_shadow)

    assert %CleanupOperation{state: :cleanup_complete, last_error: nil} = Repo.reload!(operation)
    assert %Repository{storage_reclaimed_at: %DateTime{}} = Repo.reload!(fixture.repository)

    assert [_existing] =
             Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^operation.operation_id
             )
  end

  @tag :tmp_dir
  test "cleanup audit preserves canonical request context and cleanup operation authority", %{
    tmp_dir: tmp_dir
  } do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    request_metadata = %{
      "request_id" => "cleanup-request-#{fixture.item.id}",
      "ip_address" => "127.0.0.1",
      "user_agent" => "cleanup-test-agent",
      "operation_id" => "untrusted-caller-operation"
    }

    Repo.update_all(
      from(run in ImportRun, where: run.id == ^fixture.run.id),
      set: [request_metadata: request_metadata]
    )

    assert :attempted = reconcile(:unpublished_shadow)

    assert %AuditEvent{
             request_id: request_id,
             ip_address: "127.0.0.1",
             user_agent: "cleanup-test-agent",
             operation_id: operation_id,
             metadata: metadata
           } =
             Repo.get_by!(AuditEvent, operation_id: fixture.operation.operation_id)

    assert request_id == request_metadata["request_id"]
    assert operation_id == fixture.operation.operation_id
    assert metadata["request_id"] == request_metadata["request_id"]
    assert metadata["ip_address"] == "127.0.0.1"
    assert metadata["user_agent"] == "cleanup-test-agent"
    refute metadata["operation_id"]
  end

  @tag :tmp_dir
  test "cleanup audit replay rejects mismatched dedicated request context", %{tmp_dir: tmp_dir} do
    fixture = cleanup_fixture(:unpublished_shadow, tmp_dir, create_target?: true)

    request_metadata = %{
      "request_id" => "cleanup-replay-#{fixture.item.id}",
      "ip_address" => "127.0.0.2",
      "user_agent" => "cleanup-replay-agent"
    }

    Repo.update_all(
      from(run in ImportRun, where: run.id == ^fixture.run.id),
      set: [request_metadata: request_metadata]
    )

    assert :attempted =
             reconcile(:unpublished_shadow, git_core: __MODULE__.DeleteThenFailGitCore)

    operation =
      fixture.operation
      |> Repo.reload!()
      |> Ecto.Changeset.change(effect_finished_at: DateTime.utc_now(:second))
      |> Repo.update!()

    assert {:ok, audit} =
             Audit.record(
               fixture.actor,
               "repository.storage_reclaimed",
               "repository",
               fixture.repository.id,
               cleanup_audit_metadata(operation, :removed, request_metadata),
               operation_id: operation.operation_id,
               request_metadata: request_metadata
             )

    audit
    |> Ecto.Changeset.change(user_agent: "mismatched-agent")
    |> Repo.update!()

    make_due!(operation)
    assert :attempted = reconcile(:unpublished_shadow)
    assert Repo.reload!(fixture.repository).storage_reclaimed_at == nil

    assert %CleanupOperation{state: :cleanup_blocked, last_error: "audit_mismatch"} =
             Repo.reload!(operation)
  end

  @tag :tmp_dir
  test "replacement cleanup waits without intent until its parent run is terminal", %{
    tmp_dir: tmp_dir
  } do
    fixture = replacement_cleanup_fixture(tmp_dir)

    Repo.update_all(
      from(run in ImportRun, where: run.id == ^fixture.run.id),
      set: [state: :running, terminal_at: nil, failure_kind: nil]
    )

    assert :none = reconcile_at(:replacement_tombstone, fixture.now)
    assert File.dir?(fixture.target)
    assert Repo.reload!(fixture.old_repository).storage_reclaimed_at == nil

    refute Repo.get_by(CleanupOperation,
             repository_item_id: fixture.item.id,
             kind: :replacement_tombstone
           )

    Repo.update_all(
      from(run in ImportRun, where: run.id == ^fixture.run.id),
      set: [state: :completed, terminal_at: fixture.now]
    )

    assert :attempted = reconcile_at(:replacement_tombstone, fixture.now)
    refute File.exists?(fixture.target)

    assert %CleanupOperation{state: :cleanup_complete} =
             Repo.get_by!(CleanupOperation,
               repository_item_id: fixture.item.id,
               kind: :replacement_tombstone
             )
  end

  @tag :tmp_dir
  test "replacement tombstone reclaims only the exact published predecessor at the grace boundary",
       %{
         tmp_dir: tmp_dir
       } do
    fixture =
      cleanup_fixture(:replacement_tombstone, tmp_dir,
        create_target?: true,
        insert_operation?: false
      )

    now = DateTime.utc_now(:second)
    grace = Fornacast.Config.repository_cleanup().grace_seconds

    old_repository =
      fixture.repository
      |> Ecto.Changeset.change(deleted_at: DateTime.add(now, -grace, :second))
      |> Repo.update!()

    {:ok, new_repository} =
      ForgeRepos.create_repository(fixture.actor, %{
        name: "Published replacement",
        slug: old_repository.slug,
        visibility: :private
      })

    new_repository =
      new_repository
      |> Ecto.Changeset.change(generation: old_repository.generation + 1)
      |> Repo.update!()

    decision = %{
      "action" => "replace",
      "slug" => old_repository.slug,
      "replacement_repository_id" => old_repository.id,
      "replacement_owner_id" => old_repository.owner_user_id,
      "replacement_storage_path" => old_repository.storage_path,
      "replacement_generation" => old_repository.generation,
      "replacement_write_version" => old_repository.write_version,
      "replacement_updated_at" => DateTime.to_iso8601(old_repository.updated_at),
      "replacement_last_pushed_at" => nil
    }

    attempt =
      Repo.get_by!(ImportAttempt,
        repository_item_id: fixture.item.id,
        attempt_number: fixture.item.attempt_count
      )
      |> Ecto.Changeset.change(
        state: :completed,
        decision: decision,
        terminal_at: now,
        failure_kind: nil
      )
      |> Repo.update!()

    publication_operation_id =
      "github-import-publication-#{fixture.item.id}-#{attempt.attempt_number}"

    marker = %{
      "version" => 1,
      "state" => "committed",
      "attempt_number" => attempt.attempt_number,
      "action" => "replace",
      "hidden_repository_id" => new_repository.id,
      "operation_id" => publication_operation_id,
      "request_metadata" => %{},
      "repository_id" => new_repository.id,
      "owner_user_id" => new_repository.owner_user_id,
      "slug" => new_repository.slug,
      "generation" => new_repository.generation,
      "replaced_repository_id" => old_repository.id,
      "run_id" => fixture.run.id,
      "published_count_after" => 1,
      "run_lock_version_after" => fixture.run.lock_version
    }

    fixture.item
    |> Ecto.Changeset.change(
      state: :published,
      hidden_repository_id: new_repository.id,
      replacement_repository_id: old_repository.id,
      publication_evidence: marker,
      failure_kind: nil
    )
    |> Repo.update!()

    publication_metadata = %{
      "item_id" => fixture.item.id,
      "attempt_number" => attempt.attempt_number,
      "run_id" => fixture.run.id,
      "published_count_after" => 1,
      "run_lock_version_after" => fixture.run.lock_version,
      "new_repository_id" => new_repository.id,
      "old_repository_id" => old_repository.id
    }

    assert {:ok, %AuditEvent{} = publication_audit} =
             Audit.record(
               fixture.actor,
               "repository.replaced",
               "repository",
               new_repository.id,
               publication_metadata,
               operation_id: publication_operation_id
             )

    assert :none =
             reconcile_at(:replacement_tombstone, DateTime.add(now, -1, :second))

    assert File.dir?(fixture.target)
    assert :attempted = reconcile_at(:replacement_tombstone, now)
    refute File.exists?(fixture.target)

    cleanup =
      Repo.get_by!(CleanupOperation,
        repository_item_id: fixture.item.id,
        kind: :replacement_tombstone
      )

    assert cleanup.state == :cleanup_complete
    assert cleanup.evidence["publication_audit_id"] == publication_audit.id
    assert %DateTime{} = Repo.reload!(old_repository).storage_reclaimed_at
    assert Repo.reload!(new_repository).storage_reclaimed_at == nil

    assert [%AuditEvent{action: "repository.storage_reclaimed"}] =
             Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^cleanup.operation_id
             )
  end

  @tag :tmp_dir
  test "replacement cleanup revalidates every eligibility fact before observation", %{
    tmp_dir: tmp_dir
  } do
    mutations = [
      lifecycle: fn fixture ->
        fixture.new_repository
        |> Ecto.Changeset.change(slug: "drifted-successor-#{fixture.new_repository.id}")
        |> Repo.update!()

        fixture.old_repository
        |> Ecto.Changeset.change(lifecycle: :ready, deleted_at: nil)
        |> Repo.update!()
      end,
      grace: fn fixture ->
        fixture.old_repository
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      reclaimed: fn fixture ->
        fixture.old_repository
        |> Ecto.Changeset.change(storage_reclaimed_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      item_state: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(state: :failed, failure_kind: "drift")
        |> Repo.update!()
      end,
      attempt_state: fn fixture ->
        fixture.attempt
        |> Ecto.Changeset.change(state: :failed, failure_kind: "drift")
        |> Repo.update!()
      end,
      marker: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(
          publication_evidence: Map.put(fixture.marker, "published_count_after", 2)
        )
        |> Repo.update!()
      end,
      successor: fn fixture ->
        fixture.new_repository
        |> Ecto.Changeset.change(lifecycle: :importing)
        |> Repo.update!()
      end,
      audit: fn fixture ->
        fixture.publication_audit
        |> Ecto.Changeset.change(
          metadata: Map.put(fixture.publication_audit.metadata, "drift", true)
        )
        |> Repo.update!()
      end
    ]

    for {dimension, mutate} <- mutations do
      fixture = replacement_cleanup_fixture(tmp_dir)
      parent = self()

      task =
        Task.async(fn ->
          reconcile_at(:replacement_tombstone, fixture.now,
            after_claim_hook: fn operation ->
              send(parent, {:replacement_claimed, self(), operation.id})

              receive do
                :continue_replacement -> :ok
              end
            end
          )
        end)

      assert_receive {:replacement_claimed, cleanup_pid, operation_id}, 1_000
      mutate.(fixture)
      reclaimed_before = Repo.reload!(fixture.old_repository).storage_reclaimed_at
      send(cleanup_pid, :continue_replacement)

      assert :attempted = Task.await(task, 5_000), "#{dimension} drift did not settle"
      assert File.dir?(fixture.target), "#{dimension} drift reached filesystem removal"
      assert Repo.reload!(fixture.old_repository).storage_reclaimed_at == reclaimed_before
      assert Repo.get!(CleanupOperation, operation_id).state == :cleanup_blocked

      refute Repo.get_by(AuditEvent,
               operation_id:
                 CleanupOperation.deterministic_operation_id(
                   :replacement_tombstone,
                   fixture.old_repository.id,
                   fixture.item.id,
                   fixture.item.lock_version
                 )
             )
    end
  end

  @tag :tmp_dir
  test "replacement cleanup revalidates every eligibility fact in the final CAS", %{
    tmp_dir: tmp_dir
  } do
    probe = ForgeImports.CleanupFinalizationProbe
    Process.register(self(), probe)

    on_exit(fn ->
      if Process.whereis(probe) == self(), do: Process.unregister(probe)
    end)

    for {dimension, mutate} <- replacement_final_drift_mutations() do
      fixture = replacement_cleanup_fixture(tmp_dir)

      task =
        Task.async(fn ->
          reconcile_at(:replacement_tombstone, fixture.now,
            git_core: __MODULE__.DeleteThenPauseGitCore
          )
        end)

      assert_receive {:cleanup_removed, cleanup_pid}, 1_000
      mutate.(fixture)
      reclaimed_before = Repo.reload!(fixture.old_repository).storage_reclaimed_at
      send(cleanup_pid, :continue_finalization)

      assert :attempted = Task.await(task, 5_000), "final #{dimension} drift did not settle"
      assert Repo.reload!(fixture.old_repository).storage_reclaimed_at == reclaimed_before

      cleanup =
        Repo.get_by!(CleanupOperation,
          repository_item_id: fixture.item.id,
          kind: :replacement_tombstone
        )

      assert cleanup.state == :cleanup_blocked
      refute Repo.get_by(AuditEvent, operation_id: cleanup.operation_id)
    end
  end

  defmodule TrackingGitCore do
    def contained_tree_identity(root, segments, deadline),
      do: GitCore.contained_tree_identity(root, segments, deadline)

    def invalidate_repository_cache_strict(path),
      do: GitCore.invalidate_repository_cache_strict(path)

    def remove_contained_tree(root, segments, proof, deadline) do
      send(Process.get({__MODULE__, :test_pid}), :remove_contained_tree)
      GitCore.remove_contained_tree(root, segments, proof, deadline)
    end
  end

  defmodule EffectTrackingGitCore do
    def contained_tree_identity(root, segments, deadline) do
      send(Process.get({__MODULE__, :test_pid}), {:cleanup_effect, :observe})
      GitCore.contained_tree_identity(root, segments, deadline)
    end

    def invalidate_repository_cache_strict(path) do
      send(Process.get({__MODULE__, :test_pid}), {:cleanup_effect, :cache})
      GitCore.invalidate_repository_cache_strict(path)
    end

    def remove_contained_tree(root, segments, proof, deadline) do
      send(Process.get({__MODULE__, :test_pid}), {:cleanup_effect, :remove})
      GitCore.remove_contained_tree(root, segments, proof, deadline)
    end
  end

  defmodule BlockingGitCore do
    def contained_tree_identity(_root, _segments, _deadline) do
      send(ForgeImports.CleanupReconcilerRuntimeProbe, {:cleanup_observation_started, self()})
      Process.sleep(:infinity)
    end

    def invalidate_repository_cache_strict(_path),
      do: raise("cache invalidation must not run while observation is blocked")

    def remove_contained_tree(_root, _segments, _proof, _deadline),
      do: raise("removal must not run while observation is blocked")
  end

  defmodule FailingReadLimiter do
    def acquire_cleanup(_repository_id, _deadline), do: {:error, :capacity}
  end

  defmodule PassingReadLimiter do
    def acquire_cleanup(_repository_id, _deadline), do: {:ok, :cleanup_lease}
    def release(:cleanup_lease), do: :ok
  end

  defmodule PassingWriteLimiter do
    def acquire(_repository_id, _deadline), do: {:ok, {:writer_lease, self()}}
    def release({:writer_lease, _owner}), do: :ok
  end

  defmodule FailingWriteLimiter do
    def acquire(_repository_id, _deadline), do: {:error, :capacity}
  end

  defmodule UnexpectedWriteLimiter do
    def acquire(_repository_id, _deadline),
      do: raise("writer permit must not be attempted when cleanup permit acquisition fails")
  end

  defmodule CacheFailureGitCore do
    def contained_tree_identity(root, segments, deadline),
      do: GitCore.contained_tree_identity(root, segments, deadline)

    def invalidate_repository_cache_strict(_path), do: {:error, :cache_unavailable}

    def remove_contained_tree(_root, _segments, _proof, _deadline),
      do: raise("removal must not run after cache failure")
  end

  defmodule DeleteThenFailGitCore do
    def contained_tree_identity(root, segments, deadline),
      do: GitCore.contained_tree_identity(root, segments, deadline)

    def invalidate_repository_cache_strict(path),
      do: GitCore.invalidate_repository_cache_strict(path)

    def remove_contained_tree(root, segments, proof, deadline) do
      assert_removed!(GitCore.remove_contained_tree(root, segments, proof, deadline))
      {:error, :io_error}
    end

    defp assert_removed!({:ok, {:removed, _proof}}), do: :ok
  end

  defmodule PermitGateGitCore do
    def contained_tree_identity(root, segments, deadline) do
      if Process.get({__MODULE__, :gated}) do
        GitCore.contained_tree_identity(root, segments, deadline)
      else
        Process.put({__MODULE__, :gated}, true)
        send(ForgeImports.CleanupPermitProbe, {:cleanup_effect_gate, self()})

        receive do
          :continue_cleanup -> GitCore.contained_tree_identity(root, segments, deadline)
        end
      end
    end

    def invalidate_repository_cache_strict(path),
      do: GitCore.invalidate_repository_cache_strict(path)

    def remove_contained_tree(root, segments, proof, deadline),
      do: GitCore.remove_contained_tree(root, segments, proof, deadline)
  end

  defmodule ObservationFailureGitCore do
    def contained_tree_identity(_root, _segments, _deadline), do: {:error, :io}

    def invalidate_repository_cache_strict(_path),
      do: raise("cache invalidation must not run without a durable observation")

    def remove_contained_tree(_root, _segments, _proof, _deadline),
      do: raise("removal must not run without a durable observation")
  end

  defmodule DeleteThenPauseGitCore do
    def contained_tree_identity(root, segments, deadline),
      do: GitCore.contained_tree_identity(root, segments, deadline)

    def invalidate_repository_cache_strict(path),
      do: GitCore.invalidate_repository_cache_strict(path)

    def remove_contained_tree(root, segments, proof, deadline) do
      result = GitCore.remove_contained_tree(root, segments, proof, deadline)
      send(ForgeImports.CleanupFinalizationProbe, {:cleanup_removed, self()})

      receive do
        :continue_finalization -> result
      end
    end
  end

  defmodule ForgedRemovalProofGitCore do
    def contained_tree_identity(root, segments, deadline),
      do: GitCore.contained_tree_identity(root, segments, deadline)

    def invalidate_repository_cache_strict(path),
      do: GitCore.invalidate_repository_cache_strict(path)

    def remove_contained_tree(root, segments, proof, deadline) do
      case GitCore.remove_contained_tree(root, segments, proof, deadline) do
        {:ok, {:removed, returned_proof}} ->
          {:ok, {:removed, Map.put(returned_proof, :unexpected, :forged)}}

        other ->
          other
      end
    end
  end

  defp reconcile(kind, opts \\ []) do
    deadline_ms = Keyword.get(opts, :deadline_ms, 5_000)

    reconcile_at(kind, DateTime.utc_now(:second), opts, deadline_ms)
  end

  defp reconcile_at(kind, now, opts \\ [], deadline_ms \\ 5_000) do
    RepositoryCleanup.reconcile_kind(
      kind,
      now,
      System.monotonic_time(:millisecond) + deadline_ms,
      opts
    )
  end

  defp cleanup_fixture(kind, tmp_dir, options) do
    root = Path.join(Path.expand(tmp_dir), "storage-#{System.unique_integer([:positive])}")
    assert_safe_test_root!(root, tmp_dir)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    Application.put_env(:fornacast, :repo_storage_root, root)

    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "cleanup-effect-#{suffix}",
        email: "cleanup-effect-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_700_000_000 + suffix,
          login: "cleanup-effect-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        DateTime.utc_now(:second)
      )

    {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)

    {:ok, run} =
      ForgeImports.create_run(actor, %{
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: identity.github_user_id,
        source_owner_login: identity.login,
        request_metadata: %{}
      })

    {:ok, item} =
      ForgeImports.create_repository_item(actor, run, %{
        github_repository_id: 8_710_000_000 + suffix,
        source_full_name: "acme/cleanup-effect-#{suffix}",
        source_name: "cleanup-effect-#{suffix}",
        source_metadata: %{},
        source_observed_at: DateTime.utc_now(:second)
      })

    raw_unpublished? = Keyword.get(options, :raw_unpublished?, false)

    repository_name =
      if raw_unpublished?, do: "GitHub import #{item.id}", else: "cleanup-effect-#{suffix}"

    repository_slug =
      if raw_unpublished? do
        hex = suffix |> Integer.to_string(16) |> String.pad_leading(24, "0")
        "import-#{item.id}-#{String.slice(hex, -24, 24)}"
      else
        "cleanup-effect-#{suffix}"
      end

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{
        name: repository_name,
        slug: repository_slug,
        visibility: :private
      })

    repository =
      if Keyword.fetch!(options, :create_target?) do
        repository
      else
        repository
        |> Ecto.Changeset.change(storage_path: "missing/#{suffix}.git")
        |> Repo.update!()
      end

    now = DateTime.utc_now(:second)
    target = Path.join(root, repository.storage_path)
    assert_safe_cleanup_target!(target, root)

    if Keyword.fetch!(options, :create_target?) do
      {_, 0} = System.cmd("git", ["init", "--bare", target], stderr_to_stdout: true)
      File.chmod!(target, 0o700)
    else
      File.mkdir_p!(Path.dirname(target))
    end

    run =
      run
      |> ImportRun.transition_changeset(:failed, %{terminal_at: now, failure_kind: "test_failure"})
      |> Repo.update!()

    item =
      item
      |> Ecto.Changeset.change(
        state: :failed,
        hidden_repository_id: repository.id,
        attempt_count: 1,
        failure_kind: "test_failure",
        next_attempt_at: nil,
        lease_owner: nil,
        lease_expires_at: nil
      )
      |> Repo.update!()

    decision = %{"action" => "create", "slug" => repository.slug}

    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :failed,
      decision: decision,
      started_at: now,
      terminal_at: now,
      failure_kind: "test_failure"
    })
    |> Repo.insert!()

    repository =
      if raw_unpublished? do
        repository
        |> Ecto.Changeset.change(lifecycle: :importing)
        |> Repo.update!()
      else
        deleted_at =
          if kind == :unpublished_shadow,
            do: DateTime.add(now, -Fornacast.Config.repository_cleanup().grace_seconds, :second),
            else: now

        repository
        |> Ecto.Changeset.change(lifecycle: :tombstoned, deleted_at: deleted_at)
        |> Repo.update!()
      end

    evidence = %{
      "version" => 1,
      "kind" => Atom.to_string(kind),
      "storage_root" => root,
      "relative_path" => repository.storage_path,
      "repository_id" => repository.id,
      "repository_generation" => repository.generation,
      "repository_write_version" => repository.write_version,
      "repository_storage_path" => repository.storage_path,
      "repository_updated_at" => DateTime.to_iso8601(repository.updated_at),
      "item_id" => item.id,
      "item_lock_version" => item.lock_version,
      "item_state" => "failed",
      "run_id" => run.id,
      "run_state" => "failed",
      "attempt_number" => 1,
      "attempt_state" => "failed",
      "attempt_decision" => decision,
      "attempt_fingerprint" => CleanupOperation.attempt_fingerprint(item.id, 1, decision),
      "publication_evidence" => %{},
      "predecessor_item_id" => nil,
      "successor_item_id" => nil,
      "adopter_item_id" => nil
    }

    attrs = %{
      repository_id: repository.id,
      repository_item_id: item.id,
      source_lock_version: item.lock_version,
      kind: kind,
      operation_id:
        CleanupOperation.deterministic_operation_id(
          kind,
          repository.id,
          item.id,
          item.lock_version
        ),
      evidence: evidence,
      eligible_at: now,
      next_attempt_at: now
    }

    insert_operation? = Keyword.get(options, :insert_operation?, not raw_unpublished?)

    operation =
      if insert_operation? do
        %CleanupOperation{}
        |> CleanupOperation.create_changeset(attrs)
        |> Repo.insert!()
      else
        nil
      end

    %{
      actor: actor,
      run: run,
      item: item,
      repository: repository,
      operation: operation,
      target: target,
      root: root,
      now: now
    }
  end

  defp replacement_cleanup_fixture(tmp_dir) do
    fixture =
      cleanup_fixture(:replacement_tombstone, tmp_dir,
        create_target?: true,
        insert_operation?: false
      )

    now = DateTime.utc_now(:second)
    grace = Fornacast.Config.repository_cleanup().grace_seconds

    old_repository =
      fixture.repository
      |> Ecto.Changeset.change(deleted_at: DateTime.add(now, -grace, :second))
      |> Repo.update!()

    {:ok, new_repository} =
      ForgeRepos.create_repository(fixture.actor, %{
        name: "Published replacement helper #{System.unique_integer([:positive])}",
        slug: old_repository.slug,
        visibility: :private
      })

    new_repository =
      new_repository
      |> Ecto.Changeset.change(generation: old_repository.generation + 1)
      |> Repo.update!()

    decision = %{
      "action" => "replace",
      "slug" => old_repository.slug,
      "replacement_repository_id" => old_repository.id,
      "replacement_owner_id" => old_repository.owner_user_id,
      "replacement_storage_path" => old_repository.storage_path,
      "replacement_generation" => old_repository.generation,
      "replacement_write_version" => old_repository.write_version,
      "replacement_updated_at" => DateTime.to_iso8601(old_repository.updated_at),
      "replacement_last_pushed_at" => nil
    }

    attempt =
      Repo.get_by!(ImportAttempt,
        repository_item_id: fixture.item.id,
        attempt_number: fixture.item.attempt_count
      )
      |> Ecto.Changeset.change(
        state: :completed,
        decision: decision,
        terminal_at: now,
        failure_kind: nil
      )
      |> Repo.update!()

    publication_operation_id =
      "github-import-publication-#{fixture.item.id}-#{attempt.attempt_number}"

    marker = %{
      "version" => 1,
      "state" => "committed",
      "attempt_number" => attempt.attempt_number,
      "action" => "replace",
      "hidden_repository_id" => new_repository.id,
      "operation_id" => publication_operation_id,
      "request_metadata" => %{},
      "repository_id" => new_repository.id,
      "owner_user_id" => new_repository.owner_user_id,
      "slug" => new_repository.slug,
      "generation" => new_repository.generation,
      "replaced_repository_id" => old_repository.id,
      "run_id" => fixture.run.id,
      "published_count_after" => 1,
      "run_lock_version_after" => fixture.run.lock_version
    }

    item =
      fixture.item
      |> Ecto.Changeset.change(
        state: :published,
        hidden_repository_id: new_repository.id,
        replacement_repository_id: old_repository.id,
        publication_evidence: marker,
        failure_kind: nil
      )
      |> Repo.update!()

    publication_metadata = %{
      "item_id" => item.id,
      "attempt_number" => attempt.attempt_number,
      "run_id" => fixture.run.id,
      "published_count_after" => 1,
      "run_lock_version_after" => fixture.run.lock_version,
      "new_repository_id" => new_repository.id,
      "old_repository_id" => old_repository.id
    }

    {:ok, publication_audit} =
      Audit.record(
        fixture.actor,
        "repository.replaced",
        "repository",
        new_repository.id,
        publication_metadata,
        operation_id: publication_operation_id
      )

    Map.merge(fixture, %{
      now: now,
      old_repository: old_repository,
      new_repository: new_repository,
      item: item,
      attempt: attempt,
      marker: marker,
      publication_audit: publication_audit
    })
  end

  defp insert_invalid_remote_candidate!(fixture, now, index) do
    github_id = 8_990_000_000 + System.unique_integer([:positive])

    item =
      %RepositoryItem{}
      |> RepositoryItem.discovery_changeset(%{
        import_run_id: fixture.run.id,
        github_repository_id: github_id,
        source_full_name: "acme/invalid-remote-#{index}-#{github_id}",
        source_name: "invalid-remote-#{index}",
        source_metadata: %{},
        source_observed_at: now
      })
      |> Repo.insert!()

    {:ok, repository} =
      ForgeRepos.create_repository(fixture.actor, %{
        name: "Invalid remote #{index}",
        slug: "invalid-remote-#{index}-#{item.id}",
        visibility: :private
      })

    repository =
      repository
      |> Ecto.Changeset.change(lifecycle: :importing)
      |> Repo.update!()

    requested_path = ForgeRepos.absolute_storage_path(repository)

    item =
      item
      |> Ecto.Changeset.change(
        state: :staging_git,
        hidden_repository_id: repository.id,
        staged_storage_path: GitCore.Remote.cleanup_slot_path(requested_path),
        cleanup_state: "cleanup_pending",
        cleanup_eligible_at: now,
        cleanup_attempt_count: 0,
        cleanup_error: "source_validation",
        checkpoint: %{},
        attempt_count: 1,
        next_attempt_at: nil
      )
      |> Repo.update!()

    _attempt =
      %ImportAttempt{}
      |> ImportAttempt.create_changeset(%{
        repository_item_id: item.id,
        attempt_number: 1,
        state: :running,
        decision: %{"action" => "create", "slug" => repository.slug},
        started_at: now
      })
      |> Repo.insert!()

    item
  end

  defp valid_remote_raw_fixture(tmp_dir) do
    fixture =
      cleanup_fixture(:unpublished_shadow, tmp_dir,
        create_target?: false,
        raw_unpublished?: true
      )

    requested_path = ForgeRepos.absolute_storage_path(fixture.repository)
    quarantine_path = GitCore.Remote.cleanup_slot_path(requested_path)
    assert_safe_cleanup_target!(quarantine_path, fixture.root)
    File.mkdir_p!(Path.dirname(quarantine_path))
    {_, 0} = System.cmd("git", ["init", "--bare", quarantine_path], stderr_to_stdout: true)
    File.chmod!(quarantine_path, 0o700)

    relative_path = Path.relative_to(quarantine_path, fixture.root)
    {:ok, segments} = RepositoryCleanup.relative_segments(relative_path)

    assert {:ok, {:present, %{target: identity}}} =
             GitCore.contained_tree_identity(fixture.root, segments, 5_000)

    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(run in ImportRun, where: run.id == ^fixture.run.id),
      set: [state: :running, terminal_at: nil, failure_kind: nil]
    )

    Repo.update_all(
      from(attempt in ImportAttempt,
        where:
          attempt.repository_item_id == ^fixture.item.id and
            attempt.attempt_number == ^fixture.item.attempt_count
      ),
      set: [state: :running, terminal_at: nil, failure_kind: nil]
    )

    item =
      fixture.item
      |> Ecto.Changeset.change(
        state: :staging_git,
        staged_storage_path: quarantine_path,
        cleanup_state: "cleanup_pending",
        cleanup_eligible_at: now,
        cleanup_attempt_count: 0,
        cleanup_error: "source_validation",
        checkpoint: %{
          "cleanup_identity" => %{
            "mode" => identity.mode,
            "major_device" => identity.major_device,
            "minor_device" => identity.minor_device,
            "inode" => identity.inode
          }
        },
        failure_kind: nil
      )
      |> Repo.update!()

    %{fixture | run: Repo.get!(ImportRun, fixture.run.id), item: item, now: now}
  end

  defp raw_candidate_barrier(parent, only_kind \\ nil) do
    fn candidate ->
      if is_nil(only_kind) or candidate.kind == only_kind do
        send(parent, {:raw_candidate_barrier, self(), candidate.id})

        receive do
          {:release_raw_candidate, candidate_id} when candidate_id == candidate.id -> :ok
        end
      end
    end
  end

  defp git_write_operation!(fixture) do
    %GitWriteOperation{}
    |> GitWriteOperation.changeset(%{
      repository_id: fixture.repository.id,
      actor_user_id: fixture.actor.id,
      request_id: "cleanup-race-#{System.unique_integer([:positive])}",
      kind: :ref_create,
      state: :prepared,
      target_ref: "refs/heads/main",
      expected_oid: nil,
      proposed_oid: String.duplicate("a", 40),
      result_blob_oid: nil,
      failure_reason: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      lock_version: 0
    })
    |> Repo.insert!()
  end

  defp unpublished_final_drift_mutations do
    [
      lifecycle: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(lifecycle: :ready, deleted_at: nil)
        |> Repo.update!()
      end,
      grace: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      visibility: fn fixture ->
        fixture.repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()
      end,
      write_version: fn fixture ->
        fixture.repository |> Ecto.Changeset.change(write_version: 1) |> Repo.update!()
      end,
      last_push: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(last_pushed_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      reclaimed: fn fixture ->
        fixture.repository
        |> Ecto.Changeset.change(storage_reclaimed_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      item_state: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(state: :completed, failure_kind: nil)
        |> Repo.update!()
      end,
      run_state: fn fixture ->
        fixture.run
        |> Ecto.Changeset.change(state: :completed, failure_kind: nil)
        |> Repo.update!()
      end,
      attempt_state: fn fixture ->
        Repo.get_by!(ImportAttempt,
          repository_item_id: fixture.item.id,
          attempt_number: fixture.item.attempt_count
        )
        |> Ecto.Changeset.change(state: :canceled, failure_kind: nil)
        |> Repo.update!()
      end,
      publication: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(publication_evidence: %{"drift" => true})
        |> Repo.update!()
      end
    ]
  end

  defp replacement_final_drift_mutations do
    [
      lifecycle: fn fixture ->
        fixture.new_repository
        |> Ecto.Changeset.change(slug: "final-drift-successor-#{fixture.new_repository.id}")
        |> Repo.update!()

        fixture.old_repository
        |> Ecto.Changeset.change(lifecycle: :ready, deleted_at: nil)
        |> Repo.update!()
      end,
      grace: fn fixture ->
        fixture.old_repository
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      reclaimed: fn fixture ->
        fixture.old_repository
        |> Ecto.Changeset.change(storage_reclaimed_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end,
      item_state: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(state: :failed, failure_kind: "drift")
        |> Repo.update!()
      end,
      attempt_state: fn fixture ->
        fixture.attempt
        |> Ecto.Changeset.change(state: :failed, failure_kind: "drift")
        |> Repo.update!()
      end,
      marker: fn fixture ->
        fixture.item
        |> Ecto.Changeset.change(
          publication_evidence: Map.put(fixture.marker, "published_count_after", 2)
        )
        |> Repo.update!()
      end,
      successor: fn fixture ->
        fixture.new_repository
        |> Ecto.Changeset.change(lifecycle: :importing)
        |> Repo.update!()
      end,
      audit: fn fixture ->
        fixture.publication_audit
        |> Ecto.Changeset.change(
          metadata: Map.put(fixture.publication_audit.metadata, "drift", true)
        )
        |> Repo.update!()
      end
    ]
  end

  defp make_due!(operation) do
    Repo.update_all(
      from(candidate in CleanupOperation, where: candidate.id == ^operation.id),
      set: [next_attempt_at: DateTime.utc_now(:second), lease_owner: nil, lease_expires_at: nil]
    )
  end

  defp cleanup_audit_metadata(operation, effect, request_metadata \\ %{}) do
    fingerprint =
      operation.evidence
      |> Map.drop(~w(root_identity anchored_identity anchored_absence))
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    base = %{
      "kind" => Atom.to_string(operation.kind),
      "item_id" => operation.repository_item_id,
      "repository_id" => operation.repository_id,
      "repository_generation" => operation.evidence["repository_generation"],
      "evidence_fingerprint" => fingerprint,
      "effect" => Atom.to_string(effect)
    }

    request_metadata
    |> Map.drop(["operation_id", :operation_id])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> then(&Map.merge(base, &1))
  end

  defp assert_safe_test_root!(root, tmp_dir) do
    expanded_root = Path.expand(root)
    expanded_tmp = Path.expand(tmp_dir)
    workspace = Path.expand("../../..", __DIR__)

    assert expanded_root != "/"
    assert expanded_root != workspace
    assert String.starts_with?(expanded_root, expanded_tmp <> "/")
    refute String.starts_with?(workspace, expanded_root <> "/")
    :ok
  end

  defp assert_safe_cleanup_target!(target, root) do
    expanded_target = Path.expand(target)
    expanded_root = Path.expand(root)
    assert expanded_target != "/"
    assert expanded_target != expanded_root
    assert String.starts_with?(expanded_target, expanded_root <> "/")
    :ok
  end

  defp cache_keys_for(path) do
    parent = self()
    ref = make_ref()

    :sys.replace_state(GitCore.Cache, fn state ->
      send(parent, {ref, :ets.tab2list(state.table)})
      state
    end)

    assert_receive {^ref, entries}

    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(is_tuple(&1) and tuple_size(&1) > 0 and elem(&1, 0) == path))
    |> MapSet.new()
  end

  defp wait_until!(fun, attempts \\ 100)

  defp wait_until!(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until!(fun, attempts - 1)
    end
  end

  defp wait_until!(_fun, 0), do: flunk("condition did not become true")

  defp reset_database! do
    for table <- [
          "github_import_repository_cleanups",
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "pull_merge_operations",
          "pull_requests",
          "git_write_operations",
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

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
