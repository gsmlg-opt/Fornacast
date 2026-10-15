defmodule ForgeImports.AdminJobs do
  @moduledoc "Read-only operational job metadata for persisted site administrators."

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{PatSyncRepositoryResult, PatSyncRun, RepositoryItem}
  alias Fornacast.Repo

  @control "ForgeImports.SyncJobs.ControlWorker"
  @discovery "ForgeImports.SyncJobs.DiscoveryWorker"
  @repository "ForgeImports.SyncJobs.RepositoryWorker"
  @update "ForgeImports.SyncJobs.PatRepositoryWorker"
  @page_size 50
  @max_id 9_223_372_036_854_775_807

  def list_jobs(actor, params \\ %{}) do
    with :ok <- authorize(actor),
         :ok <- validate_keys(params),
         {:ok, page} <- page(Map.get(params, "page", "1")),
         {:ok, state} <- state(Map.get(params, "state", "")),
         queues = queues(),
         {:ok, queue} <- queue(Map.get(params, "queue", ""), queues) do
      rows = jobs(queue, state, page)
      visible = Enum.take(rows, @page_size)
      paths = task_paths(visible)

      jobs =
        Enum.map(visible, fn row ->
          {reference, job} = Map.pop(row, :task_reference)
          Map.put(job, :task_path, paths[{row.worker, reference_id(reference)}])
        end)

      {:ok,
       %{
         jobs: jobs,
         queues: queues,
         filters: %{queue: queue, state: state},
         page: page,
         has_next?: page < 10_000 and length(rows) > @page_size
       }}
    end
  end

  defp authorize(%User{id: id}) when is_integer(id) and id > 0 and id <= @max_id do
    case ForgeAccounts.get_session_user(id) do
      %User{kind: :user, role: :admin, state: :active} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_), do: {:error, :forbidden}

  defp validate_keys(params) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 in ["queue", "state", "page"])),
      do: :ok,
      else: {:error, :invalid_filter}
  end

  defp validate_keys(_), do: {:error, :invalid_filter}

  defp page(value) when is_integer(value) and value in 1..10_000, do: {:ok, value}

  defp page(value) when is_binary(value) and byte_size(value) in 1..5 do
    if value =~ ~r/\A[0-9]+\z/ do
      {number, ""} = Integer.parse(value)
      page(number)
    else
      {:error, :invalid_filter}
    end
  end

  defp page(_), do: {:error, :invalid_filter}

  defp state(""), do: {:ok, nil}

  defp state(value) when is_binary(value) do
    if value in Enum.map(Styx.Job.states(), &to_string/1),
      do: {:ok, value},
      else: {:error, :invalid_filter}
  end

  defp state(_), do: {:error, :invalid_filter}

  defp queue("", _queues), do: {:ok, nil}

  defp queue(value, queues) when is_binary(value) and byte_size(value) <= 255 do
    if value in queues, do: {:ok, value}, else: {:error, :invalid_filter}
  end

  defp queue(_, _), do: {:error, :invalid_filter}

  defp queues do
    configured =
      case Application.get_env(:forge_imports, Styx, []) |> Keyword.get(:queues) do
        queues when is_list(queues) -> Enum.map(queues, fn {name, _opts} -> to_string(name) end)
        _ -> []
      end

    stored = Repo.all(from job in Styx.Job, distinct: true, select: job.queue)
    Enum.sort(Enum.uniq(configured ++ stored))
  end

  defp jobs(queue, state, page) do
    filters = Enum.reject([queue: queue, state: state], fn {_key, value} -> is_nil(value) end)

    filters
    |> Styx.Job.query()
    |> order_by([job], desc: job.id)
    |> offset(^((page - 1) * @page_size))
    |> limit(^(@page_size + 1))
    |> select([job], %{
      id: job.id,
      state: job.state,
      queue: job.queue,
      worker: job.worker,
      attempt: job.attempt,
      max_attempts: job.max_attempts,
      priority: job.priority,
      inserted_at: job.inserted_at,
      scheduled_at: job.scheduled_at,
      attempted_at: job.attempted_at,
      completed_at: job.completed_at,
      discarded_at: job.discarded_at,
      cancelled_at: job.cancelled_at,
      error_count: fragment("cardinality(?)", job.errors),
      task_reference:
        fragment(
          "?->>(CASE ? WHEN ? THEN 'pat_sync_run_id' WHEN ? THEN 'import_run_id' WHEN ? THEN 'repository_item_id' WHEN ? THEN 'result_id' END)",
          job.args,
          job.worker,
          ^@control,
          ^@discovery,
          ^@repository,
          ^@update
        )
    })
    |> Repo.all()
  end

  defp task_paths(rows) do
    rows
    |> Enum.group_by(& &1.worker, &reference_id(&1.task_reference))
    |> Enum.reduce(%{}, fn {worker, references}, paths ->
      ids = references |> Enum.reject(&is_nil/1) |> Enum.uniq()

      if ids == [] do
        paths
      else
        worker
        |> task_query(ids)
        |> Repo.all()
        |> Enum.reduce(paths, fn {reference, username, run_id}, acc ->
          Map.put(
            acc,
            {worker, reference},
            "/organizations/#{username}/settings/github/runs/#{run_id}"
          )
        end)
      end
    end)
  end

  defp reference_id(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= @max_id -> id
      _ -> nil
    end
  end

  defp reference_id(_), do: nil

  defp task_query(worker, ids) do
    base =
      from run in PatSyncRun,
        join: organization in User,
        on: organization.id == run.organization_id,
        where: organization.kind == :organization

    case worker do
      @control ->
        from [run, organization] in base,
          where: run.id in ^ids,
          select: {run.id, organization.username, run.id}

      @discovery ->
        from [run, organization] in base,
          where: run.import_run_id in ^ids,
          select: {run.import_run_id, organization.username, run.id}

      @repository ->
        from [run, organization] in base,
          join: item in RepositoryItem,
          on: item.import_run_id == run.import_run_id,
          where: item.id in ^ids,
          select: {item.id, organization.username, run.id}

      @update ->
        from [run, organization] in base,
          join: result in PatSyncRepositoryResult,
          on: result.pat_sync_run_id == run.id,
          where: result.id in ^ids,
          select: {result.id, organization.username, run.id}
    end
  end
end
