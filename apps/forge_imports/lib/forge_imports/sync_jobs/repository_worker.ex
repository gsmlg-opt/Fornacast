defmodule ForgeImports.SyncJobs.RepositoryWorker do
  @moduledoc false
  use Styx.Worker,
    queue: :github_import,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ForgeImports.SyncJobs.Execution
  @impl Styx.Worker
  def timeout(_job), do: :timer.hours(1)

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"repository_item_id" => id}} = job) do
    item = Fornacast.Repo.get(ForgeImports.RepositoryItem, id)

    cond do
      is_nil(item) or to_string(item.state) != job.args["phase"] ->
        :ok

      Execution.expired?(job) ->
        Execution.exhausted(job)
        {:cancel, :sync_deadline_exceeded}

      true ->
        result =
          ForgeImports.Worker.run(
            id,
            Execution.owner(job),
            Execution.options(:repository)
            |> Keyword.put_new(:repository_worker_options, lease_seconds: 2_400)
          )

        item = Fornacast.Repo.get!(ForgeImports.RepositoryItem, id)

        if item.state in [:failed, :canceled, :published, :completed, :awaiting_credential],
          do: ForgeImports.RunAggregator.finish_if_terminal(item.import_run_id)

        ForgeImports.SyncJobs.notify_import(item.import_run_id)
        Execution.result(job, result)
    end
  end
end
