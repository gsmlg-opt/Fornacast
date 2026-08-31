defmodule ForgeImports.RepositoryCleanup do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{CleanupOperation, ImportAttempt, ImportRun, RepositoryItem}
  alias ForgeRepos.{Repository, RepositoryWriteReconcilers}
  alias Fornacast.{Audit, AuditEvent, Config, OperationLease, Repo}

  @terminal_item_states [:completed, :skipped, :canceled, :failed, :published]
  @terminal_run_states [:completed, :completed_with_warnings, :canceled, :failed]
  @terminal_attempt_states [:completed, :failed, :canceled, :destination_changed]
  @cleanup_audit_reserved_keys ~w(
    operation_id kind item_id repository_id repository_generation evidence_fingerprint effect
  )
  @raw_candidate_page_size 100
  @raw_candidate_page_budget 1
  @remote_run_states [
    :running,
    :cancel_requested,
    :awaiting_credential,
    :completed,
    :completed_with_warnings,
    :canceled,
    :failed
  ]

  @doc false
  def backoff_seconds(attempt_count, minimum, maximum)
      when is_integer(attempt_count) and attempt_count > 0 and is_integer(minimum) and
             minimum > 0 and is_integer(maximum) and maximum >= minimum do
    exponent = min(attempt_count - 1, 30)
    min(minimum * Bitwise.bsl(1, exponent), maximum)
  end

  @doc false
  def relative_segments(relative_path) when is_binary(relative_path) do
    segments = String.split(relative_path, "/", trim: false)

    valid? =
      relative_path != "" and Path.type(relative_path) == :relative and
        not String.contains?(relative_path, ["\\", <<0>>]) and
        Enum.all?(segments, fn segment ->
          segment not in ["", ".", ".."] and byte_size(segment) <= 255
        end) and Enum.join(segments, "/") == relative_path

    if valid?, do: {:ok, segments}, else: {:error, :path_mismatch}
  end

  def relative_segments(_relative_path), do: {:error, :path_mismatch}

  @doc false
  def validate_storage_root(live, persisted)
      when is_binary(live) and is_binary(persisted) do
    if live == persisted and Path.type(live) == :absolute and Path.expand(live) == live and
         live != "/" and not String.contains?(live, ["\\", <<0>>]),
       do: :ok,
       else: {:error, :storage_root_mismatch}
  end

  def validate_storage_root(_live, _persisted), do: {:error, :storage_root_mismatch}

  @spec reconcile_kind(atom(), DateTime.t(), integer(), keyword()) ::
          :none | :attempted | {:error, atom()}
  def reconcile_kind(kind, %DateTime{} = now, absolute_deadline, opts \\ [])
      when kind in [:remote_quarantine, :unpublished_shadow, :replacement_tombstone] and
             is_integer(absolute_deadline) and is_list(opts) do
    now = DateTime.truncate(now, :second)

    case candidate(kind, now, absolute_deadline, opts) do
      nil ->
        :none

      candidate ->
        notify_selection(opts, kind)

        case with_permits(
               candidate.repository_id,
               absolute_deadline,
               fn ->
                 clear_admitted_raw_cursor(candidate, opts)
                 reconcile_candidate(candidate, now, absolute_deadline, opts)
               end,
               opts
             ) do
          {:error, :limiter_unavailable} ->
            checkpoint_unadmitted_raw_candidate(candidate, opts)
            retry_unclaimed_candidate(candidate, now)

          result ->
            result
        end
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] -> {:error, :persistence_unavailable}
  end

  @doc false
  def import_safety_locked(%CleanupOperation{} = operation, %DateTime{} = now) do
    with {:ok, repository, run, item, attempt} <- locked_cleanup_context(operation),
         :ok <- validate_import_safety(operation, repository, item, run, attempt, now),
         :safe <- RepositoryWriteReconcilers.cleanup_safety_locked(repository, now) do
      :safe
    else
      {:blocked, _reason} = blocked -> blocked
      {:error, :unavailable} -> {:error, :unavailable}
      _unsafe -> {:blocked, :evidence_mismatch}
    end
  end

  def import_safety_locked(_operation, _now), do: {:error, :unavailable}

  defp candidate(kind, now, absolute_deadline, opts) do
    due_journal(kind, now) || raw_candidate(kind, now, absolute_deadline, opts)
  end

  defp due_journal(kind, now) do
    CleanupOperation
    |> where(
      [operation],
      operation.kind == ^kind and operation.state == :cleanup_pending and
        operation.eligible_at <= ^now and operation.next_attempt_at <= ^now and
        (is_nil(operation.lease_expires_at) or operation.lease_expires_at <= ^now)
    )
    |> order_by([operation],
      asc: operation.next_attempt_at,
      asc: operation.eligible_at,
      asc: operation.id
    )
    |> limit(1)
    |> select([operation], %{
      type: :journal,
      id: operation.id,
      repository_id: operation.repository_id
    })
    |> Repo.one()
  end

  defp raw_candidate(kind, now, absolute_deadline, opts) do
    cursor = Keyword.get(opts, :raw_cursor)

    scan_raw_candidates(
      kind,
      now,
      absolute_deadline,
      cursor,
      @raw_candidate_page_budget,
      opts
    )
  end

  defp scan_raw_candidates(kind, now, absolute_deadline, cursor, pages_left, opts) do
    if raw_remaining_ms(absolute_deadline, opts) <= 0 do
      nil
    else
      page = raw_candidate_page(kind, now, cursor)

      case scan_raw_candidate_page(page, kind, now, absolute_deadline, cursor, opts) do
        {:exhausted, _cursor} when page == [] ->
          notify_raw_cursor(opts, kind, nil)
          nil

        {:exhausted, next_cursor} when pages_left > 1 ->
          scan_raw_candidates(
            kind,
            now,
            absolute_deadline,
            next_cursor,
            pages_left - 1,
            opts
          )

        {:exhausted, _cursor} ->
          nil

        {:halt, _cursor} ->
          nil

        {:selected, candidate} ->
          candidate
          |> Map.put(:raw_cursor, raw_candidate_cursor(kind, candidate))
          |> Map.delete(:sort_at)
      end
    end
  end

  defp scan_raw_candidate_page([], _kind, _now, _deadline, cursor, _opts),
    do: {:exhausted, cursor}

  defp scan_raw_candidate_page(
         [candidate | rest],
         kind,
         now,
         absolute_deadline,
         cursor,
         opts
       ) do
    if raw_remaining_ms(absolute_deadline, opts) <= 0 do
      {:halt, cursor}
    else
      observe_raw_candidate(opts, candidate)

      if raw_remaining_ms(absolute_deadline, opts) <= 0 do
        {:halt, cursor}
      else
        case raw_candidate_discoverable?(candidate, now) do
          true ->
            if raw_remaining_ms(absolute_deadline, opts) <= 0,
              do: {:halt, cursor},
              else: {:selected, candidate}

          false ->
            next_cursor = raw_candidate_cursor(kind, candidate)
            notify_raw_cursor(opts, kind, next_cursor)

            if raw_remaining_ms(absolute_deadline, opts) <= 0 do
              {:halt, next_cursor}
            else
              scan_raw_candidate_page(
                rest,
                kind,
                now,
                absolute_deadline,
                next_cursor,
                opts
              )
            end
        end
      end
    end
  end

  defp notify_raw_cursor(opts, kind, cursor) do
    case Keyword.get(opts, :raw_cursor_observer) do
      observer when is_function(observer, 2) -> observer.(kind, cursor)
      _none -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp observe_raw_candidate(opts, candidate) do
    case Keyword.get(opts, :raw_candidate_observer) do
      observer when is_function(observer, 1) -> observer.(candidate)
      _none -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp clear_admitted_raw_cursor(%{type: :raw, kind: kind}, opts),
    do: notify_raw_cursor(opts, kind, nil)

  defp clear_admitted_raw_cursor(_candidate, _opts), do: :ok

  defp checkpoint_unadmitted_raw_candidate(
         %{type: :raw, kind: kind, raw_cursor: cursor},
         opts
       ),
       do: notify_raw_cursor(opts, kind, cursor)

  defp checkpoint_unadmitted_raw_candidate(_candidate, _opts), do: :ok

  defp raw_remaining_ms(deadline, opts) do
    monotonic_ms =
      Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    deadline - monotonic_ms.()
  end

  defp raw_candidate_page(:remote_quarantine, now, cursor) do
    query =
      RepositoryItem
      |> where(
        [item],
        item.state == :staging_git and item.cleanup_state == "cleanup_pending" and
          item.cleanup_eligible_at <= ^now and not is_nil(item.hidden_repository_id)
      )
      |> where(
        [item],
        not exists(
          from operation in CleanupOperation,
            where:
              operation.repository_item_id == parent_as(:item).id and
                operation.kind == :remote_quarantine and
                operation.source_lock_version == parent_as(:item).lock_version
        )
      )
      |> from(as: :item)

    query =
      case cursor do
        {%DateTime{} = sort_at, id} ->
          where(
            query,
            [item],
            item.cleanup_eligible_at > ^sort_at or
              (item.cleanup_eligible_at == ^sort_at and item.id > ^id)
          )

        nil ->
          query
      end

    query
    |> order_by([item], asc: item.cleanup_eligible_at, asc: item.id)
    |> limit(@raw_candidate_page_size)
    |> select([item], %{
      type: :raw,
      kind: :remote_quarantine,
      id: item.id,
      repository_id: item.hidden_repository_id,
      sort_at: item.cleanup_eligible_at
    })
    |> Repo.all()
  end

  defp raw_candidate_page(:unpublished_shadow, now, cursor) do
    query =
      RepositoryItem
      |> from(as: :item)
      |> where(
        [item],
        item.state in ^@terminal_item_states and item.publication_evidence == ^%{} and
          is_nil(item.lease_owner) and is_nil(item.lease_expires_at) and
          (is_nil(item.cleanup_eligible_at) or item.cleanup_eligible_at <= ^now)
      )
      |> where(
        [item],
        exists(
          from repository in Repository,
            where:
              repository.id == parent_as(:item).hidden_repository_id and
                repository.lifecycle == :importing and repository.visibility == :private and
                repository.write_version == 0 and is_nil(repository.deleted_at) and
                is_nil(repository.last_pushed_at) and is_nil(repository.storage_reclaimed_at)
        )
      )
      |> where(
        [item],
        exists(
          from run in ImportRun,
            where:
              run.id == parent_as(:item).import_run_id and run.state in ^@terminal_run_states and
                is_nil(run.lease_owner) and is_nil(run.lease_expires_at)
        )
      )
      |> where(
        [item],
        exists(
          from attempt in ImportAttempt,
            where:
              attempt.repository_item_id == parent_as(:item).id and
                attempt.attempt_number == parent_as(:item).attempt_count and
                attempt.state in ^@terminal_attempt_states
        )
      )
      |> where(
        [item],
        not exists(
          from successor in RepositoryItem,
            where:
              successor.predecessor_item_id == parent_as(:item).id or
                (successor.id != parent_as(:item).id and
                   successor.hidden_repository_id == parent_as(:item).hidden_repository_id)
        )
      )
      |> where(
        [item],
        not exists(
          from operation in CleanupOperation,
            where:
              operation.repository_item_id == parent_as(:item).id and
                operation.kind == :unpublished_shadow and
                operation.source_lock_version == parent_as(:item).lock_version
        )
      )

    query =
      case cursor do
        {%DateTime{} = sort_at, id} ->
          where(
            query,
            [item],
            coalesce(item.cleanup_eligible_at, item.updated_at) > ^sort_at or
              (coalesce(item.cleanup_eligible_at, item.updated_at) == ^sort_at and item.id > ^id)
          )

        nil ->
          query
      end

    query
    |> order_by([item], asc: coalesce(item.cleanup_eligible_at, item.updated_at), asc: item.id)
    |> limit(@raw_candidate_page_size)
    |> select([item], %{
      type: :raw,
      kind: :unpublished_shadow,
      id: item.id,
      repository_id: item.hidden_repository_id,
      sort_at: coalesce(item.cleanup_eligible_at, item.updated_at)
    })
    |> Repo.all()
  end

  defp raw_candidate_page(:replacement_tombstone, now, cursor) do
    cutoff = DateTime.add(now, -Config.repository_cleanup().grace_seconds, :second)

    query =
      Repository
      |> join(:inner, [repository], item in RepositoryItem,
        on: item.replacement_repository_id == repository.id,
        as: :item
      )
      |> join(:inner, [_repository, item], run in ImportRun, on: run.id == item.import_run_id)
      |> join(:inner, [_repository, item, _run], attempt in ImportAttempt,
        on: attempt.repository_item_id == item.id and attempt.attempt_number == item.attempt_count
      )
      |> where(
        [repository, item, run, attempt],
        repository.lifecycle == :tombstoned and repository.deleted_at <= ^cutoff and
          is_nil(repository.storage_reclaimed_at) and item.state in [:published, :completed] and
          attempt.state == :completed and run.state in ^@terminal_run_states and
          is_nil(item.lease_owner) and is_nil(item.lease_expires_at) and
          is_nil(run.lease_owner) and is_nil(run.lease_expires_at)
      )
      |> where(
        [_repository, item, _run, _attempt],
        not exists(
          from operation in CleanupOperation,
            where:
              operation.repository_item_id == parent_as(:item).id and
                operation.kind == :replacement_tombstone and
                operation.source_lock_version == parent_as(:item).lock_version
        )
      )

    query =
      case cursor do
        {%DateTime{} = sort_at, repository_id, item_id} ->
          where(
            query,
            [repository, item, _run, _attempt],
            repository.deleted_at > ^sort_at or
              (repository.deleted_at == ^sort_at and repository.id > ^repository_id) or
              (repository.deleted_at == ^sort_at and repository.id == ^repository_id and
                 item.id > ^item_id)
          )

        nil ->
          query
      end

    query
    |> order_by([repository, item, _run, _attempt],
      asc: repository.deleted_at,
      asc: repository.id,
      asc: item.id
    )
    |> limit(@raw_candidate_page_size)
    |> select([repository, item, _run, _attempt], %{
      type: :raw,
      kind: :replacement_tombstone,
      id: item.id,
      repository_id: repository.id,
      sort_at: repository.deleted_at
    })
    |> Repo.all()
  end

  defp raw_candidate_cursor(:replacement_tombstone, candidate),
    do: {candidate.sort_at, candidate.repository_id, candidate.id}

  defp raw_candidate_cursor(_kind, candidate), do: {candidate.sort_at, candidate.id}

  defp raw_candidate_discoverable?(candidate, now) do
    with %Repository{} = repository <- Repo.get(Repository, candidate.repository_id),
         %RepositoryItem{} = item <- Repo.get(RepositoryItem, candidate.id),
         %ImportRun{} = run <- Repo.get(ImportRun, item.import_run_id),
         %ImportAttempt{} = attempt <-
           Repo.get_by(ImportAttempt,
             repository_item_id: item.id,
             attempt_number: item.attempt_count
           ) do
      raw_candidate_discoverable?(candidate.kind, repository, item, run, attempt, now)
    else
      _missing -> false
    end
  rescue
    _error in [File.Error, ArgumentError] -> false
  end

  defp raw_candidate_discoverable?(:remote_quarantine, repository, item, run, attempt, now) do
    item.state == :staging_git and item.cleanup_state == "cleanup_pending" and
      due?(item.cleanup_eligible_at, now) and
      run.state in @remote_run_states and
      attempt.state == :running and attempt.attempt_number == item.attempt_count and
      is_map(item.checkpoint["cleanup_identity"]) and
      exact_remote_item_path(repository, item) == :ok and
      match?({:ok, _relative_path}, relative_under_root(item.staged_storage_path))
  end

  defp raw_candidate_discoverable?(:unpublished_shadow, repository, item, run, attempt, _now) do
    canonical_unpublished?(repository, item, run, attempt) and
      not successor_or_adopter?(item, repository)
  end

  defp raw_candidate_discoverable?(:replacement_tombstone, repository, item, run, attempt, now) do
    marker = item.publication_evidence
    cutoff = DateTime.add(now, -Config.repository_cleanup().grace_seconds, :second)

    repository.lifecycle == :tombstoned and due?(repository.deleted_at, cutoff) and
      is_nil(repository.storage_reclaimed_at) and item.state in [:published, :completed] and
      attempt.state == :completed and run.state in @terminal_run_states and
      is_nil(item.lease_owner) and is_nil(item.lease_expires_at) and
      is_nil(run.lease_owner) and is_nil(run.lease_expires_at) and
      exact_replacement?(repository, item, attempt, marker) and
      match?(
        %Repository{lifecycle: :ready, deleted_at: nil},
        Repo.get(Repository, item.hidden_repository_id)
      ) and
      match?(
        %AuditEvent{},
        publication_audit(marker, repository.id, item.hidden_repository_id, item, run)
      )
  end

  defp raw_candidate_discoverable?(_kind, _repository, _item, _run, _attempt, _now),
    do: false

  defp with_permits(repository_id, deadline, fun, opts) do
    read_limiter = Keyword.get(opts, :read_limiter, GitCore.RepositoryReadLimiter)
    write_limiter = Keyword.get(opts, :write_limiter, GitCore.RepositoryWriteLimiter)

    case safe_limiter_call(read_limiter, :acquire_cleanup, [repository_id, deadline]) do
      {:ok, cleanup_lease} ->
        try do
          case safe_limiter_call(write_limiter, :acquire, [repository_id, deadline]) do
            {:ok, writer_lease} ->
              try do
                fun.()
              after
                _ = safe_limiter_call(write_limiter, :release, [writer_lease])
              end

            {:error, _reason} ->
              {:error, :limiter_unavailable}
          end
        after
          _ = safe_limiter_call(read_limiter, :release, [cleanup_lease])
        end

      {:error, _reason} ->
        {:error, :limiter_unavailable}
    end
  end

  defp safe_limiter_call(module, function, arguments) do
    apply(module, function, arguments)
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp notify_selection(opts, kind) do
    case Keyword.get(opts, :selection_observer) do
      observer when is_function(observer, 1) -> observer.(kind)
      _none -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp retry_unclaimed_candidate(%{type: :journal, id: operation_id}, now) do
    case Repo.get(CleanupOperation, operation_id) do
      %CleanupOperation{state: :cleanup_pending} = operation ->
        config = Config.repository_cleanup()
        count = operation.attempt_count + 1
        seconds = backoff_seconds(count, config.backoff_min_seconds, config.backoff_max_seconds)

        query =
          from candidate in CleanupOperation,
            where:
              candidate.id == ^operation.id and candidate.lock_version == ^operation.lock_version and
                candidate.state == :cleanup_pending and candidate.eligible_at <= ^now and
                candidate.next_attempt_at <= ^now and
                (is_nil(candidate.lease_expires_at) or candidate.lease_expires_at <= ^now)

        _result =
          Repo.update_all(query,
            set: [
              attempt_count: count,
              last_error: "limiter_unavailable",
              next_attempt_at: DateTime.add(now, seconds, :second),
              lease_owner: nil,
              lease_expires_at: nil
            ],
            inc: [lock_version: 1]
          )

        :attempted

      _missing_or_changed ->
        :attempted
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] ->
      {:error, :persistence_unavailable}
  end

  defp retry_unclaimed_candidate(_raw_candidate, _now), do: {:error, :limiter_unavailable}

  defp reconcile_candidate(candidate, now, absolute_deadline, opts) do
    with {:ok, operation} <- materialize_and_claim(candidate, now),
         :ok <- run_after_claim_hook(operation, opts),
         {:ok, operation} <- preflight_owned(operation, now),
         {:ok, operation, proof_kind} <- observe_owned(operation, now, absolute_deadline, opts),
         {:ok, operation} <- cache_owned(operation, opts),
         {:ok, operation, effect} <-
           remove_or_confirm(operation, proof_kind, now, absolute_deadline, opts),
         :ok <- finalize(operation, effect, now, absolute_deadline, opts) do
      :attempted
    else
      :busy ->
        :attempted

      {:blocked, operation, classification} ->
        block(operation, classification, now)

      {:retry, operation, classification} ->
        retry(operation, classification, now)

      {:reschedule, operation, classification, next_attempt_at} ->
        reschedule(operation, classification, next_attempt_at)

      {:deferred, _operation} ->
        :attempted

      {:deferred_raw, _next_attempt_at} ->
        :attempted

      {:error, :disappeared} ->
        :attempted

      {:error, :not_found} ->
        :attempted

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] -> {:error, :persistence_unavailable}
  end

  defp run_after_claim_hook(operation, opts) do
    case Keyword.get(opts, :after_claim_hook) do
      hook when is_function(hook, 1) -> hook.(operation)
      _none -> :ok
    end
  end

  defp materialize_and_claim(candidate, now) do
    Repo.transaction(fn ->
      operation =
        case candidate do
          %{type: :journal} ->
            locked_operation(candidate.id)

          %{type: :raw, kind: :remote_quarantine} ->
            case defer_raw_remote_live_lease(candidate, now) do
              :continue -> materialize_raw(candidate, now)
              deferred_or_error -> deferred_or_error
            end

          %{type: :raw} ->
            materialize_raw(candidate, now)
        end

      case operation do
        %CleanupOperation{} = operation ->
          if due?(operation.eligible_at, now) and due?(operation.next_attempt_at, now) do
            owner = "cleanup:#{node()}:#{inspect(self())}:#{operation.id}"

            case OperationLease.claim(
                   CleanupOperation,
                   operation.id,
                   owner,
                   now,
                   Config.repository_cleanup().lease_seconds,
                   allowed_states: [:cleanup_pending]
                 ) do
              {:ok, claimed} -> claimed
              :busy -> Repo.rollback(:busy)
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            {:deferred, operation}
          end

        nil ->
          Repo.rollback(:disappeared)

        {:deferred_raw, _next_attempt_at} = deferred ->
          deferred

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %CleanupOperation{} = operation} -> {:ok, operation}
      {:ok, {:deferred, %CleanupOperation{} = operation}} -> {:deferred, operation}
      {:ok, {:deferred_raw, next_attempt_at}} -> {:deferred_raw, next_attempt_at}
      {:error, :busy} -> :busy
      {:error, reason} -> {:error, reason}
    end
  end

  defp defer_raw_remote_live_lease(candidate, now) do
    with {:ok, repository, run, item, attempt} <-
           locked_raw_context(candidate.kind, candidate.repository_id, candidate.id),
         {:ok, _repository, _evidence, _eligible_at} <-
           raw_evidence(candidate.kind, repository, item, run, attempt, now) do
      case raw_remote_live_expiry(item, run, now) do
        {:ok, nil} ->
          :continue

        {:error, :inconsistent_lease} ->
          :continue

        {:ok, latest_expiry} ->
          operation_id =
            CleanupOperation.deterministic_operation_id(
              :remote_quarantine,
              repository.id,
              item.id,
              item.lock_version
            )

          jitter_seconds = :erlang.phash2(operation_id, 30) + 1
          next_attempt_at = DateTime.add(latest_expiry, jitter_seconds, :second)

          case Repo.update_all(
                 from(candidate in RepositoryItem,
                   where:
                     candidate.id == ^item.id and
                       candidate.lock_version == ^item.lock_version and
                       candidate.hidden_repository_id == ^repository.id and
                       candidate.state == :staging_git and
                       candidate.cleanup_state == "cleanup_pending" and
                       candidate.cleanup_eligible_at == ^item.cleanup_eligible_at
                 ),
                 set: [cleanup_eligible_at: next_attempt_at],
                 inc: [lock_version: 1]
               ) do
            {1, _rows} -> {:deferred_raw, next_attempt_at}
            {0, _rows} -> {:error, :disappeared}
          end
      end
    else
      _drifted -> {:error, :disappeared}
    end
  end

  defp raw_remote_live_expiry(item, run, now) do
    lease_states = [raw_remote_lease_state(item, now), raw_remote_lease_state(run, now)]

    if :inconsistent in lease_states do
      {:error, :inconsistent_lease}
    else
      latest_expiry =
        lease_states
        |> Enum.flat_map(fn
          {:live, expiry} -> [expiry]
          :inactive -> []
        end)
        |> Enum.max_by(&DateTime.to_unix(&1, :second), fn -> nil end)

      {:ok, latest_expiry}
    end
  end

  defp raw_remote_lease_state(%{lease_owner: nil, lease_expires_at: nil}, _now),
    do: :inactive

  defp raw_remote_lease_state(
         %{lease_owner: owner, lease_expires_at: %DateTime{} = expires_at},
         now
       )
       when is_binary(owner) and owner != "" do
    if DateTime.compare(expires_at, now) == :gt,
      do: {:live, expires_at},
      else: :inactive
  end

  defp raw_remote_lease_state(_row, _now), do: :inconsistent

  defp materialize_raw(%{kind: kind, id: item_id, repository_id: repository_id}, now) do
    with {:ok, repository, run, item, attempt} <-
           locked_raw_context(kind, repository_id, item_id),
         {:ok, repository, evidence, eligible_at} <-
           raw_evidence(kind, repository, item, run, attempt, now) do
      attrs = %{
        repository_id: repository.id,
        repository_item_id: item.id,
        source_lock_version: item.lock_version,
        kind: kind,
        operation_id:
          CleanupOperation.deterministic_operation_id(
            kind,
            repository.id,
            item.id,
            item.lock_version
          ),
        evidence: evidence,
        eligible_at: eligible_at,
        next_attempt_at: eligible_at
      }

      case Repo.insert(CleanupOperation.create_changeset(%CleanupOperation{}, attrs),
             on_conflict: :nothing,
             returning: true
           ) do
        {:ok, %CleanupOperation{id: id} = operation} when is_integer(id) ->
          operation

        {:ok, %CleanupOperation{id: nil}} ->
          load_materialized(attrs)

        {:error, _changeset} ->
          {:error, :evidence_mismatch}
      end
    else
      _drifted -> nil
    end
  end

  defp raw_evidence(:remote_quarantine, repository, item, run, attempt, now) do
    with true <- item.state == :staging_git and item.cleanup_state == "cleanup_pending",
         true <- due?(item.cleanup_eligible_at, now),
         true <- run.state in @remote_run_states,
         true <- attempt.state == :running,
         true <- attempt.attempt_number == item.attempt_count,
         identity when is_map(identity) <- item.checkpoint["cleanup_identity"],
         :ok <- exact_remote_item_path(repository, item),
         {:ok, relative_path} <- relative_under_root(item.staged_storage_path) do
      evidence = %{
        "version" => 1,
        "kind" => "remote_quarantine",
        "storage_root" => Config.repo_storage_root(),
        "relative_path" => relative_path,
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_storage_path" => repository.storage_path,
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "requested_path" => ForgeRepos.absolute_storage_path(repository),
        "quarantine_path" => item.staged_storage_path,
        "mode" => identity["mode"],
        "major_device" => identity["major_device"],
        "minor_device" => identity["minor_device"],
        "inode" => identity["inode"],
        "remote_failure_kind" => item.cleanup_error
      }

      {:ok, repository, evidence, item.cleanup_eligible_at}
    else
      _invalid -> {:error, :disappeared}
    end
  end

  defp raw_evidence(:unpublished_shadow, repository, item, run, attempt, now) do
    with true <- canonical_unpublished?(repository, item, run, attempt),
         false <- successor_or_adopter?(item, repository),
         {1, _} <-
           Repo.update_all(
             from(candidate in Repository,
               where:
                 candidate.id == ^repository.id and candidate.lifecycle == :importing and
                   is_nil(candidate.deleted_at) and candidate.write_version == 0 and
                   is_nil(candidate.last_pushed_at)
             ),
             set: [lifecycle: :tombstoned, deleted_at: now]
           ) do
      repository = %{repository | lifecycle: :tombstoned, deleted_at: now}
      eligible_at = DateTime.add(now, Config.repository_cleanup().grace_seconds, :second)

      evidence = %{
        "version" => 1,
        "kind" => "unpublished_shadow",
        "storage_root" => Config.repo_storage_root(),
        "relative_path" => repository.storage_path,
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_write_version" => repository.write_version,
        "repository_storage_path" => repository.storage_path,
        "repository_updated_at" => DateTime.to_iso8601(repository.updated_at),
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "item_state" => Atom.to_string(item.state),
        "run_id" => run.id,
        "run_state" => Atom.to_string(run.state),
        "attempt_number" => attempt.attempt_number,
        "attempt_state" => Atom.to_string(attempt.state),
        "attempt_decision" => attempt.decision,
        "attempt_fingerprint" =>
          CleanupOperation.attempt_fingerprint(item.id, attempt.attempt_number, attempt.decision),
        "publication_evidence" => item.publication_evidence,
        "predecessor_item_id" => item.predecessor_item_id,
        "successor_item_id" => nil,
        "adopter_item_id" => nil
      }

      {:ok, repository, evidence, eligible_at}
    else
      _invalid -> {:error, :disappeared}
    end
  end

  defp raw_evidence(:replacement_tombstone, repository, item, run, attempt, now) do
    marker = item.publication_evidence
    cutoff = DateTime.add(now, -Config.repository_cleanup().grace_seconds, :second)

    with true <- repository.lifecycle == :tombstoned and due?(repository.deleted_at, cutoff),
         true <- is_nil(repository.storage_reclaimed_at),
         true <- item.state in [:published, :completed] and attempt.state == :completed,
         true <- run.state in @terminal_run_states,
         true <- is_nil(item.lease_owner) and is_nil(item.lease_expires_at),
         true <- is_nil(run.lease_owner) and is_nil(run.lease_expires_at),
         true <- exact_replacement?(repository, item, attempt, marker),
         %Repository{lifecycle: :ready, deleted_at: nil} = new_repository <-
           Repo.get(Repository, item.hidden_repository_id),
         true <- new_repository.id == marker["repository_id"],
         %AuditEvent{} = audit <-
           publication_audit(marker, repository.id, new_repository.id, item, run) do
      evidence = %{
        "version" => 1,
        "kind" => "replacement_tombstone",
        "storage_root" => Config.repo_storage_root(),
        "relative_path" => repository.storage_path,
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_write_version" => repository.write_version,
        "repository_storage_path" => repository.storage_path,
        "repository_deleted_at" => DateTime.to_iso8601(repository.deleted_at),
        "repository_updated_at" => DateTime.to_iso8601(repository.updated_at),
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "attempt_number" => attempt.attempt_number,
        "attempt_decision" => attempt.decision,
        "attempt_fingerprint" =>
          CleanupOperation.attempt_fingerprint(item.id, attempt.attempt_number, attempt.decision),
        "publication_operation_id" => marker["operation_id"],
        "publication_marker" => marker,
        "new_repository_id" => new_repository.id,
        "new_repository_generation" => new_repository.generation,
        "publication_audit_id" => audit.id
      }

      {:ok, repository, evidence, repository.deleted_at}
    else
      _invalid -> {:error, :disappeared}
    end
  end

  defp load_materialized(attrs) do
    operation =
      Repo.get_by(CleanupOperation,
        repository_item_id: attrs.repository_item_id,
        kind: attrs.kind,
        source_lock_version: attrs.source_lock_version,
        operation_id: attrs.operation_id
      )

    case operation do
      %CleanupOperation{} = operation ->
        exact? =
          operation.repository_id == attrs.repository_id and
            operation.repository_item_id == attrs.repository_item_id and
            operation.source_lock_version == attrs.source_lock_version and
            operation.kind == attrs.kind and operation.operation_id == attrs.operation_id and
            operation.evidence == attrs.evidence and operation.eligible_at == attrs.eligible_at

        if exact?, do: operation, else: {:error, :evidence_mismatch}

      nil ->
        {:error, :disappeared}
    end
  end

  defp preflight_owned(operation, now) do
    Repo.transaction(fn ->
      with {:ok, repository, run, item, attempt} <- locked_cleanup_context(operation),
           :ok <- validate_operation_path(operation),
           :ok <- validate_import_safety(operation, repository, item, run, attempt, now),
           :safe <- RepositoryWriteReconcilers.cleanup_safety_locked(repository, now),
           %CleanupOperation{} = current <- locked_owned_operation(operation),
           :ok <- validate_operation_path(current) do
        case validate_import_safety(current, repository, item, run, attempt, now) do
          :ok ->
            case preflight_audit_safe(current, run) do
              :ok -> current
              {:blocked, reason} -> Repo.rollback({:blocked, reason})
            end

          {:blocked, :live_lease} ->
            Repo.rollback({:reschedule, :live_lease, live_lease_retry_at(current, now)})

          {:blocked, :claimable_operation} ->
            Repo.rollback({:reschedule, :claimable_operation, DateTime.add(now, 30, :second)})

          {:blocked, reason} ->
            Repo.rollback({:blocked, reason})
        end
      else
        {:error, :unavailable} ->
          Repo.rollback({:retry, :persistence_unavailable})

        {:blocked, :live_lease} ->
          Repo.rollback({:reschedule, :live_lease, live_lease_retry_at(operation, now)})

        {:blocked, :claimable_operation} ->
          Repo.rollback({:reschedule, :claimable_operation, DateTime.add(now, 30, :second)})

        {:blocked, reason} ->
          Repo.rollback({:blocked, reason})

        nil ->
          Repo.rollback({:retry, :lost_lease})

        _unsafe ->
          Repo.rollback({:blocked, :evidence_mismatch})
      end
    end)
    |> case do
      {:ok, operation} ->
        {:ok, operation}

      {:error, {:blocked, reason}} ->
        {:blocked, operation, classify(reason)}

      {:error, {:retry, reason}} ->
        {:retry, operation, classify(reason)}

      {:error, {:reschedule, classification, next_attempt_at}} ->
        {:reschedule, operation, classify(classification), next_attempt_at}

      {:error, _reason} ->
        {:retry, operation, :persistence_unavailable}
    end
  end

  defp observe_owned(operation, now, deadline, opts) do
    git_core = Keyword.get(opts, :git_core, GitCore)

    with :ok <- validate_operation_path(operation),
         {:ok, segments} <- relative_segments(operation.evidence["relative_path"]),
         {:ok, operation} <- renew(operation, now),
         remaining when remaining > 0 <- remaining_ms(deadline),
         result <-
           git_core.contained_tree_identity(
             operation.evidence["storage_root"],
             segments,
             remaining
           ) do
      handle_observation(operation, result, now)
    else
      {:error, reason}
      when reason in [
             :symlink,
             :not_directory,
             :mode_mismatch,
             :invalid_argument,
             :unsupported_platform
           ] ->
        {:blocked, operation, classify(reason)}

      {:error, _reason} ->
        {:retry, operation, :storage_unavailable}

      _deadline ->
        {:retry, operation, :cleanup_timeout}
    end
  end

  defp handle_observation(operation, {:ok, {:present, %{root: root, target: target}}}, now) do
    observed_root = stringify_identity(root)
    observed_target = stringify_identity(target)

    with true <- is_nil(operation.evidence["anchored_absence"]),
         true <- operation.evidence["root_identity"] in [nil, observed_root],
         true <- operation.evidence["anchored_identity"] in [nil, observed_target],
         :ok <- remote_identity_matches(operation, target),
         evidence <-
           operation.evidence
           |> Map.put("root_identity", observed_root)
           |> Map.put("anchored_identity", observed_target),
         {:ok, updated} <-
           OperationLease.update_owned(
             CleanupOperation,
             operation,
             [evidence: evidence, effect_started_at: now],
             now: now,
             lease_seconds: Config.repository_cleanup().lease_seconds
           ) do
      {:ok, updated, :present}
    else
      false -> {:blocked, operation, :identity_mismatch}
      {:error, :identity_mismatch} -> {:blocked, operation, :identity_mismatch}
      {:error, _reason} -> {:retry, operation, :persistence_unavailable}
    end
  end

  defp handle_observation(operation, {:ok, {:missing, root}}, now) do
    existing_root = operation.evidence["root_identity"]
    absence = operation.evidence["anchored_absence"]

    cond do
      is_map(existing_root) and existing_root != stringify_identity(root) ->
        {:blocked, operation, :root_identity_mismatch}

      is_map(absence) and absence["root_identity"] != stringify_identity(root) ->
        {:blocked, operation, :root_identity_mismatch}

      is_map(existing_root) and match?(%DateTime{}, operation.effect_finished_at) ->
        {:ok, operation, :removed}

      is_map(existing_root) ->
        finish_effect(operation, now, :removed)

      is_map(absence) ->
        {:ok, operation, :missing}

      true ->
        evidence =
          Map.put(operation.evidence, "anchored_absence", %{
            "version" => 1,
            "observed_at" => DateTime.to_iso8601(now),
            "root_identity" => stringify_identity(root)
          })

        case OperationLease.update_owned(
               CleanupOperation,
               operation,
               [evidence: evidence, effect_started_at: now, effect_finished_at: now],
               now: now,
               lease_seconds: Config.repository_cleanup().lease_seconds
             ) do
          {:ok, updated} -> {:ok, updated, :unconfirmed_missing}
          {:error, _reason} -> {:retry, operation, :persistence_unavailable}
        end
    end
  end

  defp handle_observation(operation, {:error, reason}, _now)
       when reason in [:io, :io_error, :unavailable],
       do: {:retry, operation, :storage_unavailable}

  defp handle_observation(operation, {:error, reason}, _now)
       when reason in [:deadline_exceeded, :timeout],
       do: {:retry, operation, :cleanup_timeout}

  defp handle_observation(operation, {:error, reason}, _now),
    do: {:blocked, operation, classify(reason)}

  defp invalidate_cache(operation, opts) do
    git_core = Keyword.get(opts, :git_core, GitCore)
    path = Path.join(operation.evidence["storage_root"], operation.evidence["relative_path"])
    git_core.invalidate_repository_cache_strict(path)
  end

  defp cache_owned(operation, opts) do
    with :ok <- run_phase_hook(opts, :before_cache_hook, operation),
         :ok <- validate_operation_path(operation) do
      case invalidate_cache(operation, opts) do
        :ok -> {:ok, operation}
        {:error, _reason} -> {:retry, operation, :cache_unavailable}
      end
    else
      {:blocked, reason} -> {:blocked, operation, classify(reason)}
      {:error, _reason} -> {:retry, operation, :persistence_unavailable}
    end
  catch
    _kind, _reason -> {:retry, operation, :cache_unavailable}
  end

  defp remove_or_confirm(operation, :missing, _now, _deadline, _opts),
    do: {:ok, operation, :missing}

  defp remove_or_confirm(operation, :unconfirmed_missing, _now, _deadline, _opts) do
    case OperationLease.release(CleanupOperation, operation) do
      :ok -> {:deferred, operation}
      {:error, _reason} -> {:retry, operation, :persistence_unavailable}
    end
  end

  defp remove_or_confirm(operation, :removed, _now, _deadline, _opts),
    do: {:ok, operation, :removed}

  defp remove_or_confirm(operation, :present, now, deadline, opts) do
    git_core = Keyword.get(opts, :git_core, GitCore)
    root = atomize_identity(operation.evidence["root_identity"])
    target = atomize_identity(operation.evidence["anchored_identity"])
    proof = %{root: root, target: target}

    with :ok <- run_phase_hook(opts, :before_remove_hook, operation),
         :ok <- validate_operation_path(operation),
         {:ok, segments} <- relative_segments(operation.evidence["relative_path"]),
         {:ok, operation} <- renew(operation, now),
         remaining when remaining > 0 <- remaining_ms(deadline),
         result <-
           git_core.remove_contained_tree(
             operation.evidence["storage_root"],
             segments,
             proof,
             remaining
           ) do
      case result do
        {:ok, {:removed, ^proof}} ->
          finish_effect(operation, now, :removed)

        {:ok, {:missing, ^root}} ->
          finish_effect(operation, now, :removed)

        {:ok, {:missing, _different_root}} ->
          {:blocked, operation, :root_identity_mismatch}

        {:error, reason} when reason in [:deadline_exceeded, :timeout] ->
          {:retry, operation, :cleanup_timeout}

        {:error, reason} when reason in [:io, :io_error, :partial] ->
          {:retry, operation, :storage_unavailable}

        {:error, reason} ->
          {:blocked, operation, classify(reason)}

        _invalid ->
          {:blocked, operation, :identity_mismatch}
      end
    else
      {:blocked, reason} -> {:blocked, operation, classify(reason)}
      {:error, _reason} -> {:retry, operation, :persistence_unavailable}
      _deadline -> {:retry, operation, :cleanup_timeout}
    end
  end

  defp run_phase_hook(opts, key, operation) do
    case Keyword.get(opts, key) do
      hook when is_function(hook, 1) -> hook.(operation)
      _none -> :ok
    end
  catch
    _kind, _reason -> {:error, :hook_failed}
  end

  defp finish_effect(operation, now, effect) do
    case OperationLease.update_owned(
           CleanupOperation,
           operation,
           [effect_finished_at: now],
           now: now,
           lease_seconds: Config.repository_cleanup().lease_seconds
         ) do
      {:ok, updated} -> {:ok, updated, effect}
      {:error, _reason} -> {:retry, operation, :persistence_unavailable}
    end
  end

  defp finalize(operation, effect, now, absolute_deadline, opts) do
    Repo.transaction(fn ->
      with {:ok, repository, run, item, attempt} <- locked_cleanup_context(operation),
           :ok <- validate_operation_path(operation),
           :ok <- validate_import_safety(operation, repository, item, run, attempt, now),
           :safe <- RepositoryWriteReconcilers.cleanup_safety_locked(repository, now),
           %CleanupOperation{} = current <- locked_owned_operation(operation),
           :ok <- validate_operation_path(current),
           :ok <- validate_import_safety(current, repository, item, run, attempt, now),
           :ok <- validate_final_outcome(current, effect, absolute_deadline, opts),
           :ok <- final_source_matches(current, repository, item),
           :ok <- finalize_kind(current, repository, item, run, effect, now),
           {:ok, _completed} <-
             OperationLease.update_owned(CleanupOperation, current,
               state: :cleanup_complete,
               next_attempt_at: nil,
               last_error: nil,
               completed_at: now
             ) do
        :ok
      else
        {:blocked, :live_lease} ->
          Repo.rollback({:reschedule, :live_lease, live_lease_retry_at(operation, now)})

        {:blocked, :claimable_operation} ->
          Repo.rollback({:reschedule, :claimable_operation, DateTime.add(now, 30, :second)})

        {:blocked, reason} ->
          Repo.rollback({:blocked, reason})

        {:retry, reason} ->
          Repo.rollback({:retry, reason})

        {:error, :unavailable} ->
          Repo.rollback({:retry, :persistence_unavailable})

        {:error, reason} ->
          Repo.rollback({:blocked, reason})

        nil ->
          Repo.rollback({:blocked, :evidence_mismatch})

        _unsafe ->
          Repo.rollback({:blocked, :evidence_mismatch})
      end
    end)
    |> case do
      {:ok, :ok} ->
        :ok

      {:error, {:blocked, reason}} ->
        {:blocked, operation, classify(reason)}

      {:error, {:retry, reason}} ->
        {:retry, operation, classify(reason)}

      {:error, {:reschedule, classification, next_attempt_at}} ->
        {:reschedule, operation, classify(classification), next_attempt_at}

      {:error, _reason} ->
        {:retry, operation, :persistence_unavailable}
    end
  end

  defp validate_final_outcome(operation, effect, deadline, opts) do
    git_core = Keyword.get(opts, :git_core, GitCore)

    with {:ok, segments} <- relative_segments(operation.evidence["relative_path"]),
         remaining when remaining > 0 <- remaining_ms(deadline),
         result <-
           git_core.contained_tree_identity(
             operation.evidence["storage_root"],
             segments,
             remaining
           ) do
      expected_root =
        case effect do
          :removed -> operation.evidence["root_identity"]
          :missing -> get_in(operation.evidence, ["anchored_absence", "root_identity"])
        end

      case result do
        {:ok, {:missing, root}} ->
          if stringify_identity(root) == expected_root,
            do: :ok,
            else: {:blocked, :root_identity_mismatch}

        {:ok, {:present, _proof}} ->
          {:blocked, :identity_mismatch}

        {:error, reason} when reason in [:io, :io_error, :unavailable] ->
          {:retry, :storage_unavailable}

        {:error, reason} when reason in [:deadline_exceeded, :timeout] ->
          {:retry, :cleanup_timeout}

        {:error, reason} ->
          {:blocked, classify(reason)}

        _invalid ->
          {:blocked, :identity_mismatch}
      end
    else
      {:error, reason} -> {:blocked, classify(reason)}
      _deadline -> {:retry, :cleanup_timeout}
    end
  end

  defp finalize_kind(
         %CleanupOperation{kind: :remote_quarantine} = operation,
         repository,
         item,
         run,
         effect,
         now
       ) do
    with :ok <- exact_remote_item_path(repository, item),
         :ok <-
           record_or_verify_audit(
             operation,
             run,
             "github_import.quarantine_reclaimed",
             effect
           ),
         checkpoint <-
           (item.checkpoint || %{})
           |> Map.delete("cleanup_identity")
           |> Map.put("remote_cleanup_operation_id", operation.operation_id),
         canonical_path <- ForgeRepos.absolute_storage_path(repository),
         {1, _} <-
           Repo.update_all(
             from(candidate in RepositoryItem,
               where:
                 candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
                   candidate.state == :staging_git and
                   candidate.cleanup_state == "cleanup_pending"
             ),
             set: [
               cleanup_state: nil,
               cleanup_eligible_at: nil,
               cleanup_attempt_count: 0,
               cleanup_error: nil,
               checkpoint: checkpoint,
               staged_storage_path: canonical_path,
               next_attempt_at: now,
               lease_owner: nil,
               lease_expires_at: nil,
               updated_at: now
             ],
             inc: [lock_version: 1]
           ),
         {1, _} <-
           Repo.update_all(
             from(candidate in ImportRun,
               where: candidate.id == ^run.id and candidate.lock_version == ^run.lock_version
             ),
             set: [updated_at: now],
             inc: [lock_version: 1]
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :evidence_mismatch}
    end
  end

  defp finalize_kind(operation, repository, _item, run, effect, now) do
    with true <- is_nil(repository.storage_reclaimed_at),
         {1, _} <-
           Repo.update_all(
             from(candidate in Repository,
               where:
                 candidate.id == ^repository.id and
                   is_nil(candidate.storage_reclaimed_at) and
                   candidate.lifecycle == :tombstoned
             ),
             set: [storage_reclaimed_at: now]
           ),
         :ok <-
           record_or_verify_audit(
             operation,
             run,
             "repository.storage_reclaimed",
             effect
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :evidence_mismatch}
    end
  end

  defp record_or_verify_audit(operation, run, action, effect) do
    actor_user_id = run.actor_user_id
    request_metadata = cleanup_request_metadata(run)
    metadata = cleanup_audit_metadata(operation, effect, request_metadata)

    existing =
      Repo.all(
        from event in AuditEvent,
          where: event.operation_id == ^operation.operation_id,
          order_by: [asc: event.id]
      )

    case existing do
      [] ->
        with %User{} = actor <- Repo.get(User, actor_user_id),
             {:ok, _event} <-
               Audit.record(actor, action, "repository", operation.repository_id, metadata,
                 operation_id: operation.operation_id,
                 request_metadata: request_metadata
               ),
             [%AuditEvent{} = event] <-
               Repo.all(
                 from event in AuditEvent,
                   where: event.operation_id == ^operation.operation_id
               ),
             true <-
               exact_cleanup_audit?(
                 event,
                 actor_user_id,
                 action,
                 operation,
                 metadata,
                 request_metadata
               ) do
          :ok
        else
          _collision -> {:error, :audit_mismatch}
        end

      [%AuditEvent{} = event] ->
        if exact_cleanup_audit?(
             event,
             actor_user_id,
             action,
             operation,
             metadata,
             request_metadata
           ),
           do: :ok,
           else: {:error, :audit_mismatch}

      _collision ->
        {:error, :audit_mismatch}
    end
  end

  defp exact_cleanup_audit?(
         event,
         actor_user_id,
         action,
         operation,
         metadata,
         request_metadata
       ) do
    event.actor_user_id == actor_user_id and event.action == action and
      event.target_type == "repository" and
      event.target_id == Integer.to_string(operation.repository_id) and event.metadata == metadata and
      event.operation_id == operation.operation_id and
      event.request_id == request_metadata["request_id"] and
      event.ip_address == request_metadata["ip_address"] and
      event.user_agent == request_metadata["user_agent"]
  end

  defp preflight_audit_safe(operation, run) do
    actor_user_id = run.actor_user_id
    request_metadata = cleanup_request_metadata(run)

    existing =
      Repo.all(
        from event in AuditEvent,
          where: event.operation_id == ^operation.operation_id,
          order_by: [asc: event.id]
      )

    case existing do
      [] ->
        :ok

      [%AuditEvent{} = event] ->
        with {:ok, effect} <- cleanup_audit_effect(event.metadata["effect"]),
             true <- durable_effect_proof?(operation, effect),
             action <- cleanup_audit_action(operation.kind),
             metadata <- cleanup_audit_metadata(operation, effect, request_metadata),
             true <-
               exact_cleanup_audit?(
                 event,
                 actor_user_id,
                 action,
                 operation,
                 metadata,
                 request_metadata
               ) do
          :ok
        else
          _collision -> {:blocked, :audit_mismatch}
        end

      _collision ->
        {:blocked, :audit_mismatch}
    end
  end

  defp cleanup_audit_effect("removed"), do: {:ok, :removed}
  defp cleanup_audit_effect("missing"), do: {:ok, :missing}
  defp cleanup_audit_effect(_effect), do: {:error, :audit_mismatch}

  defp cleanup_audit_action(:remote_quarantine), do: "github_import.quarantine_reclaimed"
  defp cleanup_audit_action(_kind), do: "repository.storage_reclaimed"

  defp cleanup_audit_metadata(operation, effect, request_metadata) do
    base = %{
      "kind" => Atom.to_string(operation.kind),
      "item_id" => operation.repository_item_id,
      "repository_id" => operation.repository_id,
      "repository_generation" => operation.evidence["repository_generation"],
      "evidence_fingerprint" => evidence_fingerprint(operation.evidence),
      "effect" => Atom.to_string(effect)
    }

    Map.merge(base, request_metadata)
  end

  defp cleanup_request_metadata(run) do
    (run.request_metadata || %{})
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(@cleanup_audit_reserved_keys)
  end

  defp durable_effect_proof?(operation, :removed) do
    match?(%DateTime{}, operation.effect_started_at) and
      match?(%DateTime{}, operation.effect_finished_at) and
      is_map(operation.evidence["root_identity"]) and
      is_map(operation.evidence["anchored_identity"]) and
      is_nil(operation.evidence["anchored_absence"])
  end

  defp durable_effect_proof?(operation, :missing) do
    match?(%DateTime{}, operation.effect_started_at) and
      match?(%DateTime{}, operation.effect_finished_at) and
      match?(%DateTime{}, operation.completed_at) and
      is_map(operation.evidence["anchored_absence"])
  end

  defp evidence_fingerprint(evidence) do
    evidence
    |> Map.drop(~w(root_identity anchored_identity anchored_absence))
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp retry(operation, classification, now) do
    config = Config.repository_cleanup()
    count = operation.attempt_count + 1
    seconds = backoff_seconds(count, config.backoff_min_seconds, config.backoff_max_seconds)

    case OperationLease.update_owned(CleanupOperation, operation,
           attempt_count: count,
           last_error: Atom.to_string(classification),
           next_attempt_at: DateTime.add(now, seconds, :second)
         ) do
      {:ok, _updated} -> :attempted
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp reschedule(operation, classification, next_attempt_at) do
    case OperationLease.update_owned(CleanupOperation, operation,
           last_error: Atom.to_string(classification),
           next_attempt_at: next_attempt_at
         ) do
      {:ok, _updated} -> :attempted
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp block(operation, classification, _now) do
    case OperationLease.update_owned(CleanupOperation, operation,
           state: :cleanup_blocked,
           next_attempt_at: nil,
           last_error: Atom.to_string(classification)
         ) do
      {:ok, _updated} -> :attempted
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp validate_operation_path(operation) do
    root = operation.evidence["storage_root"]
    relative = operation.evidence["relative_path"]

    with :ok <- validate_storage_root(Config.repo_storage_root(), root),
         {:ok, _segments} <- relative_segments(relative),
         true <- Path.join(root, relative) == Path.expand(Path.join(root, relative)),
         :ok <- validate_kind_path(operation) do
      :ok
    else
      {:error, reason} -> {:blocked, reason}
      _invalid -> {:blocked, :path_mismatch}
    end
  end

  defp validate_kind_path(%CleanupOperation{kind: :remote_quarantine, evidence: evidence}) do
    requested = evidence["requested_path"]
    quarantine = evidence["quarantine_path"]

    if requested == Path.join(evidence["storage_root"], evidence["repository_storage_path"]) and
         quarantine == Path.join(evidence["storage_root"], evidence["relative_path"]) and
         quarantine == GitCore.Remote.cleanup_slot_path(requested),
       do: :ok,
       else: {:error, :path_mismatch}
  end

  defp validate_kind_path(_operation), do: :ok

  defp validate_import_safety(operation, repository, item, run, attempt, now) do
    cond do
      successor_or_adopter?(item, repository) ->
        {:blocked, :successor_or_adopter}

      other_nonterminal_import_work?(operation, repository.id) ->
        {:blocked, :concurrent_import_work}

      operation.kind == :remote_quarantine ->
        with :ok <- remote_lease_shape(item.lease_owner, item.lease_expires_at, now),
             :ok <- remote_lease_shape(run.lease_owner, run.lease_expires_at, now) do
          remote_source_safe?(operation, repository, item, run, attempt, now)
        else
          {:blocked, reason} -> {:blocked, reason}
        end

      true ->
        with :ok <- lease_shape(item.lease_owner, item.lease_expires_at, now),
             :ok <- lease_shape(run.lease_owner, run.lease_expires_at, now) do
          terminal_source_safe?(operation, repository, item, run, attempt, now)
        else
          {:blocked, reason} -> {:blocked, reason}
        end
    end
  end

  defp remote_source_safe?(operation, repository, item, run, attempt, now) do
    valid? =
      operation.repository_id == repository.id and operation.repository_item_id == item.id and
        operation.source_lock_version == item.lock_version and
        operation.operation_id ==
          CleanupOperation.deterministic_operation_id(
            :remote_quarantine,
            repository.id,
            item.id,
            operation.source_lock_version
          ) and item.state == :staging_git and item.cleanup_state == "cleanup_pending" and
        paired_null_or_expired?(item.lease_owner, item.lease_expires_at, now) and
        attempt.repository_item_id == item.id and attempt.attempt_number == item.attempt_count and
        attempt.state == :running and run.id == item.import_run_id and
        run.state in @remote_run_states and
        paired_null_or_expired?(run.lease_owner, run.lease_expires_at, now) and
        exact_remote_evidence?(operation, item, repository)

    if valid?, do: :ok, else: {:blocked, :evidence_mismatch}
  end

  defp terminal_source_safe?(operation, repository, item, run, attempt, now) do
    valid? =
      operation.repository_id == repository.id and operation.repository_item_id == item.id and
        operation.source_lock_version == item.lock_version and run.id == item.import_run_id and
        attempt.repository_item_id == item.id and attempt.attempt_number == item.attempt_count and
        run.state in @terminal_run_states and is_nil(item.lease_owner) and
        is_nil(item.lease_expires_at) and is_nil(run.lease_owner) and
        is_nil(run.lease_expires_at) and kind_eligible?(operation, repository, item, attempt, now) and
        exact_terminal_evidence?(operation, repository, item, run, attempt)

    if valid?, do: :ok, else: {:blocked, :evidence_mismatch}
  end

  defp kind_eligible?(
         %CleanupOperation{kind: :unpublished_shadow} = operation,
         repository,
         item,
         attempt,
         now
       ) do
    grace = Config.repository_cleanup().grace_seconds

    repository.lifecycle == :tombstoned and match?(%DateTime{}, repository.deleted_at) and
      DateTime.compare(DateTime.add(repository.deleted_at, grace, :second), now) != :gt and
      operation.eligible_at == DateTime.add(repository.deleted_at, grace, :second) and
      repository.visibility == :private and repository.write_version == 0 and
      is_nil(repository.last_pushed_at) and is_nil(repository.storage_reclaimed_at) and
      item.state in [:failed, :canceled] and attempt.state in @terminal_attempt_states and
      item.publication_evidence == %{} and not successor_or_adopter?(item, repository)
  end

  defp kind_eligible?(
         %CleanupOperation{kind: :replacement_tombstone} = operation,
         repository,
         item,
         attempt,
         now
       ) do
    cutoff = DateTime.add(now, -Config.repository_cleanup().grace_seconds, :second)

    repository.lifecycle == :tombstoned and due?(repository.deleted_at, cutoff) and
      operation.eligible_at == repository.deleted_at and is_nil(repository.storage_reclaimed_at) and
      item.state in [:published, :completed] and attempt.state == :completed
  end

  defp kind_eligible?(_operation, _repository, _item, _attempt, _now), do: false

  defp exact_terminal_evidence?(
         %CleanupOperation{kind: :unpublished_shadow, evidence: evidence},
         repository,
         item,
         run,
         attempt
       ) do
    evidence["repository_id"] == repository.id and
      evidence["repository_generation"] == repository.generation and
      evidence["repository_write_version"] == repository.write_version and
      evidence["repository_storage_path"] == repository.storage_path and
      evidence["relative_path"] == repository.storage_path and
      evidence["repository_updated_at"] == DateTime.to_iso8601(repository.updated_at) and
      evidence["item_id"] == item.id and evidence["item_lock_version"] == item.lock_version and
      evidence["item_state"] == Atom.to_string(item.state) and evidence["run_id"] == run.id and
      evidence["run_state"] == Atom.to_string(run.state) and
      evidence["attempt_number"] == attempt.attempt_number and
      evidence["attempt_state"] == Atom.to_string(attempt.state) and
      evidence["attempt_decision"] == attempt.decision and
      evidence["attempt_fingerprint"] ==
        CleanupOperation.attempt_fingerprint(item.id, attempt.attempt_number, attempt.decision) and
      evidence["publication_evidence"] == item.publication_evidence and
      evidence["predecessor_item_id"] == item.predecessor_item_id and
      is_nil(evidence["successor_item_id"]) and is_nil(evidence["adopter_item_id"])
  end

  defp exact_terminal_evidence?(
         %CleanupOperation{kind: :replacement_tombstone, evidence: evidence},
         repository,
         item,
         run,
         attempt
       ) do
    marker = item.publication_evidence

    with %Repository{lifecycle: :ready, deleted_at: nil} = new_repository <-
           Repo.get(Repository, evidence["new_repository_id"]),
         %AuditEvent{} = audit <-
           publication_audit(marker, repository.id, new_repository.id, item, run) do
      evidence["repository_id"] == repository.id and
        evidence["repository_generation"] == repository.generation and
        evidence["repository_write_version"] == repository.write_version and
        evidence["repository_storage_path"] == repository.storage_path and
        evidence["relative_path"] == repository.storage_path and
        evidence["repository_deleted_at"] == DateTime.to_iso8601(repository.deleted_at) and
        evidence["repository_updated_at"] == DateTime.to_iso8601(repository.updated_at) and
        evidence["item_id"] == item.id and evidence["item_lock_version"] == item.lock_version and
        evidence["attempt_number"] == attempt.attempt_number and
        evidence["attempt_decision"] == attempt.decision and
        evidence["attempt_fingerprint"] ==
          CleanupOperation.attempt_fingerprint(item.id, attempt.attempt_number, attempt.decision) and
        evidence["publication_marker"] == marker and
        evidence["publication_operation_id"] == marker["operation_id"] and
        evidence["new_repository_id"] == new_repository.id and
        evidence["new_repository_generation"] == new_repository.generation and
        evidence["publication_audit_id"] == audit.id and
        exact_replacement?(repository, item, attempt, marker)
    else
      _drift -> false
    end
  rescue
    _error -> false
  end

  defp exact_remote_evidence?(operation, item, repository) do
    evidence = operation.evidence
    identity = item.checkpoint["cleanup_identity"] || %{}

    operation.kind == :remote_quarantine and evidence["repository_id"] == repository.id and
      evidence["repository_generation"] == repository.generation and
      evidence["repository_storage_path"] == repository.storage_path and
      evidence["item_id"] == item.id and evidence["item_lock_version"] == item.lock_version and
      evidence["requested_path"] == ForgeRepos.absolute_storage_path(repository) and
      evidence["quarantine_path"] == item.staged_storage_path and
      evidence["quarantine_path"] == GitCore.Remote.cleanup_slot_path(evidence["requested_path"]) and
      Enum.all?(~w(mode major_device minor_device inode), &(&1 in Map.keys(evidence))) and
      evidence["mode"] == identity["mode"] and
      evidence["major_device"] == identity["major_device"] and
      evidence["minor_device"] == identity["minor_device"] and
      evidence["inode"] == identity["inode"] and
      evidence["remote_failure_kind"] == item.cleanup_error
  rescue
    _error -> false
  end

  defp other_nonterminal_import_work?(operation, repository_id) do
    source = Repo.get(RepositoryItem, operation.repository_item_id)

    other_item? =
      RepositoryItem
      |> where(
        [item],
        item.id != ^operation.repository_item_id and
          (item.hidden_repository_id == ^repository_id or
             item.replacement_repository_id == ^repository_id)
      )
      |> where([item], item.state not in ^@terminal_item_states)
      |> Repo.exists?()

    other_attempt? =
      ImportAttempt
      |> join(:inner, [attempt], item in RepositoryItem,
        on: item.id == attempt.repository_item_id
      )
      |> where(
        [attempt, item],
        (item.hidden_repository_id == ^repository_id or
           item.replacement_repository_id == ^repository_id) and
          attempt.state not in ^@terminal_attempt_states
      )
      |> where(
        [attempt, item],
        item.id != ^operation.repository_item_id or
          attempt.attempt_number != ^source.attempt_count
      )
      |> Repo.exists?()

    other_run? =
      ImportRun
      |> join(:inner, [run], item in RepositoryItem, on: item.import_run_id == run.id)
      |> where(
        [run, item],
        (item.hidden_repository_id == ^repository_id or
           item.replacement_repository_id == ^repository_id) and
          run.state not in ^@terminal_run_states and
          run.id != ^source.import_run_id
      )
      |> Repo.exists?()

    other_item? or other_attempt? or other_run?
  end

  defp canonical_unpublished?(repository, item, run, attempt) do
    canonical_shadow =
      case Regex.run(~r/\Aimport-([1-9][0-9]*)-[0-9a-f]{24}\z/, repository.slug || "") do
        [_slug, item_id] ->
          item_id == Integer.to_string(item.id) and repository.name == "GitHub import #{item.id}"

        _invalid ->
          false
      end

    canonical_shadow and repository.lifecycle == :importing and repository.visibility == :private and
      repository.write_version == 0 and is_nil(repository.last_pushed_at) and
      is_nil(repository.deleted_at) and is_nil(repository.storage_reclaimed_at) and
      item.state in [:failed, :canceled] and run.state in @terminal_run_states and
      attempt.state in @terminal_attempt_states and item.publication_evidence == %{} and
      is_nil(item.lease_owner) and is_nil(item.lease_expires_at) and is_nil(run.lease_owner) and
      is_nil(run.lease_expires_at)
  end

  defp successor_or_adopter?(item, repository) do
    Repo.exists?(
      from candidate in RepositoryItem,
        where:
          candidate.id != ^item.id and
            (candidate.predecessor_item_id == ^item.id or
               candidate.hidden_repository_id == ^repository.id)
    )
  end

  defp exact_replacement?(repository, item, attempt, marker) do
    decision = attempt.decision

    ForgeImports.RepositoryPublisher.valid_committed_evidence?(marker, %{
      item_id: item.id,
      hidden_repository_id: item.hidden_repository_id
    }) and marker["action"] == "replace" and marker["replaced_repository_id"] == repository.id and
      decision["action"] == "replace" and decision["replacement_repository_id"] == repository.id and
      decision["replacement_owner_id"] == repository.owner_user_id and
      decision["replacement_storage_path"] == repository.storage_path and
      decision["replacement_generation"] == repository.generation and
      decision["replacement_write_version"] == repository.write_version and
      decision["replacement_updated_at"] == DateTime.to_iso8601(repository.updated_at) and
      marker["attempt_number"] == attempt.attempt_number
  end

  defp publication_audit(marker, old_id, new_id, item, run) do
    request_metadata = marker["request_metadata"]

    expected_metadata =
      %{
        "item_id" => item.id,
        "attempt_number" => marker["attempt_number"],
        "run_id" => marker["run_id"],
        "published_count_after" => marker["published_count_after"],
        "run_lock_version_after" => marker["run_lock_version_after"],
        "new_repository_id" => new_id,
        "old_repository_id" => old_id
      }
      |> Map.merge(request_metadata)

    case Repo.all(
           from event in AuditEvent,
             where: event.operation_id == ^marker["operation_id"],
             order_by: [asc: event.id]
         ) do
      [%AuditEvent{} = event] ->
        if event.action == "repository.replaced" and event.actor_user_id == run.actor_user_id and
             event.target_type == "repository" and event.target_id == Integer.to_string(new_id) and
             event.metadata == expected_metadata and
             event.request_id == request_metadata["request_id"] and
             event.ip_address == request_metadata["ip_address"] and
             event.user_agent == request_metadata["user_agent"],
           do: event,
           else: nil

      _missing ->
        nil
    end
  end

  defp exact_remote_item_path(repository, item) do
    requested = ForgeRepos.absolute_storage_path(repository)

    if item.staged_storage_path == GitCore.Remote.cleanup_slot_path(requested),
      do: :ok,
      else: {:error, :path_mismatch}
  end

  defp relative_under_root(path) do
    root = Config.repo_storage_root()

    if is_binary(path) and String.starts_with?(path, root <> "/") do
      relative = Path.relative_to(path, root)

      case relative_segments(relative) do
        {:ok, _segments} -> {:ok, relative}
        error -> error
      end
    else
      {:error, :path_mismatch}
    end
  end

  defp final_source_matches(operation, repository, item) do
    if operation.repository_id == repository.id and operation.repository_item_id == item.id and
         operation.source_lock_version == item.lock_version and
         operation.evidence["repository_id"] == repository.id and
         operation.evidence["item_id"] == item.id,
       do: :ok,
       else: {:error, :evidence_mismatch}
  end

  defp remote_identity_matches(
         %CleanupOperation{kind: :remote_quarantine, evidence: evidence},
         target
       ) do
    expected = %{
      mode: evidence["mode"],
      major_device: evidence["major_device"],
      minor_device: evidence["minor_device"],
      inode: evidence["inode"]
    }

    if target == expected, do: :ok, else: {:error, :identity_mismatch}
  end

  defp remote_identity_matches(_operation, _target), do: :ok

  defp renew(operation, now) do
    OperationLease.renew_owned(CleanupOperation, operation,
      now: now,
      lease_seconds: Config.repository_cleanup().lease_seconds
    )
  end

  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp live_lease_retry_at(operation, now) do
    item = Repo.get(RepositoryItem, operation.repository_item_id)
    run = if item, do: Repo.get(ImportRun, item.import_run_id)
    repository = Repo.get(Repository, operation.repository_id)

    reconciler_expiry =
      case RepositoryWriteReconcilers.cleanup_live_lease_expiry_locked(repository, now) do
        {:ok, expiry} -> expiry
        {:error, :unavailable} -> nil
      end

    expiries = [live_expiry(item, now), live_expiry(run, now), reconciler_expiry]

    latest =
      expiries
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(&DateTime.to_unix(&1, :second), fn ->
        DateTime.add(now, Config.repository_cleanup().lease_seconds, :second)
      end)

    jitter_seconds = :erlang.phash2(operation.operation_id, 30) + 1
    DateTime.add(latest, jitter_seconds, :second)
  end

  defp live_expiry(%{lease_owner: owner, lease_expires_at: %DateTime{} = expires_at}, now)
       when is_binary(owner) and owner != "" do
    if DateTime.compare(expires_at, now) == :gt, do: expires_at
  end

  defp live_expiry(_row, _now), do: nil

  defp stringify_identity(identity) do
    %{
      "mode" => identity.mode,
      "major_device" => identity.major_device,
      "minor_device" => identity.minor_device,
      "inode" => identity.inode
    }
  end

  defp atomize_identity(identity) do
    %{
      mode: identity["mode"],
      major_device: identity["major_device"],
      minor_device: identity["minor_device"],
      inode: identity["inode"]
    }
  end

  defp paired_null_or_expired?(nil, nil, _now), do: true

  defp paired_null_or_expired?(owner, %DateTime{} = expires, now) when is_binary(owner),
    do: owner != "" and DateTime.compare(expires, now) in [:lt, :eq]

  defp paired_null_or_expired?(_owner, _expires, _now), do: false

  defp lease_shape(nil, nil, _now), do: :ok

  defp lease_shape(owner, %DateTime{} = expires, now) when is_binary(owner) and owner != "" do
    if DateTime.compare(expires, now) == :gt,
      do: {:blocked, :live_lease},
      else: {:blocked, :claimable_operation}
  end

  defp lease_shape(_owner, _expires, _now), do: {:blocked, :inconsistent_lease}

  defp remote_lease_shape(nil, nil, _now), do: :ok

  defp remote_lease_shape(owner, %DateTime{} = expires, now)
       when is_binary(owner) and owner != "" do
    if DateTime.compare(expires, now) == :gt, do: {:blocked, :live_lease}, else: :ok
  end

  defp remote_lease_shape(_owner, _expires, _now), do: {:blocked, :inconsistent_lease}

  defp due?(%DateTime{} = value, %DateTime{} = boundary),
    do: DateTime.compare(value, boundary) in [:lt, :eq]

  defp due?(_value, _boundary), do: false

  defp classify(reason)
       when reason in [
              :audit_mismatch,
              :cache_unavailable,
              :claimable_operation,
              :cleanup_timeout,
              :concurrent_import_work,
              :evidence_mismatch,
              :identity_mismatch,
              :inconsistent_lease,
              :limiter_unavailable,
              :live_lease,
              :path_mismatch,
              :persistence_unavailable,
              :root_identity_mismatch,
              :storage_root_mismatch,
              :storage_unavailable,
              :successor_or_adopter,
              :symlink,
              :special_file,
              :unsupported_platform
            ],
       do: reason

  defp classify(:deadline_exceeded), do: :cleanup_timeout
  defp classify(:timeout), do: :cleanup_timeout
  defp classify(:not_directory), do: :special_file
  defp classify(:mode_mismatch), do: :special_file
  defp classify(_reason), do: :evidence_mismatch

  defp locked_cleanup_context(operation) do
    with %RepositoryItem{} = observed_item <-
           Repo.get(RepositoryItem, operation.repository_item_id),
         {:ok, repositories} <-
           lock_repositories(cleanup_repository_ids(operation)),
         %Repository{} = repository <- Map.get(repositories, operation.repository_id),
         %ImportRun{} = run <- locked_run(observed_item.import_run_id),
         %RepositoryItem{} = item <- locked_item(operation.repository_item_id),
         true <- item.import_run_id == run.id,
         %ImportAttempt{} = attempt <- locked_attempt(item.id, item.attempt_count) do
      {:ok, repository, run, item, attempt}
    else
      _missing_or_changed -> {:error, :evidence_mismatch}
    end
  end

  defp locked_raw_context(kind, repository_id, item_id) do
    with %RepositoryItem{} = observed_item <- Repo.get(RepositoryItem, item_id),
         repository_ids <-
           raw_repository_ids(kind, repository_id, observed_item.hidden_repository_id),
         {:ok, repositories} <- lock_repositories(repository_ids),
         %Repository{} = repository <- Map.get(repositories, repository_id),
         %ImportRun{} = run <- locked_run(observed_item.import_run_id),
         %RepositoryItem{} = item <- locked_item(item_id),
         true <- item.import_run_id == run.id,
         %ImportAttempt{} = attempt <- locked_attempt(item.id, item.attempt_count) do
      {:ok, repository, run, item, attempt}
    else
      _missing_or_changed -> {:error, :evidence_mismatch}
    end
  end

  defp lock_repositories(repository_ids) do
    ids = repository_ids |> Enum.filter(&positive_integer?/1) |> Enum.uniq() |> Enum.sort()

    repositories =
      Repository
      |> where([repository], repository.id in ^ids)
      |> order_by([repository], asc: repository.id)
      |> maybe_lock()
      |> Repo.all()

    if length(repositories) == length(ids),
      do: {:ok, Map.new(repositories, &{&1.id, &1})},
      else: {:error, :evidence_mismatch}
  end

  defp cleanup_repository_ids(%CleanupOperation{kind: :replacement_tombstone} = operation),
    do: [operation.repository_id, operation.evidence["new_repository_id"]]

  defp cleanup_repository_ids(operation), do: [operation.repository_id]

  defp raw_repository_ids(:replacement_tombstone, repository_id, hidden_repository_id),
    do: [repository_id, hidden_repository_id]

  defp raw_repository_ids(_kind, repository_id, _hidden_repository_id), do: [repository_id]

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp locked_item(id),
    do: RepositoryItem |> where([row], row.id == ^id) |> maybe_lock() |> Repo.one()

  defp locked_run(id), do: ImportRun |> where([row], row.id == ^id) |> maybe_lock() |> Repo.one()

  defp locked_attempt(item_id, attempt_number) do
    ImportAttempt
    |> where(
      [attempt],
      attempt.repository_item_id == ^item_id and attempt.attempt_number == ^attempt_number
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp locked_operation(id),
    do: CleanupOperation |> where([row], row.id == ^id) |> maybe_lock() |> Repo.one()

  defp locked_owned_operation(operation) do
    CleanupOperation
    |> where(
      [row],
      row.id == ^operation.id and row.lease_owner == ^operation.lease_owner and
        row.lock_version == ^operation.lock_version and row.state == :cleanup_pending
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp maybe_lock(query) do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"],
      do: lock(query, "FOR UPDATE"),
      else: query
  end
end
