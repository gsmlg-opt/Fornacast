defmodule ForgeImports.Persistence do
  @moduledoc false

  import Ecto.Query

  alias ForgeImports.{CleanupOperation, ImportRun, RepositoryItem}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @turso_busy_attempts 12
  @turso_busy_backoff_ms 5

  if Mix.env() == :test do
    @adoption_safety_hook_key {__MODULE__, :adoption_safety_hook}

    @doc false
    def with_test_after_adoption_safety_hook(hook, fun)
        when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@adoption_safety_hook_key)
      Process.put(@adoption_safety_hook_key, hook)

      try do
        fun.()
      after
        if is_nil(previous),
          do: Process.delete(@adoption_safety_hook_key),
          else: Process.put(@adoption_safety_hook_key, previous)
      end
    end

    defp after_adoption_safety do
      case Process.get(@adoption_safety_hook_key) do
        hook when is_function(hook, 0) -> hook.()
        nil -> :ok
      end
    end
  else
    defp after_adoption_safety, do: :ok
  end

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
    with {:ok, predecessor} <- lock_predecessor(attrs),
         :ok <- ensure_optional_adoption_safe(predecessor) do
      %RepositoryItem{}
      |> RepositoryItem.discovery_changeset(Map.put(attrs, :import_run_id, run_id))
      |> Repo.insert()
    else
      {:error, :cleanup_conflict} -> {:error, :invalid_predecessor}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def ensure_adoption_safe_locked(repo, %RepositoryItem{} = item) when is_atom(repo) do
    repository_ids =
      [item.hidden_repository_id, item.replacement_repository_id]
      |> Enum.filter(&(is_integer(&1) and &1 > 0))

    cleanup? =
      repo.exists?(
        from cleanup in CleanupOperation,
          where:
            cleanup.repository_item_id == ^item.id or cleanup.repository_id in ^repository_ids
      )

    reclaimed? =
      repository_ids != [] and
        repo.exists?(
          from repository in Repository,
            where:
              repository.id in ^repository_ids and not is_nil(repository.storage_reclaimed_at)
        )

    if cleanup? or reclaimed? do
      {:error, :cleanup_conflict}
    else
      :ok = after_adoption_safety()
      :ok
    end
  rescue
    _error -> {:error, :cleanup_conflict}
  end

  @doc false
  def create_cleanup_operation(%RepositoryItem{id: item_id}, attrs)
      when is_integer(item_id) and item_id > 0 and is_map(attrs) do
    transaction = fn ->
      Repo.transaction(fn ->
        item =
          RepositoryItem
          |> where([candidate], candidate.id == ^item_id)
          |> maybe_lock()
          |> Repo.one()

        with %RepositoryItem{} = item <- item,
             :ok <- cleanup_identity_matches?(item, attrs),
             false <- successor_or_adopter_exists?(item),
             :ok <- ensure_adoption_safe_locked(Repo, item),
             changeset <- CleanupOperation.create_changeset(%CleanupOperation{}, attrs),
             {:ok, cleanup} <- Repo.insert(changeset) do
          cleanup
        else
          nil -> Repo.rollback(:not_found)
          true -> Repo.rollback(:adopted)
          {:error, :cleanup_conflict} -> Repo.rollback(:cleanup_conflict)
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
          false -> Repo.rollback(:stale)
          _invalid -> Repo.rollback(:stale)
        end
      end)
    end

    case with_retry(transaction) do
      {:ok, %CleanupOperation{} = cleanup} -> {:ok, cleanup}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :stale}
    end
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  def create_cleanup_operation(_item, _attrs), do: {:error, :stale}

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

  defp cleanup_identity_matches?(item, attrs) do
    item_id = Map.get(attrs, :repository_item_id) || Map.get(attrs, "repository_item_id")
    version = Map.get(attrs, :source_lock_version) || Map.get(attrs, "source_lock_version")

    if item_id == item.id and version == item.lock_version,
      do: :ok,
      else: {:error, :stale}
  end

  defp lock_predecessor(attrs) do
    predecessor_id = Map.get(attrs, :predecessor_item_id) || Map.get(attrs, "predecessor_item_id")

    case predecessor_id do
      nil ->
        {:ok, nil}

      id when is_integer(id) and id > 0 ->
        case RepositoryItem |> where([item], item.id == ^id) |> maybe_lock() |> Repo.one() do
          %RepositoryItem{} = item -> {:ok, item}
          nil -> {:error, :invalid_predecessor}
        end

      _invalid ->
        {:error, :invalid_predecessor}
    end
  end

  defp ensure_optional_adoption_safe(nil), do: :ok
  defp ensure_optional_adoption_safe(item), do: ensure_adoption_safe_locked(Repo, item)

  defp successor_or_adopter_exists?(item) do
    predecessor? =
      Repo.exists?(
        from candidate in RepositoryItem,
          where: candidate.predecessor_item_id == ^item.id
      )

    adopter? =
      is_integer(item.hidden_repository_id) and
        Repo.exists?(
          from candidate in RepositoryItem,
            where:
              candidate.id != ^item.id and
                candidate.hidden_repository_id == ^item.hidden_repository_id
        )

    predecessor? or adopter?
  end

  defp maybe_lock(query) do
    if turso?(), do: query, else: lock(query, "FOR UPDATE")
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
