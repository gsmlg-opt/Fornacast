defmodule ForgeImports.PatSyncQueries do
  @moduledoc "Organization-authorized, credential-free synchronization task views."
  import Ecto.Query
  alias ForgeImports.{ImportRun, PatSyncRun, PatSyncRepositoryResult, RepositoryItem, SafeValue}
  alias Fornacast.Repo

  def list_runs(actor, organization_id) do
    with {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      runs =
        Repo.all(
          from r in PatSyncRun,
            where: r.organization_id == ^organization_id,
            order_by: [desc: r.id],
            limit: 50
        )

      ids = Enum.map(runs, & &1.id)

      counts =
        Repo.all(
          from r in PatSyncRepositoryResult,
            where: r.pat_sync_run_id in ^ids,
            group_by: [r.pat_sync_run_id, r.state],
            select: {r.pat_sync_run_id, r.state, count(r.id)}
        )

      by_run = Enum.group_by(counts, &elem(&1, 0))

      {:ok,
       Enum.map(runs, fn run ->
         counts =
           case by_run[run.id] do
             nil -> Enum.frequencies_by(Map.values(run.progress), & &1["status"])
             rows -> Map.new(rows, fn {_id, state, count} -> {state, count} end)
           end

         total = Enum.sum(Map.values(counts))
         succeeded = counts["succeeded"] || 0
         failed = counts["failed"] || 0

         %{
           "id" => run.id,
           "status" => run.state,
           "github_organization" => safe(run.github_organization, 255),
           "requested_at" => iso(run.inserted_at),
           "started_at" => iso(run.started_at),
           "finished_at" => iso(run.finished_at),
           "total" => total,
           "succeeded" => succeeded,
           "failed" => failed,
           "pending" => total - succeeded - failed
         }
       end)}
    end
  end

  def get_run(actor, organization_id, id) do
    with {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 <- Integer.parse(to_string(id)),
         %PatSyncRun{} = run <-
           Repo.one(
             from r in PatSyncRun,
               where: r.id == ^id and r.organization_id == ^organization_id
           ) do
      {:ok, project(run)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp project(run) do
    configuration = Repo.get(ForgeMirrors.PatConfiguration, run.configuration_id)

    paused? =
      run.state in ["queued", "running"] and configuration != nil and configuration.paused and
        configuration.owner_user_id == run.owner_user_id and
        configuration.github_identity_id == run.github_identity_id and
        configuration.github_organization == run.github_organization

    import_run = if run.import_run_id, do: Repo.get(ImportRun, run.import_run_id)

    items =
      if import_run,
        do:
          Repo.all(
            from i in RepositoryItem,
              where: i.import_run_id == ^import_run.id and i.selected == true
          ),
        else: []

    snapshots = ForgeImports.PatSyncProgress.snapshots(items)
    items_by_id = Map.new(items, &{&1.id, &1})
    results = Repo.all(from r in PatSyncRepositoryResult, where: r.pat_sync_run_id == ^run.id)
    deliveries = deliveries(run, items, results)
    control = Enum.find(deliveries, &(&1.args["pat_sync_run_id"] == run.id))

    rows =
      if results == [] do
        Enum.map(run.progress, fn {id, data} ->
          item =
            case Integer.parse(id) do
              {id, ""} -> items_by_id[id]
              _ -> nil
            end

          row(data, item, snapshots, nil, delivery_for(deliveries, item, nil))
        end)
      else
        Enum.map(
          results,
          &row(
            &1.data,
            items_by_id[&1.repository_item_id],
            snapshots,
            &1,
            delivery_for(deliveries, items_by_id[&1.repository_item_id], &1)
          )
        )
      end

    rows = Enum.sort_by(rows, & &1["source_full_name"])

    updated_at =
      Enum.reduce(items ++ results, run.updated_at, fn item, latest ->
        if DateTime.compare(item.updated_at, latest) == :gt, do: item.updated_at, else: latest
      end)

    %{
      "id" => run.id,
      "status" => run.state,
      "terminal" => run.state not in ["queued", "running"],
      "phase" => run_phase(run, import_run),
      "error" => code(run.error),
      "execution_state" => if(control, do: to_string(control.state)),
      "worker_started_at" => if(control, do: iso(control.attempted_at)),
      "attempts" => if(control, do: control.attempt),
      "max_attempts" => if(control, do: control.max_attempts),
      "github_organization" => safe(run.github_organization, 255),
      "requested_at" => iso(run.inserted_at),
      "started_at" => iso(run.started_at),
      "heartbeat_at" => iso(run.heartbeat_at),
      "last_progress_at" => iso(run.last_progress_at),
      "updated_at" => iso(updated_at),
      "finished_at" => iso(run.finished_at),
      "observed_at" => iso(DateTime.utc_now(:second)),
      "wait_reason" =>
        if(paused?, do: "paused", else: if(import_run, do: code(import_run.wait_reason))),
      "next_attempt_at" => iso((import_run && import_run.next_attempt_at) || retry_at(control)),
      "warnings" => if(import_run, do: import_run.warning_count, else: 0),
      "total" => length(rows),
      "succeeded" => Enum.count(rows, &(&1["status"] == "succeeded")),
      "failed" => Enum.count(rows, &(&1["status"] == "failed")),
      "pending" => Enum.count(rows, &(&1["status"] not in ["succeeded", "failed"])),
      "repositories" => rows
    }
  end

  defp row(data, item, snapshots, result, delivery) do
    importing? = data["mode"] == "import" and item != nil

    status =
      cond do
        result && result.state == "failed" -> "failed"
        importing? -> item_status(item)
        result -> result.state
        true -> data["status"]
      end

    progress = if importing?, do: snapshots[item.id] || %{}, else: data["progress"] || %{}

    %{
      "source_full_name" =>
        safe(data["source_full_name"] || (item && item.source_full_name), 512),
      "mode" => code(data["mode"]),
      "status" => code(status),
      "phase" => if(importing?, do: to_string(item.state), else: code(progress["phase"])),
      "error" =>
        code(if(importing?, do: item.failure_kind || data["error"], else: data["error"])),
      "wait_reason" =>
        if(importing?, do: code(item.wait_reason), else: code(data["wait_reason"])),
      "next_attempt_at" => iso((importing? && item.next_attempt_at) || retry_at(delivery)),
      "execution_state" => if(delivery, do: to_string(delivery.state)),
      "attempts" => if(delivery, do: delivery.attempt),
      "max_attempts" => if(delivery, do: delivery.max_attempts),
      "import_attempts" => if(importing?, do: item.attempt_count, else: 0),
      "warnings" => if(importing?, do: item.warning_count, else: number(data["warnings"])),
      "progress" => %{
        "phase" => code(progress["phase"]),
        "completed" => number(progress["completed"]),
        "total" => number(progress["total"])
      }
    }
  end

  defp deliveries(run, items, results) do
    item_ids = Enum.map(items, &to_string(&1.id))
    result_ids = Enum.map(results, &to_string(&1.id))
    import_id = to_string(run.import_run_id || 0)
    run_id = to_string(run.id)

    Repo.all(
      from j in Styx.Job,
        where:
          j.queue in ["github_control", "github_discovery", "github_import", "github_update"],
        where:
          fragment("?->>'pat_sync_run_id'", j.args) == ^run_id or
            fragment("?->>'import_run_id'", j.args) == ^import_id or
            fragment("?->>'repository_item_id'", j.args) in ^item_ids or
            fragment("?->>'result_id'", j.args) in ^result_ids,
        order_by: [desc: j.id],
        select: %{
          args: j.args,
          state: j.state,
          attempt: j.attempt,
          max_attempts: j.max_attempts,
          scheduled_at: j.scheduled_at,
          attempted_at: j.attempted_at
        }
    )
  end

  defp delivery_for(deliveries, item, result) do
    Enum.find(deliveries, fn delivery ->
      (item != nil and delivery.args["repository_item_id"] == item.id) or
        (result != nil and delivery.args["result_id"] == result.id)
    end)
  end

  defp retry_at(%{state: state, scheduled_at: time}) when state in ["scheduled", "retryable"],
    do: time

  defp retry_at(_), do: nil

  defp item_status(%{state: state}) when state in [:published, :completed], do: "succeeded"
  defp item_status(%{state: state}) when state in [:failed, :canceled, :skipped], do: "failed"
  defp item_status(_), do: "pending"
  defp run_phase(%{state: "queued"}, _), do: "queued"
  defp run_phase(%{state: state}, _) when state not in ["queued", "running"], do: state
  defp run_phase(_, nil), do: "discovery"
  defp run_phase(_, run), do: to_string(run.state)
  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(_), do: 0
  defp code(nil), do: nil
  defp code(value) when is_binary(value) or is_atom(value), do: safe(to_string(value), 120)
  defp code(_), do: nil
  defp safe(value, size), do: SafeValue.classified_or_nil(value, size)
  defp iso(nil), do: nil
  defp iso(value), do: DateTime.to_iso8601(value)
end
