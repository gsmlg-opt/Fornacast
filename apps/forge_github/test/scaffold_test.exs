defmodule ForgeGitHub.ScaffoldTest do
  use ExUnit.Case, async: true

  test "application starts only bounded provider authentication infrastructure" do
    supervisor = Process.whereis(ForgeGitHub.Supervisor)

    assert is_pid(supervisor)

    assert [
             {ForgeGitHub.InstallationTokenBroker, broker, :worker,
              [ForgeGitHub.InstallationTokenBroker]},
             {ForgeGitHub.TokenTaskSupervisor, task_supervisor, :supervisor, [Task.Supervisor]}
           ] = Enum.sort(Supervisor.which_children(supervisor))

    assert is_pid(broker)
    assert is_pid(task_supervisor)
  end

  test "context exposes stable provider boundary types" do
    assert {:ok, types} = Code.Typespec.fetch_types(ForgeGitHub)

    assert types
           |> Enum.map(fn {_kind, {name, _definition, args}} -> {name, length(args)} end)
           |> Enum.sort() == [external_id: 0, installation_id: 0, provider: 0]
  end
end
