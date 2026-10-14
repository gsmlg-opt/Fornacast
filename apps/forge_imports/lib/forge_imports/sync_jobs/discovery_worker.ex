defmodule ForgeImports.SyncJobs.DiscoveryWorker do
  @moduledoc false
  use Styx.Worker,
    queue: :github_discovery,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable],
      keys: [:import_run_id]
    ]

  alias ForgeImports.SyncJobs.Execution
  @impl Styx.Worker
  def timeout(_job), do: :timer.hours(1)

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"import_run_id" => id}} = job) do
    run = Fornacast.Repo.get(ForgeImports.ImportRun, id)

    cond do
      is_nil(run) or run.state not in [:discovering, :awaiting_resolution] ->
        :ok

      Execution.expired?(job) ->
        Execution.exhausted(job)
        {:cancel, :sync_deadline_exceeded}

      true ->
        result =
          ForgeImports.Worker.run_discovery(
            id,
            Execution.owner(job),
            Execution.options(:discovery)
          )

        ForgeImports.SyncJobs.notify_import(id)
        Execution.result(job, result)
    end
  end
end
