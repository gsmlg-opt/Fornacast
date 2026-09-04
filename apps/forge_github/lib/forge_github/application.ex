defmodule ForgeGitHub.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    _validated_configuration =
      :forge_github
      |> Application.get_env(:app_configuration, :disabled)
      |> ForgeGitHub.AppConfig.validate!()

    children = [
      {Task.Supervisor, name: ForgeGitHub.TokenTaskSupervisor, max_children: 16},
      {ForgeGitHub.InstallationTokenBroker,
       task_supervisor: ForgeGitHub.TokenTaskSupervisor, max_inflight: 16, max_entries: 256}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ForgeGitHub.Supervisor)
  end
end
