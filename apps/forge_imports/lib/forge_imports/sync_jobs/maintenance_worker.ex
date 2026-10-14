defmodule ForgeImports.SyncJobs.MaintenanceWorker do
  @moduledoc false
  use Styx.Worker,
    queue: :github_maintenance,
    max_attempts: 5,
    unique: [
      period: 55,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Styx.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Styx.Worker
  def perform(_job) do
    :ok = ForgeImports.PatSyncScheduler.run_once()
    :ok = ForgeImports.SyncJobs.recover()
    # Preserve the GitHub App inventory branch formerly dispatched by Reconciler.
    case ForgeImports.OrganizationSync.InventoryImportWorker.run_once("styx-inventory") do
      {:ok, outcomes} ->
        case Enum.find(outcomes, fn {_id, result} -> match?({:error, _}, result) end) do
          {_id, {:error, reason}} -> {:error, ForgeImports.SyncJobs.Execution.classify(reason)}
          nil -> :ok
        end

      {:error, reason} ->
        {:error, ForgeImports.SyncJobs.Execution.classify(reason)}
    end
  end
end
