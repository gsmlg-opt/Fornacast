defmodule ForgeImports.RepositoryStager do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, RepositoryItem}
  alias ForgeRepos.Repository
  alias Fornacast.{Config, Repo, Storage}

  if Mix.env() == :test do
    @after_run_lock_hook_key {__MODULE__, :after_run_lock_hook}
    @after_capability_locks_hook_key {__MODULE__, :after_capability_locks_hook}
    @after_scan_hook_key {__MODULE__, :after_scan_hook}

    @doc false
    def with_test_after_run_lock_hook(hook, fun)
        when is_function(hook, 2) and is_function(fun, 0) do
      previous = Process.get(@after_run_lock_hook_key)
      Process.put(@after_run_lock_hook_key, hook)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@after_run_lock_hook_key),
          else: Process.put(@after_run_lock_hook_key, previous)
      end
    end

    defp after_run_lock(repo, run) do
      case Process.get(@after_run_lock_hook_key) do
        hook when is_function(hook, 2) -> hook.(repo, run)
        nil -> :ok
      end
    end

    @doc false
    def with_test_after_capability_locks_hook(hook, fun)
        when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@after_capability_locks_hook_key)
      Process.put(@after_capability_locks_hook_key, hook)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@after_capability_locks_hook_key),
          else: Process.put(@after_capability_locks_hook_key, previous)
      end
    end

    defp after_capability_locks do
      case Process.get(@after_capability_locks_hook_key) do
        hook when is_function(hook, 0) -> hook.()
        nil -> :ok
      end
    end

    @doc false
    def with_test_after_scan_hook(hook, fun)
        when is_function(hook, 1) and is_function(fun, 0) do
      previous = Process.get(@after_scan_hook_key)
      Process.put(@after_scan_hook_key, hook)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@after_scan_hook_key),
          else: Process.put(@after_scan_hook_key, previous)
      end
    end

    defp after_scan(path) do
      case Process.get(@after_scan_hook_key) do
        hook when is_function(hook, 1) -> hook.(path)
        nil -> :ok
      end
    end
  else
    defp after_run_lock(_repo, _run), do: :ok
    defp after_capability_locks, do: :ok
    defp after_scan(_path), do: :ok
  end

  @spec ensure_shadow(RepositoryItem.t()) ::
          {:ok, {RepositoryItem.t(), Repository.t()}} | {:error, atom()}
  def ensure_shadow(%RepositoryItem{state: :queued} = capability) do
    multi =
      Multi.new()
      |> Multi.run(:run, fn repo, _changes -> current_run(repo, capability) end)
      |> Multi.run(:capability, fn repo, %{run: run} ->
        current_capability(repo, capability, run)
      end)
      |> ForgeRepos.create_import_shadow(:shadow, capability.destination_owner_id, %{
        item_id: capability.id,
        generation: intended_generation(capability)
      })
      |> Multi.run(:item, fn repo, %{run: run, capability: current, shadow: shadow} ->
        persist_staging_intent(repo, run, current, shadow)
      end)

    case transact(multi) do
      {:ok, %{item: item, shadow: shadow}} -> {:ok, {item, shadow}}
      {:error, _step, reason, _changes} -> {:error, normalize_error(reason)}
    end
  end

  def ensure_shadow(%RepositoryItem{state: :staging_git} = capability) do
    multi =
      Multi.new()
      |> Multi.run(:run, fn repo, _changes -> current_run(repo, capability) end)
      |> Multi.run(:capability, fn repo, %{run: run} ->
        current_capability(repo, capability, run)
      end)
      |> Multi.run(:shadow, fn repo, %{capability: current} -> current_shadow(repo, current) end)

    case transact(multi) do
      {:ok, %{capability: item, shadow: shadow}} -> {:ok, {item, shadow}}
      {:error, _step, reason, _changes} -> {:error, normalize_error(reason)}
    end
  end

  def ensure_shadow(%RepositoryItem{}), do: {:error, :stale}

  @spec ensure_parent(Repository.t()) :: :ok | {:error, :storage_unavailable}
  def ensure_parent(%Repository{} = shadow) do
    destination = intended_path(shadow.storage_path)
    parent = Path.dirname(destination)

    with :ok <- ensure_directory_chain(Config.repo_storage_root(), parent),
         {:error, :enoent} <- File.lstat(destination) do
      :ok
    else
      _unsafe -> {:error, :storage_unavailable}
    end
  rescue
    File.Error -> {:error, :storage_unavailable}
    ArgumentError -> {:error, :storage_unavailable}
  end

  @doc false
  @spec scan_unsupported(Path.t(), String.t()) ::
          {:ok, %{lfs?: boolean(), submodules?: boolean(), truncated?: boolean()}}
  def scan_unsupported(path, default_branch, opts \\ [])

  def scan_unsupported(path, default_branch, opts)
      when is_binary(path) and is_binary(default_branch) and is_list(opts) do
    limits = scan_limits(opts)
    deadline = System.monotonic_time(:millisecond) + limits.deadline_ms

    with {:ok, oid} when is_binary(oid) <-
           GitCore.exact_ref(path, "refs/heads/#{default_branch}",
             deadline_ms: limits.deadline_ms
           ) do
      {attribute_paths, attributes_truncated?} =
        search_paths(path, oid, ".gitattributes", limits, deadline)

      {module_paths, modules_truncated?} =
        search_paths(path, oid, ".gitmodules", limits, deadline)

      {pointer_detected?, pointers_truncated?} =
        search_content(
          path,
          oid,
          "version https://git-lfs.github.com/spec/v1",
          limits,
          deadline
        )

      {attributes_detected?, attribute_bodies_truncated?} =
        scan_attribute_paths(path, oid, attribute_paths, limits, deadline)

      result = %{
        lfs?: pointer_detected? or attributes_detected?,
        submodules?: Enum.any?(module_paths, &(Path.basename(&1) == ".gitmodules")),
        truncated?:
          attributes_truncated? or modules_truncated? or pointers_truncated? or
            attribute_bodies_truncated?
      }

      after_scan(path)
      {:ok, result}
    else
      _unavailable -> {:ok, %{lfs?: false, submodules?: false, truncated?: true}}
    end
  end

  def scan_unsupported(_path, _default_branch, _opts),
    do: {:ok, %{lfs?: false, submodules?: false, truncated?: true}}

  defp current_run(repo, capability) do
    allowed_states =
      if capability.state == :queued,
        do: [:running],
        else: [
          :running,
          :cancel_requested,
          :canceled,
          :failed,
          :completed,
          :completed_with_warnings
        ]

    ImportRun
    |> where(
      [run],
      run.id == ^capability.import_run_id and run.state in ^allowed_states
    )
    |> maybe_lock()
    |> repo.one()
    |> case do
      %ImportRun{} = run ->
        after_run_lock(repo, run)
        {:ok, run}

      nil ->
        {:error, :lost_lease}
    end
  end

  defp current_capability(repo, capability, run) do
    item =
      RepositoryItem
      |> where(
        [item],
        item.id == ^capability.id and item.import_run_id == ^capability.import_run_id and
          item.lock_version == ^capability.lock_version and
          item.lease_owner == ^capability.lease_owner and item.selected == true and
          item.state == ^capability.state and is_nil(item.cleanup_state)
      )
      |> maybe_lock()
      |> repo.one()

    attempt =
      ImportAttempt
      |> where(
        [attempt],
        attempt.repository_item_id == ^capability.id and
          attempt.attempt_number == ^capability.attempt_count
      )
      |> maybe_lock()
      |> repo.one()

    :ok = after_capability_locks()
    now = DateTime.utc_now(:second)

    with %RepositoryItem{} = item <- item,
         %ImportAttempt{} = attempt <- attempt,
         true <- live_lease?(item, now),
         true <- run.id == item.import_run_id,
         true <- run.state != :running or attempt.state == :running do
      {:ok, item}
    else
      _stale -> {:error, :lost_lease}
    end
  end

  defp live_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp live_lease?(_item, _now), do: false

  defp current_shadow(repo, item) do
    expected_generation = intended_generation(item)

    query =
      from shadow in Repository,
        where:
          shadow.id == ^item.hidden_repository_id and
            shadow.owner_user_id == ^item.destination_owner_id and
            shadow.lifecycle == :importing and shadow.visibility == :private and
            shadow.generation == ^expected_generation and shadow.write_version == 0 and
            is_nil(shadow.deleted_at)

    case repo.one(query) do
      %Repository{} = shadow ->
        if intended_path(shadow.storage_path) == item.staged_storage_path and
             import_shadow_slug?(shadow.slug, item.id),
           do: {:ok, shadow},
           else: {:error, :ambiguous_staging}

      nil ->
        {:error, :ambiguous_staging}
    end
  end

  defp import_shadow_slug?(slug, item_id) when is_binary(slug) and is_integer(item_id) do
    Regex.match?(~r/\Aimport-#{item_id}-[0-9a-f]{24}\z/, slug)
  end

  defp import_shadow_slug?(_slug, _item_id), do: false

  defp persist_staging_intent(repo, run, current, shadow) do
    path = intended_path(shadow.storage_path)
    changeset = RepositoryItem.staging_intent_changeset(current, shadow.id, path)

    cond do
      not changeset.valid? -> {:error, :invalid_shadow}
      guard_run_for_intent(repo, run) != :ok -> {:error, :lost_lease}
      true -> persist_staging_changeset(repo, current, changeset)
    end
  end

  defp persist_staging_changeset(repo, current, changeset) do
    updates =
      changeset.changes
      |> Map.drop([:lock_version])
      |> Map.put(:updated_at, DateTime.utc_now(:second))
      |> Map.to_list()

    query =
      from item in RepositoryItem,
        where:
          item.id == ^current.id and item.lock_version == ^current.lock_version and
            item.lease_owner == ^current.lease_owner and
            item.lease_expires_at == ^current.lease_expires_at and item.state == :queued and
            is_nil(item.hidden_repository_id) and is_nil(item.staged_storage_path)

    case repo.update_all(query, set: updates, inc: [lock_version: 1]) do
      {1, _rows} ->
        case repo.get_by(RepositoryItem,
               id: current.id,
               lock_version: current.lock_version + 1,
               lease_owner: current.lease_owner,
               state: :staging_git
             ) do
          %RepositoryItem{} = item -> {:ok, item}
          nil -> {:error, :lost_lease}
        end

      {0, _rows} ->
        {:error, :lost_lease}
    end
  end

  defp guard_run_for_intent(repo, run) do
    case repo.update_all(
           from(candidate in ImportRun,
             where:
               candidate.id == ^run.id and candidate.lock_version == ^run.lock_version and
                 candidate.state == :running
           ),
           set: [updated_at: DateTime.utc_now(:second)],
           inc: [lock_version: 1]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :lost_lease}
    end
  end

  defp intended_generation(%RepositoryItem{conflict_action: :replace, replacement_generation: n})
       when is_integer(n) and n > 0,
       do: n + 1

  defp intended_generation(%RepositoryItem{}), do: 1

  defp intended_path(storage_path) do
    :ok = normalize_storage_path(Storage.validate_relative_storage_path(storage_path))
    root = Config.repo_storage_root()
    path = Path.expand(Path.join(root, storage_path))

    if String.starts_with?(path, root <> "/"), do: path, else: raise(ArgumentError)
  end

  defp normalize_storage_path(:ok), do: :ok
  defp normalize_storage_path({:error, _reason}), do: raise(ArgumentError)

  defp ensure_directory_chain(root, parent) do
    with :ok <- ensure_directory(root) do
      parent
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.reduce_while({:ok, root}, fn segment, {:ok, current} ->
        next = Path.join(current, segment)

        case ensure_directory(next) do
          :ok -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, ^parent} -> :ok
        _unsafe -> {:error, :unsafe_path}
      end
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:error, :enoent} -> mkdir_private(path)
      _unsafe -> {:error, :unsafe_path}
    end
  end

  defp search_paths(path, oid, query, limits, deadline) do
    case search(path, oid, query, :path, limits, deadline) do
      {:ok, result} ->
        paths = Enum.map(result.results, & &1.path)
        {paths, result.truncated_reasons != []}

      {:error, _reason} ->
        {[], true}
    end
  end

  defp search_content(path, oid, query, limits, deadline) do
    case search(path, oid, query, :content, limits, deadline) do
      {:ok, result} -> {result.results != [], result.truncated_reasons != []}
      {:error, _reason} -> {false, true}
    end
  end

  defp search(path, oid, query, scope, limits, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      GitCore.search_tree(path, oid, query,
        scope: scope,
        file_limit: limits.entry_limit,
        byte_limit: limits.byte_limit,
        result_limit: min(limits.entry_limit, 100),
        deadline_ms: min(remaining, 2_000)
      )
    else
      {:error, :deadline}
    end
  end

  defp scan_attribute_paths(path, oid, paths, limits, deadline) do
    paths
    |> Enum.filter(&(Path.basename(&1) == ".gitattributes"))
    |> Enum.reduce_while({false, false, 0}, fn attribute_path, {_lfs?, truncated?, bytes} ->
      remaining = limits.byte_limit - bytes

      cond do
        System.monotonic_time(:millisecond) >= deadline ->
          {:halt, {false, true, bytes}}

        remaining <= 0 ->
          {:halt, {false, true, bytes}}

        true ->
          limit = min(limits.blob_limit, remaining)

          case GitCore.read_blob(path, oid, attribute_path, limit: limit) do
            {:ok, %GitCore.Blob{} = blob} ->
              try do
                data = blob.data || ""
                detected? = lfs_attributes?(Path.basename(attribute_path), data)
                next = {detected?, truncated? or blob.truncated, bytes + byte_size(data)}
                if detected?, do: {:halt, next}, else: {:cont, next}
              after
                GitCore.release_blob(blob)
              end

            {:error, _reason} ->
              {:halt, {false, true, bytes}}
          end
      end
    end)
    |> then(fn {lfs?, truncated?, _bytes} -> {lfs?, truncated?} end)
  end

  defp lfs_attributes?(".gitattributes", data) when is_binary(data) do
    String.valid?(data) and Regex.match?(~r/(?:^|\s)filter\s*=\s*lfs(?:\s|$)/m, data)
  end

  defp lfs_attributes?(_basename, _data), do: false

  defp scan_limits(opts) do
    allowed = [:entry_limit, :byte_limit, :blob_limit, :deadline_ms]

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      %{
        entry_limit: bounded_limit(opts, :entry_limit, 10_000),
        byte_limit: bounded_limit(opts, :byte_limit, 8_388_608),
        blob_limit: bounded_limit(opts, :blob_limit, 4_096),
        deadline_ms: bounded_limit(opts, :deadline_ms, 5_000)
      }
    else
      raise ArgumentError, "invalid unsupported Git scan limits"
    end
  end

  defp bounded_limit(opts, key, hard) do
    case Keyword.get(opts, key, hard) do
      value when is_integer(value) and value > 0 -> min(value, hard)
      _invalid -> raise ArgumentError, "invalid unsupported Git scan limit"
    end
  end

  defp mkdir_private(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> ensure_directory(path)
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  defp transact(multi) do
    Persistence.with_retry(fn -> Repo.transaction(multi) end)
  end

  defp normalize_error(reason)
       when reason in [:lost_lease, :ambiguous_staging, :invalid_owner, :invalid_shadow],
       do: reason

  defp normalize_error(_reason), do: :persistence_unavailable

  defp maybe_lock(query) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
