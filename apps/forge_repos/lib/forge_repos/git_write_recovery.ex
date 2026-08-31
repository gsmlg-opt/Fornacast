defmodule ForgeRepos.GitWriteRecovery do
  @moduledoc false

  @behaviour ForgeRepos.RepositoryWriteReconcilers

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts.User
  alias ForgeRepos.{GitWriteOperation, Repository}
  alias Fornacast.{Audit, OperationLease, Repo}

  @lease_seconds 30
  @terminal_states [:bookkeeping_complete, :failed]
  @complete_multi_hook_key {__MODULE__, :complete_multi_hook}
  @completion_clock_key {__MODULE__, :completion_clock}
  @iteration_clock_key {__MODULE__, :iteration_clock}
  @claim_observer_key {__MODULE__, :claim_observer}

  @doc false
  def with_test_complete_multi_hook(hook, fun)
      when is_function(hook, 2) and is_function(fun, 0) do
    previous = Process.get(@complete_multi_hook_key)
    Process.put(@complete_multi_hook_key, hook)

    try do
      fun.()
    after
      if previous == nil,
        do: Process.delete(@complete_multi_hook_key),
        else: Process.put(@complete_multi_hook_key, previous)
    end
  end

  @doc false
  def with_test_completion_clock(clock, fun)
      when is_function(clock, 0) and is_function(fun, 0) do
    previous = Process.get(@completion_clock_key)
    Process.put(@completion_clock_key, clock)

    try do
      fun.()
    after
      restore_process_value(@completion_clock_key, previous)
    end
  end

  @doc false
  def with_test_iteration_clock(clock, claim_observer, fun)
      when is_function(clock, 0) and is_function(claim_observer, 2) and is_function(fun, 0) do
    previous_clock = Process.get(@iteration_clock_key)
    previous_observer = Process.get(@claim_observer_key)
    Process.put(@iteration_clock_key, clock)
    Process.put(@claim_observer_key, claim_observer)

    try do
      fun.()
    after
      restore_process_value(@iteration_clock_key, previous_clock)
      restore_process_value(@claim_observer_key, previous_observer)
    end
  end

  @spec reconcile_repository(Repository.t()) :: :ok | {:error, {:unavailable, atom()}}
  def reconcile_repository(%Repository{id: repository_id} = repository)
      when is_integer(repository_id) do
    absolute_deadline =
      System.monotonic_time(:millisecond) + GitCore.Limits.get(:content_deadline_ms)

    case GitCore.RepositoryWriteLimiter.acquire(repository_id, absolute_deadline) do
      {:ok, lease} ->
        try do
          with {:ok, repository} <- reload_repository(repository),
               {:ok, repository_path} <- safe_repository_path(repository),
               :ok <-
                 reconcile_repository_locked(repository, repository_path, absolute_deadline) do
            :ok
          else
            _error -> {:error, {:unavailable, :git_write_recovery}}
          end
        after
          GitCore.RepositoryWriteLimiter.release(lease)
        end

      {:error, _reason} ->
        {:error, {:unavailable, :git_write_recovery}}
    end
  end

  defp reload_repository(%Repository{id: repository_id, generation: generation})
       when is_integer(repository_id) and repository_id > 0 and is_integer(generation) and
              generation > 0 do
    repository =
      Repository
      |> where(
        [repository],
        repository.id == ^repository_id and repository.generation == ^generation and
          repository.lifecycle == :ready and is_nil(repository.deleted_at)
      )
      |> Repo.one()

    if repository, do: {:ok, repository}, else: {:error, :stale_repository}
  end

  defp reload_repository(%Repository{}), do: {:error, :stale_repository}

  @impl true
  def reconcile_repository_locked(
        %Repository{id: repository_id} = repository,
        repository_path,
        absolute_deadline
      )
      when is_integer(repository_id) and is_binary(repository_path) and
             is_integer(absolute_deadline) do
    owner = lease_owner(repository_id)
    reconcile_next(repository, repository_path, absolute_deadline, owner, 0)
  end

  @impl true
  def cleanup_safety_locked(%Repository{id: repository_id}, %DateTime{} = now)
      when is_integer(repository_id) and repository_id > 0 do
    GitWriteOperation
    |> where([operation], operation.repository_id == ^repository_id)
    |> order_by([operation], asc: operation.id)
    |> maybe_lock()
    |> Repo.all()
    |> classify_cleanup_safety(now, GitWriteOperation.terminal_states())
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def cleanup_safety_locked(_repository, _now), do: {:error, :unavailable}

  @impl true
  def cleanup_live_lease_expiry_locked(%Repository{id: repository_id}, %DateTime{} = now)
      when is_integer(repository_id) and repository_id > 0 do
    expiry =
      Repo.one(
        from operation in GitWriteOperation,
          where:
            operation.repository_id == ^repository_id and operation.state not in ^@terminal_states and
              not is_nil(operation.lease_owner) and operation.lease_expires_at > ^now,
          select: max(operation.lease_expires_at)
      )

    {:ok, expiry}
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def cleanup_live_lease_expiry_locked(_repository, _now), do: {:error, :unavailable}

  defp reconcile_next(repository, repository_path, absolute_deadline, owner, after_id) do
    with :ok <- check_deadline(absolute_deadline) do
      now = iteration_now()

      case next_operation(repository.id, after_id) do
        nil ->
          :ok

        %GitWriteOperation{} = operation ->
          reconcile_operation(
            repository,
            repository_path,
            operation,
            absolute_deadline,
            owner,
            now
          )
          |> case do
            :ok ->
              reconcile_next(
                repository,
                repository_path,
                absolute_deadline,
                owner,
                operation.id
              )

            :busy ->
              {:error, :unavailable}

            {:error, :unavailable} = error ->
              error
          end
      end
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp next_operation(repository_id, after_id) do
    GitWriteOperation
    |> where([operation], operation.repository_id == ^repository_id)
    |> where([operation], operation.state not in ^@terminal_states)
    |> where([operation], operation.id > ^after_id)
    |> order_by([operation], asc: operation.id)
    |> limit(1)
    |> Repo.one()
  end

  defp classify_cleanup_safety(operations, now, terminal_states) do
    flags =
      Enum.reduce(operations, MapSet.new(), fn operation, flags ->
        terminal? = operation.state in terminal_states
        owner = operation.lease_owner
        expires_at = operation.lease_expires_at

        cond do
          terminal? and (not is_nil(owner) or not is_nil(expires_at)) ->
            MapSet.put(flags, :inconsistent_lease)

          (is_nil(owner) and not is_nil(expires_at)) or
            (not is_nil(owner) and is_nil(expires_at)) or owner == "" ->
            MapSet.put(flags, :inconsistent_lease)

          terminal? ->
            flags

          is_nil(owner) ->
            MapSet.put(flags, :claimable_operation)

          DateTime.compare(expires_at, now) == :gt ->
            MapSet.put(flags, :live_lease)

          true ->
            MapSet.put(flags, :claimable_operation)
        end
      end)

    cond do
      MapSet.member?(flags, :inconsistent_lease) -> {:blocked, :inconsistent_lease}
      MapSet.member?(flags, :live_lease) -> {:blocked, :live_lease}
      MapSet.member?(flags, :claimable_operation) -> {:blocked, :claimable_operation}
      true -> :safe
    end
  end

  defp maybe_lock(query) do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"],
      do: lock(query, "FOR UPDATE"),
      else: query
  end

  defp reconcile_operation(
         repository,
         repository_path,
         operation,
         absolute_deadline,
         owner,
         now
       ) do
    with :ok <- check_deadline(absolute_deadline),
         {:ok, claimed} <- claim(operation, owner, now) do
      try do
        notify_claim_observer(claimed, now)

        with :ok <- check_deadline_or_release(claimed, absolute_deadline),
             {:ok, current_oid} <- read_current_ref(repository_path, claimed, absolute_deadline) do
          classify(repository, repository_path, claimed, current_oid, absolute_deadline)
        end
      after
        _result = OperationLease.release(GitWriteOperation, claimed)
      end
    else
      :busy -> :busy
      {:error, :not_found} -> :busy
      {:error, :unavailable} = error -> error
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp claim(operation, owner, now) do
    OperationLease.claim(
      GitWriteOperation,
      operation.id,
      owner,
      now,
      @lease_seconds
    )
  end

  defp read_current_ref(repository_path, claimed, absolute_deadline) do
    remaining = absolute_deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case GitCore.exact_ref(repository_path, claimed.target_ref, deadline_ms: remaining) do
        {:ok, current_oid} -> {:ok, current_oid}
        {:error, _error} -> release_unavailable(claimed)
      end
    else
      release_unavailable(claimed)
    end
  end

  defp classify(repository, repository_path, operation, current_oid, absolute_deadline) do
    cond do
      current_oid == operation.proposed_oid ->
        complete(repository, repository_path, operation, absolute_deadline)

      current_oid == operation.expected_oid and operation.state == :prepared ->
        fail(operation, "effect_not_started", absolute_deadline)

      current_oid == operation.expected_oid and operation.state == :object_written ->
        fail(operation, "ref_not_advanced", absolute_deadline)

      true ->
        block(operation, current_oid, absolute_deadline)
    end
  end

  defp fail(operation, reason, absolute_deadline) do
    with :ok <- check_deadline_or_release(operation, absolute_deadline),
         {:ok, _operation} <-
           OperationLease.update_owned(GitWriteOperation, operation,
             state: :failed,
             failure_reason: reason
           ) do
      :ok
    else
      _error -> {:error, :unavailable}
    end
  end

  defp block(operation, current_oid, absolute_deadline) do
    with :ok <- check_deadline_or_release(operation, absolute_deadline),
         :ok <- mark_unexpected(operation),
         :ok <- record_blocked_audit(operation, current_oid) do
      {:error, :unavailable}
    else
      _error -> {:error, :unavailable}
    end
  end

  defp mark_unexpected(%GitWriteOperation{failure_reason: "unexpected_ref"} = operation) do
    OperationLease.release(GitWriteOperation, operation)
  end

  defp mark_unexpected(operation) do
    case OperationLease.update_owned(GitWriteOperation, operation,
           failure_reason: "unexpected_ref"
         ) do
      {:ok, _operation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp record_blocked_audit(operation, current_oid) do
    metadata = %{
      "ref" => operation.target_ref,
      "expected_oid" => operation.expected_oid,
      "proposed_oid" => operation.proposed_oid,
      "current_oid" => current_oid,
      "result" => "blocked"
    }

    case Audit.record(
           nil,
           "git.write.recovery_blocked",
           "repository",
           operation.repository_id,
           metadata,
           request_id: operation.request_id,
           operation_id: operation_id(operation)
         ) do
      {:ok, _audit} -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp complete(repository, repository_path, operation, absolute_deadline) do
    with :ok <- check_deadline_or_release(operation, absolute_deadline),
         {:ok, _changes} <- complete_transaction(repository, operation),
         :ok <- GitCore.invalidate_repository_cache(repository_path) do
      :ok
    else
      _error -> {:error, :unavailable}
    end
  end

  defp complete_transaction(repository, operation) do
    now = completion_now()
    actor = load_actor(operation.actor_user_id)

    operation_query =
      from candidate in GitWriteOperation,
        where:
          candidate.id == ^operation.id and candidate.lease_owner == ^operation.lease_owner and
            candidate.lock_version == ^operation.lock_version

    repository_query =
      from candidate in Repository,
        where:
          candidate.id == ^repository.id and candidate.generation == ^repository.generation and
            candidate.lifecycle == :ready and is_nil(candidate.deleted_at)

    multi =
      Multi.new()
      |> Multi.update_all(
        :operation,
        operation_query,
        set: [
          state: :bookkeeping_complete,
          failure_reason: nil,
          lease_owner: nil,
          lease_expires_at: nil,
          updated_at: now
        ],
        inc: [lock_version: 1]
      )
      |> require_one(:operation)
      |> Multi.update_all(:repository, repository_query,
        set: [last_pushed_at: now, updated_at: now],
        inc: [write_version: 1]
      )
      |> require_one(:repository)
      |> Audit.record_multi(
        :audit,
        actor,
        audit_action(operation.kind),
        "repository",
        repository.id,
        %{
          "ref" => operation.target_ref,
          "oid" => operation.proposed_oid,
          "result" => "success"
        },
        request_id: operation.request_id,
        operation_id: operation_id(operation)
      )

    multi =
      case Process.get(@complete_multi_hook_key) do
        hook when is_function(hook, 2) -> hook.(multi, operation)
        nil -> multi
      end

    Repo.transaction(multi)
  end

  defp require_one(multi, key) do
    Multi.run(multi, {key, :ownership}, fn _repo, changes ->
      case Map.fetch!(changes, key) do
        {1, _rows} -> {:ok, :owned}
        _other -> {:error, :lost_lease}
      end
    end)
  end

  defp audit_action(:ref_create), do: "git.ref.created"
  defp audit_action(:ref_update), do: "git.ref.updated"
  defp audit_action(:content_create), do: "git.content.created"
  defp audit_action(:content_update), do: "git.content.updated"
  defp audit_action(:content_delete), do: "git.content.deleted"
  defp audit_action(:receive_pack), do: "repository.pushed"

  defp load_actor(nil), do: nil
  defp load_actor(actor_user_id), do: Repo.get(User, actor_user_id)

  defp operation_id(operation), do: "git_write:" <> Integer.to_string(operation.id)

  defp completion_now do
    case Process.get(@completion_clock_key) do
      clock when is_function(clock, 0) -> clock.()
      nil -> DateTime.utc_now()
    end
    |> DateTime.truncate(:second)
  end

  defp check_deadline(absolute_deadline) do
    if System.monotonic_time(:millisecond) < absolute_deadline,
      do: :ok,
      else: {:error, :unavailable}
  end

  defp check_deadline_or_release(operation, absolute_deadline) do
    case check_deadline(absolute_deadline) do
      :ok -> :ok
      {:error, :unavailable} -> release_unavailable(operation)
    end
  end

  defp release_unavailable(operation) do
    _result = OperationLease.release(GitWriteOperation, operation)
    {:error, :unavailable}
  end

  defp lease_owner(repository_id) do
    "git-write-recovery:#{node()}:#{inspect(self())}:#{repository_id}"
  end

  defp iteration_now do
    case Process.get(@iteration_clock_key) do
      clock when is_function(clock, 0) -> clock.()
      nil -> DateTime.utc_now()
    end
    |> DateTime.truncate(:second)
  end

  defp notify_claim_observer(claimed, now) do
    case Process.get(@claim_observer_key) do
      observer when is_function(observer, 2) -> observer.(claimed, now)
      nil -> :ok
    end
  end

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp safe_repository_path(repository) do
    {:ok, ForgeRepos.absolute_storage_path(repository)}
  rescue
    File.Error -> {:error, :unavailable}
    ArgumentError -> {:error, :unavailable}
  end
end
