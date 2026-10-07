defmodule ForgeReleases.AssetMaintenance do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:maintain, state) do
    if ForgeReleases.AssetStorage.ready?() do
      ForgeReleases.Assets.recover()
      ForgeReleases.Assets.collect_garbage()
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :maintain, 30_000)
end
