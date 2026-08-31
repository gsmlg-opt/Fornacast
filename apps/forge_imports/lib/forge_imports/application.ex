defmodule ForgeImports.Application do
  use Application

  @recovery_enabled Mix.env() != :test

  @impl true
  def start(_type, _args) do
    recovery_enabled = Application.get_env(:forge_imports, :recovery_enabled, @recovery_enabled)

    cleanup_enabled =
      Application.get_env(:forge_imports, :repository_cleanup_enabled, @recovery_enabled)

    children = [
      {ForgeImports.RecoverySupervisor,
       enabled: recovery_enabled, cleanup_enabled: cleanup_enabled}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ForgeImports.Supervisor)
  end
end
