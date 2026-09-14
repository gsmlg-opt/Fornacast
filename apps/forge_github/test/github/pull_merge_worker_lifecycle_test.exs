defmodule ForgeGitHub.PullMergeWorkerLifecycleTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.PullMergeWorker
  alias ForgeMirrors.MirrorOperation

  test "explicitly disabled workers do not poll" do
    worker = start_worker(enabled: false)
    refute_receive :merge_claimed, 40
    send(worker, :tick)
    assert %{enabled: false} = :sys.get_state(worker)
    refute_receive :merge_claimed, 40
  end

  test "explicit enablement uses the long lease and exact merge allowlist" do
    _worker = start_worker(enabled: true)

    assert_receive {:merge_claimed, 1_860, 2, ["merge.pull"]}, 1_000
  end

  test "the claim loop restarts after its runner crashes" do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end})

    worker =
      start_worker(
        enabled: true,
        runner: fn ->
          send(parent, :merge_runner_started)

          case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
            0 -> raise "boom"
            _ -> :ok
          end
        end
      )

    assert_receive :merge_runner_started, 1_000
    assert_receive :merge_runner_started, 1_000
    assert Process.alive?(worker)
    assert :ok = stop_supervised(PullMergeWorker)
  end

  test "an unmarked operation-task crash durably releases the lease for retry" do
    parent = self()
    operation = operation(1)

    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 1}, id: {:crash_tasks, make_ref()})

    assert {:ok, [{1, {:ok, :retried}}]} =
             PullMergeWorker.run_once("merge-lifecycle-test",
               task_supervisor: task_supervisor,
               batch_size: 1,
               max_concurrency: 1,
               processor_timeout_ms: 100,
               claim: fn _, %DateTime{}, 1_860, 1, ["merge.pull"] -> {:ok, [operation]} end,
               processor: fn _, _, _ -> raise "operation crash" end,
               current_operation: fn 1 -> nil end,
               retry: fn ^operation, %DateTime{}, %DateTime{}, "network", [] ->
                 send(parent, :merge_retried)
                 {:ok, :retried}
               end
             )

    assert_receive :merge_retried
  end

  test "a marked operation-task crash defers without rewriting its marker" do
    parent = self()
    marker = %{"phase" => "remote_cas_pending", "merge_oid" => String.duplicate("a", 40)}
    operation = %{operation(2) | state: :effect_pending, external_effect_marker: marker}

    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 1}, id: {:marked_tasks, make_ref()})

    assert {:ok, [{2, {:ok, :deferred}}]} =
             PullMergeWorker.run_once("merge-lifecycle-test",
               task_supervisor: task_supervisor,
               batch_size: 1,
               max_concurrency: 1,
               processor_timeout_ms: 100,
               claim: fn _, %DateTime{}, 1_860, 1, ["merge.pull"] -> {:ok, [operation]} end,
               processor: fn _, _, _ -> raise "operation crash" end,
               defer: fn %{external_effect_marker: ^marker},
                         %DateTime{},
                         %DateTime{},
                         :worker_crash ->
                 send(parent, :merge_deferred)
                 {:ok, :deferred}
               end
             )

    assert_receive :merge_deferred
  end

  test "the operation pool admits the supported concurrency maximum" do
    parent = self()
    operations = Enum.map(1..8, &operation/1)

    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 8}, id: {:maximum_tasks, make_ref()})

    runner =
      Task.async(fn ->
        PullMergeWorker.run_once("merge-lifecycle-test",
          task_supervisor: task_supervisor,
          batch_size: 8,
          max_concurrency: 8,
          processor_timeout_ms: 1_000,
          claim: fn _, %DateTime{}, 1_860, 8, ["merge.pull"] -> {:ok, operations} end,
          processor: fn operation, _, _ ->
            send(parent, {:merge_operation_started, operation.id, self()})

            receive do
              :release -> {:ok, operation.id}
            end
          end
        )
      end)

    started =
      Enum.map(1..8, fn _ ->
        assert_receive {:merge_operation_started, id, pid}, 1_000
        {id, pid}
      end)

    assert started |> Enum.map(&elem(&1, 0)) |> MapSet.new() == MapSet.new(1..8)
    assert started |> Enum.map(&elem(&1, 1)) |> MapSet.new() |> MapSet.size() == 8
    Enum.each(started, fn {_id, pid} -> send(pid, :release) end)
    assert {:ok, results} = Task.await(runner)
    assert length(results) == 8
  end

  test "a prepared intent is written under a live authorizer and reloaded before execution" do
    operation = operation(3)
    Process.put(:merge_context_load, 0)

    merge_context = fn ^operation, %DateTime{} ->
      load = Process.get(:merge_context_load, 0)
      Process.put(:merge_context_load, load + 1)

      state = if load == 0, do: "prepared", else: "merge_written"
      {:ok, %{intent: %{id: 41, state: state}}}
    end

    assert {:ok, :executed} =
             PullMergeWorker.process_operation(operation, DateTime.utc_now(:second),
               merge_context: merge_context,
               write_coordinated_merge: fn 41, 3, authorize: authorize ->
                 assert is_function(authorize, 1)
                 {:ok, %{id: 41, state: "merge_written"}}
               end,
               unmarked_execute: fn ^operation,
                                    %DateTime{},
                                    %{intent: %{id: 41, state: "merge_written"}},
                                    _ ->
                 {:ok, :executed}
               end
             )

    assert Process.get(:merge_context_load) == 2
  end

  test "a crash after marking is durably deferred without clearing the new marker" do
    parent = self()
    operation = operation(5)
    marker = %{"phase" => "remote_cas_pending", "merge_oid" => String.duplicate("b", 40)}
    marked = %{operation | state: :effect_pending, external_effect_marker: marker}

    assert {:error, :worker_crash} =
             PullMergeWorker.process_operation(operation, DateTime.utc_now(:second),
               merge_context: fn _, _ -> {:ok, %{intent: %{id: 42, state: "merge_written"}}} end,
               unmarked_execute: fn _, _, _, _ -> raise "crash after durable mark" end,
               current_operation: fn 5 -> marked end,
               defer: fn %{external_effect_marker: ^marker},
                         %DateTime{},
                         %DateTime{},
                         :worker_crash ->
                 send(parent, :new_marker_deferred)
                 {:ok, :deferred}
               end
             )

    assert_receive :new_marker_deferred
  end

  test "an unmarked processing error is persisted while preserving the processor return" do
    parent = self()
    operation = operation(4)

    assert {:error, :stale_merge_identity} =
             PullMergeWorker.process_operation(operation, DateTime.utc_now(:second),
               merge_context: fn _, _ -> {:error, :stale_merge_identity} end,
               fail: fn ^operation, %DateTime{}, "local_validation", detail ->
                 send(parent, {:merge_failed, detail})
                 {:ok, :failed}
               end
             )

    assert_receive {:merge_failed, "coordinated merge state is invalid"}
  end

  test "processor timeout must remain strictly within the long lease margin" do
    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 1}, id: {:timeout_tasks, make_ref()})

    assert {:error, :unavailable} =
             PullMergeWorker.run_once("merge-lifecycle-test",
               task_supervisor: task_supervisor,
               lease_seconds: 1_860,
               processor_timeout_ms: 1_855_000,
               claim: fn _, _, _, _, _ -> flunk("invalid timeout must fail before claim") end
             )
  end

  defp start_worker(options) do
    parent = self()

    task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 2}, id: {:merge_tasks, make_ref()})

    loop_task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 1}, id: {:merge_loop, make_ref()})

    defaults = [
      name: nil,
      owner: "merge-lifecycle-test",
      interval_ms: 10,
      task_supervisor: task_supervisor,
      loop_task_supervisor: loop_task_supervisor,
      claim: fn "merge-lifecycle-test", %DateTime{}, lease, batch, kinds ->
        send(parent, {:merge_claimed, lease, batch, kinds})
        {:ok, []}
      end
    ]

    start_supervised!({PullMergeWorker, Keyword.merge(defaults, options)})
  end

  defp operation(id) do
    %MirrorOperation{
      id: id,
      kind: "merge.pull",
      state: :processing,
      lease_owner: "merge-lifecycle-test",
      lease_expires_at: DateTime.add(DateTime.utc_now(:second), 1_860)
    }
  end
end
