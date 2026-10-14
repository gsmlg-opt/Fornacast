defmodule ForgeImports.Application do
  use Application

  @recovery_enabled Mix.env() != :test

  @impl true
  def start(_type, _args) do
    recovery_enabled = Application.get_env(:forge_imports, :recovery_enabled, @recovery_enabled)

    cleanup_enabled =
      Application.get_env(:forge_imports, :repository_cleanup_enabled, @recovery_enabled)

    styx = Application.fetch_env!(:forge_imports, Styx)

    children = [
      {Styx, styx},
      {ForgeImports.SyncJobs.Bootstrap, enabled: recovery_enabled},
      {ForgeImports.RecoverySupervisor,
       enabled: false, cleanup_enabled: cleanup_enabled, import_enabled: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ForgeImports.Supervisor)
  end
end
