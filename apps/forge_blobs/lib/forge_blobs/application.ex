defmodule ForgeBlobs.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [ForgeBlobs.Supervisor],
      strategy: :one_for_one,
      name: ForgeBlobs.ApplicationSupervisor
    )
  end
end
