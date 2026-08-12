defmodule ForgePulls.MergeRecovery do
  @moduledoc false

  @behaviour ForgeRepos.RepositoryWriteReconcilers

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts.User
  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest}
  alias ForgeRepos.Repository
  alias Fornacast.{Audit, OperationLease, Repo}

  @lease_seconds 30
  @terminal_states [:completed, :failed]
  @iteration_clock_key {__MODULE__, :iteration_clock}
  @lease_owner_key {__MODULE__, :lease_owner}
  @claim_observer_key {__MODULE__, :claim_observer}

  if Mix.env() == :test do
    @complete_multi_hook_key {__MODULE__, :complete_multi_hook}
    @reconcile_observer_key {__MODULE__, :reconcile_observer}

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
    def with_test_iteration_context(clock, owner, observer, fun)
        when is_function(clock, 0) and is_binary(owner) and owner != "" and
               is_function(observer, 2) and is_function(fun, 0) do
      previous_clock = Process.get(@iteration_clock_key)
      previous_owner = Process.get(@lease_owner_key)
      previous_observer = Process.get(@claim_observer_key)
      Process.put(@iteration_clock_key, clock)
      Process.put(@lease_owner_key, owner)
      Process.put(@claim_observer_key, observer)

      try do
        fun.()
      after
        restore_process_value(@iteration_clock_key, previous_clock)
        restore_process_value(@lease_owner_key, previous_owner)
        restore_process_value(@claim_observer_key, previous_observer)
      end
    end

    @doc false
    def with_test_reconcile_observer(observer, fun)
        when is_function(observer, 0) and is_function(fun, 0) do
      previous = Process.get(@reconcile_observer_key)
      Process.put(@reconcile_observer_key, observer)

      try do
        fun.()
      after
        restore_process_value(@reconcile_observer_key, previous)
      end
    end

    defp restore_process_value(key, nil), do: Process.delete(key)
    defp restore_process_value(key, value), do: Process.put(key, value)

    defp apply_complete_multi_hook(multi, operation) do
      case Process.get(@complete_multi_hook_key) do
        hook when is_function(hook, 2) -> hook.(multi, operation)
        nil -> multi
      end
    end

    defp notify_reconcile_observer do
      case Process.get(@reconcile_observer_key) do
        observer when is_function(observer, 0) -> observer.()
        nil -> :ok
      end
    end
  else
    defp apply_complete_multi_hook(multi, _operation), do: multi
    defp notify_reconcile_observer, do: :ok
  end

  @impl true
  def reconcile_repository_locked(
        %Repository{id: repository_id} = repository,
        repository_path,
        absolute_deadline
      )
      when is_integer(repository_id) and is_binary(repository_path) and
             is_integer(absolute_deadline) do
    notify_reconcile_observer()

    reconcile_next(
      repository,
      repository_path,
      absolute_deadline,
      lease_owner(repository_id),
      0
    )
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp reconcile_next(repository, repository_path, absolute_deadline, owner, after_id) do
    with :ok <- check_deadline(absolute_deadline) do
      now = iteration_now()

      case next_operation(repository.id, after_id) do
        nil ->
          :ok

        %MergeOperation{} = operation ->
          case reconcile_operation(
                 repository,
                 repository_path,
                 operation,
                 absolute_deadline,
                 owner,
                 now
               ) do
            :ok ->
              reconcile_next(
                repository,
                repository_path,
                absolute_deadline,
                owner,
                operation.id
              )

            {:error, :unavailable} = error ->
              error
          end
      end
    end
  end

  defp next_operation(repository_id, after_id) do
    MergeOperation
    |> where([operation], operation.repository_id == ^repository_id)
    |> where([operation], operation.state not in ^@terminal_states)
    |> where([operation], operation.id > ^after_id)
    |> order_by([operation], asc: operation.id)
    |> limit(1)
    |> Repo.one()
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
         {:ok, claimed} <-
           OperationLease.claim(MergeOperation, operation.id, owner, now, @lease_seconds) do
      try do
        notify_claim_observer(claimed, now)

        with {:ok, current_oid} <- read_base_ref(repository_path, claimed, absolute_deadline) do
          classify(
            repository,
            repository_path,
            claimed,
            current_oid,
            absolute_deadline,
            owner,
            now
          )
        end
      after
        _result = OperationLease.release(MergeOperation, claimed)
      end
    else
      :busy -> {:error, :unavailable}
      {:error, :not_found} -> {:error, :unavailable}
      _error -> {:error, :unavailable}
    end
  end

  defp read_base_ref(repository_path, operation, absolute_deadline) do
    with {:ok, remaining} <- remaining_ms(absolute_deadline) do
      case GitCore.exact_ref(repository_path, operation.base_ref, deadline_ms: remaining) do
        {:ok, oid} -> {:ok, oid}
        {:error, _error} -> {:error, :unavailable}
      end
    end
  end

  defp classify(
         repository,
         repository_path,
         %MergeOperation{merge_oid: merge_oid} = operation,
         current_oid,
         absolute_deadline,
         owner,
         now
       )
       when is_binary(merge_oid) and current_oid == merge_oid do
    advance_and_complete(
      repository,
      repository_path,
      operation,
      absolute_deadline,
      owner,
      now
    )
  end

  defp classify(
         _repository,
         _repository_path,
         %MergeOperation{state: :prepared, expected_base_oid: expected} = operation,
         expected,
         absolute_deadline,
         _owner,
         _now
       ),
       do: fail(operation, "effect_not_started", absolute_deadline)

  defp classify(
         _repository,
         _repository_path,
         %MergeOperation{state: :merge_written, expected_base_oid: expected} = operation,
         expected,
         absolute_deadline,
         _owner,
         _now
       ),
       do: fail(operation, "ref_not_advanced", absolute_deadline)

  defp classify(
         _repository,
         _repository_path,
         operation,
         current_oid,
         absolute_deadline,
         _owner,
         _now
       ) do
    block(operation, current_oid, absolute_deadline)
  end

  defp block(operation, current_oid, absolute_deadline) do
    with :ok <- check_deadline(absolute_deadline),
         :ok <- mark_unexpected(operation),
         :ok <- record_blocked_audit(operation, current_oid) do
      {:error, :unavailable}
    else
      _error -> {:error, :unavailable}
    end
  end

  defp mark_unexpected(%MergeOperation{failure_reason: "unexpected_ref"} = operation),
    do: OperationLease.release(MergeOperation, operation)

  defp mark_unexpected(operation) do
    case OperationLease.update_owned(MergeOperation, operation, failure_reason: "unexpected_ref") do
      {:ok, _operation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp record_blocked_audit(operation, current_oid) do
    metadata = %{
      "ref" => operation.base_ref,
      "expected_oid" => operation.expected_base_oid,
      "merge_oid" => operation.merge_oid,
      "current_oid" => current_oid,
      "result" => "blocked"
    }

    case Audit.record(
           nil,
           "pull_request.merge_recovery_blocked",
           "repository",
           operation.repository_id,
           metadata,
           request_metadata: operation_request_metadata(operation),
           operation_id: operation_id(operation)
         ) do
      {:ok, _audit} -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp advance_and_complete(
         repository,
         repository_path,
         %MergeOperation{state: :prepared} = operation,
         absolute_deadline,
         owner,
         now
       ) do
    with :ok <- check_deadline(absolute_deadline),
         {:ok, operation} <-
           OperationLease.update_owned(MergeOperation, operation, state: :merge_written),
         {:ok, operation} <- reclaim(operation, owner, now),
         :ok <-
           advance_and_complete(
             repository,
             repository_path,
             operation,
             absolute_deadline,
             owner,
             now
           ) do
      :ok
    else
      _error -> {:error, :unavailable}
    end
  end

  defp advance_and_complete(
         repository,
         repository_path,
         %MergeOperation{state: :merge_written} = operation,
         absolute_deadline,
         owner,
         now
       ) do
    with :ok <- check_deadline(absolute_deadline),
         {:ok, operation} <-
           OperationLease.update_owned(MergeOperation, operation, state: :ref_advanced),
         {:ok, operation} <- reclaim(operation, owner, now),
         :ok <- complete(repository, repository_path, operation, absolute_deadline) do
      :ok
    else
      _error -> {:error, :unavailable}
    end
  end

  defp advance_and_complete(
         repository,
         repository_path,
         %MergeOperation{state: :ref_advanced} = operation,
         absolute_deadline,
         _owner,
         _now
       ),
       do: complete(repository, repository_path, operation, absolute_deadline)

  defp fail(operation, reason, absolute_deadline) do
    with :ok <- check_deadline(absolute_deadline),
         {:ok, _operation} <-
           OperationLease.update_owned(MergeOperation, operation,
             state: :failed,
             failure_reason: reason
           ) do
      :ok
    else
      _error -> {:error, :unavailable}
    end
  end

  defp reclaim(operation, owner, now) do
    case OperationLease.claim(MergeOperation, operation.id, owner, now, @lease_seconds) do
      {:ok, operation} -> {:ok, operation}
      _error -> {:error, :unavailable}
    end
  end

  defp complete(repository, repository_path, operation, absolute_deadline) do
    with :ok <- check_deadline(absolute_deadline),
         {:ok, _changes} <- complete_transaction(repository, operation),
         :ok <- GitCore.invalidate_repository_cache(repository_path) do
      :ok
    else
      _error -> {:error, :unavailable}
    end
  end

  defp complete_transaction(repository, operation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    actor = load_actor(operation.actor_user_id)
    pull = Repo.get!(PullRequest, operation.pull_request_id)

    with %Issue{kind: :pull_request, repository_id: repository_id, state: state} = issue
         when repository_id == repository.id and state in [:open, :closed] <-
           Repo.get(Issue, pull.issue_id) do
      operation_query =
        from candidate in MergeOperation,
          where:
            candidate.id == ^operation.id and candidate.lease_owner == ^operation.lease_owner and
              candidate.lock_version == ^operation.lock_version and
              candidate.state == :ref_advanced and candidate.merge_oid == ^operation.merge_oid

      pull_query =
        from candidate in PullRequest,
          where:
            candidate.id == ^pull.id and candidate.repository_id == ^repository.id and
              candidate.head_ref == ^operation.head_ref and
              candidate.base_ref == ^operation.base_ref and
              is_nil(candidate.merge_commit_sha)

      repository_query = from candidate in Repository, where: candidate.id == ^repository.id

      multi =
        Multi.new()
        |> Multi.update_all(
          :operation,
          operation_query,
          set: [
            state: :completed,
            failure_reason: nil,
            lease_owner: nil,
            lease_expires_at: nil,
            updated_at: now
          ],
          inc: [lock_version: 1]
        )
        |> require_one(:operation)
        |> Multi.update_all(:pull_request, pull_query,
          set: [
            merge_commit_sha: operation.merge_oid,
            merged_at: now,
            merged_by_user_id: operation.actor_user_id,
            updated_at: now
          ]
        )
        |> require_one(:pull_request)
        |> ForgeIssues.update_identity(:issue, issue, actor, %{
          "state" => "closed",
          "state_reason" => "completed"
        })
        |> Multi.update_all(:repository, repository_query,
          set: [last_pushed_at: now, updated_at: now]
        )
        |> Audit.record_multi(
          :audit,
          actor,
          "pull_request.merged",
          "repository",
          repository.id,
          %{
            "pull_request_id" => pull.id,
            "ref" => operation.base_ref,
            "oid" => operation.merge_oid,
            "result" => "success"
          },
          request_metadata: operation_request_metadata(operation),
          operation_id: operation_id(operation)
        )

      operation
      |> then(&apply_complete_multi_hook(multi, &1))
      |> Repo.transaction()
    else
      _invalid_issue -> {:error, :invalid_issue}
    end
  end

  defp require_one(multi, key) do
    Multi.run(multi, {key, :ownership}, fn _repo, changes ->
      case Map.fetch!(changes, key) do
        {1, _rows} -> {:ok, :owned}
        _other -> {:error, :lost_lease}
      end
    end)
  end

  defp load_actor(nil), do: nil
  defp load_actor(actor_user_id), do: Repo.get(User, actor_user_id)

  defp remaining_ms(absolute_deadline) do
    remaining = absolute_deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, :unavailable}
  end

  defp check_deadline(absolute_deadline) do
    case remaining_ms(absolute_deadline) do
      {:ok, _remaining} -> :ok
      {:error, :unavailable} = error -> error
    end
  end

  defp lease_owner(repository_id) do
    case Process.get(@lease_owner_key) do
      owner when is_binary(owner) and owner != "" -> owner
      nil -> "pull-merge-recovery:#{node()}:#{inspect(self())}:#{repository_id}"
    end
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

  defp operation_id(operation), do: "pull_merge:" <> Integer.to_string(operation.id)

  defp operation_request_metadata(operation) do
    [:request_id, :api_version, :ip_address, :user_agent, :token_id]
    |> Enum.reduce(%{}, fn key, metadata ->
      case Map.get(operation, key) do
        nil -> metadata
        value -> Map.put(metadata, key, value)
      end
    end)
  end
end
