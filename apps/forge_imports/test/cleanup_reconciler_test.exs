defmodule ForgeImports.CleanupReconcilerTest do
  use ExUnit.Case, async: true

  alias ForgeImports.CleanupReconciler
  alias Fornacast.Repo

  setup tags do
    if Map.get(tags, :postgres) && postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    :ok
  end

  test "kind cursor advances round-robin after every attempted kind" do
    assert CleanupReconciler.kinds_after(nil) ==
             [:remote_quarantine, :unpublished_shadow, :replacement_tombstone]

    assert CleanupReconciler.kinds_after(:remote_quarantine) ==
             [:unpublished_shadow, :replacement_tombstone, :remote_quarantine]

    assert CleanupReconciler.kinds_after(:unpublished_shadow) ==
             [:replacement_tombstone, :remote_quarantine, :unpublished_shadow]

    assert CleanupReconciler.kinds_after(:replacement_tombstone) ==
             [:remote_quarantine, :unpublished_shadow, :replacement_tombstone]
  end

  test "default scheduler configuration is bounded" do
    assert CleanupReconciler.interval_ms() == 30_000
    assert CleanupReconciler.runtime_ms() == 60_000

    assert {:ok, state} = CleanupReconciler.init(enabled: false)
    assert state.runtime_ms == 60_000
    assert state.operation_deadline_ms == 59_000
    assert state.runtime_ms - state.operation_deadline_ms == 1_000

    for operation_deadline_ms <- [0, 100, 101] do
      assert_raise ArgumentError, fn ->
        CleanupReconciler.init(
          enabled: false,
          runtime_ms: 100,
          operation_deadline_ms: operation_deadline_ms
        )
      end
    end
  end

  test "scheduler runs one selected effect per tick and rotates all three kinds" do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: make_ref()))

    reconciler =
      start_supervised!(
        Supervisor.child_spec(
          {CleanupReconciler,
           name: __MODULE__.RoundRobinReconciler,
           task_supervisor: task_supervisor,
           repository_cleanup: __MODULE__.ProbeCleanup,
           interval_ms: 60_000,
           runtime_ms: 1_000,
           cleanup_options: [test_pid: self()]},
          id: make_ref()
        )
      )

    for expected <- [
          :remote_quarantine,
          :unpublished_shadow,
          :replacement_tombstone,
          :remote_quarantine
        ] do
      assert_receive {:probe_cleanup, ^expected}, 1_000
      refute_receive {:probe_cleanup, _other}
      wait_until_idle!(reconciler)
      CleanupReconciler.kick(reconciler)
    end
  end

  test "selected kind cursor survives block race and task crash outcomes" do
    for mode <- [:block, :race, :crash] do
      task_supervisor =
        start_supervised!(
          Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: make_ref())
        )

      reconciler =
        start_supervised!(
          Supervisor.child_spec(
            {CleanupReconciler,
             name: {:global, {__MODULE__, mode, make_ref()}},
             task_supervisor: task_supervisor,
             repository_cleanup: __MODULE__.ProbeCleanup,
             last_kind: :remote_quarantine,
             interval_ms: 60_000,
             runtime_ms: 1_000,
             cleanup_options: [test_pid: self(), mode: mode]},
            id: make_ref()
          )
        )

      assert_receive {:probe_cleanup, :unpublished_shadow}, 1_000
      wait_until_idle!(reconciler)

      state = :sys.get_state(reconciler)
      assert state.last_kind == :unpublished_shadow
      assert state.task == nil
      assert state.timer != nil
      assert Process.alive?(reconciler)
    end
  end

  test "timeout-boundary task success preserves kind and raw cursor exactly once" do
    raw_cursor = {~U[2026-08-31 10:00:00Z], 42}

    result =
      {:cleanup_scan, :replacement_tombstone, %{remote_quarantine: raw_cursor}}

    task = Task.completed(result)

    state = %{
      enabled: true,
      task_supervisor: nil,
      task: task,
      task_timeout: nil,
      timer: nil,
      last_kind: :unpublished_shadow,
      raw_cursors: %{},
      repository_cleanup: __MODULE__.ResumeProbe,
      interval_ms: 60_000,
      runtime_ms: 1_000,
      cleanup_options: [test_pid: self()]
    }

    assert {:noreply, settled} =
             CleanupReconciler.handle_info({:task_timeout, task.ref}, state)

    assert settled.task == nil
    assert settled.task_timeout == nil
    assert settled.last_kind == :replacement_tombstone
    assert settled.raw_cursors == %{remote_quarantine: raw_cursor}
    assert {_timer, _token} = settled.timer

    assert :remote_quarantine =
             CleanupReconciler.reconcile_once(settled.last_kind,
               repository_cleanup: __MODULE__.ResumeProbe,
               raw_cursors: settled.raw_cursors,
               test_pid: self()
             )

    assert_receive {:resume_probe, :remote_quarantine, ^raw_cursor}

    assert {:noreply, ^settled} = CleanupReconciler.handle_info({task.ref, result}, settled)

    assert {:noreply, ^settled} =
             CleanupReconciler.handle_info(
               {:DOWN, task.ref, :process, self(), :normal},
               settled
             )

    {timer, _token} = settled.timer
    Process.cancel_timer(timer)
  end

  test "operation deadline leaves a bounded settlement margin before the watchdog" do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: make_ref()))

    clock = :atomics.new(1, [])
    frozen = System.monotonic_time(:millisecond)
    :atomics.put(clock, 1, frozen)
    raw_cursor = {~U[2026-08-31 10:30:00Z], 77}

    reconciler =
      start_supervised!(
        Supervisor.child_spec(
          {CleanupReconciler,
           name: __MODULE__.DeadlineMarginReconciler,
           task_supervisor: task_supervisor,
           repository_cleanup: __MODULE__.DeadlineProbeCleanup,
           last_kind: :replacement_tombstone,
           raw_cursors: %{remote_quarantine: raw_cursor},
           interval_ms: 60_000,
           operation_deadline_ms: 40,
           runtime_ms: 100,
           cleanup_options: [
             test_pid: self(),
             monotonic_ms: fn -> :atomics.get(clock, 1) end
           ]},
          id: make_ref()
        )
      )

    assert_receive {:deadline_probe_waiting, worker, deadline, ^raw_cursor}
    assert deadline == frozen + 40
    :atomics.put(clock, 1, deadline)
    send(worker, :return_at_internal_deadline)
    assert_receive {:deadline_probe_settled, ^deadline}
    wait_until_idle!(reconciler)

    state = :sys.get_state(reconciler)
    assert state.last_kind == :remote_quarantine
    assert state.raw_cursors == %{remote_quarantine: raw_cursor}
    assert state.task == nil
    assert state.timer != nil
  end

  test "child scheduling delay cannot move the operation deadline past the parent epoch" do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, max_children: 1}, id: make_ref()))

    clock = :atomics.new(1, [])
    frozen = System.monotonic_time(:millisecond)
    :atomics.put(clock, 1, frozen)
    test_pid = self()

    reconciler =
      start_supervised!(
        Supervisor.child_spec(
          {CleanupReconciler,
           name: __MODULE__.ParentEpochReconciler,
           task_supervisor: task_supervisor,
           repository_cleanup: __MODULE__.DeadlineProbeCleanup,
           interval_ms: 60_000,
           operation_deadline_ms: 40,
           runtime_ms: 5_000,
           cleanup_options: [
             test_pid: test_pid,
             monotonic_ms: fn -> :atomics.get(clock, 1) end,
             before_reconcile_hook: fn ->
               send(test_pid, {:before_reconcile, self()})

               receive do
                 :continue_reconcile -> :ok
               end
             end
           ]},
          id: make_ref()
        )
      )

    assert_receive {:before_reconcile, worker}
    :atomics.put(clock, 1, frozen + 80)
    send(worker, :continue_reconcile)

    assert_receive {:deadline_probe_waiting, ^worker, deadline, nil}
    assert deadline == frozen + 40
    send(worker, :return_at_internal_deadline)
    assert_receive {:deadline_probe_settled, ^deadline}
    wait_until_idle!(reconciler)
  end

  defmodule ProbeCleanup do
    def reconcile_kind(kind, _now, _deadline, opts) do
      opts[:selection_observer].(kind)
      send(Keyword.fetch!(opts, :test_pid), {:probe_cleanup, kind})

      case Keyword.get(opts, :mode, :attempted) do
        :attempted -> :attempted
        :block -> :attempted
        :race -> {:error, :persistence_unavailable}
        :crash -> raise "injected cleanup crash"
      end
    end
  end

  defmodule ResumeProbe do
    def reconcile_kind(kind, _now, _deadline, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:resume_probe, kind, opts[:raw_cursor]})
      :attempted
    end
  end

  defmodule DeadlineProbeCleanup do
    def reconcile_kind(kind, _now, deadline, opts) do
      cursor = Keyword.fetch!(opts, :raw_cursor)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:deadline_probe_waiting, self(), deadline, cursor})

      receive do
        :return_at_internal_deadline -> :ok
      end

      opts[:raw_cursor_observer].(kind, cursor)
      opts[:selection_observer].(kind)
      send(test_pid, {:deadline_probe_settled, deadline})
      :attempted
    end
  end

  @tag :postgres
  test "reconcile returns zero when no cancel-requested runs are terminal-ready" do
    assert CleanupReconciler.reconcile(~U[2026-08-25 12:00:00Z], 10) == 0
  end

  defp postgres? do
    Application.get_env(:fornacast, Fornacast.Repo)[:adapter] == Ecto.Adapters.Postgres
  end

  defp wait_until_idle!(reconciler, attempts \\ 100)

  defp wait_until_idle!(reconciler, attempts) when attempts > 0 do
    if :sys.get_state(reconciler).task == nil do
      :ok
    else
      Process.sleep(10)
      wait_until_idle!(reconciler, attempts - 1)
    end
  end

  defp wait_until_idle!(_reconciler, 0), do: flunk("cleanup task did not become idle")
end
