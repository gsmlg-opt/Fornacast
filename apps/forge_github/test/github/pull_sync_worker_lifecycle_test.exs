defmodule ForgeGitHub.PullSyncWorkerLifecycleTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.PullSyncWorker

  test "explicitly disabled workers neither poll at startup nor reactivate on a queued tick" do
    worker = start_worker(enabled: false)
    refute_receive :pull_claimed, 40
    send(worker, :tick)
    assert %{enabled: false} = :sys.get_state(worker)
    refute_receive :pull_claimed, 40
  end

  test "the application test configuration disables polling when no option is supplied" do
    worker = start_worker([])
    refute_receive :pull_claimed, 40
    assert %{enabled: false} = :sys.get_state(worker)
  end

  test "explicit enablement starts the bounded claim loop" do
    worker = start_worker(enabled: true)
    assert_receive :pull_claimed, 1_000
    assert %{enabled: true} = :sys.get_state(worker)
  end

  test "an enabled worker restarts its claim loop after a task crash" do
    parent = self()

    worker =
      start_worker(
        enabled: true,
        runner: fn ->
          send(parent, :pull_sync_task_started)
          raise "boom"
        end
      )

    assert_receive :pull_sync_task_started, 1_000
    assert_eventually(fn -> :sys.get_state(worker).task_ref == nil end)

    send(worker, :tick)
    assert_receive :pull_sync_task_started, 1_000
  end

  test "the default claim loop leaves both bounded operation slots available" do
    parent = self()

    operations = [
      %ForgeMirrors.MirrorOperation{
        id: 1,
        kind: "reconcile.repository.pull_heads",
        state: :processing
      },
      %ForgeMirrors.MirrorOperation{
        id: 2,
        kind: "reconcile.repository.pull_heads",
        state: :processing
      }
    ]

    worker =
      start_worker(
        enabled: true,
        claim: fn "pull-lifecycle-test",
                  %DateTime{},
                  60,
                  2,
                  ["sync.pull", "reconcile.repository.pull_heads"] ->
          {:ok, operations}
        end,
        reconcile_pull_heads: fn operation, %DateTime{} ->
          send(parent, {:pull_operation_started, operation.id, self()})

          receive do
            :release -> {:ok, operation.id}
          end
        end
      )

    assert_receive {:pull_operation_started, first_id, first_pid}, 1_000
    assert_receive {:pull_operation_started, second_id, second_pid}, 1_000
    assert MapSet.new([first_id, second_id]) == MapSet.new([1, 2])
    assert first_pid != second_pid

    send(first_pid, :release)
    send(second_pid, :release)
    assert %{enabled: true} = :sys.get_state(worker)
  end

  test "the production operation supervisor capacity covers the supported concurrency maximum" do
    parent = self()

    operations =
      Enum.map(1..8, fn id ->
        %ForgeMirrors.MirrorOperation{
          id: id,
          kind: "reconcile.repository.pull_heads",
          state: :processing
        }
      end)

    _worker =
      start_worker(
        enabled: true,
        task_max_children: 8,
        batch_size: 8,
        max_concurrency: 8,
        claim: fn "pull-lifecycle-test",
                  %DateTime{},
                  60,
                  8,
                  ["sync.pull", "reconcile.repository.pull_heads"] ->
          {:ok, operations}
        end,
        reconcile_pull_heads: fn operation, %DateTime{} ->
          send(parent, {:maximum_pull_operation_started, operation.id, self()})

          receive do
            :release -> {:ok, operation.id}
          end
        end
      )

    started =
      Enum.map(1..8, fn _ ->
        assert_receive {:maximum_pull_operation_started, id, pid}, 1_000
        {id, pid}
      end)

    assert started |> Enum.map(&elem(&1, 0)) |> MapSet.new() == MapSet.new(1..8)
    assert started |> Enum.map(&elem(&1, 1)) |> MapSet.new() |> MapSet.size() == 8
    Enum.each(started, fn {_id, pid} -> send(pid, :release) end)
  end

  defp start_worker(options) do
    parent = self()

    {task_max_children, options} = Keyword.pop(options, :task_max_children, 2)

    task_supervisor =
      start_supervised!(
        {Task.Supervisor, max_children: task_max_children},
        id: {:pull_tasks, make_ref()}
      )

    loop_task_supervisor =
      start_supervised!({Task.Supervisor, max_children: 1}, id: {:pull_loop, make_ref()})

    options =
      Keyword.merge(
        [
          name: nil,
          owner: "pull-lifecycle-test",
          interval_ms: 10,
          task_supervisor: task_supervisor,
          loop_task_supervisor: loop_task_supervisor,
          claim: fn "pull-lifecycle-test",
                    %DateTime{},
                    60,
                    2,
                    ["sync.pull", "reconcile.repository.pull_heads"] ->
            send(parent, :pull_claimed)
            {:ok, []}
          end
        ],
        options
      )

    start_supervised!({PullSyncWorker, options})
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("expected condition to become true")
end
