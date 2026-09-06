defmodule ForgeGitHub.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    app_configuration =
      :forge_github
      |> Application.get_env(:app_configuration, :disabled)
      |> ForgeGitHub.AppConfig.validate!()

    inventory_options =
      if app_configuration == :disabled,
        do: [enabled: false],
        else: []

    children = [
      {Task.Supervisor, name: ForgeGitHub.TokenTaskSupervisor, max_children: 16},
      {Task.Supervisor, name: ForgeGitHub.InventoryTaskSupervisor, max_children: 9},
      {Task.Supervisor, name: ForgeGitHub.GitRefTaskSupervisor, max_children: 5},
      {ForgeGitHub.InstallationTokenBroker,
       task_supervisor: ForgeGitHub.TokenTaskSupervisor, max_inflight: 16, max_entries: 256},
      {ForgeMirrors.WebhookWorker, processor: ForgeGitHub.WebhookProcessor},
      {ForgeGitHub.InventoryWorker,
       [task_supervisor: ForgeGitHub.InventoryTaskSupervisor] ++ inventory_options},
      {ForgeGitHub.GitRefWorker,
       [task_supervisor: ForgeGitHub.GitRefTaskSupervisor] ++ inventory_options}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ForgeGitHub.Supervisor)
  end
end
