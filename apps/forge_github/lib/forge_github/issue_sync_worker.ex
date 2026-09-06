defmodule ForgeGitHub.IssueSyncWorker do
  @moduledoc """
  Bounded, crash-recoverable executor for issue and comment synchronization.

  A claim performs one resource reconciliation or one provider page. Outbound
  writes are preceded by a durable effect marker. Ambiguous creates scan the
  complete provider collection, one page per claim, before any retry.
  """

  use GenServer

  alias ForgeGitHub.{
    Client,
    Error,
    InstallationToken,
    InstallationTokenBroker,
    IssueClient,
    LabelClient
  }

  alias ForgeGitHub.IssueSyncProjection
  alias ForgeMirrors.{CorrelationMarker, MirrorOperation, ResourceDecision}

  @resource_kinds ["sync.issue", "sync.issue_comment"]
  @reconciliation_kinds [
    "reconcile.repository.issues",
    "reconcile.repository.issue_comments"
  ]
  @operation_kinds @resource_kinds ++ @reconciliation_kinds
  @default_interval_ms 1_000
  @default_lease_seconds 60
  @default_batch_size 4
  @default_max_concurrency 2
  @default_processor_timeout_ms 50_000
  @lease_margin_ms 5_000
  @full_scan_since ~U[1970-01-01 00:00:00Z]
  @scalar_fields ~w(title body state state_reason)
  @set_fields ~w(label_github_ids assignee_github_ids)
  @run_option_keys [
    :lease_seconds,
    :batch_size,
    :max_concurrency,
    :processor_timeout_ms,
    :task_supervisor,
    :claim,
    :context,
    :token_fetch,
    :local_observe,
    :remote_relationships,
    :get_issue,
    :get_comment,
    :get_repository,
    :get_label,
    :create_label,
    :label_observe,
    :list_issues,
    :list_comments,
    :resource_inventory,
    :create_issue,
    :update_issue,
    :create_comment,
    :update_comment,
    :delete_comment,
    :mark_effect,
    :mark_label_effect,
    :replace_effect,
    :requeue_effect,
    :checkpoint,
    :confirm,
    :confirm_label,
    :conflict,
    :record_page,
    :retry,
    :fail,
    :fingerprint,
    :correlation_id,
    :now
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc false
  @spec run_once(String.t(), keyword()) :: {:ok, list()} | {:error, atom()}
  def run_once(owner, options \\ [])

  def run_once(owner, options) when is_binary(owner) and is_list(options) do
    now = callback(options, :now, fn -> DateTime.utc_now(:second) end).()
    lease_seconds = bounded_option(options, :lease_seconds, @default_lease_seconds, 1, 3_600)
    batch_size = bounded_option(options, :batch_size, @default_batch_size, 1, 100)

    max_concurrency =
      bounded_option(
        options,
        :max_concurrency,
        config(:issue_sync_worker_max_concurrency, @default_max_concurrency),
        1,
        8
      )

    processor_timeout_ms =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:issue_sync_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_599_000
      )

    unless processor_timeout_ms <= lease_seconds * 1_000 - @lease_margin_ms do
      raise ArgumentError, "issue sync processor timeout must finish inside its lease"
    end

    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, lease_seconds, min(batch_size, max_concurrency), @operation_kinds) do
      supervisor =
        Keyword.get(options, :task_supervisor, ForgeGitHub.IssueSyncTaskSupervisor)

      results =
        supervisor
        |> Task.Supervisor.async_stream_nolink(
          operations,
          &process_operation(&1, now, options),
          max_concurrency: max_concurrency,
          ordered: true,
          on_timeout: :kill_task,
          timeout: processor_timeout_ms
        )
        |> Stream.zip(operations)
        |> Enum.map(fn
          {{:ok, result}, operation} -> {operation.id, result}
          {{:exit, _reason}, operation} -> {operation.id, {:error, :worker_crash}}
        end)

      {:ok, results}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def run_once(_owner, _options), do: {:error, :invalid_argument}

  @doc false
  def process_operation(%MirrorOperation{kind: kind} = operation, %DateTime{} = now, options)
      when kind in @reconciliation_kinds do
    with {:ok, sync} <- context(operation, options),
         {:ok, token} <- installation_token(sync, options),
         {:ok, page} <- fetch_reconciliation_page(sync, token, options),
         {:ok, observations} <- page_observations(sync.phase, sync.resource_kind, page) do
      callback(options, :record_page, &ForgeMirrors.record_resource_reconciliation_page/5).(
        operation,
        sync.resource_kind,
        observations,
        page.next_cursor,
        now
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  rescue
    _exception -> persist_failure(operation, now, :worker_crash, options)
  catch
    _kind, _reason -> persist_failure(operation, now, :worker_crash, options)
  end

  def process_operation(%MirrorOperation{kind: kind} = operation, %DateTime{} = now, options)
      when kind in @resource_kinds do
    with {:ok, sync} <- context(operation, options),
         {:ok, token} <- installation_token(sync, options) do
      if label_effect?(operation, sync) do
        recover_label_effect(operation, now, sync, token, options)
      else
        continue_resource_operation(operation, now, sync, token, options)
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  rescue
    _exception -> persist_failure(operation, now, :worker_crash, options)
  catch
    _kind, _reason -> persist_failure(operation, now, :worker_crash, options)
  end

  def process_operation(%MirrorOperation{} = operation, %DateTime{} = now, options),
    do: persist_failure(operation, now, :unsupported_operation, options)

  defp continue_resource_operation(operation, now, sync, token, options) do
    case local_observation(sync, options) do
      {:ok, local} ->
        if create_effect?(operation, sync) do
          recover_create(operation, now, sync, token, local, options)
        else
          continue_with_local(operation, now, sync, token, local, options)
        end

      {:label_required, candidate} ->
        if resource_effect?(operation) do
          conflict(operation, now, sync, :ambiguous_external_effect, :missing, :missing, options)
        else
          materialize_label(operation, now, sync, token, candidate, options)
        end

      {:label_required, candidate, local_identity} ->
        if resource_effect?(operation) do
          recover_resource_effect_before_label(
            operation,
            now,
            sync,
            token,
            local_identity,
            options
          )
        else
          materialize_label(operation, now, sync, token, candidate, options)
        end

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp continue_with_local(operation, now, sync, token, local, options) do
    case remote_observation(sync, token, now, options) do
      {:ok, remote} ->
        continue_after_observation(operation, now, sync, token, local, remote, options)

      {:label_required, candidate} ->
        if resource_effect?(operation) do
          conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)
        else
          materialize_label(operation, now, sync, token, candidate, options)
        end

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp recover_resource_effect_before_label(
         operation,
         now,
         sync,
         token,
         local_identity,
         options
       ) do
    with {:ok, local} <- unresolved_effect_local(sync, operation, local_identity) do
      if create_effect?(operation, sync) do
        recover_create_before_label(operation, now, sync, token, local, options)
      else
        recover_update_before_label(operation, now, sync, token, local, options)
      end
    else
      {:error, _reason} ->
        conflict(operation, now, sync, :ambiguous_external_effect, :missing, :missing, options)
    end
  end

  defp recover_update_before_label(operation, now, sync, token, local, options) do
    case remote_observation(sync, token, now, options) do
      {:ok, remote} ->
        case recorded_effect_condition(operation, sync, local, remote, options) do
          {:applied, postcondition} ->
            confirm_reconciled_resource_effect(
              operation,
              now,
              sync,
              local,
              postcondition,
              options
            )

          :not_applied ->
            requeue_reconciled_effect(operation, now, options)

          _ambiguous ->
            conflict(operation, now, sync, :ambiguous_external_effect, local, remote, options)
        end

      {:label_required, _candidate} ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options, preserve_effect?: true)
    end
  end

  defp recover_create_before_label(operation, now, sync, token, local, options) do
    with :ok <- validate_create_marker(sync.effect_marker, sync, local, options),
         {:ok, recovery} <- recovery_checkpoint(operation.checkpoint) do
      case recovery do
        %{complete: true, match: nil} ->
          requeue_reconciled_effect(operation, now, options)

        %{complete: true, match: match} ->
          adopt_created_match_before_label(operation, now, sync, token, local, match, options)

        %{page: page, match: match} ->
          scan_create_page(operation, now, sync, token, local, page, match, options)
      end
    else
      _invalid ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)
    end
  end

  defp adopt_created_match_before_label(
         operation,
         now,
         sync,
         token,
         local,
         match,
         options
       ) do
    recovery_sync = %{
      sync
      | github_object_id: match["github_object_id"],
        github_number: match["github_number"]
    }

    result =
      case sync.resource_kind do
        :issue ->
          callback(options, :get_issue, &IssueClient.get_issue/5).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            match["github_number"],
            request_options(sync)
          )

        :issue_comment ->
          callback(options, :get_comment, &IssueClient.get_comment/5).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            match["github_object_id"],
            request_options(sync)
          )
      end

    with {:ok, remote} <-
           decode_remote(
             result,
             recovery_sync,
             now,
             sync.effect_marker["correlation_id"],
             options
           ),
         {:ok, fingerprint} <- observation_fingerprint(remote, options),
         true <- fingerprint == sync.effect_marker["proposed_fingerprint"] do
      confirm_reconciled_resource_effect(
        operation,
        now,
        recovery_sync,
        local,
        remote,
        options
      )
    else
      _invalid ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)
    end
  end

  defp confirm_reconciled_resource_effect(operation, now, sync, local, remote, options) do
    marker = operation.external_effect_marker

    domain_request = %{
      action: :observe,
      repository_id: sync.repository_id,
      resource_kind: sync.resource_kind,
      local_resource_id: local.local_resource_id,
      minimum_local_version: marker["expected_local_version"]
    }

    confirmation = %{
      github_object_id: remote.github_object_id,
      github_node_id: remote.github_node_id,
      github_number: remote.github_number,
      remote_updated_at: remote.remote_updated_at,
      confirmed_local_version: marker["expected_local_version"],
      confirmed_snapshot: remote.snapshot,
      state: :confirmed
    }

    expected = %{
      resource_state_lock_version: sync.resource_state_lock_version || :missing,
      local_resource_id: local.local_resource_id,
      expected_local_version: local.local_version,
      github_object_id: remote.github_object_id,
      observed_remote_updated_at: remote.remote_updated_at,
      effect_marker: marker
    }

    callback(options, :confirm, &default_confirm/5).(
      operation,
      now,
      expected,
      confirmation,
      domain_request
    )
  end

  defp requeue_reconciled_effect(operation, now, options) do
    callback(
      options,
      :requeue_effect,
      &ForgeMirrors.requeue_reconciled_resource_effect/2
    ).(operation, now)
  end

  defp unresolved_effect_local(
         sync,
         %MirrorOperation{state: :effect_pending, external_effect_marker: marker},
         %{local_resource_id: id, local_version: version}
       )
       when is_integer(id) and id > 0 and is_integer(version) and version > 0 and is_map(marker) do
    if marker == sync.effect_marker and marker["local_resource_id"] == id and
         is_integer(marker["expected_local_version"]) and
         version > marker["expected_local_version"] do
      {:ok,
       %{
         presence: :present,
         resource_kind: sync.resource_kind,
         local_resource_id: id,
         local_version: version,
         snapshot: %{},
         label_catalog: %{},
         assignee_catalog: %{}
       }}
    else
      {:error, :ambiguous_external_effect}
    end
  end

  defp unresolved_effect_local(_sync, _operation, _local_identity),
    do: {:error, :ambiguous_external_effect}

  defp resource_effect?(%MirrorOperation{state: :effect_pending}), do: true
  defp resource_effect?(_operation), do: false

  @impl true
  def init(options) do
    owner = "issue-sync-#{node()}-#{System.unique_integer([:positive])}"
    run_options = Keyword.take(options, @run_option_keys)

    state = %{
      enabled: Keyword.get(options, :enabled, config(:issue_sync_worker_enabled, true)),
      interval_ms:
        bounded_option(
          options,
          :interval_ms,
          config(:issue_sync_worker_interval_ms, @default_interval_ms),
          1,
          3_600_000
        ),
      task_supervisor:
        Keyword.get(options, :task_supervisor, ForgeGitHub.IssueSyncTaskSupervisor),
      runner: Keyword.get(options, :runner, fn -> run_once(owner, run_options) end),
      task_ref: nil
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    case Task.Supervisor.start_child(state.task_supervisor, state.runner) do
      {:ok, pid} -> {:noreply, %{state | task_ref: Process.monitor(pid)}}
      {:error, _reason} -> schedule(state.interval_ms) && {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp context(operation, options) do
    callback(options, :context, &ForgeMirrors.resource_operation_context/1).(operation)
  end

  defp installation_token(sync, options) do
    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           %{permissions: %{"issues" => "write", "metadata" => "read"}}
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :credential_unavailable}
    end
  end

  defp local_observation(%{local_resource_id: nil}, _options), do: {:ok, :missing}

  defp local_observation(%{local_deleted: true}, _options), do: {:ok, :deleted}

  defp local_observation(sync, options) do
    callback(options, :local_observe, &default_local_observation/1).(sync)
  end

  defp default_local_observation(sync) do
    with {:ok, projection} <-
           ForgeIssues.Sync.sync_projection(
             sync.repository_id,
             sync.resource_kind,
             sync.local_resource_id
           ) do
      case ForgeMirrors.resolve_issue_relationships(
             sync.repository_mirror_id,
             :local,
             projection.label_ids,
             projection.assignee_refs
           ) do
        {:ok, relationships} ->
          IssueSyncProjection.from_local(projection, relationships)

        {:error, {:unmapped_label, candidate}} ->
          {:label_required, candidate,
           %{
             local_resource_id: projection.local_resource_id,
             local_version: projection.local_version
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp remote_observation(%{resource_kind: :issue, github_number: nil}, _token, _now, _options),
    do: {:ok, :missing}

  defp remote_observation(
         %{resource_kind: :issue, github_number: number} = sync,
         token,
         now,
         options
       ) do
    result =
      callback(options, :get_issue, &IssueClient.get_issue/5).(
        token,
        sync.remote_owner,
        sync.remote_repository,
        number,
        request_options(sync)
      )

    decode_remote(result, sync, now, nil, options)
  end

  defp remote_observation(
         %{resource_kind: :issue_comment, github_object_id: nil},
         _token,
         _now,
         _options
       ),
       do: {:ok, :missing}

  defp remote_observation(
         %{resource_kind: :issue_comment, github_object_id: id} = sync,
         token,
         now,
         options
       ) do
    result =
      callback(options, :get_comment, &IssueClient.get_comment/5).(
        token,
        sync.remote_owner,
        sync.remote_repository,
        id,
        request_options(sync)
      )

    case result do
      {:error, %Error{kind: :not_found}} -> verify_repository_access(sync, token, options)
      _other -> decode_remote(result, sync, now, nil, options)
    end
  end

  defp decode_remote({:ok, raw}, sync, now, correlation_id, options) do
    with :ok <- validate_remote_identity(raw, sync) do
      case remote_relationships(sync, raw, now, options) do
        {:ok, relationships} ->
          case sync.resource_kind do
            :issue ->
              IssueSyncProjection.from_remote_issue(raw, relationships, correlation_id)

            :issue_comment ->
              IssueSyncProjection.from_remote_comment(raw, relationships, correlation_id)
          end

        {:label_required, candidate} ->
          {:label_required, candidate}

        {:error, {:unmapped_label, candidate}} ->
          {:label_required, candidate}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_remote({:error, %Error{} = error}, _sync, _now, _id, _options),
    do: {:error, error}

  defp decode_remote(_result, _sync, _now, _id, _options),
    do: {:error, :invalid_remote_resource}

  defp verify_repository_access(
         %{github_repository_id: expected_id} = sync,
         token,
         options
       )
       when is_integer(expected_id) and expected_id > 0 do
    case callback(options, :get_repository, &Client.repository/4).(
           token,
           sync.remote_owner,
           sync.remote_repository,
           request_options(sync)
         ) do
      {:ok, %{id: ^expected_id}} -> {:ok, :deleted}
      {:ok, _mismatched_repository} -> {:error, :invalid_remote_resource}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp verify_repository_access(_sync, _token, _options),
    do: {:error, :invalid_remote_resource}

  defp remote_relationships(sync, raw, now, options) do
    callback(options, :remote_relationships, &default_remote_relationships/3).(sync, raw, now)
  end

  defp default_remote_relationships(sync, raw, now) do
    labels = if sync.resource_kind == :issue, do: raw["labels"], else: []
    assignees = if sync.resource_kind == :issue, do: raw["assignees"], else: []

    with {:ok, author} <- observe_author(raw["user"], now),
         {:ok, observed_assignees} <- observe_assignees(assignees, now) do
      case ForgeMirrors.resolve_issue_relationships(
             sync.repository_mirror_id,
             :remote,
             labels,
             observed_assignees
           ) do
        {:ok, relationships} -> {:ok, Map.put(relationships, :author, author)}
        {:error, {:unmapped_label, candidate}} -> {:label_required, candidate}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp observe_author(nil, _now), do: {:error, :unsupported_resource}

  defp observe_author(user, now) do
    case ForgeAccounts.observe_github_identity(user, now) do
      {:ok, identity} -> {:ok, %{github_identity_id: identity.id}}
      {:error, _reason} -> {:error, :invalid_remote_resource}
    end
  end

  defp observe_assignees(assignees, now) when is_list(assignees) do
    Enum.reduce_while(assignees, {:ok, []}, fn user, {:ok, observed} ->
      case ForgeAccounts.observe_github_identity(user, now) do
        {:ok, identity} ->
          value = Map.put(user, "github_identity_id", identity.id)
          {:cont, {:ok, [value | observed]}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_remote_resource}}
      end
    end)
    |> case do
      {:ok, observed} -> {:ok, Enum.reverse(observed)}
      error -> error
    end
  end

  defp observe_assignees(_assignees, _now), do: {:error, :invalid_remote_resource}

  defp materialize_label(operation, now, sync, token, candidate, options) do
    with {:ok, candidate} <- normalize_label_candidate(candidate),
         {:ok, candidate} <- put_label_fingerprint(candidate, options) do
      case candidate.direction do
        :local -> materialize_local_label(operation, now, sync, token, candidate, options)
        :remote -> confirm_label_mapping(operation, now, sync, candidate, nil, options)
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp materialize_local_label(operation, now, sync, token, candidate, options) do
    case callback(options, :get_label, &LabelClient.get_label/5).(
           token,
           sync.remote_owner,
           sync.remote_repository,
           candidate.snapshot["name"],
           request_options(sync)
         ) do
      {:ok, raw} ->
        with {:ok, remote} <- provider_label(raw) do
          if remote.snapshot == candidate.snapshot do
            confirm_label_mapping(operation, now, sync, candidate, remote, options)
          else
            label_conflict(
              operation,
              now,
              sync,
              :label_namespace_collision,
              candidate.snapshot,
              remote.snapshot,
              options
            )
          end
        else
          {:error, reason} -> persist_failure(operation, now, reason, options)
        end

      {:error, %Error{kind: :not_found}} ->
        create_local_label(operation, now, sync, token, candidate, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)

      _invalid ->
        persist_failure(operation, now, :invalid_remote_resource, options)
    end
  end

  defp create_local_label(operation, now, sync, token, candidate, options) do
    with {:ok, marker} <- label_effect_marker(candidate, options),
         expected <- label_expected(candidate, nil),
         domain_request <- label_domain_request(sync, operation, candidate),
         {:ok, %{operation: marked}} <-
           callback(
             options,
             :mark_label_effect,
             &default_mark_label_effect/5
           ).(operation, now, expected, marker, domain_request) do
      case callback(options, :create_label, &LabelClient.create_label/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             candidate.snapshot,
             request_options(sync)
           ) do
        {:ok, raw} ->
          with {:ok, remote} <- provider_label(raw) do
            if remote.snapshot == candidate.snapshot do
              confirm_label_mapping(marked, now, sync, candidate, remote, options)
            else
              label_conflict(
                marked,
                now,
                sync,
                :ambiguous_label_create,
                candidate.snapshot,
                remote.snapshot,
                options
              )
            end
          else
            {:error, reason} -> schedule_effect_recovery(marked, now, reason, options)
          end

        {:error, reason} ->
          schedule_effect_recovery(marked, now, reason, options)

        _invalid ->
          schedule_effect_recovery(marked, now, :invalid_remote_resource, options)
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp recover_label_effect(operation, now, sync, token, options) do
    marker = operation.external_effect_marker

    with {:ok, projection} <-
           callback(options, :label_observe, &ForgeIssues.label_sync_projection/2).(
             sync.repository_id,
             marker["local_label_id"]
           ),
         {:ok, candidate} <- label_candidate_from_projection(projection),
         {:ok, candidate} <- put_label_fingerprint(candidate, options),
         :ok <- validate_label_effect_marker(marker, sync, candidate, options) do
      case callback(options, :get_label, &LabelClient.get_label/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             marker["label_name"],
             request_options(sync)
           ) do
        {:ok, raw} ->
          with {:ok, remote} <- provider_label(raw) do
            if remote.snapshot == candidate.snapshot do
              confirm_label_mapping(operation, now, sync, candidate, remote, options)
            else
              label_conflict(
                operation,
                now,
                sync,
                :ambiguous_label_create,
                candidate.snapshot,
                remote.snapshot,
                options
              )
            end
          else
            {:error, reason} -> schedule_effect_recovery(operation, now, reason, options)
          end

        {:error, %Error{kind: :not_found}} ->
          label_conflict(
            operation,
            now,
            sync,
            :ambiguous_label_create,
            candidate.snapshot,
            %{},
            options
          )

        {:error, reason} ->
          schedule_effect_recovery(operation, now, reason, options)

        _invalid ->
          schedule_effect_recovery(operation, now, :invalid_remote_resource, options)
      end
    else
      {:error, reason} ->
        label_conflict(operation, now, sync, reason, %{}, %{}, options)
    end
  end

  defp confirm_label_mapping(operation, now, sync, candidate, remote, options) do
    expected = label_expected(candidate, operation.external_effect_marker)
    confirmation = label_confirmation(candidate, remote)
    domain_request = label_domain_request(sync, operation, candidate)

    case callback(options, :confirm_label, &default_confirm_label/5).(
           operation,
           now,
           expected,
           confirmation,
           domain_request
         ) do
      {:error, reason} when reason in [:namespace_collision, :label_normalization_conflict] ->
        {local, remote} = label_conflict_snapshots(candidate)

        label_conflict(
          operation,
          now,
          sync,
          :label_namespace_collision,
          local,
          remote,
          options
        )

      {:error, reason} ->
        persist_failure(
          operation,
          now,
          reason,
          options,
          preserve_effect?: operation.state == :effect_pending
        )

      result ->
        result
    end
  end

  defp default_mark_label_effect(operation, now, expected, marker, domain_request) do
    ForgeMirrors.mark_label_effect_for_resource_operation(
      operation,
      now,
      expected,
      marker,
      label_domain_multi(domain_request)
    )
  end

  defp default_confirm_label(operation, now, expected, confirmation, domain_request) do
    ForgeMirrors.confirm_label_for_resource_operation(
      operation,
      now,
      expected,
      confirmation,
      label_domain_multi(domain_request)
    )
  end

  defp label_domain_multi(%{action: :observe} = request),
    do: &ForgeIssues.append_sync_label_observe(&1, :resource, Map.delete(request, :action))

  defp label_domain_multi(%{action: :import} = request),
    do: &ForgeIssues.append_sync_label_import(&1, :resource, Map.delete(request, :action))

  defp label_domain_request(sync, _operation, %{direction: :local} = candidate) do
    %{
      action: :observe,
      repository_id: sync.repository_id,
      local_resource_id: candidate.local_label_id,
      expected_local_version: candidate.local_version,
      expected_fields: candidate.snapshot
    }
  end

  defp label_domain_request(sync, operation, %{direction: :remote} = candidate) do
    %{
      action: :import,
      repository_id: sync.repository_id,
      fields: candidate.snapshot,
      provenance: resource_provenance(sync, operation)
    }
  end

  defp resource_provenance(sync, operation) do
    %{
      origin: :github,
      causation_id:
        sync.provenance.delivery_guid || sync.provenance.outbox_event_id ||
          "mirror-operation:#{operation.id}",
      correlation_id: sync.provenance.correlation_id || "mirror-operation:#{operation.id}"
    }
  end

  defp label_expected(candidate, effect_marker) do
    %{
      resource_state_lock_version: :missing,
      local_label_id: candidate[:local_label_id],
      expected_local_version: candidate[:local_version],
      expected_local_fingerprint:
        if(candidate.direction == :local, do: candidate[:fingerprint], else: nil),
      github_object_id: candidate[:github_object_id],
      effect_marker: effect_marker
    }
  end

  defp label_confirmation(%{direction: :local}, remote) do
    %{
      github_object_id: remote.github_object_id,
      github_node_id: remote.github_node_id,
      confirmed_snapshot: remote.snapshot
    }
  end

  defp label_confirmation(%{direction: :remote} = candidate, nil) do
    %{
      github_object_id: candidate.github_object_id,
      github_node_id: candidate.github_node_id,
      confirmed_snapshot: candidate.snapshot
    }
  end

  defp label_effect_marker(candidate, options) do
    with {:ok, fingerprint} <- fingerprint(candidate.snapshot, options) do
      {:ok,
       %{
         "v" => 1,
         "action" => "create_remote_label",
         "resource_kind" => "label",
         "local_label_id" => candidate.local_label_id,
         "expected_local_version" => candidate.local_version,
         "expected_local_fingerprint" => fingerprint,
         "expected_remote_absent" => true,
         "label_name" => candidate.snapshot["name"],
         "proposed_fingerprint" => fingerprint,
         "proposed_snapshot" => candidate.snapshot
       }}
    end
  end

  defp validate_label_effect_marker(marker, sync, candidate, options) do
    with true <- sync.effect_marker == marker,
         true <- marker["v"] == 1 and marker["action"] == "create_remote_label",
         true <- marker["resource_kind"] == "label",
         true <- marker["local_label_id"] == candidate.local_label_id,
         true <- marker["expected_local_version"] == candidate.local_version,
         true <- marker["expected_remote_absent"] == true,
         true <- marker["label_name"] == candidate.snapshot["name"],
         true <- marker["proposed_snapshot"] == candidate.snapshot,
         {:ok, fingerprint} <- fingerprint(candidate.snapshot, options),
         true <- marker["expected_local_fingerprint"] == fingerprint,
         true <- marker["proposed_fingerprint"] == fingerprint do
      :ok
    else
      _invalid -> {:error, :ambiguous_label_create}
    end
  end

  defp label_effect?(
         %MirrorOperation{state: :effect_pending, external_effect_marker: marker},
         %{effect_marker: marker}
       )
       when is_map(marker),
       do: marker["action"] == "create_remote_label" and marker["resource_kind"] == "label"

  defp label_effect?(_operation, _sync), do: false

  defp normalize_label_candidate(%{direction: :local} = candidate) do
    with id when is_integer(id) and id > 0 <- candidate[:local_label_id],
         version when is_integer(version) and version > 0 <- candidate[:local_version],
         {:ok, snapshot} <- canonical_label_snapshot(candidate_snapshot(candidate)) do
      {:ok, Map.merge(candidate, %{snapshot: snapshot, fingerprint: nil})}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp normalize_label_candidate(%{direction: :remote} = candidate) do
    with id when is_integer(id) and id > 0 <- candidate[:github_object_id],
         node_id when is_binary(node_id) and node_id != "" <- candidate[:github_node_id],
         {:ok, snapshot} <- canonical_label_snapshot(candidate_snapshot(candidate)) do
      {:ok, Map.merge(candidate, %{snapshot: snapshot, fingerprint: nil})}
    else
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp normalize_label_candidate(%{local_label_id: _id} = candidate),
    do: normalize_label_candidate(Map.put(candidate, :direction, :local))

  defp normalize_label_candidate(%{github_object_id: _id, node_id: node_id} = candidate),
    do:
      candidate
      |> Map.put(:direction, :remote)
      |> Map.put(:github_node_id, node_id)
      |> normalize_label_candidate()

  defp normalize_label_candidate(_candidate), do: {:error, :invalid_projection}

  defp label_candidate_from_projection(%{
         repository_id: repository_id,
         resource_kind: :label,
         local_resource_id: id,
         local_resource_type: "ForgeIssues.Label",
         local_version: version,
         fields: fields
       })
       when is_integer(repository_id) and repository_id > 0 do
    normalize_label_candidate(%{
      direction: :local,
      local_label_id: id,
      local_version: version,
      snapshot: fields
    })
  end

  defp label_candidate_from_projection(_projection), do: {:error, :invalid_projection}

  defp put_label_fingerprint(candidate, options) do
    with {:ok, fingerprint} <- fingerprint(candidate.snapshot, options) do
      {:ok, Map.put(candidate, :fingerprint, fingerprint)}
    end
  end

  defp provider_label(raw) when is_map(raw) do
    with false <- raw["archived"] == true,
         id when is_integer(id) and id > 0 <- raw["id"],
         node_id when is_binary(node_id) and node_id != "" <- raw["node_id"],
         {:ok, snapshot} <- canonical_label_snapshot(raw) do
      {:ok, %{github_object_id: id, github_node_id: node_id, snapshot: snapshot}}
    else
      true -> {:error, :unsupported_resource}
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp provider_label(_raw), do: {:error, :invalid_remote_resource}

  defp candidate_snapshot(%{snapshot: snapshot}), do: snapshot

  defp candidate_snapshot(candidate) do
    %{
      "name" => candidate[:name],
      "color" => candidate[:color],
      "description" => candidate[:description]
    }
  end

  defp canonical_label_snapshot(
         %{"name" => name, "color" => color, "description" => description} = snapshot
       )
       when map_size(snapshot) >= 3 and is_binary(name) and is_binary(color) do
    description =
      if is_binary(description) and String.trim(description) == "", do: nil, else: description

    color = String.downcase(color)

    if valid_label_text?(name, 255) and String.trim(name) != "" and
         Regex.match?(~r/\A[0-9a-f]{6}\z/, color) and
         (is_nil(description) or valid_label_text?(description, 100)) do
      {:ok, %{"name" => name, "color" => color, "description" => description}}
    else
      {:error, :invalid_projection}
    end
  end

  defp canonical_label_snapshot(_snapshot), do: {:error, :invalid_projection}

  defp valid_label_text?(value, maximum)
       when is_binary(value) and byte_size(value) <= maximum * 4 do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      length(String.codepoints(value)) <= maximum
  end

  defp valid_label_text?(_value, _maximum), do: false

  defp label_conflict_snapshots(%{direction: :local, snapshot: snapshot}),
    do: {snapshot, %{}}

  defp label_conflict_snapshots(%{direction: :remote, snapshot: snapshot}),
    do: {%{}, snapshot}

  defp label_conflict(operation, now, sync, kind, local, remote, options) do
    conflict(
      operation,
      now,
      sync,
      kind,
      %{snapshot: local},
      %{snapshot: remote},
      options
    )
  end

  defp continue_after_observation(operation, now, sync, token, local, remote, options) do
    case recorded_effect_condition(operation, sync, local, remote, options) do
      :none ->
        decide_and_apply(operation, now, sync, token, local, remote, options)

      :not_applied ->
        decide_and_apply(operation, now, sync, token, local, remote, options)

      {:applied, postcondition} ->
        decide_and_apply(operation, now, sync, token, local, postcondition, options)

      {:error, :ambiguous_external_effect} ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, remote, options)
    end
  end

  defp recorded_effect_condition(
         %MirrorOperation{state: :processing},
         _sync,
         _local,
         _remote,
         _opts
       ),
       do: :none

  defp recorded_effect_condition(
         %MirrorOperation{state: :effect_pending, external_effect_marker: marker},
         sync,
         local,
         remote,
         options
       ) do
    with :ok <- validate_effect_marker(marker, sync, local, options),
         {:ok, remote_fingerprint} <- observation_fingerprint(remote, options) do
      cond do
        marker["action"] == "delete_remote_comment" and remote == :deleted ->
          {:applied, :deleted}

        present?(remote) and remote_fingerprint == marker["proposed_fingerprint"] ->
          {:applied, remote}

        present?(remote) and remote_fingerprint == marker["expected_remote_fingerprint"] and
            iso8601(remote.remote_updated_at) == marker["expected_remote_updated_at"] ->
          :not_applied

        true ->
          {:error, :ambiguous_external_effect}
      end
    else
      _invalid -> {:error, :ambiguous_external_effect}
    end
  end

  defp decide_and_apply(operation, now, sync, token, local, remote, options) do
    case resource_decision(sync, sync.baseline, local, remote) do
      {:ok, decision} ->
        apply_decision(operation, now, sync, token, local, remote, decision, options)

      {:conflict, kind} ->
        conflict(operation, now, sync, kind, local, remote, options)
    end
  end

  defp resource_decision(_sync, _baseline, :missing, :missing),
    do: {:ok, %{target: :deleted, local?: false, remote?: false}}

  defp resource_decision(_sync, _baseline, :deleted, :deleted),
    do: {:ok, %{target: :deleted, local?: false, remote?: false}}

  defp resource_decision(_sync, _baseline, local, :missing) when is_map(local),
    do: {:ok, %{target: local.snapshot, local?: false, remote?: true}}

  defp resource_decision(_sync, _baseline, local, :deleted) when is_map(local),
    do: {:ok, %{target: :deleted, local?: true, remote?: false}}

  defp resource_decision(_sync, _baseline, :missing, remote) when is_map(remote),
    do: {:ok, %{target: remote.snapshot, local?: true, remote?: false}}

  defp resource_decision(%{trigger: :local}, _baseline, :deleted, remote) when is_map(remote),
    do: {:ok, %{target: :deleted, local?: false, remote?: true}}

  defp resource_decision(_sync, _baseline, :deleted, remote) when is_map(remote),
    do: {:ok, %{target: remote.snapshot, local?: true, remote?: false}}

  defp resource_decision(_sync, :missing, local, remote) when is_map(local) and is_map(remote) do
    if local.snapshot == remote.snapshot,
      do: {:ok, %{target: local.snapshot, local?: false, remote?: false}},
      else: {:conflict, :missing_baseline}
  end

  defp resource_decision(_sync, baseline, local, remote)
       when is_map(baseline) and is_map(local) and is_map(remote) do
    fields = if local.resource_kind == :issue, do: @scalar_fields ++ @set_fields, else: ["body"]

    Enum.reduce_while(fields, {:ok, %{}, false, false}, fn field,
                                                           {:ok, target, local?, remote?} ->
      decision =
        if field in @set_fields do
          ResourceDecision.set(
            MapSet.new(Map.fetch!(baseline, field)),
            MapSet.new(Map.fetch!(local.snapshot, field)),
            MapSet.new(Map.fetch!(remote.snapshot, field))
          )
        else
          ResourceDecision.scalar(
            Map.fetch!(baseline, field),
            Map.fetch!(local.snapshot, field),
            Map.fetch!(remote.snapshot, field)
          )
        end

      case decision_flags(decision) do
        {:ok, value, field_local?, field_remote?} ->
          value =
            if is_struct(value, MapSet), do: value |> MapSet.to_list() |> Enum.sort(), else: value

          {:cont,
           {:ok, Map.put(target, field, value), local? or field_local?, remote? or field_remote?}}

        {:conflict, kind} ->
          {:halt, {:conflict, kind}}
      end
    end)
    |> case do
      {:ok, target, local?, remote?} ->
        {:ok, %{target: target, local?: local?, remote?: remote?}}

      conflict ->
        conflict
    end
  rescue
    _invalid -> {:conflict, :missing_baseline}
  end

  defp resource_decision(_sync, _baseline, _local, _remote), do: {:conflict, :missing_baseline}

  defp decision_flags({:confirm, value}), do: {:ok, value, false, false}
  defp decision_flags({:apply_local, _expected, value}), do: {:ok, value, true, false}
  defp decision_flags({:apply_remote, _expected, value}), do: {:ok, value, false, true}
  defp decision_flags({:apply_both, _local, _remote, value}), do: {:ok, value, true, true}
  defp decision_flags({:conflict, kind}), do: {:conflict, kind}

  defp apply_decision(operation, now, sync, token, local, remote, decision, options) do
    catalogs = merged_catalogs(local, remote)

    cond do
      decision.target == :deleted and sync.resource_kind != :issue_comment ->
        persist_failure(operation, now, :unsupported_resource, options)

      decision.remote? ->
        with {:ok, attrs} <- target_remote_attrs(sync, decision.target, catalogs),
             {:ok, marked} <-
               mark_effect(operation, now, sync, local, remote, decision.target, options),
             {:ok, postcondition} <-
               execute_remote_effect(marked, sync, token, attrs, decision.target, now, options) do
          confirm_observation(
            marked,
            now,
            sync,
            local,
            postcondition,
            decision.local?,
            options,
            catalogs
          )
        else
          {:effect_error, marked, reason} ->
            schedule_effect_recovery(marked, now, reason, options)

          {:error, reason} ->
            persist_failure(operation, now, reason, options)
        end

      true ->
        confirm_observation(
          operation,
          now,
          sync,
          local,
          target_observation(remote, decision.target),
          decision.local?,
          options,
          catalogs
        )
    end
  end

  defp target_remote_attrs(%{resource_kind: :issue_comment}, :deleted, _catalogs),
    do: {:ok, %{}}

  defp target_remote_attrs(sync, target, %{labels: labels, assignees: assignees}) do
    IssueSyncProjection.remote_attrs(sync.resource_kind, target, labels, assignees)
  end

  defp target_observation(_remote, :deleted), do: :deleted
  defp target_observation(remote, _target), do: remote

  defp mark_effect(operation, now, sync, local, remote, proposed, options) do
    with {:ok, marker} <- effect_marker(sync, local, remote, proposed, options) do
      case operation do
        %MirrorOperation{state: :effect_pending, external_effect_marker: previous}
        when is_map(previous) ->
          if marker == previous do
            {:ok, operation}
          else
            callback(options, :replace_effect, &ForgeMirrors.replace_external_effect/4).(
              operation,
              now,
              previous,
              marker
            )
          end

        %MirrorOperation{} ->
          callback(options, :mark_effect, &ForgeMirrors.mark_external_effect/3).(
            operation,
            now,
            marker
          )
      end
    end
  end

  defp effect_marker(sync, local, remote, proposed, options) do
    with {:ok, local_id, local_version, local_fingerprint} <-
           local_effect_state(sync, local, options),
         {:ok, remote_fingerprint} <- observation_fingerprint(remote, options),
         {:ok, proposed_fingerprint} <- target_fingerprint(proposed, options) do
      action = effect_action(sync.resource_kind, remote, proposed)

      marker = %{
        "v" => 1,
        "action" => action,
        "resource_kind" => Atom.to_string(sync.resource_kind),
        "local_resource_id" => local_id,
        "expected_local_version" => local_version,
        "expected_local_fingerprint" => local_fingerprint,
        "expected_remote_updated_at" => observation_updated_at(remote),
        "expected_remote_fingerprint" => remote_fingerprint,
        "proposed_fingerprint" => proposed_fingerprint
      }

      marker =
        if present?(remote),
          do: Map.put(marker, "github_object_id", remote.github_object_id),
          else: marker

      if action in ["create_remote_issue", "create_remote_comment"] do
        correlation_id = callback(options, :correlation_id, &Ecto.UUID.generate/0).()

        if match?({:ok, _}, Ecto.UUID.cast(correlation_id)) do
          {:ok,
           marker
           |> Map.put("correlation_id", correlation_id)
           |> Map.put("recovery_since", DateTime.to_iso8601(@full_scan_since))}
        else
          {:error, :invalid_correlation_id}
        end
      else
        {:ok, marker}
      end
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp effect_action(:issue, :missing, _proposed), do: "create_remote_issue"
  defp effect_action(:issue, _remote, _proposed), do: "update_remote_issue"
  defp effect_action(:issue_comment, :missing, _proposed), do: "create_remote_comment"
  defp effect_action(:issue_comment, _remote, :deleted), do: "delete_remote_comment"
  defp effect_action(:issue_comment, _remote, _proposed), do: "update_remote_comment"

  defp execute_remote_effect(marked, sync, token, attrs, target, now, options) do
    result =
      case marked.external_effect_marker["action"] do
        "create_remote_issue" ->
          with {:ok, create_attrs} <- append_correlation(attrs, marked.external_effect_marker) do
            callback(options, :create_issue, &IssueClient.create_issue/5).(
              token,
              sync.remote_owner,
              sync.remote_repository,
              create_attrs,
              request_options(sync)
            )
          end

        "update_remote_issue" ->
          callback(options, :update_issue, &IssueClient.update_issue/6).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            sync.github_number,
            attrs,
            request_options(sync)
          )

        "create_remote_comment" ->
          with {:ok, create_attrs} <- append_correlation(attrs, marked.external_effect_marker) do
            callback(options, :create_comment, &IssueClient.create_comment/6).(
              token,
              sync.remote_owner,
              sync.remote_repository,
              sync.github_number,
              create_attrs,
              request_options(sync)
            )
          end

        "update_remote_comment" ->
          callback(options, :update_comment, &IssueClient.update_comment/6).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            sync.github_object_id,
            attrs,
            request_options(sync)
          )

        "delete_remote_comment" ->
          callback(options, :delete_comment, &IssueClient.delete_comment/5).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            sync.github_object_id,
            request_options(sync)
          )
      end

    case {target, result} do
      {:deleted, :ok} ->
        {:ok, :deleted}

      {_snapshot, {:ok, raw}} ->
        correlation_id = marked.external_effect_marker["correlation_id"]

        case decode_remote({:ok, raw}, sync, now, correlation_id, options) do
          {:ok, observation} ->
            with {:ok, actual} <- observation_fingerprint(observation, options),
                 true <- actual == marked.external_effect_marker["proposed_fingerprint"] do
              {:ok, observation}
            else
              _invalid -> {:effect_error, marked, :invalid_remote_resource}
            end

          {:error, reason} ->
            {:effect_error, marked, reason}
        end

      {_target, {:error, reason}} ->
        {:effect_error, marked, reason}

      _invalid ->
        {:effect_error, marked, :invalid_remote_resource}
    end
  rescue
    _exception -> {:effect_error, marked, :worker_crash}
  end

  defp append_correlation(attrs, marker) do
    case CorrelationMarker.append(attrs["body"], marker["correlation_id"]) do
      {:ok, body} -> {:ok, Map.put(attrs, "body", body)}
      {:error, _reason} -> {:error, :invalid_projection}
    end
  end

  defp confirm_observation(
         operation,
         now,
         sync,
         local,
         remote,
         apply_local?,
         options,
         catalogs \\ nil
       ) do
    target = if remote == :deleted, do: :deleted, else: remote.snapshot
    catalogs = catalogs || merged_catalogs(local, remote)

    with {:ok, domain_request} <-
           domain_request(sync, operation, local, remote, target, apply_local?, catalogs),
         {:ok, confirmation} <-
           confirmation(sync, local, remote, target, domain_request.action),
         expected <- confirmation_expected(sync, operation, local, remote) do
      callback(options, :confirm, &default_confirm/5).(
        operation,
        now,
        expected,
        confirmation,
        domain_request
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp domain_request(sync, operation, local, remote, target, apply_local?, catalogs) do
    provenance = %{
      origin: :github,
      causation_id:
        sync.provenance.delivery_guid || sync.provenance.outbox_event_id ||
          "mirror-operation:#{operation.id}",
      correlation_id:
        (operation.external_effect_marker && operation.external_effect_marker["correlation_id"]) ||
          sync.provenance.correlation_id || "mirror-operation:#{operation.id}"
    }

    cond do
      apply_local? and target == :deleted and sync.resource_kind == :issue_comment and
          present?(local) ->
        {:ok,
         %{
           action: :delete,
           repository_id: sync.repository_id,
           resource_kind: :issue_comment,
           local_resource_id: local.local_resource_id,
           expected_local_version: local.local_version,
           fields: %{},
           provenance: provenance
         }}

      apply_local? and local in [:missing, :deleted] and present?(remote) ->
        with {:ok, relationships} <- domain_relationships(sync.resource_kind, remote, catalogs) do
          {:ok,
           %{
             action: :create,
             repository_id: sync.repository_id,
             resource_kind: sync.resource_kind,
             local_resource_id: nil,
             expected_local_version: :missing,
             fields: mutable_fields(sync.resource_kind, remote.snapshot),
             local_label_ids: relationships.local_label_ids,
             assignee_refs: relationships.assignee_refs,
             github_number: remote.github_number,
             parent_issue_id: sync.parent_issue_id,
             author_github_identity_id: get_in(remote, [:author, :github_identity_id]),
             inserted_at: remote.remote_created_at,
             updated_at: remote.remote_updated_at,
             provenance: provenance
           }}
        end

      apply_local? and present?(local) and present?(remote) ->
        with {:ok, relationships} <- domain_relationships(sync.resource_kind, remote, catalogs) do
          {:ok,
           %{
             action: :update,
             repository_id: sync.repository_id,
             resource_kind: sync.resource_kind,
             local_resource_id: local.local_resource_id,
             expected_local_version: local.local_version,
             fields: mutable_fields(sync.resource_kind, remote.snapshot),
             local_label_ids: relationships.local_label_ids,
             assignee_refs: relationships.assignee_refs,
             provenance: provenance
           }}
        end

      present?(local) ->
        minimum? = operation.state == :effect_pending

        request = %{
          action: :observe,
          repository_id: sync.repository_id,
          resource_kind: sync.resource_kind,
          local_resource_id: local.local_resource_id
        }

        if minimum?,
          do: {:ok, Map.put(request, :minimum_local_version, effect_local_version(operation))},
          else: {:ok, Map.put(request, :expected_local_version, local.local_version)}

      target == :deleted ->
        with {:ok, projection} <- deleted_projection(sync, local) do
          {:ok,
           %{
             action: :none,
             repository_id: sync.repository_id,
             resource_kind: sync.resource_kind,
             projection: projection
           }}
        end

      true ->
        {:error, :invalid_projection}
    end
  end

  defp domain_relationships(:issue, remote, catalogs) do
    IssueSyncProjection.local_relationships(
      remote.snapshot,
      catalogs.labels,
      catalogs.assignees
    )
  end

  defp domain_relationships(:issue_comment, _remote, _catalogs),
    do: {:ok, %{local_label_ids: [], assignee_refs: []}}

  defp default_confirm(operation, now, expected, confirmation, domain_request) do
    domain_multi = fn multi ->
      case domain_request.action do
        action when action in [:create, :update, :delete] ->
          ForgeIssues.Sync.append_sync_apply(multi, :resource, domain_request)

        :observe ->
          ForgeIssues.Sync.append_sync_observe(multi, :resource, domain_request)

        :none ->
          Ecto.Multi.run(multi, :resource, fn _repo, _changes ->
            {:ok, domain_request.projection}
          end)
      end
    end

    ForgeMirrors.confirm_resource_operation(
      operation,
      now,
      expected,
      confirmation,
      domain_multi
    )
  end

  defp confirmation(sync, local, :deleted, :deleted, action) do
    {:ok,
     %{
       github_object_id: sync.github_object_id,
       github_node_id: sync.github_node_id,
       github_number: sync.github_number,
       remote_updated_at: sync.confirmed_remote_updated_at,
       confirmed_local_version: confirmed_local_version(sync, local, action),
       confirmed_snapshot: %{},
       state: :deleted
     }}
  end

  defp confirmation(sync, local, remote, snapshot, action) when is_map(remote) do
    {:ok,
     %{
       github_object_id: remote.github_object_id,
       github_node_id: remote.github_node_id,
       github_number: remote.github_number,
       remote_updated_at: remote.remote_updated_at,
       confirmed_local_version: confirmed_local_version(sync, local, action),
       confirmed_snapshot: snapshot,
       state: :confirmed
     }}
  end

  defp confirmation(_sync, _local, _remote, _snapshot, _action),
    do: {:error, :invalid_projection}

  defp confirmed_local_version(_sync, _local, :create), do: 1

  defp confirmed_local_version(_sync, %{local_version: version}, action)
       when action in [:update, :delete],
       do: version + 1

  defp confirmed_local_version(_sync, %{local_version: version}, :observe), do: version
  defp confirmed_local_version(%{local_version: version}, :deleted, :none), do: version
  defp confirmed_local_version(_sync, _local, _action), do: nil

  defp effect_local_version(%MirrorOperation{external_effect_marker: marker}) when is_map(marker),
    do: marker["expected_local_version"]

  defp effect_local_version(_operation), do: nil

  defp confirmation_expected(sync, operation, local, remote) do
    {local_id, local_version} = local_confirmation_identity(sync, local)

    %{
      resource_state_lock_version: sync.resource_state_lock_version || :missing,
      local_resource_id: local_id,
      expected_local_version: local_version,
      github_object_id:
        if(present?(remote), do: remote.github_object_id, else: sync.github_object_id),
      observed_remote_updated_at:
        if(present?(remote), do: remote.remote_updated_at, else: sync.confirmed_remote_updated_at),
      effect_marker: if(operation.state == :effect_pending, do: operation.external_effect_marker)
    }
  end

  defp recover_create(operation, now, sync, token, local, options) do
    marker = sync.effect_marker

    with :ok <- validate_create_marker(marker, sync, local, options),
         {:ok, recovery} <- recovery_checkpoint(operation.checkpoint) do
      case recovery do
        %{complete: true, match: nil} ->
          retry_create_after_scan(operation, now, sync, token, local, options)

        %{complete: true, match: match} ->
          adopt_created_match(operation, now, sync, token, local, match, options)

        %{page: page, match: match} ->
          scan_create_page(operation, now, sync, token, local, page, match, options)
      end
    else
      _invalid ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)
    end
  end

  defp scan_create_page(operation, now, sync, token, local, page, prior_match, options) do
    with {:ok, result} <- list_recovery_page(sync, token, page, options),
         {:ok, match} <- find_correlation_match(result, sync.effect_marker, prior_match) do
      checkpoint =
        if is_nil(result.next_cursor) do
          %{"recovery" => %{"complete" => true, "match" => match}}
        else
          %{"recovery" => %{"page" => result.next_cursor, "match" => match}}
        end

      checkpoint_operation(operation, checkpoint, now, nil, now, options)
    else
      {:error, :multiple_correlation_matches} ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options, preserve_effect?: true)
    end
  end

  defp list_recovery_page(%{resource_kind: :issue} = sync, token, page, options) do
    callback(options, :list_issues, &IssueClient.list_updated_issues_page/6).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      @full_scan_since,
      page,
      request_options(sync)
    )
  end

  defp list_recovery_page(%{resource_kind: :issue_comment} = sync, token, page, options) do
    callback(options, :list_comments, &IssueClient.list_updated_comments_page/6).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      @full_scan_since,
      page,
      request_options(sync)
    )
  end

  defp find_correlation_match(result, marker, prior_match) do
    resources = Map.get(result, :issues) || Map.get(result, :comments)

    matches =
      resources
      |> Enum.filter(&CorrelationMarker.matches?(&1["body"], marker["correlation_id"]))
      |> Enum.map(&match_identity/1)
      |> then(fn matches -> if prior_match, do: [prior_match | matches], else: matches end)
      |> Enum.uniq_by(& &1["github_object_id"])

    case matches do
      [] -> {:ok, nil}
      [match] -> {:ok, match}
      _many -> {:error, :multiple_correlation_matches}
    end
  rescue
    _invalid -> {:error, :invalid_remote_resource}
  end

  defp match_identity(raw) do
    %{
      "github_object_id" => raw["id"],
      "github_number" => raw["number"] || raw["issue_number"],
      "remote_updated_at" => raw["updated_at"]
    }
  end

  defp retry_create_after_scan(operation, now, sync, token, local, options) do
    with {:ok, current_fingerprint} <- observation_fingerprint(local, options),
         {:ok, prepared} <-
           maybe_replace_create_marker(operation, now, current_fingerprint, options),
         {:ok, attrs} <-
           target_remote_attrs(sync, local.snapshot, merged_catalogs(local, :missing)),
         {:ok, postcondition} <-
           execute_remote_effect(prepared, sync, token, attrs, local.snapshot, now, options) do
      confirm_observation(prepared, now, sync, local, postcondition, false, options)
    else
      {:effect_error, marked, reason} -> schedule_effect_recovery(marked, now, reason, options)
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp maybe_replace_create_marker(operation, now, fingerprint, options) do
    if operation.external_effect_marker["proposed_fingerprint"] == fingerprint do
      {:ok, operation}
    else
      replacement =
        operation.external_effect_marker
        |> Map.put("expected_local_fingerprint", fingerprint)
        |> Map.put("proposed_fingerprint", fingerprint)

      callback(options, :replace_effect, &ForgeMirrors.replace_external_effect/4).(
        operation,
        now,
        operation.external_effect_marker,
        replacement
      )
    end
  end

  defp adopt_created_match(operation, now, sync, token, local, match, options) do
    recovery_sync = %{
      sync
      | github_object_id: match["github_object_id"],
        github_number: match["github_number"]
    }

    result =
      case sync.resource_kind do
        :issue ->
          callback(options, :get_issue, &IssueClient.get_issue/5).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            match["github_number"],
            request_options(sync)
          )

        :issue_comment ->
          callback(options, :get_comment, &IssueClient.get_comment/5).(
            token,
            sync.remote_owner,
            sync.remote_repository,
            match["github_object_id"],
            request_options(sync)
          )
      end

    with {:ok, remote} <-
           decode_remote(
             result,
             recovery_sync,
             now,
             sync.effect_marker["correlation_id"],
             options
           ),
         {:ok, fingerprint} <- observation_fingerprint(remote, options),
         true <- fingerprint == sync.effect_marker["proposed_fingerprint"] do
      decide_and_apply(operation, now, recovery_sync, token, local, remote, options)
    else
      _invalid ->
        conflict(operation, now, sync, :ambiguous_external_effect, local, :missing, options)
    end
  end

  defp recovery_checkpoint(checkpoint) when checkpoint == %{} do
    {:ok, %{page: nil, match: nil}}
  end

  defp recovery_checkpoint(%{"recovery" => %{"page" => page, "match" => match}})
       when is_integer(page) and page > 0 and (is_nil(match) or is_map(match)),
       do: {:ok, %{page: page, match: match}}

  defp recovery_checkpoint(%{"recovery" => %{"complete" => true, "match" => match}})
       when is_nil(match) or is_map(match),
       do: {:ok, %{complete: true, match: match}}

  defp recovery_checkpoint(_checkpoint), do: {:error, :invalid_checkpoint}

  defp validate_create_marker(marker, sync, local, options) do
    with {:ok, local_id, local_version, local_fingerprint} <-
           local_effect_state(sync, local, options),
         true <- is_map(marker),
         true <- marker["v"] == 1,
         true <- marker["action"] == create_action(sync.resource_kind),
         true <- marker["resource_kind"] == Atom.to_string(sync.resource_kind),
         true <- marker["local_resource_id"] == local_id,
         true <- is_integer(marker["expected_local_version"]),
         true <- local_version >= marker["expected_local_version"],
         true <- valid_fingerprint?(marker["expected_local_fingerprint"]),
         true <- valid_fingerprint?(marker["proposed_fingerprint"]),
         true <-
           local_version != marker["expected_local_version"] or
             local_fingerprint == marker["expected_local_fingerprint"],
         true <- match?({:ok, _}, Ecto.UUID.cast(marker["correlation_id"])),
         true <- marker["recovery_since"] == DateTime.to_iso8601(@full_scan_since) do
      :ok
    else
      _invalid -> {:error, :ambiguous_external_effect}
    end
  end

  defp create_action(:issue), do: "create_remote_issue"
  defp create_action(:issue_comment), do: "create_remote_comment"

  defp create_effect?(%MirrorOperation{state: :effect_pending}, %{effect_marker: marker})
       when is_map(marker),
       do: marker["action"] in ["create_remote_issue", "create_remote_comment"]

  defp create_effect?(_operation, _sync), do: false

  defp validate_effect_marker(marker, sync, local, options) do
    with {:ok, local_id, local_version, local_fingerprint} <-
           local_effect_state(sync, local, options),
         true <- is_map(marker) and marker["v"] == 1,
         true <- marker["resource_kind"] == Atom.to_string(sync.resource_kind),
         true <- marker["local_resource_id"] == local_id,
         true <- is_integer(marker["expected_local_version"]),
         true <- local_version >= marker["expected_local_version"],
         true <- marker["github_object_id"] == sync.github_object_id,
         true <- marker["action"] in effect_actions(sync.resource_kind),
         true <- valid_optional_fingerprint?(marker["expected_remote_fingerprint"]),
         true <- valid_optional_fingerprint?(marker["proposed_fingerprint"]),
         true <- valid_optional_fingerprint?(marker["expected_local_fingerprint"]),
         true <-
           local_version != marker["expected_local_version"] or
             local_fingerprint == marker["expected_local_fingerprint"] do
      :ok
    else
      _invalid -> {:error, :ambiguous_external_effect}
    end
  end

  defp effect_actions(:issue), do: ["update_remote_issue"]

  defp effect_actions(:issue_comment),
    do: ["update_remote_comment", "delete_remote_comment"]

  defp fetch_reconciliation_page(%{phase: :mapped} = sync, _token, options) do
    callback(options, :resource_inventory, &ForgeMirrors.ResourceInventory.page/4).(
      sync.repository_mirror_id,
      sync.resource_kind,
      sync.mapping_cursor,
      100
    )
  end

  defp fetch_reconciliation_page(%{phase: :remote, resource_kind: :issue} = sync, token, options) do
    callback(options, :list_issues, &IssueClient.list_updated_issues_page/6).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      sync.since,
      sync.page,
      request_options(sync)
    )
  end

  defp fetch_reconciliation_page(
         %{phase: :remote, resource_kind: :issue_comment} = sync,
         token,
         options
       ) do
    callback(options, :list_comments, &IssueClient.list_updated_comments_page/6).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      sync.since,
      sync.page,
      request_options(sync)
    )
  end

  defp page_observations(:remote, :issue, %{issues: issues, next_cursor: next_cursor})
       when is_list(issues) and length(issues) <= 100 do
    observations =
      Enum.map(issues, fn issue ->
        %{
          github_object_id: issue["id"],
          github_number: issue["number"],
          github_issue_id: nil,
          remote_updated_at: parse_datetime!(issue["updated_at"])
        }
      end)

    {:ok, observations_with_cursor(observations, next_cursor)}
  rescue
    _invalid -> {:error, :invalid_remote_resource}
  end

  defp page_observations(
         :remote,
         :issue_comment,
         %{comments: comments, next_cursor: next_cursor}
       )
       when is_list(comments) and length(comments) <= 100 do
    observations =
      Enum.map(comments, fn comment ->
        %{
          github_object_id: comment["id"],
          github_number: comment["issue_number"],
          github_issue_id: nil,
          remote_updated_at: parse_datetime!(comment["updated_at"])
        }
      end)

    {:ok, observations_with_cursor(observations, next_cursor)}
  rescue
    _invalid -> {:error, :invalid_remote_resource}
  end

  defp page_observations(
         :mapped,
         kind,
         %{observations: observations, next_cursor: next_cursor}
       )
       when kind in [:issue, :issue_comment] and is_list(observations) and
              length(observations) <= 100 and (is_nil(next_cursor) or is_map(next_cursor)) do
    if Enum.all?(observations, &valid_inventory_observation?/1),
      do: {:ok, observations},
      else: {:error, :invalid_remote_resource}
  end

  defp page_observations(_phase, _kind, _page), do: {:error, :invalid_remote_resource}

  defp valid_inventory_observation?(observation) when is_map(observation) do
    Enum.sort(Map.keys(observation)) ==
      [:github_issue_id, :github_number, :github_object_id, :remote_updated_at] and
      is_integer(observation.github_object_id) and observation.github_object_id > 0 and
      is_integer(observation.github_number) and observation.github_number > 0 and
      (is_nil(observation.github_issue_id) or
         (is_integer(observation.github_issue_id) and observation.github_issue_id > 0)) and
      match?(%DateTime{utc_offset: 0, std_offset: 0}, observation.remote_updated_at)
  end

  defp valid_inventory_observation?(_observation), do: false

  defp observations_with_cursor(observations, _next_cursor), do: observations

  defp conflict(operation, now, sync, kind, local, remote, options) do
    baseline = if is_map(sync.baseline), do: sync.baseline, else: %{}
    local = snapshot_or_empty(local)
    remote = snapshot_or_empty(remote)

    callback(options, :conflict, &ForgeMirrors.conflict_resource_operation/6).(
      operation,
      now,
      Atom.to_string(kind),
      baseline,
      local,
      remote
    )
  end

  defp schedule_effect_recovery(operation, now, reason, options) do
    if effect_definitively_rejected?(reason) do
      persist_failure(operation, now, reason, options)
    else
      {failure_class, retry_at} = retry_schedule(reason, now)

      failure_class =
        if failure_class in ["network", "primary_rate_limit", "secondary_rate_limit"],
          do: failure_class,
          else: "network"

      checkpoint_operation(operation, %{}, retry_at, failure_class, now, options)
    end
  end

  defp effect_definitively_rejected?(%Error{kind: kind})
       when kind in [:invalid_credential, :forbidden, :not_found, :invalid_request],
       do: true

  defp effect_definitively_rejected?(reason)
       when reason in [:invalid_projection, :invalid_correlation_id],
       do: true

  defp effect_definitively_rejected?(_reason), do: false

  defp checkpoint_operation(operation, checkpoint, retry_at, failure_class, now, options) do
    callback(options, :checkpoint, &ForgeMirrors.checkpoint_resource_operation/5).(
      operation,
      checkpoint,
      retry_at,
      failure_class,
      now
    )
  end

  defp persist_failure(operation, now, reason, options, extra \\ []) do
    if Keyword.get(extra, :preserve_effect?, false) and operation.state == :effect_pending do
      schedule_effect_recovery(operation, now, reason, options)
    else
      case failure(reason) do
        {:retry, failure_class, retry_at} ->
          retry_at = retry_at || DateTime.add(now, 30, :second)

          callback(options, :retry, &ForgeMirrors.retry_operation/5).(
            operation,
            now,
            retry_at,
            failure_class,
            []
          )

        {:fail, failure_class, detail} ->
          callback(options, :fail, &ForgeMirrors.fail_operation/4).(
            operation,
            now,
            failure_class,
            detail
          )
      end
    end
  end

  defp failure(%Error{kind: kind, retry_at: retry_at})
       when kind in [:primary_rate_limit, :secondary_rate_limit],
       do: {:retry, Atom.to_string(kind), retry_at}

  defp failure(%Error{kind: kind})
       when kind in [
              :transport,
              :timeout,
              :upstream_unavailable,
              :host_unavailable,
              :request_gate_busy
            ],
       do: {:retry, "network", nil}

  defp failure(%Error{kind: :invalid_credential}),
    do: {:fail, "credential_revoked", "GitHub rejected the installation token"}

  defp failure(%Error{kind: :forbidden}),
    do: {:fail, "permission_missing", "GitHub denied issue synchronization"}

  defp failure(%Error{kind: :not_found}),
    do: {:fail, "provider_validation", "mapped GitHub resource was not found"}

  defp failure(%Error{}),
    do: {:fail, "provider_validation", "GitHub returned an invalid issue resource"}

  defp failure(reason) when reason in [:busy, :timeout, :unavailable, :invalidated],
    do: {:retry, "network", nil}

  defp failure(:revoked),
    do: {:fail, "credential_revoked", "installation token revoked"}

  defp failure(reason)
       when reason in [
              :invalid_scope,
              :not_configured,
              :credential_unavailable,
              :invalid_projection,
              :invalid_remote_resource,
              :invalid_checkpoint,
              :invalid_correlation_id
            ],
       do: {:fail, "local_validation", "issue synchronization state is invalid"}

  defp failure(:unsupported_resource),
    do: {:fail, "unsupported_resource", "GitHub resource cannot be represented locally"}

  defp failure(:worker_crash), do: {:retry, "network", nil}

  defp failure(:unsupported_operation),
    do: {:fail, "unsupported_resource", "unsupported operation"}

  defp failure(_reason), do: {:retry, "network", nil}

  defp retry_schedule(reason, now) do
    case failure(reason) do
      {:retry, failure_class, %DateTime{} = retry_at} ->
        if DateTime.after?(retry_at, now),
          do: {failure_class, retry_at},
          else: {failure_class, DateTime.add(now, 30, :second)}

      {:retry, failure_class, _retry_at} ->
        {failure_class, DateTime.add(now, 30, :second)}

      {:fail, failure_class, _detail} ->
        {failure_class, DateTime.add(now, 30, :second)}
    end
  end

  defp validate_remote_identity(raw, sync) do
    cond do
      not is_map(raw) -> :error
      sync.github_object_id && raw["id"] != sync.github_object_id -> :error
      sync.github_number && (raw["number"] || raw["issue_number"]) != sync.github_number -> :error
      true -> :ok
    end
  end

  defp request_options(sync),
    do: [gate_key: {:github_installation, sync.github_installation_id}]

  defp mutable_fields(:issue, snapshot), do: Map.take(snapshot, @scalar_fields)
  defp mutable_fields(:issue_comment, snapshot), do: Map.take(snapshot, ["body"])

  defp merged_catalogs(left, right) do
    %{
      labels: Map.merge(catalog(left, :label_catalog), catalog(right, :label_catalog)),
      assignees: Map.merge(catalog(left, :assignee_catalog), catalog(right, :assignee_catalog))
    }
  end

  defp catalog(observation, key) when is_map(observation), do: Map.get(observation, key, %{})
  defp catalog(_observation, _key), do: %{}

  defp observation_fingerprint(:missing, _options), do: {:ok, nil}
  defp observation_fingerprint(:deleted, _options), do: {:ok, nil}
  defp observation_fingerprint(%{snapshot: snapshot}, options), do: fingerprint(snapshot, options)
  defp observation_fingerprint(_observation, _options), do: {:error, :invalid_projection}

  defp fingerprint(snapshot, options) do
    case callback(options, :fingerprint, &ForgeMirrors.resource_fingerprint/1).(snapshot) do
      {:ok, fingerprint} when is_binary(fingerprint) -> {:ok, fingerprint}
      fingerprint when is_binary(fingerprint) -> {:ok, fingerprint}
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp target_fingerprint(:deleted, _options), do: {:ok, nil}
  defp target_fingerprint(snapshot, options), do: fingerprint(snapshot, options)

  defp valid_fingerprint?(value) when is_binary(value),
    do: byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/

  defp valid_fingerprint?(_value), do: false
  defp valid_optional_fingerprint?(nil), do: true
  defp valid_optional_fingerprint?(value), do: valid_fingerprint?(value)

  defp local_effect_state(
         _sync,
         %{local_resource_id: id, local_version: version} = local,
         options
       )
       when is_integer(id) and id > 0 and is_integer(version) and version > 0 do
    with {:ok, fingerprint} <- observation_fingerprint(local, options) do
      {:ok, id, version, fingerprint}
    end
  end

  defp local_effect_state(
         %{local_resource_id: id, local_version: version},
         :deleted,
         _options
       )
       when is_integer(id) and id > 0 and is_integer(version) and version > 0,
       do: {:ok, id, version, nil}

  defp local_effect_state(_sync, _local, _options), do: {:error, :invalid_projection}

  defp local_confirmation_identity(_sync, %{local_resource_id: id, local_version: version}),
    do: {id, version}

  defp local_confirmation_identity(%{local_resource_id: id, local_version: version}, :deleted),
    do: {id, version}

  defp local_confirmation_identity(_sync, _local), do: {nil, :missing}

  defp deleted_projection(
         %{repository_id: repository_id, resource_kind: :issue_comment} = sync,
         :deleted
       )
       when is_integer(repository_id) and repository_id > 0 do
    with id when is_integer(id) and id > 0 <- sync.local_resource_id,
         version when is_integer(version) and version > 0 <- sync.local_version do
      {:ok,
       %{
         repository_id: repository_id,
         resource_kind: :issue_comment,
         local_resource_id: id,
         local_resource_type: "ForgeIssues.Comment",
         local_version: version,
         deleted: true
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp deleted_projection(_sync, _local), do: {:error, :invalid_projection}

  defp observation_updated_at(%{remote_updated_at: updated_at}), do: iso8601(updated_at)
  defp observation_updated_at(_observation), do: nil

  defp snapshot_or_empty(%{snapshot: snapshot}) when is_map(snapshot), do: snapshot
  defp snapshot_or_empty(_observation), do: %{}

  defp present?(%{presence: :present, snapshot: snapshot}) when is_map(snapshot), do: true
  defp present?(_observation), do: false

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil

  defp parse_datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    DateTime.truncate(datetime, :second)
  end

  defp callback(options, key, default), do: Keyword.get(options, key, default)

  defp bounded_option(options, key, default, minimum, maximum) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value >= minimum and value <= maximum -> value
      _invalid -> raise ArgumentError, "invalid #{key}"
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp config(key, default), do: Application.get_env(:forge_github, key, default)
end
