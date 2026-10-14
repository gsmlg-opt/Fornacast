defmodule ForgeImports.SyncJobs do
  @moduledoc "Durable GitHub execution admission and crash-gap recovery through Styx."
  import Ecto.Query
  alias ForgeImports.{ImportRun, PatSyncRun, PatSyncRepositoryResult, RepositoryItem, Scheduler}

  alias ForgeImports.SyncJobs.{
    ControlWorker,
    DiscoveryWorker,
    RepositoryWorker,
    PatRepositoryWorker
  }

  alias Fornacast.Repo

  def enqueue_pat_sync(id), do: insert(ControlWorker, %{"pat_sync_run_id" => id})
  def enqueue_discovery(id), do: insert(DiscoveryWorker, %{"import_run_id" => id})

  def enqueue_repository(id) do
    case Repo.get(RepositoryItem, id) do
      %RepositoryItem{state: state} = item
      when state in [
             :queued,
             :staging_git,
             :git_staged,
             :staging_metadata,
             :ready_to_publish,
             :publishing
           ] ->
        insert(
          RepositoryWorker,
          %{
            "repository_item_id" => id,
            "phase" => to_string(state),
            "generation" => item.lock_version
          },
          scheduled_at: item.next_attempt_at || DateTime.utc_now()
        )

      _ ->
        {:ok, :ignored}
    end
  end

  def enqueue_update(id), do: insert(PatRepositoryWorker, %{"result_id" => id})

  def enqueue_run(id) do
    case Repo.get(ImportRun, id) do
      %ImportRun{state: :discovering} ->
        enqueue_discovery(id)

      %ImportRun{state: :awaiting_resolution, credential_source: :github_app} ->
        enqueue_discovery(id)

      %ImportRun{state: :running} ->
        Repo.all(
          from i in RepositoryItem,
            where: i.import_run_id == ^id and i.selected,
            select: i.id
        )
        |> Enum.each(&enqueue_repository!/1)

        {:ok, id}

      _ ->
        {:ok, :ignored}
    end
  end

  def notify_import(id) do
    Repo.all(
      from j in PatSyncRun,
        where: j.import_run_id == ^id and j.state in ["queued", "running"],
        select: j.id
    )
    |> Enum.each(fn id -> require_ok(enqueue_pat_sync(id)) end)

    :ok
  end

  def continue_item(item) do
    require_ok(enqueue_repository(item.id))
    notify_import(item.import_run_id)
    item
  end

  def enqueue_repository!(id), do: require_ok(enqueue_repository(id))
  def enqueue_run!(id), do: require_ok(enqueue_run(id))

  # Runs on deployment bootstrap and periodically. Existing domain leases remain authoritative.
  def recover(now \\ DateTime.utc_now(:second)) do
    reconcile_discarded()
    Scheduler.claimable_discovery_ids(now, 100) |> Enum.each(&require_ok(enqueue_discovery(&1)))

    Repo.all(
      from r in ImportRun,
        where: r.state == :awaiting_resolution and r.credential_source == :github_app,
        limit: 100,
        select: r.id
    )
    |> Enum.each(&require_ok(enqueue_discovery(&1)))

    Scheduler.claimable_item_ids(now, 100)
    |> Enum.reject(&active_delivery?("repository_item_id", &1))
    |> Enum.each(&enqueue_repository!/1)

    Repo.all(from j in PatSyncRun, where: j.state in ["queued", "running"], select: j.id)
    |> Enum.each(&require_ok(enqueue_pat_sync(&1)))

    Repo.all(
      from r in PatSyncRepositoryResult,
        join: parent in PatSyncRun,
        on: parent.id == r.pat_sync_run_id,
        where:
          parent.state in ["queued", "running"] and
            fragment("?->>'mode'", r.data) == "update" and r.state in ["pending", "running"] and
            (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now),
        select: r.id
    )
    |> Enum.each(&require_ok(enqueue_update(&1)))

    :ok
  end

  def reconcile_discarded do
    names =
      Enum.map(
        [ControlWorker, DiscoveryWorker, RepositoryWorker, PatRepositoryWorker],
        &Styx.Worker.to_string/1
      )

    Repo.all(
      from j in Styx.Job,
        where:
          j.worker in ^names and j.state == "discarded" and
            fragment("COALESCE(?->>'domain_reconciled', 'false')", j.meta) != "true",
        order_by: [asc: j.id],
        limit: 100
    )
    |> Enum.each(&require_ok(ForgeImports.SyncJobs.Execution.exhausted(&1)))

    :ok
  end

  def active_delivery?(key, id, newer_than \\ 0) do
    Repo.exists?(
      from j in Styx.Job,
        where:
          j.id > ^newer_than and j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>?", j.args, ^key) == ^to_string(id)
    )
  end

  defp insert(worker, args, opts \\ []), do: Styx.insert(worker.new(args, opts))
  defp require_ok(:ok), do: :ok
  defp require_ok({:ok, value}), do: value

  defp require_ok({:error, _}) do
    if Repo.in_transaction?(),
      do: Repo.rollback(:job_admission_failed),
      else: raise("GitHub job admission failed")
  end
end
