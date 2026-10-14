defmodule ForgeImports.SyncJobs.PatRepositoryWorker do
  @moduledoc false
  use Styx.Worker,
    queue: :github_update,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable],
      keys: [:result_id]
    ]

  alias ForgeImports.SyncJobs.Execution
  @impl Styx.Worker
  def timeout(_job), do: :timer.hours(1)

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"result_id" => id}} = job) do
    row = Fornacast.Repo.get(ForgeImports.PatSyncRepositoryResult, id)
    run = if row, do: Fornacast.Repo.get(ForgeImports.PatSyncRun, row.pat_sync_run_id)

    cond do
      is_nil(row) or is_nil(run) or row.state in ["succeeded", "failed"] or
          run.state in ["succeeded", "failed"] ->
        :ok

      Execution.expired?(job) ->
        Execution.exhausted(job)
        {:cancel, :sync_deadline_exceeded}

      true ->
        Execution.result(
          job,
          ForgeImports.PatSyncWorker.perform_repository(id, Execution.options(:update))
        )
    end
  end
end
