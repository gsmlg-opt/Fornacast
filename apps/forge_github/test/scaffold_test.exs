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

    assert {ForgeMirrors.WebhookWorker, webhook_worker, :worker, [ForgeMirrors.WebhookWorker]} =
             List.keyfind(children, ForgeMirrors.WebhookWorker, 0)

    assert is_pid(broker)
    assert is_pid(task_supervisor)
    assert is_pid(webhook_worker)
    assert %{enabled: false} = :sys.get_state(webhook_worker)
  end

  test "context exposes stable provider boundary types" do
    assert {:ok, types} = Code.Typespec.fetch_types(ForgeGitHub)

    assert types
           |> Enum.map(fn {_kind, {name, _definition, args}} -> {name, length(args)} end)
           |> Enum.sort() == [external_id: 0, installation_id: 0, provider: 0]
  end
end
