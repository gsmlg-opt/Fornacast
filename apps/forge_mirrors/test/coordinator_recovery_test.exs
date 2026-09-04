defmodule ForgeMirrors.CoordinatorRecoveryTest do
  use ExUnit.Case, async: false

  test "outbox coordinator observes a crashed task and schedules the next bounded run" do
    assert_coordinator_recovers(ForgeMirrors.OutboxDispatcher)
  end

  test "periodic coordinator observes a crashed task and schedules the next bounded run" do
    assert_coordinator_recovers(ForgeMirrors.PeriodicReconciler)
  end

  test "webhook coordinator observes a crashed task and schedules the next bounded run" do
    assert_coordinator_recovers(ForgeMirrors.WebhookWorker)
  end

  defp assert_coordinator_recovers(module) do
    parent = self()

    runner = fn ->
      send(parent, {:runner_started, self()})
      exit(:injected_task_crash)
    end

    assert {:ok, coordinator} =
             module.start_link(
               name: nil,
               enabled: true,
               interval_ms: 1,
               runner: runner
             )

    assert_receive {:runner_started, first_task}, 1_000
    assert_receive {:runner_started, second_task}, 1_000
    assert first_task != second_task
    assert Process.alive?(coordinator)

    GenServer.stop(coordinator)
  end
end
