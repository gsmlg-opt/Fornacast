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

  defp start_worker(options) do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    options =
      Keyword.merge(
        [
          name: nil,
          owner: "pull-lifecycle-test",
          interval_ms: 10,
          task_supervisor: supervisor,
          claim: fn "pull-lifecycle-test", %DateTime{}, 60, 2, ["sync.pull"] ->
            send(parent, :pull_claimed)
            {:ok, []}
          end
        ],
        options
      )

    start_supervised!({PullSyncWorker, options})
  end
end
