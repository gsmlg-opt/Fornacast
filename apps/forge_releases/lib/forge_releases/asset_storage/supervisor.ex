defmodule ForgeReleases.AssetStorage.Supervisor do
  @moduledoc false

  use Supervisor

  alias ForgeReleases.AssetStorage.{Config, LocalCAS, Manager}

  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    config = Config.load!()
    :ok = LocalCAS.preflight(config)

    children = [
      {DynamicSupervisor,
       strategy: :one_for_one, name: ForgeReleases.AssetStorage.InstanceSupervisor},
      {Manager, config: config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
