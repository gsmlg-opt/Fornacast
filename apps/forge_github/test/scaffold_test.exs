defmodule ForgeGitHub.ScaffoldTest do
  use ExUnit.Case, async: true

  test "application starts bounded provider authentication and webhook infrastructure" do
    supervisor = Process.whereis(ForgeGitHub.Supervisor)

    assert is_pid(supervisor)

    children = Supervisor.which_children(supervisor)

    assert {ForgeGitHub.InstallationTokenBroker, broker, :worker,
            [ForgeGitHub.InstallationTokenBroker]} =
             List.keyfind(children, ForgeGitHub.InstallationTokenBroker, 0)

    assert {ForgeGitHub.TokenTaskSupervisor, task_supervisor, :supervisor, [Task.Supervisor]} =
             List.keyfind(children, ForgeGitHub.TokenTaskSupervisor, 0)

    assert {ForgeGitHub.PullSyncTaskSupervisor, pull_sync_task_supervisor, :supervisor,
            [Task.Supervisor]} =
             List.keyfind(children, ForgeGitHub.PullSyncTaskSupervisor, 0)

    assert {ForgeGitHub.PullSyncLoopTaskSupervisor, pull_sync_loop_task_supervisor, :supervisor,
            [Task.Supervisor]} =
             List.keyfind(children, ForgeGitHub.PullSyncLoopTaskSupervisor, 0)

    assert {ForgeGitHub.PullSyncWorker, pull_sync_worker, :worker, [ForgeGitHub.PullSyncWorker]} =
             List.keyfind(children, ForgeGitHub.PullSyncWorker, 0)

    assert {ForgeMirrors.WebhookWorker, webhook_worker, :worker, [ForgeMirrors.WebhookWorker]} =
             List.keyfind(children, ForgeMirrors.WebhookWorker, 0)

    assert is_pid(broker)
    assert is_pid(task_supervisor)
    assert is_pid(pull_sync_task_supervisor)
    assert is_pid(pull_sync_loop_task_supervisor)
    assert is_pid(pull_sync_worker)
    assert is_pid(webhook_worker)
    assert %{enabled: false} = :sys.get_state(webhook_worker)

    refute List.keyfind(children, ForgeGitHub.PullMergeWorker, 0)
    refute Process.whereis(ForgeGitHub.PullMergeWorker)
    refute Process.whereis(ForgeGitHub.PullMergeLoopTaskSupervisor)
    refute Process.whereis(ForgeGitHub.PullMergeTaskSupervisor)

    assert %{
             enabled: false,
             loop_task_supervisor: ForgeGitHub.PullSyncLoopTaskSupervisor,
             task_supervisor: ForgeGitHub.PullSyncTaskSupervisor
           } =
             :sys.get_state(pull_sync_worker)
  end

  test "context exposes stable provider boundary types" do
    assert {:ok, types} = Code.Typespec.fetch_types(ForgeGitHub)

    assert types
           |> Enum.map(fn {_kind, {name, _definition, args}} -> {name, length(args)} end)
           |> Enum.sort() == [external_id: 0, installation_id: 0, provider: 0]
  end

  test "pull sync operation supervision admits the supported concurrency maximum" do
    children =
      Enum.map(1..8, fn _ ->
        assert {:ok, pid} =
                 Task.Supervisor.start_child(ForgeGitHub.PullSyncTaskSupervisor, fn ->
                   receive do
                     :release -> :ok
                   end
                 end)

        pid
      end)

    assert {:error, :max_children} =
             Task.Supervisor.start_child(ForgeGitHub.PullSyncTaskSupervisor, fn -> :ok end)

    Enum.each(children, &send(&1, :release))
  end
end
