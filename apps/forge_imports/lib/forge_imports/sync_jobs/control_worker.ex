defmodule ForgeImports.SyncJobs.ControlWorker do
  @moduledoc false
  use Styx.Worker,
    queue: :github_control,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable],
      keys: [:pat_sync_run_id]
    ]

  alias ForgeImports.SyncJobs.Execution

  @impl Styx.Worker
  def timeout(_job), do: :timer.hours(1)

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"pat_sync_run_id" => id}} = job) do
    run = Fornacast.Repo.get(ForgeImports.PatSyncRun, id)

    cond do
      is_nil(run) or run.state in ["succeeded", "failed"] ->
        :ok

      Execution.expired?(job) ->
        Execution.exhausted(job)
        {:cancel, :sync_deadline_exceeded}

      true ->
        Execution.result(
          job,
          ForgeImports.PatSyncWorker.perform(
            id,
            [queued_updates: true] ++ Execution.options(:control)
          )
        )
    end
  end
end
