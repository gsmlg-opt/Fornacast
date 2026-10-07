defmodule ForgeReleases.Application do
  @moduledoc false

  use Application

  @children [{Task.Supervisor, name: ForgeReleases.StorageTasks}] ++
              if(Mix.env() == :test, do: [], else: [ForgeReleases.AssetMaintenance])

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(@children, strategy: :one_for_one, name: ForgeReleases.Supervisor)
  end
end
