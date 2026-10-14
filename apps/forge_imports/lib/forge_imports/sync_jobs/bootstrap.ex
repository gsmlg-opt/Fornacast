defmodule ForgeImports.SyncJobs.Bootstrap do
  @moduledoc false
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, true), do: send(self(), :bootstrap)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    ForgeImports.SyncJobs.MaintenanceWorker.new(%{}) |> Styx.insert!()
    {:noreply, state}
  end
end
