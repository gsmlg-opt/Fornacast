defmodule ForgeImports.Persistence do
  @moduledoc false

  import Ecto.Query

  alias ForgeImports.{ImportRun, RepositoryItem}
  alias Fornacast.Repo

  @turso_busy_attempts 12
  @turso_busy_backoff_ms 5

  @type mutation_error :: :not_found | :stale | :busy

  def insert_run(attrs) when is_map(attrs) do
    %ImportRun{}
    |> ImportRun.persistence_changeset(attrs)
    |> Repo.insert()
  end

  def insert_repository_item(attrs) when is_map(attrs) do
    %RepositoryItem{}
    |> RepositoryItem.persistence_changeset(attrs)
    |> Repo.insert()
  end

  def create_repository_item(%ImportRun{id: run_id}, attrs) when is_map(attrs) do
    %RepositoryItem{}
    |> RepositoryItem.discovery_changeset(Map.put(attrs, :import_run_id, run_id))
    |> Repo.insert()
  end

  def select_repository_item(%ImportRun{} = run, %RepositoryItem{} = item, selected)
      when is_boolean(selected) do
    selected_count =
      RepositoryItem
      |> where(
        [candidate],
        candidate.import_run_id == ^run.id and candidate.id != ^item.id and
          candidate.selected == true
      )
      |> Repo.aggregate(:count, :id)
      |> Kernel.+(if(selected, do: 1, else: 0))

    run_changeset = ImportRun.selected_count_changeset(run, selected_count)
    item_changeset = RepositoryItem.selection_changeset(item, %{selected: selected})

    with true <- run_changeset.valid?,
         true <- item_changeset.valid?,
         {:ok, updated_run} <-
           update_without_lease(run, [:awaiting_resolution], run_changeset),
         {:ok, updated_item} <-
           update_without_lease(item, [item.state], item_changeset) do
      {:ok, %{run: updated_run, item: updated_item}}
    else
      false -> {:error, :invalid_selection}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_selection}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_retry(callback) when is_function(callback, 0) do
    attempts = if turso?(), do: @turso_busy_attempts, else: 1
    retry(callback, attempts)
  end

  @spec update_without_lease(
          struct(),
          [atom()],
          Ecto.Changeset.t(),
          DateTime.t()
        ) :: {:ok, struct()} | {:error, Ecto.Changeset.t() | mutation_error()}
  def update_without_lease(row, allowed_states, changeset, now \\ DateTime.utc_now(:second))

  def update_without_lease(
        %{__struct__: module, id: id, lock_version: version} = row,
        allowed_states,
        %Ecto.Changeset{valid?: true} = changeset,
        %DateTime{} = now
      )
      when module in [ImportRun, RepositoryItem] and is_integer(id) and id > 0 and
             is_integer(version) and version > 0 and is_list(allowed_states) and
             allowed_states != [] do
    now = DateTime.truncate(now, :second)

    query =
      from record in module,
        where:
          record.id == ^id and record.lock_version == ^version and
            record.state in ^allowed_states and
            (is_nil(record.lease_expires_at) or record.lease_expires_at <= ^now)

    updates =
      changeset.changes
      |> Map.drop([:lock_version])
      |> Map.put(:updated_at, now)
      |> Map.to_list()

    case Repo.update_all(query, set: updates, inc: [lock_version: 1]) do
      {1, _} ->
        updated =
          changeset
          |> Ecto.Changeset.apply_changes()
          |> Map.put(:lock_version, version + 1)
          |> Map.put(:updated_at, now)

        {:ok, updated}

      {0, _} ->
        classify_miss(module, row, now)
    end
  end

  def update_without_lease(_row, _allowed_states, %Ecto.Changeset{} = changeset, _now),
    do: {:error, changeset}

  defp classify_miss(module, %{id: id}, now) do
    case Repo.get(module, id) do
      nil ->
        {:error, :not_found}

      %{lease_expires_at: %DateTime{} = expires_at} ->
        if DateTime.compare(expires_at, now) == :gt,
          do: {:error, :busy},
          else: {:error, :stale}

      _row ->
        {:error, :stale}
    end
  end

  defp retry(callback, attempts_remaining) do
    callback.()
  rescue
    error in Turso.Error ->
      if turso?() and error.code == :busy and attempts_remaining > 1 do
        attempt = @turso_busy_attempts - attempts_remaining + 1
        Process.sleep(attempt * @turso_busy_backoff_ms)
        retry(callback, attempts_remaining - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp turso? do
    Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"]
  end
end
