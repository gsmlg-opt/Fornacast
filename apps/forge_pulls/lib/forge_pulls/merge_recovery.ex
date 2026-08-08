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

  if Mix.env() == :test do
    @complete_multi_hook_key {__MODULE__, :complete_multi_hook}

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

    defp apply_complete_multi_hook(multi, operation) do
      case Process.get(@complete_multi_hook_key) do
        hook when is_function(hook, 2) -> hook.(multi, operation)
        nil -> multi
      end
    end
  else
    defp apply_complete_multi_hook(multi, _operation), do: multi
  end

  @impl true
  def reconcile_repository_locked(
        %Repository{id: repository_id} = repository,
        repository_path,
        absolute_deadline
      )
      when is_integer(repository_id) and is_binary(repository_path) and
             is_integer(absolute_deadline) do
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
      now = DateTime.utc_now() |> DateTime.truncate(:second)

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
         _current_oid,
         absolute_deadline,
         _owner,
         _now
       ) do
    with :ok <- check_deadline(absolute_deadline),
         {:ok, _operation} <-
           OperationLease.update_owned(MergeOperation, operation,
             failure_reason: "unexpected_ref"
           ) do
      {:error, :unavailable}
    else
      _error -> {:error, :unavailable}
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
    issue = Repo.get!(Issue, pull.issue_id)

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
        state: :closed,
        state_reason: :completed
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
        request_id: operation.request_id,
        operation_id: operation_id(operation)
      )

    operation
    |> then(&apply_complete_multi_hook(multi, &1))
    |> Repo.transaction()
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

  defp lease_owner(repository_id),
    do: "pull-merge-recovery:#{node()}:#{inspect(self())}:#{repository_id}"

  defp operation_id(operation), do: "pull_merge:" <> Integer.to_string(operation.id)
end
