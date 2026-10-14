defmodule ForgeImports.SyncJobs.Execution do
  @moduledoc false
  import Ecto.Query

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    PatSyncRun,
    PatSyncRepositoryResult,
    RepositoryItem,
    Persistence
  }

  alias Fornacast.Repo

  @waits [
    :busy,
    :remote_busy,
    :request_gate_busy,
    :lost_lease,
    :pending,
    :paused,
    :primary_rate_limit,
    :secondary_rate_limit
  ]
  @deadline_seconds 86_400

  def owner(job), do: "styx-#{job.id}-#{job.attempt}"

  def expired?(job) do
    cond do
      paused?(job) ->
        put_wait_metadata(job, %{"explicit_pause" => true})
        false

      job.meta["explicit_pause"] == true ->
        put_wait_metadata(job, %{
          "explicit_pause" => false,
          "resumed_at" => DateTime.to_iso8601(DateTime.utc_now())
        })

        false

      true ->
        activity =
          case job.args do
            %{"pat_sync_run_id" => id} ->
              case Repo.get(PatSyncRun, id) do
                %PatSyncRun{last_progress_at: %DateTime{} = at} -> at
                _ -> job.inserted_at
              end

            _ ->
              job.inserted_at
          end

        resumed =
          case DateTime.from_iso8601(job.meta["resumed_at"] || "") do
            {:ok, at, _} -> at
            _ -> job.inserted_at
          end

        activity = if DateTime.compare(resumed, activity) == :gt, do: resumed, else: activity
        DateTime.diff(DateTime.utc_now(), activity, :second) >= @deadline_seconds
    end
  end

  defp put_wait_metadata(%{id: id} = job, fields) when is_integer(id) do
    Repo.update_all(from(j in Styx.Job, where: j.id == ^id),
      set: [meta: Map.merge(job.meta || %{}, fields)]
    )

    :ok
  end

  defp put_wait_metadata(_job, _fields), do: :ok

  def paused?(job) do
    pat_id =
      case job.args do
        %{"pat_sync_run_id" => id} ->
          id

        %{"result_id" => id} ->
          case Repo.get(PatSyncRepositoryResult, id) do
            nil -> nil
            row -> row.pat_sync_run_id
          end

        _ ->
          nil
      end

    import_id =
      case job.args do
        %{"import_run_id" => id} ->
          id

        %{"repository_item_id" => id} ->
          case Repo.get(RepositoryItem, id) do
            nil -> nil
            item -> item.import_run_id
          end

        _ ->
          nil
      end

    if pat_id || import_id do
      query =
        from j in PatSyncRun,
          join: c in ForgeMirrors.PatConfiguration,
          on: c.id == j.configuration_id,
          where: c.paused and j.state in ["queued", "running"]

      query =
        if pat_id,
          do: where(query, [j], j.id == ^pat_id),
          else: where(query, [j], j.import_run_id == ^import_id)

      Repo.exists?(query) or
        (not is_nil(import_id) and
           Repo.exists?(
             from m in ForgeMirrors.OrganizationMirror,
               where: m.bootstrap_import_run_id == ^import_id and m.state == :paused
           ))
    else
      false
    end
  end

  if Mix.env() == :test do
    def options(kind), do: Process.get({__MODULE__, kind}, [])

    def with_options(options, fun) do
      previous =
        for {kind, value} <- options do
          key = {__MODULE__, kind}
          old = Process.get(key)
          Process.put(key, value)
          {key, old}
        end

      try do
        fun.()
      after
        for {key, old} <- previous do
          if is_nil(old), do: Process.delete(key), else: Process.put(key, old)
        end
      end
    end
  else
    def options(_kind), do: []
  end

  def result(job, {:error, reason}) do
    cond do
      reason == :paused ->
        put_wait_metadata(job, %{"explicit_pause" => true})
        {:snooze, 30}

      reason in @waits and not expired?(job) ->
        {:snooze, 30}

      reason in [:awaiting_credential, :cancelled] ->
        :ok

      job.attempt >= job.max_attempts or expired?(job) ->
        exhausted(job)
        {:error, classify(reason)}

      true ->
        {:error, classify(reason)}
    end
  end

  def result(job, {:ok, :busy}), do: result(job, {:error, :busy})
  def result(_job, {:ok, _}), do: :ok
  def result(_job, :ok), do: :ok
  def result(job, :pending), do: result(job, {:error, :pending})
  def result(job, _), do: result(job, {:error, :invalid_worker_result})

  def classify(reason) when is_atom(reason), do: reason
  def classify(_), do: :sync_execution_failed

  def exhausted(%Styx.Job{args: args} = job) do
    Repo.transact(fn ->
      now = DateTime.utc_now(:second)

      cond do
        args["repository_item_id"] -> fail_item(args["repository_item_id"], now, job)
        args["result_id"] -> fail_result(args["result_id"], now)
        args["pat_sync_run_id"] -> fail_pat(args["pat_sync_run_id"], now)
        args["import_run_id"] -> fail_discovery(args["import_run_id"], now)
        true -> :ok
      end

      if is_nil(args["repository_item_id"]) and reconciled?(args), do: reconcile_job(job)
      {:ok, :ok}
    end)
    |> case do
      {:ok, _} ->
        if id = args["repository_item_id"] do
          case Repo.get(RepositoryItem, id) do
            nil -> :ok
            item -> ForgeImports.RunAggregator.finish_if_terminal(item.import_run_id)
          end
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fail_item(id, now, job) do
    snapshot = Repo.get(RepositoryItem, id)

    run =
      if snapshot,
        do:
          Repo.one(
            from r in ImportRun, where: r.id == ^snapshot.import_run_id, lock: "FOR UPDATE"
          )

    item = Repo.one(from i in RepositoryItem, where: i.id == ^id, lock: "FOR UPDATE")

    cond do
      is_nil(item) or is_nil(run) ->
        reconcile_job(job)

      item.state in [:published, :completed, :skipped, :failed, :canceled, :awaiting_credential] ->
        reconcile_job(job)

      to_string(item.state) != job.args["phase"] ->
        reconcile_job(job)

      ForgeImports.SyncJobs.active_delivery?("repository_item_id", id, job.id) ->
        reconcile_job(job)

      item.state == :publishing or not expired_lease?(item, now) ->
        :ok

      run.state != :running or not is_nil(item.cleanup_state) or item.publication_evidence != %{} ->
        :ok

      true ->
        failure_kind = item.failure_kind || "retry_exhausted"

        changeset =
          RepositoryItem.transition_changeset(item, :failed, %{
            failure_kind: failure_kind,
            failure_detail: nil,
            next_attempt_at: nil,
            wait_reason: nil,
            failure_count: item.failure_count + 1
          })

        with {:ok, _} <- Persistence.update_without_lease(item, [item.state], changeset, now) do
          Repo.all(
            from a in ImportAttempt, where: a.repository_item_id == ^id and a.state == :running
          )
          |> Enum.each(fn attempt ->
            attempt
            |> ImportAttempt.transition_changeset(:failed, %{
              terminal_at: now,
              failure_kind: failure_kind
            })
            |> Repo.update!()
          end)

          ForgeImports.SyncJobs.notify_import(item.import_run_id)
          reconcile_job(job)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp reconcile_job(%{id: id} = job) when is_integer(id) do
    Repo.update_all(from(j in Styx.Job, where: j.id == ^id),
      set: [meta: Map.put(job.meta || %{}, "domain_reconciled", true)]
    )

    :ok
  end

  defp reconcile_job(_), do: :ok

  defp reconciled?(%{"result_id" => id}) do
    row = Repo.get(PatSyncRepositoryResult, id)
    is_nil(row) or row.state in ["succeeded", "failed"]
  end

  defp reconciled?(%{"pat_sync_run_id" => id}) do
    run = Repo.get(PatSyncRun, id)
    is_nil(run) or run.state in ["succeeded", "failed"]
  end

  defp reconciled?(%{"import_run_id" => id}) do
    run = Repo.get(ImportRun, id)
    is_nil(run) or run.state != :discovering
  end

  defp reconciled?(_), do: true

  defp fail_result(id, now) do
    row = Repo.one(from r in PatSyncRepositoryResult, where: r.id == ^id, lock: "FOR UPDATE")

    if row && row.state in ["pending", "running"] && expired_lease?(row, now) do
      data =
        Map.merge(row.data, %{
          "status" => "failed",
          "error" => row.data["error"] || "retry_exhausted",
          "retry_exhausted" => true
        })

      Repo.update_all(from(r in PatSyncRepositoryResult, where: r.id == ^id),
        set: [
          state: "failed",
          data: data,
          finished_at: now,
          lease_owner: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

      case ForgeImports.SyncJobs.enqueue_pat_sync(row.pat_sync_run_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp fail_pat(id, now) do
    Repo.update_all(
      from(j in PatSyncRun,
        where:
          j.id == ^id and j.state in ["queued", "running"] and
            (is_nil(j.lease_expires_at) or j.lease_expires_at <= ^now)
      ),
      set: [
        state: "failed",
        error: "retry_exhausted",
        finished_at: now,
        lease_owner: nil,
        lease_expires_at: nil,
        updated_at: now
      ]
    )

    if Repo.get(PatSyncRun, id), do: ForgeImports.PatSyncWorker.record_summary(id)
  end

  defp fail_discovery(id, now) do
    Repo.update_all(
      from(r in ImportRun,
        where:
          r.id == ^id and r.state == :discovering and
            (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now)
      ),
      set: [
        state: :failed,
        failure_kind: "retry_exhausted",
        terminal_at: now,
        lease_owner: nil,
        lease_expires_at: nil,
        updated_at: now
      ]
    )

    ForgeImports.SyncJobs.notify_import(id)
  end

  defp expired_lease?(row, now),
    do: is_nil(row.lease_expires_at) or DateTime.compare(row.lease_expires_at, now) != :gt
end
