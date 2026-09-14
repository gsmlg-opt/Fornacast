defmodule ForgeGitHub.GitRefWorker do
  @moduledoc """
  Bounded executor for exact-state Git ref reconciliation operations.

  Every attempt re-observes both repositories. Durable operations retain only a ref hint;
  webhook payload OIDs and prior in-memory observations are never applied directly.
  """

  use GenServer

  alias ForgeGitHub.{Error, InstallationToken, InstallationTokenBroker}
  alias ForgeMirrors.{GitRefDecision, MirrorOperation}
  alias GitCore.Remote.{ObservedRef, RefUpdate, SyncRequest}

  @operation_kind "sync.git_ref"
  @operation_kinds [
    @operation_kind,
    "reconcile.repository.bootstrap",
    "reconcile.repository.git",
    "finalize.repository.git"
  ]
  @default_interval_ms 1_000
  @default_lease_seconds 1_860
  @default_batch_size 4
  @default_max_concurrency 2
  @default_processor_timeout_ms 1_850_000
  @lease_margin_ms 5_000
  @run_option_keys [
    :lease_seconds,
    :batch_size,
    :max_concurrency,
    :processor_timeout_ms,
    :task_supervisor,
    :claim,
    :context,
    :repository_context,
    :token_fetch,
    :fetch_refs,
    :exact_ref,
    :list_refs,
    :ancestor?,
    :lfs_gate,
    :checkpoint_lfs,
    :degrade_lfs,
    :authorize_lfs_effect,
    :mark_effect,
    :replace_effect,
    :authorize_effect,
    :apply_local,
    :delete_local,
    :push_remote,
    :delete_remote,
    :confirm,
    :conflict,
    :fanout,
    :finalize,
    :finalize_preflight,
    :reconcile_lfs,
    :checkpoint_reconciliation,
    :retry,
    :fail,
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
        config(:git_ref_worker_max_concurrency, @default_max_concurrency),
        1,
        8
      )

    processor_timeout_ms =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:git_ref_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_599_000
      )

    unless processor_timeout_ms <= lease_seconds * 1_000 - @lease_margin_ms do
      raise ArgumentError, "Git ref processor timeout must finish inside its lease"
    end

    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, lease_seconds, min(batch_size, max_concurrency), @operation_kinds) do
      supervisor = Keyword.get(options, :task_supervisor, ForgeGitHub.GitRefTaskSupervisor)

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
  def process_operation(
        %MirrorOperation{kind: kind} = operation,
        %DateTime{} = now,
        options
      )
      when kind in ["reconcile.repository.bootstrap", "reconcile.repository.git"] do
    context =
      callback(
        options,
        :repository_context,
        &ForgeMirrors.git_repository_operation_context/1
      )

    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    with {:ok, sync} <- context.(operation),
         %InstallationToken{token: token} <-
           token_fetch.(sync.github_installation_id, %{
             permissions: %{"contents" => "write", "metadata" => "read"}
           }),
         request <- sync_request(sync),
         {:ok, observations} <- fetch_remote_refs(request, token, sync, options),
         {:ok, local_refs} <-
           callback(options, :list_refs, &GitCore.list_refs/1).(sync.repository_path),
         {:ok, ref_names} <- reconciliation_ref_names(sync, local_refs, observations) do
      callback(options, :fanout, &ForgeMirrors.fanout_git_ref_reconciliation/3).(
        operation,
        ref_names,
        now
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
      _invalid -> persist_failure(operation, now, :credential_unavailable, options)
    end
  rescue
    _exception -> persist_failure(operation, now, :worker_crash, options)
  catch
    _kind, _reason -> persist_failure(operation, now, :worker_crash, options)
  end

  def process_operation(
        %MirrorOperation{kind: "finalize.repository.git"} = operation,
        %DateTime{} = now,
        options
      ) do
    finalize = fn ->
      callback(options, :finalize, &ForgeMirrors.finalize_git_ref_reconciliation/2).(
        operation,
        now
      )
    end

    preflight =
      callback(
        options,
        :finalize_preflight,
        &ForgeMirrors.preflight_git_ref_reconciliation/2
      )

    with {:ok, sync} <-
           callback(
             options,
             :repository_context,
             &ForgeMirrors.git_repository_operation_context/1
           ).(operation) do
      result =
        case preflight.(operation, now) do
          {:ok, :continue} ->
            if sync.lfs_enabled do
              callback(options, :reconcile_lfs, &ForgeGitHub.LFSReconciliation.run/3).(
                operation,
                sync,
                finalize
              )
            else
              finalize.()
            end

          terminal ->
            terminal
        end

      case result do
        {:incomplete, checkpoint} ->
          callback(
            options,
            :checkpoint_reconciliation,
            &ForgeMirrors.checkpoint_git_reconciliation/3
          ).(
            operation,
            checkpoint,
            now
          )

        {:error, reason} when reason in [:lfs_missing, :lfs_integrity] ->
          ForgeMirrors.fail_git_lfs_reconciliation(operation, now, Atom.to_string(reason))

        {:error, :bootstrap_refs_unconfirmed} ->
          case preflight.(operation, now) do
            {:ok, :continue} ->
              persist_failure(operation, now, :bootstrap_refs_unconfirmed, options)

            superseded ->
              superseded
          end

        {:error, reason} ->
          persist_failure(operation, now, reason, options)

        completed ->
          completed
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  rescue
    _exception -> persist_failure(operation, now, :worker_crash, options)
  catch
    _kind, _reason -> persist_failure(operation, now, :worker_crash, options)
  end

  def process_operation(
        %MirrorOperation{kind: @operation_kind} = operation,
        %DateTime{} = now,
        options
      ) do
    context = callback(options, :context, &ForgeMirrors.git_ref_operation_context/1)
    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    with {:ok, sync} <- context.(operation),
         {:ok, authorized_operation} <- authorize_recovery(operation, options),
         %InstallationToken{token: token} <-
           token_fetch.(sync.github_installation_id, %{
             permissions: %{"contents" => "write", "metadata" => "read"}
           }),
         request <- sync_request(sync),
         {:ok, observations} <- fetch_remote_refs(request, token, sync, options),
         {:ok, local_oid} <- read_local_ref(sync, options),
         remote_oid <- observed_oid(observations, sync.ref_name),
         decision <- decide(sync, local_oid, remote_oid, options) do
      continue_after_observation(
        authorized_operation,
        now,
        sync,
        request,
        token,
        local_oid,
        remote_oid,
        decision,
        options
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
      _invalid -> persist_failure(operation, now, :credential_unavailable, options)
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
    owner = "git-ref-#{node()}-#{System.unique_integer([:positive])}"
    run_options = Keyword.take(options, @run_option_keys)

    state = %{
      enabled: Keyword.get(options, :enabled, config(:git_ref_worker_enabled, true)),
      interval_ms:
        bounded_option(
          options,
          :interval_ms,
          config(:git_ref_worker_interval_ms, @default_interval_ms),
          1,
          3_600_000
        ),
      task_supervisor: Keyword.get(options, :task_supervisor, ForgeGitHub.GitRefTaskSupervisor),
      runner: Keyword.get(options, :runner, fn -> run_once(owner, run_options) end),
      task_ref: nil
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    case Task.Supervisor.start_child(state.task_supervisor, state.runner) do
      {:ok, pid} ->
        {:noreply, %{state | task_ref: Process.monitor(pid)}}

      {:error, _reason} ->
        schedule(state.interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp fetch_remote_refs(request, token, sync, options) do
    callback(options, :fetch_refs, fn request, token, namespace ->
      GitCore.Remote.fetch_observed_refs(request, token, namespace)
    end).(request, token, sync.tracking_namespace)
  end

  defp read_local_ref(sync, options) do
    callback(options, :exact_ref, &GitCore.exact_ref/2).(sync.repository_path, sync.ref_name)
  end

  defp decide(sync, local_oid, remote_oid, options) do
    ancestor = callback(options, :ancestor?, &GitCore.is_ancestor/3)

    GitRefDecision.decide(sync.ref_kind, sync.baseline, local_oid, remote_oid, fn left, right ->
      ancestor.(sync.repository_path, left, right)
    end)
  end

  defp continue_after_observation(
         operation,
         now,
         sync,
         request,
         token,
         local_oid,
         remote_oid,
         decision,
         options
       ) do
    case reconcile_recorded_effect(operation, sync, local_oid, remote_oid) do
      :ok ->
        case prepare_lfs_effect(operation, now, sync, decision, options) do
          {:ok, prepared, true} ->
            case authorize_lfs_effect(prepared, sync, options) do
              {:ok, authorized, fresh_token} ->
                continue_after_lfs(
                  authorized,
                  now,
                  sync,
                  request,
                  fresh_token,
                  local_oid,
                  remote_oid,
                  decision,
                  true,
                  options
                )

              {:error, reason} ->
                persist_effect_failure(
                  prepared,
                  now,
                  sync,
                  local_oid,
                  remote_oid,
                  reason,
                  options
                )
            end

          {:ok, prepared, false} ->
            continue_after_lfs(
              prepared,
              now,
              sync,
              request,
              token,
              local_oid,
              remote_oid,
              decision,
              false,
              options
            )

          {:error, reason} ->
            persist_failure(operation, now, reason, options)
        end

      {:error, :ambiguous_external_effect} ->
        persist_conflict(
          operation,
          now,
          sync,
          local_oid,
          remote_oid,
          :git_divergence,
          options
        )
    end
  end

  defp reconcile_recorded_effect(%MirrorOperation{state: :processing}, _sync, _local, _remote),
    do: :ok

  defp reconcile_recorded_effect(
         %MirrorOperation{state: :effect_pending},
         sync,
         local_oid,
         remote_oid
       ) do
    recorded_effect_condition(sync.effect_marker, sync.ref_name, local_oid, remote_oid)
  end

  defp recorded_effect_condition(
         %{
           "action" => "apply_local",
           "expected_oid" => expected,
           "proposed_oid" => proposed,
           "ref" => marker_ref
         },
         ref,
         local_oid,
         _remote_oid
       ) do
    validate_recorded_condition(marker_ref, ref, local_oid, expected, proposed, false, true)
  end

  defp recorded_effect_condition(
         %{
           "action" => "apply_remote",
           "expected_oid" => expected,
           "proposed_oid" => proposed,
           "ref" => marker_ref
         },
         ref,
         _local_oid,
         remote_oid
       ) do
    validate_recorded_condition(marker_ref, ref, remote_oid, expected, proposed, false, true)
  end

  defp recorded_effect_condition(
         %{"action" => "delete_local", "expected_oid" => expected, "ref" => marker_ref},
         ref,
         local_oid,
         _remote_oid
       ) do
    validate_recorded_condition(marker_ref, ref, local_oid, expected, nil, true, false)
  end

  defp recorded_effect_condition(
         %{"action" => "delete_remote", "expected_oid" => expected, "ref" => marker_ref},
         ref,
         _local_oid,
         remote_oid
       ) do
    validate_recorded_condition(marker_ref, ref, remote_oid, expected, nil, true, false)
  end

  defp recorded_effect_condition(
         %{"action" => "converge_lfs", "ref" => marker_ref, "target_oid" => target_oid},
         ref,
         local_oid,
         remote_oid
       ) do
    if marker_ref == ref and valid_effect_oid?(target_oid) and local_oid == target_oid and
         remote_oid == target_oid,
       do: :ok,
       else: {:error, :ambiguous_external_effect}
  end

  defp recorded_effect_condition(_marker, _ref, _local_oid, _remote_oid),
    do: {:error, :ambiguous_external_effect}

  defp validate_recorded_condition(
         marker_ref,
         ref,
         observed_oid,
         expected_oid,
         proposed_oid,
         expected_required?,
         proposed_required?
       ) do
    valid_expected =
      if expected_required?,
        do: valid_effect_oid?(expected_oid),
        else: valid_optional_effect_oid?(expected_oid)

    valid_proposed =
      if proposed_required?, do: valid_effect_oid?(proposed_oid), else: is_nil(proposed_oid)

    if marker_ref == ref and valid_expected and valid_proposed and
         observed_oid in [expected_oid, proposed_oid] do
      :ok
    else
      {:error, :ambiguous_external_effect}
    end
  end

  defp valid_optional_effect_oid?(nil), do: true
  defp valid_optional_effect_oid?(oid), do: valid_effect_oid?(oid)

  defp valid_effect_oid?(oid) when is_binary(oid) and byte_size(oid) in [40, 64] do
    oid == String.downcase(oid) and String.match?(oid, ~r/\A[0-9a-f]+\z/)
  end

  defp valid_effect_oid?(_oid), do: false

  defp continue_after_lfs(
         operation,
         now,
         sync,
         request,
         token,
         local_oid,
         remote_oid,
         decision,
         effect_prepared?,
         options
       ) do
    case lfs_gate(decision, operation, sync, request, token, options) do
      :ok ->
        apply_decision(
          operation,
          now,
          sync,
          request,
          token,
          local_oid,
          remote_oid,
          decision,
          effect_prepared?,
          options
        )

      {:incomplete, checkpoint} when is_map(checkpoint) ->
        callback(options, :checkpoint_lfs, &ForgeMirrors.checkpoint_git_ref_operation/4).(
          operation,
          sync.ref_name,
          checkpoint,
          now
        )

      {:error, reason} when reason in [:lfs_missing, :lfs_integrity] ->
        failure_class = Atom.to_string(reason)

        callback(options, :degrade_lfs, &ForgeMirrors.degrade_git_ref/7).(
          operation,
          sync.ref_name,
          local_oid,
          remote_oid,
          now,
          failure_class,
          lfs_failure_detail(reason)
        )

      {:error, reason} ->
        persist_failure(operation, now, reason, options, reconciled_effect_retry(operation))

      _invalid ->
        persist_failure(
          operation,
          now,
          :invalid_lfs_state,
          options,
          reconciled_effect_retry(operation)
        )
    end
  end

  defp reconciled_effect_retry(%MirrorOperation{state: :effect_pending}),
    do: [external_effect_reconciled: true]

  defp reconciled_effect_retry(%MirrorOperation{}), do: []

  defp lfs_gate({:conflict, _kind}, _operation, _sync, _request, _token, _options), do: :ok
  defp lfs_gate({:error, _reason}, _operation, _sync, _request, _token, _options), do: :ok
  defp lfs_gate(_decision, _operation, %{lfs_enabled: false}, _request, _token, _options), do: :ok

  defp lfs_gate(decision, operation, sync, request, token, options) do
    if operation.state == :effect_pending and
         (not is_map(operation.external_effect_marker) or
            operation.external_effect_marker["lfs_required"] != true) do
      :ok
    else
      run_lfs_gate(decision, operation, sync, request, token, options)
    end
  end

  defp run_lfs_gate(decision, operation, sync, request, token, options) do
    {direction, target_oid} = lfs_target(decision)

    gate =
      callback(options, :lfs_gate, fn operation, sync, direction, target_oid, token, request ->
        ForgeGitHub.LFSSync.ensure(operation, sync, direction, target_oid, token, request,
          authorize: fn -> reauthorize_lfs_effect(operation, options) end
        )
      end)

    case gate.(operation, sync, direction, target_oid, token, request) do
      {:error, %Error{kind: :object_missing}} ->
        {:error, :lfs_missing}

      {:error, %Error{kind: :integrity_mismatch}} ->
        {:error, :lfs_integrity}

      {:error, reason} when reason in [:not_found, :lfs_missing] ->
        {:error, :lfs_missing}

      {:error, reason} when reason in [:integrity_mismatch, :lfs_integrity] ->
        {:error, :lfs_integrity}

      result ->
        result
    end
  end

  defp lfs_target({:apply_local, _expected, proposed}), do: {:inbound, proposed}
  defp lfs_target({:apply_remote, _expected, proposed}), do: {:outbound, proposed}
  defp lfs_target({:confirm, oid}), do: {:converge, oid}
  defp lfs_target({:delete_local, _expected}), do: {:inbound, nil}
  defp lfs_target({:delete_remote, _expected}), do: {:outbound, nil}

  defp lfs_failure_detail(:lfs_missing), do: "a required reachable Git LFS object is missing"

  defp lfs_failure_detail(:lfs_integrity),
    do: "a required reachable Git LFS object failed integrity verification"

  defp apply_decision(
         operation,
         now,
         sync,
         _request,
         _token,
         _local_oid,
         _remote_oid,
         {:confirm, oid},
         _effect_prepared?,
         options
       ) do
    callback(options, :confirm, &ForgeMirrors.confirm_git_ref/5).(
      operation,
      sync.ref_name,
      oid,
      oid,
      now
    )
  end

  defp apply_decision(
         operation,
         now,
         sync,
         request,
         token,
         local_oid,
         remote_oid,
         decision,
         effect_prepared?,
         options
       )
       when elem(decision, 0) in [:apply_local, :apply_remote, :delete_local, :delete_remote] do
    mark_result =
      if effect_prepared?,
        do: {:ok, operation},
        else: mark_effect(operation, now, sync.effect_marker, sync.ref_name, decision, options)

    case mark_result do
      {:ok, marked} ->
        with {:ok, authorized} <- authorize_effect(marked, options),
             {:ok, effect_token} <- effect_token(decision, sync, token, options) do
          case execute_effect(decision, sync, request, effect_token, options) do
            :ok ->
              expected_oid = resulting_oid(decision)

              callback(options, :confirm, &ForgeMirrors.confirm_git_ref/5).(
                authorized,
                sync.ref_name,
                expected_oid,
                expected_oid,
                now
              )

            {:error, reason} ->
              persist_effect_failure(
                authorized,
                now,
                sync,
                local_oid,
                remote_oid,
                reason,
                options
              )
          end
        else
          {:error, reason} ->
            persist_effect_failure(marked, now, sync, local_oid, remote_oid, reason, options)
        end

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp apply_decision(
         operation,
         now,
         sync,
         _request,
         _token,
         local_oid,
         remote_oid,
         {:conflict, kind},
         _effect_prepared?,
         options
       ) do
    persist_conflict(operation, now, sync, local_oid, remote_oid, kind, options)
  end

  defp apply_decision(
         operation,
         now,
         _sync,
         _request,
         _token,
         _local_oid,
         _remote_oid,
         {:error, reason},
         _effect_prepared?,
         options
       ),
       do: persist_failure(operation, now, reason, options)

  defp mark_effect(
         %MirrorOperation{state: :effect_pending} = operation,
         now,
         recorded_marker,
         ref,
         decision,
         options
       )
       when is_map(recorded_marker) do
    mark_effect_marker(operation, now, recorded_marker, effect_marker(ref, decision), options)
  end

  defp mark_effect(operation, now, _recorded_marker, ref, decision, options) do
    marker = effect_marker(ref, decision)
    callback(options, :mark_effect, &ForgeMirrors.mark_external_effect/3).(operation, now, marker)
  end

  defp mark_effect_marker(
         %MirrorOperation{state: :effect_pending} = operation,
         now,
         recorded_marker,
         replacement_marker,
         options
       )
       when is_map(recorded_marker) do
    if replacement_marker == recorded_marker do
      {:ok, operation}
    else
      callback(options, :replace_effect, &ForgeMirrors.replace_external_effect/4).(
        operation,
        now,
        recorded_marker,
        replacement_marker
      )
    end
  end

  defp mark_effect_marker(operation, now, _recorded_marker, marker, options) do
    callback(options, :mark_effect, &ForgeMirrors.mark_external_effect/3).(operation, now, marker)
  end

  defp prepare_lfs_effect(operation, now, sync, decision, options) do
    lfs_required? =
      (operation.state == :processing and Map.get(sync, :lfs_enabled, true)) or
        (operation.state == :effect_pending and is_map(sync.effect_marker) and
           sync.effect_marker["lfs_required"] == true)

    if lfs_required? and
         elem(decision, 0) in [
           :confirm,
           :apply_local,
           :apply_remote,
           :delete_local,
           :delete_remote
         ] do
      marker = sync.ref_name |> effect_marker(decision) |> Map.put("lfs_required", true)

      case mark_effect_marker(operation, now, sync.effect_marker, marker, options) do
        {:ok, marked} -> {:ok, marked, true}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, operation, false}
    end
  end

  defp authorize_lfs_effect(operation, sync, options) do
    with {:ok, authorized} <-
           callback(
             options,
             :authorize_lfs_effect,
             &ForgeMirrors.authorize_git_lfs_effect/2
           ).(operation, operation.external_effect_marker),
         {:ok, fresh_token} <- effect_token({:apply_remote, nil, nil}, sync, nil, options) do
      {:ok, authorized, fresh_token}
    end
  end

  defp reauthorize_lfs_effect(operation, options) do
    case callback(
           options,
           :authorize_lfs_effect,
           &ForgeMirrors.authorize_git_lfs_effect/2
         ).(operation, operation.external_effect_marker) do
      {:ok, %MirrorOperation{}} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_authorization}
    end
  end

  defp authorize_effect(operation, options) do
    callback(options, :authorize_effect, &ForgeMirrors.authorize_external_effect/2).(
      operation,
      operation.external_effect_marker
    )
  end

  defp authorize_recovery(%MirrorOperation{state: :effect_pending} = operation, options),
    do: authorize_effect(operation, options)

  defp authorize_recovery(%MirrorOperation{state: :processing} = operation, _options),
    do: {:ok, operation}

  defp authorize_recovery(%MirrorOperation{}, _options), do: {:error, :invalid_transition}

  defp effect_token(decision, sync, _token, options)
       when elem(decision, 0) in [:apply_remote, :delete_remote] do
    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    case token_fetch.(sync.github_installation_id, %{
           permissions: %{"contents" => "write", "metadata" => "read"}
         }) do
      %InstallationToken{token: fresh_token} -> {:ok, fresh_token}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :credential_unavailable}
    end
  end

  defp effect_token(_decision, _sync, token, _options), do: {:ok, token}

  defp execute_effect({:apply_local, expected, proposed}, sync, _request, _token, options) do
    with_write_fence(sync.repository_id, fn ->
      callback(options, :apply_local, &apply_local/4).(
        sync.repository_path,
        sync.ref_name,
        expected,
        proposed
      )
    end)
    |> normalize_git_effect()
  end

  defp execute_effect({:delete_local, expected}, sync, _request, _token, options) do
    with_write_fence(sync.repository_id, fn ->
      callback(options, :delete_local, &delete_local/3).(
        sync.repository_path,
        sync.ref_name,
        expected
      )
    end)
    |> normalize_git_effect()
  end

  defp execute_effect({:apply_remote, expected, proposed}, sync, request, token, options) do
    update = %RefUpdate{ref: sync.ref_name, expected_oid: expected, proposed_oid: proposed}

    callback(options, :push_remote, fn request, token, update ->
      GitCore.Remote.push_refs(request, token, [update])
    end).(request, token, update)
  end

  defp execute_effect({:delete_remote, expected}, sync, request, token, options) do
    callback(options, :delete_remote, &GitCore.Remote.delete_ref/4).(
      request,
      token,
      sync.ref_name,
      expected
    )
  end

  defp apply_local(path, ref, expected, proposed) do
    with {:ok, oid} <-
           GitCore.compare_and_swap_ref(path, ref, expected, proposed, :fast_forward, []),
         :ok <- GitCore.invalidate_repository_cache(path) do
      {:ok, oid}
    end
  end

  defp delete_local(path, ref, expected) do
    with {:ok, oid} <- GitCore.compare_and_delete_ref(path, ref, expected),
         :ok <- GitCore.invalidate_repository_cache(path) do
      {:ok, oid}
    end
  end

  defp with_write_fence(repository_id, callback) do
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:ref_deadline_ms)

    case GitCore.RepositoryWriteLimiter.acquire(repository_id, deadline) do
      {:ok, lease} ->
        try do
          callback.()
        after
          :ok = GitCore.RepositoryWriteLimiter.release(lease)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_git_effect({:ok, _oid}) do
    :ok
  end

  defp normalize_git_effect(other), do: other

  defp persist_effect_failure(operation, now, sync, local_oid, remote_oid, reason, options) do
    case conflict_kind(reason) do
      nil -> persist_failure(operation, now, reason, options, external_effect_reconciled: true)
      kind -> persist_conflict(operation, now, sync, local_oid, remote_oid, kind, options)
    end
  end

  defp persist_conflict(operation, now, sync, local_oid, remote_oid, kind, options) do
    callback(options, :conflict, &ForgeMirrors.conflict_git_ref/7).(
      operation,
      sync.ref_name,
      kind,
      sync.baseline,
      local_oid,
      remote_oid,
      now
    )
  end

  defp persist_failure(operation, now, reason, options, retry_options \\ [])

  defp persist_failure(
         operation,
         now,
         %Error{kind: kind, retry_at: retry_at},
         options,
         retry_options
       )
       when kind in [:primary_rate_limit, :secondary_rate_limit] do
    retry_at =
      if is_struct(retry_at, DateTime) and DateTime.after?(retry_at, now),
        do: retry_at,
        else: DateTime.add(now, 60, :second)

    callback(options, :retry, &ForgeMirrors.retry_operation/5).(
      operation,
      now,
      retry_at,
      Atom.to_string(kind),
      retry_options
    )
  end

  defp persist_failure(operation, now, %Error{kind: :invalid_credential}, options, _retry_options) do
    callback(options, :fail, &ForgeMirrors.fail_operation/4).(
      operation,
      now,
      "credential_revoked",
      "GitHub rejected the installation token"
    )
  end

  defp persist_failure(operation, now, %Error{kind: :forbidden}, options, _retry_options) do
    callback(options, :fail, &ForgeMirrors.fail_operation/4).(
      operation,
      now,
      "permission_missing",
      "GitHub denied the Git LFS operation"
    )
  end

  defp persist_failure(operation, now, %Error{kind: kind}, options, retry_options)
       when kind in [
              :transport,
              :timeout,
              :host_unavailable,
              :upstream_unavailable,
              :request_gate_busy,
              :action_expired
            ] do
    retry_at = DateTime.add(now, 60, :second)

    callback(options, :retry, &ForgeMirrors.retry_operation/5).(
      operation,
      now,
      retry_at,
      "network",
      retry_options
    )
  end

  defp persist_failure(
         operation,
         now,
         %Error{kind: kind},
         options,
         _retry_options
       )
       when kind in [:source, :sink, :local_storage] do
    callback(options, :fail, &ForgeMirrors.fail_operation/4).(
      operation,
      now,
      "local_validation",
      "The local Git LFS object could not be read or written"
    )
  end

  defp persist_failure(operation, now, %Error{}, options, _retry_options) do
    callback(options, :fail, &ForgeMirrors.fail_operation/4).(
      operation,
      now,
      "provider_validation",
      "GitHub returned an invalid Git LFS response"
    )
  end

  defp persist_failure(operation, now, reason, options, retry_options) do
    cond do
      reason == :git_ref_conflicted ->
        callback(options, :fail, &ForgeMirrors.fail_operation/4).(
          operation,
          now,
          "git_divergence",
          "Git ref has an unresolved conflict"
        )

      reason in [:revoked, :credential_unavailable] ->
        callback(options, :fail, &ForgeMirrors.fail_operation/4).(
          operation,
          now,
          "credential_revoked",
          "GitHub installation credential unavailable"
        )

      reason in [:invalid_scope, :permission_missing] ->
        callback(options, :fail, &ForgeMirrors.fail_operation/4).(
          operation,
          now,
          "permission_missing",
          "GitHub contents write permission unavailable"
        )

      reason == :paused ->
        retry_at = DateTime.add(now, 60, :second)

        callback(options, :retry, &ForgeMirrors.retry_operation/5).(
          operation,
          now,
          retry_at,
          "network",
          retry_options
        )

      true ->
        retry_at = DateTime.add(now, 60, :second)

        callback(options, :retry, &ForgeMirrors.retry_operation/5).(
          operation,
          now,
          retry_at,
          "network",
          retry_options
        )
    end
  end

  defp conflict_kind(%GitCore.Error{kind: kind}) when kind in [:stale_ref, :ref_exists],
    do: :git_divergence

  defp conflict_kind(%GitCore.Remote.Error{kind: :stale_remote}), do: :git_divergence
  defp conflict_kind(%GitCore.Remote.Error{kind: :non_fast_forward}), do: :git_divergence
  defp conflict_kind(%GitCore.Remote.Error{kind: :tag_retarget}), do: :tag_retarget
  defp conflict_kind(_reason), do: nil

  defp effect_marker(ref, {:apply_local, expected, proposed}),
    do: %{
      "action" => "apply_local",
      "expected_oid" => expected,
      "proposed_oid" => proposed,
      "ref" => ref
    }

  defp effect_marker(ref, {:apply_remote, expected, proposed}),
    do: %{
      "action" => "apply_remote",
      "expected_oid" => expected,
      "proposed_oid" => proposed,
      "ref" => ref
    }

  defp effect_marker(ref, {:delete_local, expected}),
    do: %{"action" => "delete_local", "expected_oid" => expected, "ref" => ref}

  defp effect_marker(ref, {:delete_remote, expected}),
    do: %{"action" => "delete_remote", "expected_oid" => expected, "ref" => ref}

  defp effect_marker(ref, {:confirm, oid}),
    do: %{"action" => "converge_lfs", "ref" => ref, "target_oid" => oid}

  defp resulting_oid({:apply_local, _expected, proposed}), do: proposed
  defp resulting_oid({:apply_remote, _expected, proposed}), do: proposed
  defp resulting_oid({:delete_local, _expected}), do: nil
  defp resulting_oid({:delete_remote, _expected}), do: nil

  defp observed_oid(observations, ref_name) do
    Enum.find_value(observations, fn
      %ObservedRef{ref: ^ref_name, oid: oid} -> oid
      _other -> nil
    end)
  end

  defp reconciliation_ref_names(sync, local_refs, observations)
       when is_list(local_refs) and is_list(observations) and is_list(sync.baseline_ref_names) do
    local_names =
      Enum.flat_map(local_refs, fn
        %{name: "refs/heads/" <> _ = name} -> [name]
        %{name: "refs/tags/" <> _ = name} -> [name]
        _other -> []
      end)

    remote_names =
      Enum.flat_map(observations, fn
        %ObservedRef{ref: "refs/heads/" <> _ = ref} -> [ref]
        %ObservedRef{ref: "refs/tags/" <> _ = ref} -> [ref]
        _other -> []
      end)

    names =
      (sync.baseline_ref_names ++ local_names ++ remote_names)
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.all?(names, &valid_standard_ref?/1),
      do: {:ok, names},
      else: {:error, :invalid_ref}
  end

  defp reconciliation_ref_names(_sync, _local_refs, _observations),
    do: {:error, :invalid_ref}

  defp valid_standard_ref?(ref) do
    match?({:ok, _tracking}, GitCore.tracking_ref_name("reconcile-validation", ref))
  end

  defp sync_request(sync) do
    %SyncRequest{
      provider: :github,
      owner: sync.remote_owner,
      repository: sync.remote_repository,
      credential_login: "x-access-token",
      repository_path: sync.repository_path
    }
  end

  defp callback(options, key, default) do
    case Keyword.get(options, key, default) do
      function when is_function(function) -> function
      _invalid -> raise ArgumentError, "invalid Git ref worker callback"
    end
  end

  defp bounded_option(options, key, default, minimum, maximum) do
    value = Keyword.get(options, key, default)

    if is_integer(value) and value in minimum..maximum,
      do: value,
      else: raise(ArgumentError, "invalid Git ref worker option")
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
  defp config(key, default), do: Application.get_env(:forge_github, key, default)
end
