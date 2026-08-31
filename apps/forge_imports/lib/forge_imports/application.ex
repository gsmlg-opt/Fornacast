defmodule ForgeImports.Application do
  use Application

  @recovery_enabled Mix.env() != :test

  @impl true
  def start(_type, _args) do
    children = [
      {ForgeImports.RecoverySupervisor, enabled: @recovery_enabled}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ForgeImports.Supervisor)
  end
end
