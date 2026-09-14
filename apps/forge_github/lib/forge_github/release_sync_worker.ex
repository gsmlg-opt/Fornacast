defmodule ForgeGitHub.ReleaseSyncWorker do
  @moduledoc """
  Crash-recoverable GitHub release metadata synchronization.

  Mutable releases are read by immutable provider ID. Create recovery is the
  sole tag lookup, because GitHub makes release tags unique. Create and update
  effects are gated by a fresh, coordinator-owned tag proof.
  """

  use GenServer

  require Logger

  alias ForgeGitHub.{Error, InstallationToken, InstallationTokenBroker, ReleaseClient}
  alias ForgeGitHub.ReleaseSyncProjection
  alias ForgeMirrors.{MirrorOperation, ResourceDecision}

  @operation_kinds ["sync.release", "reconcile.repository.releases"]
  @fields ~w(tag_name name body draft prerelease target_commitish published_at)
  @default_interval_ms 1_000
  @default_lease_seconds 60
  @default_batch_size 2
  @default_max_concurrency 2
  @default_processor_timeout_ms 50_000
  @lease_margin_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc false
  def run_once(owner, options \\ [])

  def run_once(owner, options) when is_binary(owner) and is_list(options) do
    now = callback(options, :now, fn -> DateTime.utc_now(:second) end).()
    lease_seconds = bounded_option(options, :lease_seconds, @default_lease_seconds, 1, 3_600)
    batch_size = bounded_option(options, :batch_size, @default_batch_size, 1, 100)

    max_concurrency =
      bounded_option(
        options,
        :max_concurrency,
        config(:release_sync_worker_max_concurrency, @default_max_concurrency),
        1,
        8
      )

    timeout =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:release_sync_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_599_000
      )

    unless timeout <= lease_seconds * 1_000 - @lease_margin_ms do
      raise ArgumentError, "release sync processor timeout must finish inside its lease"
    end

    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, lease_seconds, min(batch_size, max_concurrency), @operation_kinds) do
      supervisor = Keyword.get(options, :task_supervisor, ForgeGitHub.ReleaseSyncTaskSupervisor)

      results =
        supervisor
        |> Task.Supervisor.async_stream_nolink(
          operations,
          &process_operation(&1, now, options),
          max_concurrency: max_concurrency,
          ordered: true,
          on_timeout: :kill_task,
          timeout: timeout
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
  def process_operation(
        %MirrorOperation{kind: "reconcile.repository.releases"} = operation,
        %DateTime{} = now,
        options
      ) do
    with {:ok, sync} <- context(operation, options),
         {:ok, token} <- installation_token(sync, options),
         {:ok, page} <- reconciliation_page(sync, token, options),
         {:ok, observations} <- page_observations(page) do
      callback(options, :record_page, &ForgeMirrors.record_resource_reconciliation_page/5).(
        operation,
        :release,
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

  def process_operation(
        %MirrorOperation{kind: "sync.release"} = operation,
        %DateTime{} = now,
        options
      ) do
    with {:ok, sync} <- context(operation, options),
         {:ok, authorized_operation} <- authorize_recovery(operation, options),
         {:ok, token} <- installation_token(sync, options),
         {:ok, local} <- local_observation(sync, options) do
      continue(authorized_operation, now, sync, token, local, options)
    else
      {:error, reason} -> handle_context_failure(operation, now, reason, options)
    end
  rescue
    _exception -> persist_failure(operation, now, :worker_crash, options)
  catch
    _kind, _reason -> persist_failure(operation, now, :worker_crash, options)
  end

  def process_operation(%MirrorOperation{} = operation, %DateTime{} = now, options),
    do: persist_failure(operation, now, :unsupported_operation, options)

  @impl true
  def init(options) do
    interval_ms = bounded_option(options, :interval_ms, @default_interval_ms, 10, 60_000)
    owner = Keyword.get(options, :owner, "release-sync-#{System.unique_integer([:positive])}")

    run_options =
      options
      |> Keyword.drop([:enabled, :interval_ms, :owner, :name, :runner])
      |> Keyword.put_new(:task_supervisor, ForgeGitHub.ReleaseSyncTaskSupervisor)

    state = %{
      enabled: Keyword.get(options, :enabled, false),
      interval_ms: interval_ms,
      owner: owner,
      task_supervisor:
        Keyword.get(options, :task_supervisor, ForgeGitHub.ReleaseSyncTaskSupervisor),
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

  defp continue(operation, now, sync, token, local, options) do
    cond do
      operation.state == :effect_pending ->
        recover_effect(operation, now, sync, token, local, options)

      sync.tag_proof == :required and canonical_observation_required?(operation, sync) ->
        record_canonical(operation, now, sync, token, options)

      sync.tag_proof == :required ->
        prepare_tag_proof(operation, now, sync, options)

      is_map(sync.tag_proof) or sync.tag_proof == :not_required ->
        with {:ok, remote} <- remote_observation(operation, sync, token, now, options) do
          decide_and_apply(operation, now, sync, token, local, remote, options)
        else
          {:error, reason} -> persist_failure(operation, now, reason, options)
        end

      true ->
        persist_failure(operation, now, :invalid_tag_proof, options)
    end
  end

  defp canonical_observation_required?(operation, %{trigger: trigger, github_object_id: id}) do
    trigger in [:remote, :reconcile] and is_integer(id) and id > 0 and
      is_nil(operation.checkpoint["canonical_release"]) and
      is_nil(operation.checkpoint["canonical_release_deletion"])
  end

  defp record_canonical(operation, now, sync, token, options) do
    case fetch_remote_by_id(sync, token, options, now) do
      {:ok, remote} ->
        with :ok <- warn_assets(remote, options) do
          observation = %{
            github_object_id: remote.github_object_id,
            tag_name: remote.snapshot["tag_name"],
            remote_updated_at: remote.remote_updated_at
          }

          callback(
            options,
            :record_canonical,
            &ForgeMirrors.record_release_canonical_observation/3
          ).(operation, observation, now)
        else
          {:error, reason} -> persist_failure(operation, now, reason, options)
        end

      {:deleted, evidence} ->
        callback(
          options,
          :record_canonical_deletion,
          &ForgeMirrors.record_release_canonical_deletion/3
        ).(operation, evidence, now)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp prepare_tag_proof(operation, now, sync, options) do
    case callback(options, :prepare_tag_proof, &ForgeMirrors.prepare_release_tag_proof/3).(
           operation,
           sync.tag_name,
           now
         ) do
      {:error, reason} when reason in [:release_tag_missing, :tag_retarget] ->
        conflict(operation, now, Atom.to_string(reason), options)

      result ->
        result
    end
  end

  defp recover_effect(operation, now, sync, token, local, options) do
    marker = operation.external_effect_marker

    with :ok <- validate_effect_marker(marker, sync, local, options),
         {:ok, recovery} <- effect_recovery(marker, sync, token, now, options) do
      case recovery do
        {:applied, remote} ->
          confirm_observation(operation, now, sync, local, remote, false, options)

        {:not_applied, remote} ->
          decide_and_apply(operation, now, sync, token, local, remote, options)

        :ambiguous ->
          conflict(operation, now, "ambiguous_external_effect", options)
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp effect_recovery(%{"action" => "create_remote_release"} = marker, sync, token, now, opts) do
    case callback(opts, :get_release_by_tag, &ReleaseClient.get_release_by_tag/5).(
           token,
           sync.remote_owner,
           sync.remote_repository,
           sync.tag_name,
           request_options(sync)
         ) do
      {:ok, raw} ->
        with {:ok, remote} <- decode_remote(raw, sync, now, opts),
             {:ok, fingerprint} <- observation_fingerprint(remote, opts) do
          if fingerprint == marker["proposed_fingerprint"],
            do: {:ok, {:applied, remote}},
            else: {:ok, :ambiguous}
        end

      {:error, %Error{kind: :not_found}} ->
        {:ok, {:not_applied, :missing}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_remote_resource}
    end
  end

  defp effect_recovery(marker, sync, token, now, opts) do
    with {:ok, remote} <- remote_observation(nil, sync, token, now, opts),
         {:ok, fingerprint} <- observation_fingerprint(remote, opts) do
      cond do
        marker["action"] == "delete_remote_release" and remote == :deleted ->
          {:ok, {:applied, remote}}

        present?(remote) and fingerprint == marker["proposed_fingerprint"] ->
          {:ok, {:applied, remote}}

        fingerprint == marker["expected_remote_fingerprint"] and
            observation_updated_at(remote) == marker["expected_remote_updated_at"] ->
          {:ok, {:not_applied, remote}}

        true ->
          {:ok, :ambiguous}
      end
    end
  end

  defp decide_and_apply(operation, now, sync, token, local, remote, options) do
    with {:ok, baseline} <- decision_baseline(sync.baseline) do
      case release_decision(baseline, local, remote) do
        {:ok, decision} ->
          apply_decision(operation, now, sync, token, local, remote, decision, options)

        {:conflict, kind} ->
          conflict(operation, now, Atom.to_string(kind), options)
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp decision_baseline(:missing), do: {:ok, :missing}

  defp decision_baseline(%{"published_at" => nil} = baseline), do: {:ok, baseline}

  defp decision_baseline(%{"published_at" => %DateTime{} = published_at} = baseline),
    do: {:ok, Map.put(baseline, "published_at", DateTime.truncate(published_at, :second))}

  defp decision_baseline(%{"published_at" => published_at} = baseline)
       when is_binary(published_at) do
    case DateTime.from_iso8601(published_at) do
      {:ok, parsed, 0} ->
        {:ok, Map.put(baseline, "published_at", DateTime.truncate(parsed, :second))}

      _invalid ->
        {:error, :invalid_projection}
    end
  end

  defp decision_baseline(_baseline), do: {:error, :invalid_projection}

  defp release_decision(_baseline, :missing, :missing),
    do: {:ok, %{target: :deleted, local?: false, remote?: false}}

  defp release_decision(_baseline, :deleted, :deleted),
    do: {:ok, %{target: :deleted, local?: false, remote?: false}}

  defp release_decision(_baseline, local, :missing) when is_map(local),
    do: {:ok, %{target: local.snapshot, local?: false, remote?: true}}

  defp release_decision(baseline, local, :deleted)
       when is_map(baseline) and is_map(local) do
    if local.snapshot == baseline,
      do: {:ok, %{target: :deleted, local?: true, remote?: false}},
      else: {:conflict, :concurrent_edit}
  end

  defp release_decision(_baseline, :missing, remote) when is_map(remote),
    do: {:ok, %{target: remote.snapshot, local?: true, remote?: false}}

  defp release_decision(baseline, :deleted, remote)
       when is_map(baseline) and is_map(remote) do
    if remote.snapshot == baseline,
      do: {:ok, %{target: :deleted, local?: false, remote?: true}},
      else: {:conflict, :concurrent_edit}
  end

  defp release_decision(:missing, local, remote) when is_map(local) and is_map(remote) do
    if local.snapshot == remote.snapshot,
      do: {:ok, %{target: local.snapshot, local?: false, remote?: false}},
      else: {:conflict, :missing_baseline}
  end

  defp release_decision(baseline, local, remote)
       when is_map(baseline) and is_map(local) and is_map(remote) do
    Enum.reduce_while(@fields, {:ok, %{}, false, false}, fn field,
                                                            {:ok, target, local?, remote?} ->
      case ResourceDecision.scalar(baseline[field], local.snapshot[field], remote.snapshot[field]) do
        {:confirm, value} ->
          {:cont, {:ok, Map.put(target, field, value), local?, remote?}}

        {:apply_local, _expected, value} ->
          {:cont, {:ok, Map.put(target, field, value), true, remote?}}

        {:apply_remote, _expected, value} ->
          {:cont, {:ok, Map.put(target, field, value), local?, true}}

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
  end

  defp release_decision(_baseline, _local, _remote), do: {:conflict, :missing_baseline}

  defp apply_decision(operation, now, sync, token, local, remote, decision, options) do
    if decision.remote? do
      with {:ok, marked} <-
             mark_effect(operation, now, sync, local, remote, decision.target, options) do
        execute_marked_effect(marked, now, sync, token, local, remote, options)
      else
        {:error, reason} -> persist_failure(operation, now, reason, options)
      end
    else
      confirm_observation(
        operation,
        now,
        sync,
        local,
        target_observation(remote, decision.target),
        decision.local?,
        options
      )
    end
  end

  defp mark_effect(operation, now, sync, local, remote, target, options) do
    with {:ok, marker} <- effect_marker(sync, local, remote, target, options) do
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

  defp effect_marker(sync, local, remote, target, options) do
    with {:ok, local_fingerprint} <- observation_fingerprint(local, options),
         {:ok, remote_fingerprint} <- observation_fingerprint(remote, options),
         {:ok, proposed_fingerprint} <- target_fingerprint(target, options),
         true <- present?(local) or local == :deleted do
      marker = %{
        "v" => 1,
        "action" => effect_action(remote, target),
        "resource_kind" => "release",
        "local_resource_id" => sync.local_resource_id,
        "expected_local_version" => sync.local_version,
        "expected_local_fingerprint" => local_fingerprint,
        "expected_remote_updated_at" => observation_updated_at(remote),
        "expected_remote_fingerprint" => remote_fingerprint,
        "proposed_fingerprint" => proposed_fingerprint,
        "tag_proof" => sync.tag_proof
      }

      {:ok, Map.put(marker, "github_object_id", remote_identity(sync, remote))}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp effect_action(:missing, _target), do: "create_remote_release"
  defp effect_action(_remote, :deleted), do: "delete_remote_release"
  defp effect_action(_remote, _target), do: "update_remote_release"

  defp execute_marked_effect(operation, now, sync, _token, local, _remote, options) do
    marker = operation.external_effect_marker

    with {:ok, token} <- authorize_effect_token(operation, sync, options),
         {:ok, attrs} <- target_attrs(marker, local),
         {:ok, postcondition} <- execute_effect(marker, sync, token, attrs, now, options) do
      apply_local? = local_needs_provider_canonical?(local, postcondition)
      confirm_observation(operation, now, sync, local, postcondition, apply_local?, options)
    else
      {:error, reason} -> schedule_effect_recovery(operation, now, reason, options)
    end
  rescue
    _exception -> schedule_effect_recovery(operation, now, :worker_crash, options)
  end

  defp authorize_effect_token(
         %MirrorOperation{external_effect_marker: marker} = operation,
         sync,
         options
       )
       when is_map(marker) do
    with {:ok, _authorized} <-
           callback(options, :authorize_effect, &ForgeMirrors.authorize_external_effect/2).(
             operation,
             marker
           ),
         {:ok, token} <- installation_token(sync, options) do
      {:ok, token}
    end
  end

  defp authorize_effect_token(_operation, _sync, _options), do: {:error, :invalid_transition}

  defp authorize_recovery(%MirrorOperation{state: :effect_pending} = operation, options) do
    callback(options, :authorize_effect, &ForgeMirrors.authorize_external_effect/2).(
      operation,
      operation.external_effect_marker
    )
  end

  defp authorize_recovery(%MirrorOperation{state: :processing} = operation, _options),
    do: {:ok, operation}

  defp authorize_recovery(%MirrorOperation{}, _options), do: {:error, :invalid_transition}

  defp target_attrs(%{"action" => "delete_remote_release"}, _local), do: {:ok, %{}}

  defp target_attrs(_marker, %{snapshot: snapshot}),
    do: ReleaseSyncProjection.remote_attrs(snapshot)

  defp target_attrs(_marker, _local), do: {:error, :invalid_projection}

  defp execute_effect(%{"action" => "create_remote_release"}, sync, token, attrs, now, opts) do
    callback(opts, :create_release, &ReleaseClient.create_release/5).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      attrs,
      request_options(sync)
    )
    |> decode_effect_result(sync, now, opts)
  end

  defp execute_effect(
         %{"action" => "update_remote_release", "github_object_id" => id},
         sync,
         token,
         attrs,
         now,
         opts
       )
       when is_integer(id) and id > 0 do
    callback(opts, :update_release, &ReleaseClient.update_release/6).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      id,
      attrs,
      request_options(sync)
    )
    |> decode_effect_result(sync, now, opts)
  end

  defp execute_effect(
         %{"action" => "delete_remote_release", "github_object_id" => id},
         sync,
         token,
         _attrs,
         _now,
         opts
       )
       when is_integer(id) and id > 0 do
    case callback(opts, :delete_release, &ReleaseClient.delete_release/5).(
           token,
           sync.remote_owner,
           sync.remote_repository,
           id,
           request_options(sync)
         ) do
      :ok -> {:ok, :deleted}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp execute_effect(_marker, _sync, _token, _attrs, _now, _opts),
    do: {:error, :invalid_effect_marker}

  defp decode_effect_result({:ok, raw}, sync, now, options),
    do: decode_remote(raw, sync, now, options)

  defp decode_effect_result({:error, reason}, _sync, _now, _options), do: {:error, reason}

  defp decode_effect_result(_result, _sync, _now, _options),
    do: {:error, :invalid_remote_resource}

  defp confirm_observation(operation, now, sync, local, remote, apply_local?, options) do
    with {:ok, request} <- domain_request(operation, sync, local, remote, apply_local?),
         {:ok, confirmation} <- confirmation(operation, now, sync, local, remote, request),
         expected <- confirmation_expected(operation, sync, local) do
      callback(options, :confirm, &default_confirm/5).(
        operation,
        now,
        expected,
        confirmation,
        request
      )
      |> case do
        {:error, reason} -> persist_failure(operation, now, reason, options)
        result -> result
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp domain_request(operation, sync, local, remote, apply_local?) do
    provenance = %{
      origin: :github,
      causation_id:
        sync.provenance.delivery_guid || sync.provenance.outbox_event_id ||
          "mirror-operation:#{operation.id}",
      correlation_id: sync.provenance.correlation_id || "mirror-operation:#{operation.id}"
    }

    cond do
      apply_local? and remote == :deleted and present?(local) ->
        {:ok,
         %{
           action: :delete,
           repository_id: sync.repository_id,
           local_resource_id: local.local_resource_id,
           expected_local_version: local.local_version,
           expected_deleted: false,
           expected_fields: local.snapshot,
           fields: %{},
           updated_at: deletion_observed_at(operation, sync),
           provenance: provenance
         }}

      apply_local? and local in [:missing, :deleted] and present?(remote) ->
        {:ok,
         %{
           action: :create,
           repository_id: sync.repository_id,
           local_resource_id: nil,
           expected_local_version: :missing,
           expected_fields: %{},
           fields: remote.snapshot,
           tag_proof: sync.tag_proof,
           author_github_identity_id: remote.author_github_identity_id,
           inserted_at: remote.remote_created_at,
           updated_at: remote.remote_updated_at,
           provenance: provenance
         }}

      apply_local? and present?(local) and present?(remote) ->
        {:ok,
         %{
           action: :update,
           repository_id: sync.repository_id,
           local_resource_id: local.local_resource_id,
           expected_local_version: local.local_version,
           expected_deleted: false,
           expected_fields: local.snapshot,
           fields: remote.snapshot,
           tag_proof: sync.tag_proof,
           updated_at: remote.remote_updated_at,
           provenance: provenance
         }}

      present?(local) ->
        request = %{
          action: :observe,
          repository_id: sync.repository_id,
          local_resource_id: local.local_resource_id,
          expected_deleted: false,
          expected_fields: remote_snapshot(remote, local)
        }

        if operation.state == :effect_pending,
          do: {:ok, Map.put(request, :minimum_local_version, effect_local_version(operation))},
          else: {:ok, Map.put(request, :expected_local_version, local.local_version)}

      local == :deleted ->
        request = %{
          action: :observe,
          repository_id: sync.repository_id,
          local_resource_id: sync.local_resource_id,
          expected_deleted: true,
          expected_fields: sync.fields
        }

        if operation.state == :effect_pending,
          do: {:ok, Map.put(request, :minimum_local_version, effect_local_version(operation))},
          else: {:ok, Map.put(request, :expected_local_version, sync.local_version)}

      true ->
        {:error, :invalid_projection}
    end
  end

  defp confirmation(operation, now, sync, local, :deleted, request) do
    with true <- is_integer(sync.github_object_id) and sync.github_object_id > 0,
         true <- is_binary(sync.github_node_id),
         snapshot when is_map(snapshot) <- deleted_snapshot(local, sync),
         version when is_integer(version) and version > 0 <-
           confirmed_local_version(operation, local, request) do
      {:ok,
       %{
         github_object_id: sync.github_object_id,
         github_node_id: sync.github_node_id,
         remote_updated_at: deletion_observed_at(operation, sync, now),
         confirmed_local_version: version,
         confirmed_snapshot: snapshot,
         state: :deleted,
         tag_proof: :not_required
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp confirmation(operation, _now, sync, local, remote, request) when is_map(remote) do
    version = confirmed_local_version(operation, local, request)

    if is_integer(version) and version > 0 do
      {:ok,
       %{
         github_object_id: remote.github_object_id,
         github_node_id: remote.github_node_id,
         remote_updated_at: remote.remote_updated_at,
         confirmed_local_version: version,
         confirmed_snapshot: remote.snapshot,
         state: :confirmed,
         tag_proof: sync.tag_proof
       }}
    else
      {:error, :invalid_projection}
    end
  end

  defp confirmation(_operation, _now, _sync, _local, _remote, _request),
    do: {:error, :invalid_projection}

  defp confirmation_expected(operation, sync, local) do
    %{
      resource_state_lock_version: sync.resource_state_lock_version,
      effect_marker: operation.external_effect_marker,
      local_resource_id: local_identity(sync, local),
      local_version: local_version(sync, local),
      local_deleted: local == :deleted,
      tag_name: sync.tag_name,
      baseline: sync.baseline,
      github_object_id: sync.github_object_id,
      github_node_id: sync.github_node_id,
      tag_proof: sync.tag_proof
    }
  end

  defp default_confirm(operation, now, expected, confirmation, request) do
    domain_multi = fn multi ->
      case request.action do
        action when action in [:create, :update, :delete] ->
          ForgeReleases.append_sync_release_apply(multi, :resource, request)

        :observe ->
          ForgeReleases.append_sync_release_observe(
            multi,
            :resource,
            Map.delete(request, :action)
          )
      end
    end

    ForgeMirrors.confirm_release_operation(operation, now, expected, confirmation, domain_multi)
  end

  defp context(operation, options),
    do: callback(options, :context, &ForgeMirrors.release_operation_context/1).(operation)

  defp installation_token(sync, options) do
    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           %{permissions: %{"contents" => "write", "metadata" => "read"}}
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
           ForgeReleases.release_sync_projection(sync.repository_id, sync.local_resource_id),
         {:ok, local} <- ReleaseSyncProjection.from_local(projection) do
      {:ok, local}
    end
  end

  defp remote_observation(
         _operation,
         %{trigger: :local, github_object_id: nil},
         _token,
         _now,
         _options
       ),
       do: {:ok, :missing}

  defp remote_observation(_operation, sync, token, now, options) do
    case fetch_remote_by_id(sync, token, options, now) do
      {:ok, remote} -> decode_remote_observation(remote, sync, now, options)
      {:deleted, _evidence} -> {:ok, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_remote_by_id(%{github_object_id: nil}, _token, _options, _now),
    do: {:error, :missing_identity}

  defp fetch_remote_by_id(sync, token, options, now) do
    case callback(options, :get_release, &ReleaseClient.get_release/5).(
           token,
           sync.remote_owner,
           sync.remote_repository,
           sync.github_object_id,
           request_options(sync)
         ) do
      {:ok, raw} ->
        with {:ok, remote} <- ReleaseSyncProjection.from_remote(raw),
             true <- remote.github_object_id == sync.github_object_id,
             true <-
               is_nil(sync.github_node_id) or remote.github_node_id == sync.github_node_id do
          {:ok, remote}
        else
          _invalid -> {:error, :invalid_remote_resource}
        end

      {:error, %Error{kind: :not_found}} ->
        {:deleted, %{github_object_id: sync.github_object_id, observed_at: now}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_remote_resource}
    end
  end

  defp decode_remote_observation(remote, _sync, now, options) do
    with :ok <- warn_assets(remote, options),
         {:ok, identity} <-
           callback(options, :author_observe, &ForgeAccounts.observe_github_identity/2).(
             remote.raw_author,
             now
           ),
         id when is_integer(id) and id > 0 <- identity.id do
      {:ok, Map.put(remote, :author_github_identity_id, id)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp decode_remote(raw, sync, now, options) do
    with {:ok, remote} <- ReleaseSyncProjection.from_remote(raw),
         true <- is_nil(sync.github_object_id) or remote.github_object_id == sync.github_object_id do
      decode_remote_observation(remote, sync, now, options)
    else
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp reconciliation_page(%{phase: :mapped} = sync, _token, options) do
    callback(options, :resource_inventory, &ForgeMirrors.ResourceInventory.page/4).(
      sync.repository_mirror_id,
      :release,
      sync.mapping_cursor,
      100
    )
  end

  defp reconciliation_page(sync, token, options) do
    callback(options, :list_releases, &ReleaseClient.list_releases_page/5).(
      token,
      sync.remote_owner,
      sync.remote_repository,
      sync.page,
      request_options(sync)
    )
  end

  defp page_observations(%{observations: observations}) when is_list(observations),
    do: {:ok, observations}

  defp page_observations(%{releases: releases}) when is_list(releases) do
    observations =
      Enum.map(releases, fn raw ->
        {:ok, remote} = ReleaseSyncProjection.from_remote(raw)

        %{
          github_object_id: remote.github_object_id,
          tag_name: remote.snapshot["tag_name"],
          remote_updated_at: remote.remote_updated_at
        }
      end)

    {:ok, observations}
  rescue
    _exception -> {:error, :invalid_remote_resource}
  end

  defp page_observations(_page), do: {:error, :invalid_remote_resource}

  defp warn_assets(%{asset_count: count, github_object_id: id, snapshot: snapshot}, options)
       when is_integer(count) and count > 0 do
    warning = %{github_object_id: id, tag_name: snapshot["tag_name"], asset_count: count}

    case callback(options, :asset_warning, &default_asset_warning/1).(warning) do
      :ok -> :ok
      _invalid -> {:error, :asset_warning_unavailable}
    end
  end

  defp warn_assets(_remote, _options), do: :ok

  defp default_asset_warning(warning) do
    Logger.warning(
      "GitHub release assets excluded from synchronization",
      github_release_id: warning.github_object_id,
      tag_name: warning.tag_name,
      asset_count: warning.asset_count
    )
  end

  defp validate_effect_marker(marker, sync, local, options) when is_map(marker) do
    with {:ok, local_fingerprint} <- observation_fingerprint(local, options),
         true <- marker["v"] == 1,
         true <- marker["resource_kind"] == "release",
         true <- marker["local_resource_id"] == sync.local_resource_id,
         version when is_integer(version) and version > 0 <- marker["expected_local_version"],
         local_version when is_integer(local_version) and local_version >= version <-
           local_version(sync, local),
         true <-
           local_version != version or marker["expected_local_fingerprint"] == local_fingerprint,
         true <- marker["tag_proof"] == sync.tag_proof,
         true <-
           marker["action"] in [
             "create_remote_release",
             "update_remote_release",
             "delete_remote_release"
           ] do
      :ok
    else
      _invalid -> {:error, :ambiguous_external_effect}
    end
  end

  defp validate_effect_marker(_marker, _sync, _local, _options),
    do: {:error, :ambiguous_external_effect}

  defp observation_fingerprint(:missing, _options), do: {:ok, nil}
  defp observation_fingerprint(:deleted, _options), do: {:ok, nil}

  defp observation_fingerprint(%{snapshot: snapshot}, options),
    do: fingerprint(snapshot, options)

  defp observation_fingerprint(_observation, _options), do: {:error, :invalid_projection}

  defp target_fingerprint(:deleted, _options), do: {:ok, nil}
  defp target_fingerprint(snapshot, options), do: fingerprint(snapshot, options)

  defp fingerprint(snapshot, options) do
    canonical =
      Map.update(snapshot, "published_at", nil, fn
        %DateTime{} = value -> DateTime.to_iso8601(value)
        value -> value
      end)

    callback(options, :fingerprint, &ForgeMirrors.resource_fingerprint/1).(canonical)
  end

  defp target_observation(_remote, :deleted), do: :deleted
  defp target_observation(remote, _target), do: remote
  defp present?(%{presence: :present, snapshot: snapshot}) when is_map(snapshot), do: true
  defp present?(_value), do: false

  defp remote_identity(_sync, %{github_object_id: id}) when is_integer(id), do: id
  defp remote_identity(sync, _remote), do: sync.github_object_id

  defp observation_updated_at(%{remote_updated_at: %DateTime{} = value}),
    do: DateTime.to_iso8601(value)

  defp observation_updated_at(_remote), do: nil

  defp local_needs_provider_canonical?(local, remote) when is_map(local) and is_map(remote),
    do: local.snapshot != remote.snapshot

  defp local_needs_provider_canonical?(_local, _remote), do: false

  defp remote_snapshot(%{snapshot: snapshot}, _local), do: snapshot
  defp remote_snapshot(:deleted, %{snapshot: snapshot}), do: snapshot
  defp remote_snapshot(_remote, %{snapshot: snapshot}), do: snapshot

  defp deleted_snapshot(%{snapshot: snapshot}, _sync), do: snapshot
  defp deleted_snapshot(:deleted, %{fields: fields}), do: fields
  defp deleted_snapshot(_local, %{baseline: baseline}) when is_map(baseline), do: baseline
  defp deleted_snapshot(_local, _sync), do: nil

  defp local_identity(_sync, %{local_resource_id: id}), do: id
  defp local_identity(sync, :deleted), do: sync.local_resource_id
  defp local_identity(_sync, :missing), do: nil

  defp local_version(_sync, %{local_version: version}), do: version
  defp local_version(sync, :deleted), do: sync.local_version
  defp local_version(_sync, :missing), do: nil

  defp confirmed_local_version(operation, local, request) do
    case request.action do
      :create -> 1
      action when action in [:update, :delete] -> local.local_version + 1
      :observe when operation.state == :effect_pending -> effect_local_version(operation)
      :observe -> local_version(%{}, local)
    end
  end

  defp effect_local_version(operation),
    do: operation.external_effect_marker["expected_local_version"]

  defp deletion_observed_at(operation, sync, fallback \\ nil) do
    with %{"observed_at" => value} <- operation.checkpoint["canonical_release_deletion"],
         {:ok, observed_at, 0} <- DateTime.from_iso8601(value) do
      observed_at
    else
      _ -> sync.confirmed_remote_updated_at || fallback || DateTime.utc_now(:second)
    end
  end

  defp handle_context_failure(operation, now, reason, options)
       when reason in [:release_tag_missing, :tag_retarget],
       do: conflict(operation, now, Atom.to_string(reason), options)

  defp handle_context_failure(operation, now, reason, options),
    do: persist_failure(operation, now, reason, options)

  defp conflict(operation, now, kind, options) do
    callback(options, :conflict, &ForgeMirrors.conflict_resource_operation/6).(
      operation,
      now,
      kind,
      %{},
      %{},
      %{}
    )
  end

  defp schedule_effect_recovery(operation, now, reason, options),
    do: persist_failure(operation, now, reason, options)

  defp persist_failure(operation, now, reason, options) do
    cond do
      local_conflict?(reason) ->
        conflict(operation, now, conflict_kind(reason), options)

      operation.state == :effect_pending and provider_validation?(reason) ->
        conflict(operation, now, "provider_validation", options)

      operation.state == :effect_pending ->
        {failure_class, retry_at, code} = effect_failure(reason, now)

        callback(options, :defer_effect, &ForgeMirrors.defer_resource_effect/5).(
          operation,
          now,
          retry_at,
          failure_class,
          code
        )

      true ->
        case failure(reason, now) do
          {:retry, failure_class, retry_at} ->
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

  defp local_conflict?(reason) do
    reason in [
      :identity_conflict,
      :invalid_argument,
      :invalid_confirmation,
      :invalid_sync_request,
      :invalid_transition,
      :namespace_collision,
      :stale_baseline,
      :stale_local_snapshot,
      :stale_local_version
    ]
  end

  defp conflict_kind(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp provider_validation?(%Error{kind: kind}) do
    kind not in [
      :invalid_credential,
      :forbidden,
      :primary_rate_limit,
      :secondary_rate_limit,
      :transport,
      :timeout,
      :upstream_unavailable,
      :host_unavailable,
      :request_gate_busy
    ]
  end

  defp provider_validation?(_reason), do: false

  defp effect_failure(reason, now) do
    code =
      case reason do
        %Error{kind: kind} when kind in [:invalid_credential, :forbidden] ->
          "credential_unavailable"

        :revoked ->
          "credential_unavailable"

        :worker_crash ->
          "worker_crash"

        _ ->
          "resource_context_unavailable"
      end

    {failure_class, retry_at} = retry_schedule(reason, now)
    {failure_class, retry_at, code}
  end

  defp failure(%Error{kind: kind, retry_at: retry_at}, now)
       when kind in [:primary_rate_limit, :secondary_rate_limit],
       do: {:retry, Atom.to_string(kind), retry_at || DateTime.add(now, 30, :second)}

  defp failure(%Error{kind: kind}, now)
       when kind in [
              :transport,
              :timeout,
              :upstream_unavailable,
              :host_unavailable,
              :request_gate_busy
            ],
       do: {:retry, "network", DateTime.add(now, 30, :second)}

  defp failure(%Error{kind: :invalid_credential}, _now),
    do: {:fail, "credential_revoked", "GitHub rejected the installation token"}

  defp failure(%Error{kind: :forbidden}, _now),
    do: {:fail, "permission_missing", "GitHub denied release synchronization"}

  defp failure(%Error{}, _now),
    do: {:fail, "provider_validation", "GitHub returned an invalid release resource"}

  defp failure(:revoked, _now),
    do: {:fail, "credential_revoked", "installation token revoked"}

  defp failure(reason, now)
       when reason in [:busy, :timeout, :unavailable, :invalidated, :worker_crash],
       do: {:retry, "network", DateTime.add(now, 30, :second)}

  defp failure(reason, _now)
       when reason in [
              :invalid_projection,
              :invalid_remote_resource,
              :invalid_tag_proof,
              :missing_identity,
              :asset_warning_unavailable,
              :ambiguous_external_effect,
              :unsupported_operation
            ],
       do: {:fail, "local_validation", "release synchronization state is invalid"}

  defp failure(_reason, now), do: {:retry, "network", DateTime.add(now, 30, :second)}

  defp retry_schedule(%Error{kind: kind, retry_at: retry_at}, now)
       when kind in [:primary_rate_limit, :secondary_rate_limit],
       do: {Atom.to_string(kind), retry_at || DateTime.add(now, 30, :second)}

  defp retry_schedule(_reason, now), do: {"network", DateTime.add(now, 30, :second)}

  defp request_options(sync),
    do: [gate_key: {:github_installation, sync.github_installation_id}]

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
