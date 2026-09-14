defmodule ForgeGitHub.PullMergeWorker do
  @moduledoc """
  Bounded remote CAS execution for a prepared coordinated merge.

  A successful push only yields the durable pre-push marker. A subsequent
  authenticated observation of the exact merged result and shared metadata can
  finalize locally through the coordinator boundary. Ref-only readiness never
  closes a pull.
  """
  use GenServer
  import Ecto.Query

  alias ForgeGitHub.{
    Client,
    Error,
    IdentityClient,
    InstallationToken,
    InstallationTokenBroker,
    IssueClient,
    IssueSyncProjection,
    LabelClient,
    LFSSync,
    PullClient,
    PullMetadataDecision,
    PullMetadataRecovery,
    PullMergeObservation,
    PullSyncWorker,
    RelationshipClient,
    RefObservation
  }

  alias ForgeMirrors.{
    MirrorOperation,
    OrganizationMirror,
    PullMergeBoundary,
    PullMergeConfirmation,
    PullMergeMetadataEffects,
    PullMergeRemoteAssigneeObservation,
    PullMergeRemoteLabelObservation,
    RepositoryMirror
  }

  alias Fornacast.Repo
  alias GitCore.Remote.{RefUpdate, SyncRequest}

  @test_callbacks Mix.env() == :test
  @max_metadata_effects 3
  @operation_kinds ["merge.pull"]
  @default_interval_ms 1_000
  @default_lease_seconds 1_860
  @default_batch_size 2
  @default_max_concurrency 2
  @default_processor_timeout_ms 1_850_000
  @lease_margin_ms 5_000

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
        config(:pull_merge_worker_max_concurrency, @default_max_concurrency),
        1,
        8
      )

    processor_timeout_ms =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:pull_merge_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_594_999
      )

    unless processor_timeout_ms < lease_seconds * 1_000 - @lease_margin_ms do
      raise ArgumentError, "pull merge processor timeout must finish inside its lease"
    end

    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, lease_seconds, min(batch_size, max_concurrency), @operation_kinds) do
      supervisor = Keyword.get(options, :task_supervisor, ForgeGitHub.PullMergeTaskSupervisor)

      results =
        supervisor
        |> Task.Supervisor.async_stream_nolink(
          operations,
          &process_claimed_operation(&1, now, options),
          max_concurrency: max_concurrency,
          ordered: true,
          on_timeout: :kill_task,
          timeout: processor_timeout_ms
        )
        |> Stream.zip(operations)
        |> Enum.map(fn
          {{:ok, result}, operation} ->
            {operation.id, result}

          {{:exit, _reason}, operation} ->
            {operation.id, recover_worker_crash(operation, now, options)}
        end)

      {:ok, results}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def run_once(_owner, _options), do: {:error, :invalid_argument}

  def process_operation(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        options
      )
      when is_list(options) do
    case operation.external_effect_marker do
      %{"phase" => "metadata_label_pending"} ->
        recover_local_label(operation, now, options)

      %{"phase" => "metadata_issue_pending"} ->
        recover_metadata(operation, now, options, 0)

      marker when is_map(marker) ->
        recover(operation, now, options)

      nil ->
        result =
          with {:ok, context} <- merge_context(operation, now, options),
               {:ok, context} <- ensure_merge_written(operation, context, options),
               result <-
                 callback(options, :unmarked_execute, &execute_unmarked/4).(
                   operation,
                   now,
                   context,
                   options
                 ) do
            result
          end

        normalize_unmarked_result(operation, now, result, options)
    end
  rescue
    _exception -> normalize_worker_crash(operation, now, options)
  catch
    _kind, _reason -> normalize_worker_crash(operation, now, options)
  end

  def process_operation(_, _, _), do: {:error, :invalid_argument}

  @impl true
  def init(options) do
    interval_ms = Keyword.get(options, :interval_ms, @default_interval_ms)
    owner = Keyword.get_lazy(options, :owner, &Ecto.UUID.generate/0)
    enabled = Keyword.get(options, :enabled, config(:pull_merge_worker_enabled, false))

    run_options =
      Keyword.drop(options, [
        :interval_ms,
        :owner,
        :name,
        :enabled,
        :loop_task_supervisor,
        :runner
      ])

    if is_integer(interval_ms) and interval_ms > 0 and is_binary(owner) and is_boolean(enabled) do
      state = %{
        interval_ms: interval_ms,
        owner: owner,
        run_options: run_options,
        enabled: enabled,
        loop_task_supervisor:
          Keyword.get(
            options,
            :loop_task_supervisor,
            ForgeGitHub.PullMergeLoopTaskSupervisor
          ),
        task_supervisor:
          Keyword.get(options, :task_supervisor, ForgeGitHub.PullMergeTaskSupervisor),
        runner: Keyword.get(options, :runner, fn -> run_once(owner, run_options) end),
        task_ref: nil
      }

      if enabled, do: schedule(0)
      {:ok, state}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_info(:tick, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{enabled: true, task_ref: nil} = state) do
    case Task.Supervisor.start_child(state.loop_task_supervisor, state.runner) do
      {:ok, pid} ->
        {:noreply, %{state | task_ref: Process.monitor(pid)}}

      {:error, _reason} ->
        schedule(state.interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    if state.enabled, do: schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp process_claimed_operation(operation, now, options) do
    callback(options, :processor, &process_operation/3).(operation, now, options)
  end

  defp recover_worker_crash(%MirrorOperation{} = operation, now, options) do
    case marked_after_crash(operation, options) do
      %MirrorOperation{} = marked ->
        callback(options, :defer, &PullMergeBoundary.defer/4).(
          marked,
          now,
          next(now),
          :worker_crash
        )

      nil ->
        persist_unmarked_failure(operation, now, :worker_crash, options)
    end
  end

  defp normalize_worker_crash(%MirrorOperation{} = operation, now, options) do
    _ = recover_worker_crash(operation, now, options)
    {:error, :worker_crash}
  end

  defp marked_after_crash(%MirrorOperation{external_effect_marker: marker} = operation, _options)
       when is_map(marker),
       do: operation

  defp marked_after_crash(%MirrorOperation{} = operation, options) do
    case callback(options, :current_operation, &Repo.get(MirrorOperation, &1)).(operation.id) do
      %MirrorOperation{
        id: id,
        kind: "merge.pull",
        state: :effect_pending,
        external_effect_marker: marker,
        lease_owner: owner
      } = current
      when id == operation.id and is_map(marker) and owner == operation.lease_owner ->
        current

      _ ->
        nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp normalize_unmarked_result(operation, now, {:error, reason} = error, options) do
    _ = persist_unmarked_failure(operation, now, reason, options)
    error
  end

  defp normalize_unmarked_result(_operation, _now, result, _options), do: result

  defp execute_unmarked(operation, now, context, options) do
    with {:ok, sync} <- execution_context(context),
         {:ok, token} <- token(sync, options) do
      push(operation, now, sync, token, options)
    end
  end

  defp merge_context(operation, now, options),
    do: callback(options, :merge_context, &PullMergeBoundary.context/2).(operation, now)

  defp ensure_merge_written(_operation, %{intent: %{state: "merge_written"}} = context, _options),
    do: {:ok, context}

  defp ensure_merge_written(operation, %{intent: %{state: "prepared"} = intent}, options) do
    authorize = fn writer_intent ->
      PullMergeBoundary.authorize(operation, DateTime.utc_now(:second), writer_intent)
    end

    with {:ok, _written} <-
           callback(options, :write_coordinated_merge, &ForgePulls.write_coordinated_merge/3).(
             intent.id,
             operation.id,
             authorize: authorize
           ),
         {:ok, context} <- merge_context(operation, DateTime.utc_now(:second), options),
         true <- context.intent.state == "merge_written" do
      {:ok, context}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp ensure_merge_written(_operation, _context, _options),
    do: {:error, :stale_merge_identity}

  defp recover(operation, now, options) do
    result =
      with {:ok, context} <- PullMergeBoundary.authorized_recovery_context(operation, now),
           {:ok, sync} <- execution_context(context),
           {:ok, token} <- token(sync, options),
           {:ok, _} <- PullMergeBoundary.authorized_recovery_context(operation, now),
           {:ok, remote} <- observe(sync, :base, token, options),
           {:ok, pair} <- pair(sync, token, options) do
        cond do
          remote.oid == context.intent.expected_base_oid ->
            # An unchanged remote ref is the only recovery observation that may
            # authorize another attempt, and it still requires fresh authority.
            with {:ok, fresh} <- PullMergeBoundary.context(operation, now),
                 {:ok, fresh_sync} <- execution_context(fresh) do
              push(operation, now, fresh_sync, token, options)
            end

          remote.oid == context.intent.merge_oid and pair.pull["merged"] == true ->
            finalize(operation, sync, pair, remote.oid, token, options, 0)

          true ->
            PullMergeBoundary.record_observation(operation, now, next(now), %{
              remote_base_oid: remote.oid,
              provider_pull_id: pair.pull["id"]
            })
        end
      end

    case result do
      {:error, reason} -> PullMergeBoundary.defer(operation, now, next(now), reason)
      other -> other
    end
  end

  defp finalize(operation, sync, pair, remote_base_oid, read_token, options, effect_count) do
    with {:ok, observation} <-
           merge_observation(operation, sync, pair, remote_base_oid) do
      case metadata_decision(operation, sync, observation) do
        {:ok, %{apply_local?: false, remote_issue_effect?: false}, _local} ->
          confirm_merge(operation, sync, pair, observation, nil)

        {:ok, %{apply_local?: true, remote_issue_effect?: false} = plan, local} ->
          with {:ok, relationships} <-
                 ForgeMirrors.resolve_issue_relationships(
                   sync.repository_mirror_id,
                   :remote,
                   pair.issue["labels"],
                   pair.issue["assignees"]
                 ),
               {:ok, target_relationships} <-
                 IssueSyncProjection.local_relationships(
                   plan.target_metadata,
                   Map.new(relationships.labels, &{&1.github_object_id, &1}),
                   Map.new(relationships.assignees, &{&1.github_user_id, &1})
                 ) do
            request = %{
              action: :update,
              repository_id: sync.repository_id,
              resource_kind: :pull,
              local_resource_id: local.local_resource_id,
              expected_local_version: local.local_version,
              expected_fields: local.fields,
              expected_merge_state: local.merge_state,
              expected_relationships: local.relationship_preimage,
              local_label_ids: target_relationships.local_label_ids,
              assignee_refs: target_relationships.assignee_refs,
              fields:
                Map.merge(local.fields, Map.take(plan.target_metadata, ~w(title body draft))),
              provenance: %{origin: :github, correlation_id: "merge-#{operation.id}"}
            }

            confirm_merge(operation, sync, pair, observation, request)
          end

        {:ok, %{remote_issue_effect?: true} = plan, local} ->
          target_issue = merge_target_issue(plan.target_metadata)

          mark_and_apply_metadata(
            operation,
            sync,
            observation,
            local,
            target_issue,
            read_token,
            options,
            effect_count
          )

        {:conflict, _kind} ->
          now = DateTime.utc_now(:second)
          PullMergeConfirmation.record_metadata_conflict(operation, now, next(now), observation)

        {:error, {:unmapped_label, candidate}} ->
          materialize_local_label(
            operation,
            sync,
            observation,
            candidate,
            options
          )

        {:error, _} = error ->
          error
      end
    else
      {:yielded, %MirrorOperation{} = yielded} -> {:ok, yielded}
      {:error, _} = error -> error
    end
  end

  defp recover_metadata(operation, now, options, effect_count) do
    result =
      with {:ok, context} <- PullMergeMetadataEffects.recovery_context(operation, now),
           {:ok, sync} <- execution_context(context),
           {:ok, read_token} <- token(sync, options),
           {:ok, current} <- PullMergeMetadataEffects.recovery_context(operation, now),
           true <- metadata_intent(current).id == metadata_intent(context).id,
           {:ok, remote} <- observe(sync, :base, read_token, options),
           {:ok, pair} <- pair(sync, read_token, options),
           {:ok, observation} <- merge_observation(operation, sync, pair, remote.oid),
           {:ok, classification} <-
             classify_metadata_recovery(current, observation) do
        case classification.status do
          :applied ->
            continue_after_applied_effect(
              operation,
              sync,
              pair,
              observation,
              current,
              read_token,
              options,
              effect_count
            )

          :not_applied ->
            if retained_metadata_timestamps?(context.marker, observation) do
              apply_marked_metadata(
                operation,
                sync,
                current,
                read_token,
                options,
                effect_count
              )
            else
              PullMergeConfirmation.record_ambiguous_effect(
                operation,
                now,
                next(now),
                observation
              )
            end
        end
      else
        {:yielded, %MirrorOperation{} = yielded} ->
          {:ok, yielded}

        {:conflict, :ambiguous_external_effect, observation} ->
          PullMergeConfirmation.record_ambiguous_effect(
            operation,
            now,
            next(now),
            observation
          )

        {:error, _} = error ->
          error

        false ->
          {:error, :stale_merge_identity}
      end

    case result do
      {:error, reason} -> PullMergeBoundary.defer(operation, now, next(now), reason)
      other -> other
    end
  end

  defp classify_metadata_recovery(context, observation) do
    if metadata_timestamps_nonregressed?(context.marker, observation) do
      case PullMetadataRecovery.classify(
             metadata_intent(context).payload,
             context.current_local_issue,
             observation.issue.confirmed_snapshot
           ) do
        {:conflict, :ambiguous_external_effect} ->
          {:conflict, :ambiguous_external_effect, observation}

        other ->
          other
      end
    else
      {:conflict, :ambiguous_external_effect, observation}
    end
  end

  defp continue_after_applied_effect(
         operation,
         sync,
         pair,
         observation,
         context,
         read_token,
         options,
         effect_count
       ) do
    payload = metadata_intent(context).payload

    case context[:unmapped_label] do
      candidate when is_map(candidate) ->
        materialize_local_label(
          operation,
          sync,
          observation,
          candidate,
          options
        )

      nil ->
        if context.current_local_issue in [
             payload["expected_local_issue"],
             payload["target_issue"]
           ] do
          finalize(
            operation,
            sync,
            pair,
            observation.remote_base_oid,
            read_token,
            options,
            effect_count
          )
        else
          mark_and_apply_metadata(
            operation,
            sync,
            observation,
            context.local_projection,
            context.current_local_issue,
            read_token,
            options,
            effect_count
          )
        end
    end
  end

  defp materialize_local_label(
         operation,
         sync,
         observation,
         candidate,
         options
       ) do
    result =
      PullSyncWorker.with_merge_ref_fences(sync.git_proof, sync.intent.merge_oid, fn ->
        with {:ok, label} <-
               ForgeIssues.label_sync_projection(sync.repository_id, candidate.local_label_id),
             {:ok, write_token} <- metadata_write_token(sync, options),
             :ok <- local_label_preflight(operation, options),
             {:ok, repository} <- relationship_repository(sync, write_token, options),
             :ok <- local_label_preflight(operation, options) do
          observed =
            callback(options, :get_label, &LabelClient.get_label/5).(
              write_token,
              sync.routing.base.owner,
              sync.routing.base.repository,
              label.fields["name"],
              request_options(sync, options)
            )

          with :ok <- local_label_preflight(operation, options),
               {:ok, ^repository} <- relationship_repository(sync, write_token, options),
               :ok <- local_label_preflight(operation, options) do
            case observed do
              {:ok, remote_label} ->
                if canonical_provider_label(remote_label) == label.fields do
                  with {:ok, fresh_observation} <-
                         refresh_merge_observation(operation, sync, write_token, options) do
                    confirm_local_label(
                      operation,
                      sync,
                      fresh_observation,
                      label,
                      remote_label,
                      options
                    )
                  end
                else
                  with {:ok, fresh_observation} <-
                         refresh_merge_observation(operation, sync, write_token, options) do
                    conflict_local_label(
                      operation,
                      sync,
                      fresh_observation,
                      label,
                      :label_namespace_collision,
                      remote_label,
                      options
                    )
                  end
                end

              {:error, %Error{kind: :not_found}} ->
                create_local_label(
                  operation,
                  sync,
                  observation,
                  label,
                  label,
                  write_token,
                  repository,
                  options
                )

              {:error, _} = error ->
                error

              _ ->
                {:error, :invalid_remote_result}
            end
          end
        end
      end)

    defer_local_label_error(operation, result)
  end

  defp create_local_label(
         operation,
         sync,
         observation,
         candidate,
         label,
         write_token,
         repository,
         options
       ) do
    now = DateTime.utc_now(:second)

    case callback(
           options,
           :mark_merge_local_label,
           &ForgeMirrors.mark_pull_merge_local_label/5
         ).(operation, now, sync.intent, observation, candidate) do
      {:ok, %{operation: marked}} ->
        result =
          with {:ok, _context} <-
                 callback(
                   options,
                   :merge_local_label_context,
                   &ForgeMirrors.pull_merge_local_label_context/2
                 ).(marked, now),
               :ok <- local_label_preflight(marked, options),
               {:ok, ^repository} <- relationship_repository(sync, write_token, options),
               :ok <- local_label_preflight(marked, options) do
            created =
              callback(options, :create_label, &LabelClient.create_label/5).(
                write_token,
                sync.routing.base.owner,
                sync.routing.base.repository,
                label.fields,
                request_options(sync, options)
              )

            with :ok <- local_label_preflight(marked, options),
                 {:ok, ^repository} <- relationship_repository(sync, write_token, options),
                 :ok <- local_label_preflight(marked, options) do
              case created do
                {:ok, remote_label} ->
                  if canonical_provider_label(remote_label) == label.fields do
                    with {:ok, fresh_observation} <-
                           refresh_merge_observation(marked, sync, write_token, options) do
                      confirm_local_label(
                        marked,
                        sync,
                        fresh_observation,
                        candidate,
                        remote_label,
                        options
                      )
                    end
                  else
                    with {:ok, fresh_observation} <-
                           refresh_merge_observation(marked, sync, write_token, options) do
                      conflict_local_label(
                        marked,
                        sync,
                        fresh_observation,
                        candidate,
                        :ambiguous_label_create,
                        remote_label,
                        options
                      )
                    end
                  end

                {:error, _} = error ->
                  error

                _ ->
                  {:error, :invalid_remote_result}
              end
            end
          end

        case result do
          {:error, reason} -> PullMergeBoundary.defer(marked, now, next(now), reason)
          other -> other
        end

      {:error, _} = error ->
        error
    end
  end

  defp recover_local_label(operation, now, options) do
    result =
      with {:ok, context} <-
             callback(
               options,
               :merge_local_label_context,
               &ForgeMirrors.pull_merge_local_label_context/2
             ).(operation, now),
           {:ok, sync} <- execution_context(context),
           {:ok, write_token} <- metadata_write_token(sync, options),
           :ok <- local_label_preflight(operation, options) do
        PullSyncWorker.with_merge_ref_fences(sync.git_proof, sync.intent.merge_oid, fn ->
          with :ok <- local_label_preflight(operation, options),
               {:ok, observation} <-
                 refresh_merge_observation(operation, sync, write_token, options),
               :ok <- local_label_preflight(operation, options),
               {:ok, repository} <- relationship_repository(sync, write_token, options),
               :ok <- local_label_preflight(operation, options) do
            candidate = context.candidate

            case context.label_conflict do
              :label_metadata_conflict ->
                conflict_local_label(
                  operation,
                  sync,
                  observation,
                  candidate,
                  :label_metadata_conflict,
                  %{},
                  options
                )

              nil ->
                recover_local_label_identity(
                  operation,
                  sync,
                  observation,
                  candidate,
                  write_token,
                  repository,
                  options
                )
            end
          end
        end)
      end

    case result do
      {:error, reason} -> PullMergeBoundary.defer(operation, now, next(now), reason)
      other -> other
    end
  end

  defp recover_local_label_identity(
         operation,
         sync,
         _observation,
         candidate,
         write_token,
         repository,
         options
       ) do
    observed =
      callback(options, :get_label, &LabelClient.get_label/5).(
        write_token,
        sync.routing.base.owner,
        sync.routing.base.repository,
        label_fields(candidate)["name"],
        request_options(sync, options)
      )

    with :ok <- local_label_preflight(operation, options),
         {:ok, ^repository} <- relationship_repository(sync, write_token, options),
         :ok <- local_label_preflight(operation, options),
         {:ok, fresh_observation} <-
           refresh_merge_observation(operation, sync, write_token, options) do
      case observed do
        {:ok, remote_label} ->
          if canonical_provider_label(remote_label) == label_fields(candidate) do
            confirm_local_label(
              operation,
              sync,
              fresh_observation,
              candidate,
              remote_label,
              options
            )
          else
            conflict_local_label(
              operation,
              sync,
              fresh_observation,
              candidate,
              :ambiguous_label_create,
              remote_label,
              options
            )
          end

        {:error, %Error{kind: :not_found}} ->
          conflict_local_label(
            operation,
            sync,
            fresh_observation,
            candidate,
            :ambiguous_label_create,
            %{},
            options
          )

        {:error, _} = error ->
          error

        _ ->
          {:error, :invalid_remote_result}
      end
    end
  end

  defp confirm_local_label(
         operation,
         sync,
         observation,
         candidate,
         remote_label,
         options
       ) do
    request = %{
      repository_id: sync.repository_id,
      local_resource_id: candidate.local_resource_id,
      expected_fields: label_fields(candidate)
    }

    request =
      if operation.external_effect_marker["phase"] == "metadata_label_pending",
        do: Map.put(request, :minimum_local_version, candidate.local_version),
        else: Map.put(request, :expected_local_version, candidate.local_version)

    confirmation = %{
      github_object_id: remote_label["id"],
      github_node_id: remote_label["node_id"],
      confirmed_snapshot: label_fields(candidate)
    }

    result =
      callback(
        options,
        :confirm_merge_local_label,
        &ForgeMirrors.confirm_pull_merge_local_label/7
      ).(
        operation,
        DateTime.utc_now(:second),
        sync.intent,
        observation,
        candidate,
        confirmation,
        fn multi -> ForgeIssues.append_sync_label_observe(multi, :resource, request) end
      )

    case result do
      {:ok, %{operation: yielded}} ->
        {:ok, yielded}

      {:error, :identity_conflict} ->
        conflict_local_label(
          operation,
          sync,
          observation,
          candidate,
          :label_identity_conflict,
          remote_label,
          options
        )

      {:error, :label_metadata_conflict} = error ->
        if match?(%{"phase" => "metadata_label_pending"}, operation.external_effect_marker) do
          conflict_local_label(
            operation,
            sync,
            observation,
            candidate,
            :label_metadata_conflict,
            remote_label,
            options
          )
        else
          error
        end

      other ->
        other
    end
  end

  defp conflict_local_label(
         operation,
         sync,
         observation,
         candidate,
         kind,
         remote_label,
         options
       ) do
    callback(
      options,
      :conflict_merge_local_label,
      &ForgeMirrors.conflict_pull_merge_local_label/7
    ).(
      operation,
      DateTime.utc_now(:second),
      sync.intent,
      observation,
      candidate,
      kind,
      Map.take(remote_label, ~w(id node_id name color description))
    )
    |> case do
      {:ok, %{operation: yielded}} -> {:ok, yielded}
      other -> other
    end
  end

  defp refresh_merge_observation(operation, sync, token, options) do
    with {:ok, remote} <- observe(sync, :base, token, options),
         {:ok, pair} <- pair(sync, token, options),
         {:ok, observation} <- merge_observation(operation, sync, pair, remote.oid) do
      {:ok, observation}
    end
  end

  defp local_label_preflight(operation, options) do
    callback(
      options,
      :merge_local_label_preflight,
      &ForgeMirrors.pull_merge_local_label_preflight/2
    ).(operation, DateTime.utc_now(:second))
    |> case do
      {:ok, _context} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_label_effect}
    end
  end

  defp defer_local_label_error(operation, {:error, reason}) do
    now = DateTime.utc_now(:second)
    PullMergeBoundary.defer(operation, now, next(now), reason)
  end

  defp defer_local_label_error(_operation, result), do: result

  defp label_fields(%{fields: fields}), do: fields

  defp label_fields(candidate),
    do: %{
      "name" => candidate.name,
      "color" => String.downcase(candidate.color),
      "description" => candidate.description
    }

  defp canonical_provider_label(observed) do
    description = observed["description"]

    %{
      "name" => observed["name"],
      "color" => if(is_binary(observed["color"]), do: String.downcase(observed["color"])),
      "description" =>
        if(is_binary(description) and String.trim(description) == "", do: nil, else: description)
    }
  end

  defp mark_and_apply_metadata(
         operation,
         sync,
         observation,
         local,
         target_issue,
         read_token,
         options,
         effect_count
       ) do
    if effect_count >= @max_metadata_effects do
      PullMergeBoundary.defer(
        operation,
        DateTime.utc_now(:second),
        next(DateTime.utc_now(:second)),
        :merge_metadata_effect_limit
      )
    else
      now = DateTime.utc_now(:second)

      with {:ok, marked} <-
             PullMergeMetadataEffects.mark(
               operation,
               now,
               sync.intent,
               observation,
               local.local_version,
               target_issue
             ) do
        apply_marked_metadata(
          marked.operation,
          sync,
          marked,
          read_token,
          options,
          effect_count
        )
      end
    end
  end

  defp apply_marked_metadata(operation, sync, context, read_token, options, effect_count) do
    now = DateTime.utc_now(:second)

    result =
      case prepare_metadata_nodes(operation, now, sync, read_token, context, options) do
        {:ok, :ready} ->
          mutate_marked_metadata(
            operation,
            sync,
            context,
            read_token,
            options,
            effect_count,
            now
          )

        {:ok, %MirrorOperation{} = yielded} ->
          {:ok, yielded}

        {:error, _} = error ->
          error
      end

    case result do
      {:error, reason} -> PullMergeBoundary.defer(operation, now, next(now), reason)
      other -> other
    end
  end

  defp mutate_marked_metadata(
         operation,
         sync,
         context,
         read_token,
         options,
         effect_count,
         now
       ) do
    with {:ok, write_token} <- metadata_write_token(sync, options),
         {:ok, current} <- PullMergeMetadataEffects.recovery_context(operation, now),
         true <- metadata_intent(current).id == metadata_intent(context).id,
         {:ok, attrs} <- metadata_effect_attrs(operation, sync, write_token, current, options) do
      case pre_patch_metadata_state(operation, sync, read_token, current, options) do
        {:yielded, %MirrorOperation{} = yielded} ->
          {:ok, yielded}

        {:ok, :preimage} ->
          with {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
               true <- metadata_intent(fresh).id == metadata_intent(current).id,
               {:ok, _untrusted} <-
                 callback(options, :update_pull_issue, &IssueClient.update_pull_issue/6).(
                   write_token,
                   sync.routing.base.owner,
                   sync.routing.base.repository,
                   sync.expected.provider_identity["github_number"],
                   attrs,
                   request_options(sync, options)
                 ) do
            confirm_metadata_effect(
              operation,
              sync,
              metadata_intent(current).id,
              read_token,
              options,
              effect_count + 1
            )
          else
            false -> {:error, :stale_merge_identity}
            {:error, _} = error -> error
            _ -> {:error, :invalid_remote_result}
          end

        {:ok, {:applied, pair, observation, fresh}} ->
          continue_after_applied_effect(
            operation,
            sync,
            pair,
            observation,
            fresh,
            read_token,
            options,
            effect_count
          )

        {:conflict, observation} ->
          PullMergeConfirmation.record_ambiguous_effect(operation, now, next(now), observation)

        {:error, _} = error ->
          error
      end
    else
      false -> {:error, :stale_merge_identity}
      {:error, _} = error -> error
      _ -> {:error, :invalid_remote_result}
    end
  end

  defp prepare_metadata_nodes(operation, now, sync, token, context, options) do
    payload = metadata_intent(context).payload

    if relationship_effect?(payload) do
      with {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
           true <- metadata_intent(fresh).id == metadata_intent(context).id do
        prepare_assignee_node(operation, now, sync, token, fresh, options)
      else
        false -> {:error, :stale_merge_identity}
        {:error, _} = error -> error
      end
    else
      {:ok, :ready}
    end
  end

  defp prepare_assignee_node(operation, now, sync, token, context, options) do
    if metadata_intent(context).payload["target_issue"]["assignee_github_ids"] == [] do
      prepare_label_nodes(operation, now, sync, token, context, options)
    else
      with {:ok, proof} <-
             callback(
               options,
               :merge_assignee_node_context,
               &ForgeMirrors.pull_merge_assignee_node_context/2
             ).(operation, now) do
        case proof.target do
          nil ->
            prepare_label_nodes(operation, now, sync, token, context, options)

          target ->
            with {:ok, user} <-
                   callback(options, :get_relationship_user, &IdentityClient.get_user/3).(
                     token,
                     target.github_user_id,
                     request_options(sync, options)
                   ),
                 {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
                 true <- metadata_intent(fresh).id == metadata_intent(context).id,
                 {:ok, saved} <-
                   callback(
                     options,
                     :seed_merge_assignee_node,
                     &ForgeMirrors.seed_pull_merge_assignee_node/4
                   ).(
                     operation,
                     now,
                     Map.take(proof, [:marker, :target]),
                     Map.from_struct(user)
                   ) do
              {:ok, saved.operation}
            else
              false -> {:error, :stale_merge_identity}
              {:error, _} = error -> error
            end
        end
      end
    end
  end

  defp prepare_label_nodes(operation, now, sync, token, context, options) do
    if metadata_intent(context).payload["target_issue"]["label_github_ids"] == [] do
      {:ok, :ready}
    else
      with {:ok, proof} <-
             callback(
               options,
               :merge_label_node_context,
               &ForgeMirrors.pull_merge_label_node_context/2
             ).(operation, now) do
        case proof.status do
          :ready ->
            {:ok, :ready}

          :unavailable ->
            case PullMergeConfirmation.record_relationship_unavailable(
                   operation,
                   now,
                   next(now)
                 ) do
              {:ok, yielded} -> {:ok, yielded}
              {:error, _} = error -> error
            end

          :scanning ->
            with {:ok, repository} <- relationship_repository(sync, token, options),
                 {:ok, page} <-
                   callback(
                     options,
                     :list_relationship_labels,
                     &LabelClient.list_labels_page/5
                   ).(
                     token,
                     sync.routing.base.owner,
                     sync.routing.base.repository,
                     proof.checkpoint["page"],
                     request_options(sync, options)
                   ),
                 {:ok, ^repository} <- relationship_repository(sync, token, options),
                 {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
                 true <- metadata_intent(fresh).id == metadata_intent(context).id,
                 {:ok, saved} <-
                   callback(
                     options,
                     :seed_merge_label_nodes,
                     &ForgeMirrors.seed_pull_merge_label_nodes/4
                   ).(
                     operation,
                     now,
                     Map.take(proof, [:marker, :targets, :checkpoint]),
                     Map.put(page, :repository, repository)
                   ) do
              {:ok, saved.operation}
            else
              false -> {:error, :stale_merge_identity}
              {:error, _} = error -> error
            end
        end
      end
    end
  end

  defp relationship_repository(sync, token, options) do
    callback(options, :get_relationship_repository, &default_relationship_repository/3).(
      sync,
      token,
      options
    )
  end

  defp default_relationship_repository(sync, token, options) do
    expected = sync.expected.provider_identity["base_repository"]

    with {:ok, repository} <-
           Client.repository(
             token,
             sync.routing.base.owner,
             sync.routing.base.repository,
             request_options(sync, options)
           ),
         true <-
           repository.id == expected["id"] and repository.node_id == expected["node_id"] and
             repository.full_name ==
               sync.routing.base.owner <> "/" <> sync.routing.base.repository do
      {:ok, %{github_object_id: repository.id, github_node_id: repository.node_id}}
    else
      {:error, _} = error -> error
      _ -> {:error, :identity_conflict}
    end
  end

  defp metadata_effect_attrs(operation, sync, token, context, options) do
    payload = metadata_intent(context).payload
    expected = payload["expected_remote_issue"]
    target = payload["target_issue"]

    scalars =
      Map.new(~w(title body), &{&1, target[&1]})
      |> Enum.reject(fn {field, value} -> expected[field] == value end)
      |> Map.new()

    if relationship_effect?(payload) do
      with {:ok, labels, assignees} <- relationship_nodes(sync, target),
           {:ok, resolved} <-
             resolve_relationship_names(operation, sync, token, labels, assignees, options) do
        relationships =
          %{}
          |> maybe_relationship_attr(
            "labels",
            expected["label_github_ids"],
            target["label_github_ids"],
            Enum.map(resolved.labels, & &1.name)
          )
          |> maybe_relationship_attr(
            "assignees",
            expected["assignee_github_ids"],
            target["assignee_github_ids"],
            Enum.map(resolved.assignees, & &1.login)
          )

        {:ok, Map.merge(scalars, relationships)}
      end
    else
      {:ok, scalars}
    end
  end

  defp resolve_relationship_names(_operation, _sync, _token, [], [], _options),
    do: {:ok, %{labels: [], assignees: []}}

  defp resolve_relationship_names(operation, sync, token, labels, assignees, options) do
    callback(options, :resolve_relationships, &RelationshipClient.resolve/5).(
      token,
      %{
        github_object_id: sync.expected.provider_identity["base_repository"]["id"],
        github_node_id: sync.expected.provider_identity["base_repository"]["node_id"]
      },
      labels,
      assignees,
      relationship_request_options(operation, sync, options)
    )
  end

  defp relationship_nodes(sync, target) do
    label_ids = target["label_github_ids"]
    assignee_ids = target["assignee_github_ids"]

    labels =
      Repo.all(
        from m in ForgeMirrors.MirrorResourceState,
          where:
            m.repository_mirror_id == ^sync.repository_mirror_id and
              m.resource_kind == :label and m.state == :confirmed and
              m.github_object_id in ^label_ids,
          order_by: m.github_object_id,
          select: %{github_object_id: m.github_object_id, github_node_id: m.github_node_id}
      )

    assignees =
      Repo.all(
        from identity in ForgeAccounts.GitHubIdentity,
          where: identity.kind == :user and identity.github_user_id in ^assignee_ids,
          order_by: identity.github_user_id,
          select: %{
            github_user_id: identity.github_user_id,
            github_node_id: identity.github_node_id
          }
      )

    if Enum.map(labels, & &1.github_object_id) == label_ids and
         Enum.map(assignees, & &1.github_user_id) == assignee_ids and
         Enum.all?(
           labels ++ assignees,
           &(is_binary(&1.github_node_id) and &1.github_node_id != "")
         ),
       do: {:ok, labels, assignees},
       else: {:error, :relationship_prerequisite}
  end

  defp relationship_request_options(operation, sync, options) do
    deadline =
      System.monotonic_time(:millisecond) +
        DateTime.diff(operation.lease_expires_at, DateTime.utc_now(), :millisecond) - 2_000

    request_options(sync, options)
    |> Keyword.put(:deadline_monotonic_ms, deadline)
  end

  defp maybe_relationship_attr(attrs, _field, same, same, _values), do: attrs

  defp maybe_relationship_attr(attrs, field, _before, _target, values),
    do: Map.put(attrs, field, values)

  defp relationship_effect?(payload) do
    before = payload["expected_remote_issue"]
    target = payload["target_issue"]

    Enum.any?(~w(label_github_ids assignee_github_ids), &(before[&1] != target[&1]))
  end

  defp pre_patch_metadata_state(operation, sync, read_token, context, options) do
    expected_id = metadata_intent(context).id

    with {:ok, before_ref} <-
           PullMergeMetadataEffects.recovery_context(operation, DateTime.utc_now(:second)),
         true <- metadata_intent(before_ref).id == expected_id,
         {:ok, remote} <- observe(sync, :base, read_token, options),
         {:ok, before_pair} <-
           PullMergeMetadataEffects.recovery_context(operation, DateTime.utc_now(:second)),
         true <- metadata_intent(before_pair).id == expected_id,
         {:ok, pair} <- pair(sync, read_token, options),
         {:ok, observation} <- merge_observation(operation, sync, pair, remote.oid),
         {:ok, fresh} <-
           PullMergeMetadataEffects.recovery_context(operation, DateTime.utc_now(:second)),
         true <- metadata_intent(fresh).id == expected_id do
      case classify_metadata_recovery(fresh, observation) do
        {:ok, %{status: :applied}} ->
          {:ok, {:applied, pair, observation, fresh}}

        {:ok, %{status: :not_applied}} ->
          if retained_metadata_timestamps?(fresh.marker, observation),
            do: {:ok, :preimage},
            else: {:conflict, observation}

        {:conflict, :ambiguous_external_effect, _} ->
          {:conflict, observation}

        {:error, _} = error ->
          error
      end
    else
      {:yielded, %MirrorOperation{} = yielded} ->
        {:yielded, yielded}

      {:conflict, :ambiguous_external_effect, observation} ->
        {:conflict, observation}

      false ->
        {:error, :stale_merge_identity}

      {:error, _} = error ->
        error
    end
  end

  defp confirm_metadata_effect(
         operation,
         sync,
         expected_metadata_intent_id,
         read_token,
         options,
         effect_count
       ) do
    with {:ok, before_ref} <-
           PullMergeMetadataEffects.recovery_context(operation, DateTime.utc_now(:second)),
         true <- metadata_intent(before_ref).id == expected_metadata_intent_id,
         {:ok, remote} <- observe(sync, :base, read_token, options),
         {:ok, before_pair} <-
           PullMergeMetadataEffects.recovery_context(operation, DateTime.utc_now(:second)),
         true <- metadata_intent(before_pair).id == expected_metadata_intent_id,
         {:ok, pair} <- pair(sync, read_token, options),
         {:ok, observation} <- merge_observation(operation, sync, pair, remote.oid),
         {:ok, context} <-
           PullMergeMetadataEffects.recovery_context(operation, DateTime.utc_now(:second)),
         true <- metadata_intent(context).id == expected_metadata_intent_id,
         {:ok, classification} <- classify_metadata_recovery(context, observation) do
      case classification.status do
        :applied ->
          continue_after_applied_effect(
            operation,
            sync,
            pair,
            observation,
            context,
            read_token,
            options,
            effect_count
          )

        :not_applied ->
          PullMergeBoundary.defer(
            operation,
            DateTime.utc_now(:second),
            next(DateTime.utc_now(:second)),
            :remote_confirmation_required
          )
      end
    else
      {:yielded, %MirrorOperation{} = yielded} ->
        {:ok, yielded}

      {:conflict, :ambiguous_external_effect, observation} ->
        now = DateTime.utc_now(:second)
        PullMergeConfirmation.record_ambiguous_effect(operation, now, next(now), observation)

      {:error, reason} ->
        now = DateTime.utc_now(:second)
        PullMergeBoundary.defer(operation, now, next(now), reason)

      false ->
        now = DateTime.utc_now(:second)
        PullMergeBoundary.defer(operation, now, next(now), :stale_merge_identity)
    end
  end

  defp retained_metadata_timestamps?(marker, observation) do
    marker["expected_remote_updated_at"] ==
      DateTime.to_iso8601(observation.pull.remote_updated_at) and
      marker["expected_remote_issue_updated_at"] ==
        DateTime.to_iso8601(observation.issue.remote_updated_at)
  end

  defp merge_observation(operation, sync, pair, remote_base_oid) do
    now = DateTime.utc_now(:second)

    with {:ok, label} <- PullMergeObservation.label_candidate(sync, pair, remote_base_oid) do
      case label do
        %{status: :ready} ->
          with {:ok, profiles} <-
                 PullMergeObservation.assignee_profiles(sync, pair, remote_base_oid),
               {:ok, context} <- PullMergeRemoteAssigneeObservation.context(operation, now),
               expected = Map.take(context, [:marker, :coordinator_intent, :metadata_intent]),
               validation = fn ->
                 case PullMergeObservation.label_candidate(sync, pair, remote_base_oid) do
                   {:ok, %{status: :ready, observation: observation}} -> {:ok, observation}
                   {:ok, %{status: :missing}} -> {:error, :merge_metadata_unconfirmed}
                   {:error, _} = error -> error
                 end
               end,
               {:ok, %{validation: observation}} <-
                 PullMergeRemoteAssigneeObservation.observe(
                   operation,
                   now,
                   expected,
                   profiles,
                   validation
                 ) do
            {:ok, observation}
          end

        %{status: :missing, candidate: candidate, observation: observation} ->
          import_remote_label(operation, now, sync, observation, candidate)
      end
    end
  end

  defp import_remote_label(operation, now, sync, observation, candidate) do
    result =
      PullSyncWorker.with_merge_ref_fences(sync.git_proof, sync.intent.merge_oid, fn ->
        PullMergeRemoteLabelObservation.import(
          operation,
          now,
          sync.intent,
          observation,
          candidate,
          fn multi ->
            ForgeIssues.append_sync_label_import(multi, :resource, %{
              repository_id: sync.repository_id,
              fields: %{
                "name" => candidate.name,
                "color" => candidate.color,
                "description" => candidate.description
              },
              provenance: %{origin: :github, correlation_id: "merge-#{operation.id}"}
            })
          end
        )
      end)

    case result do
      {:ok, %{operation: %MirrorOperation{} = yielded}} ->
        {:yielded, yielded}

      {:error, :ambiguous_external_effect} ->
        {:conflict, :ambiguous_external_effect, observation}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_label_observation}
    end
  end

  defp metadata_timestamps_nonregressed?(marker, observation) do
    with {:ok, pull_time, 0} <- DateTime.from_iso8601(marker["expected_remote_updated_at"]),
         {:ok, issue_time, 0} <-
           DateTime.from_iso8601(marker["expected_remote_issue_updated_at"]) do
      DateTime.compare(observation.pull.remote_updated_at, pull_time) != :lt and
        DateTime.compare(observation.issue.remote_updated_at, issue_time) != :lt
    else
      _ -> false
    end
  end

  defp merge_target_issue(target) do
    target
    |> Map.take(~w(title body label_github_ids assignee_github_ids))
    |> Map.merge(%{"state" => "closed", "state_reason" => "completed"})
  end

  defp metadata_intent(%{metadata_intent: intent}) when not is_nil(intent), do: intent
  defp metadata_intent(%{intent: intent}), do: intent

  defp metadata_decision(operation, sync, observation) do
    with {:ok, context} <- PullMergeConfirmation.context(operation, DateTime.utc_now(:second)),
         {:ok, local} <-
           ForgePulls.sync_projection(sync.repository_id, :pull, sync.expected.pull_id),
         {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             sync.repository_mirror_id,
             :local,
             local.label_ids,
             local.assignee_refs
           ) do
      local_issue =
        Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
          "label_github_ids" => Enum.sort(Enum.map(relationships.labels, & &1.github_object_id)),
          "assignee_github_ids" =>
            Enum.sort(Enum.map(relationships.assignees, & &1.github_user_id))
        })

      case PullMetadataDecision.decide_merge(
             context.pull.confirmed_snapshot,
             local.fields,
             observation.pull.confirmed_snapshot,
             context.issue.confirmed_snapshot,
             local_issue,
             observation.issue.confirmed_snapshot
           ) do
        {:ok, plan} -> {:ok, plan, local}
        other -> other
      end
    end
  end

  defp confirm_merge(operation, sync, pair, observation, metadata_request) do
    options = [
      authorize: fn intent ->
        with :ok <-
               PullMergeConfirmation.authorize(
                 operation,
                 DateTime.utc_now(:second),
                 intent,
                 observation
               ),
             {:ok, ^observation} <-
               PullMergeObservation.build(sync, pair, observation.remote_base_oid) do
          :ok
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_merge_observation}
        end
      end,
      confirm: fn projection, intent ->
        PullMergeConfirmation.confirm(
          operation,
          DateTime.utc_now(:second),
          intent,
          observation,
          projection
        )
      end
    ]

    options =
      if is_nil(metadata_request),
        do: options,
        else: Keyword.put(options, :metadata_request, metadata_request)

    with {:ok, merged_at, 0} <-
           DateTime.from_iso8601(observation.pull.confirmed_merge_state["merged_at"]),
         {:ok, result} <-
           ForgePulls.finalize_coordinated_merge(sync.intent.id, operation.id, merged_at, options) do
      {:ok, result.confirmation.operation}
    end
  end

  defp push(operation, now, sync, token, options) do
    with :ok <- local_refs(sync),
         :ok <- provider_ready(sync, token, options),
         {:ok, marked} <-
           PullMergeBoundary.mark(
             operation,
             now,
             operation.external_effect_marker,
             marker(sync.intent)
           ) do
      case lfs(marked, sync, token, options) do
        :ok ->
          # Remote.push_refs owns its own repository fence; nesting it under
          # with_ref_fences would deadlock its supervised transport task.
          with {:ok, _} <-
                 PullMergeBoundary.authorize_external_effect(
                   marked,
                   marked.external_effect_marker,
                   DateTime.utc_now(:second)
                 ),
               :ok <- local_refs(sync),
               :ok <- provider_ready(sync, token, options) do
            execute(marked, now, sync, token, options)
          else
            {:error, reason} -> PullMergeBoundary.defer(marked, now, next(now), reason)
          end

        {:incomplete, checkpoint} ->
          PullMergeBoundary.checkpoint_lfs(marked, now, checkpoint)

        {:error, reason} ->
          PullMergeBoundary.defer(marked, now, next(now), reason)
      end
    else
      {:error, _} = error ->
        error
    end
  end

  defp execute(marked, now, sync, _token, options) do
    # Recheck after marking: a slow LFS scan or provider request can outlive
    # the lease or installation permission that initially admitted the claim.
    with {:ok, _} <- PullMergeBoundary.context(marked, now),
         {:ok, push_token} <- push_token(sync, options),
         {:ok, _} <- PullMergeBoundary.context(marked, now) do
      update = %RefUpdate{
        ref: sync.intent.base_ref,
        expected_oid: sync.intent.expected_base_oid,
        proposed_oid: sync.intent.merge_oid
      }

      transport_options = [
        heartbeat: fn ->
          case PullMergeBoundary.context(marked, DateTime.utc_now(:second)) do
            {:ok, _} -> :ok
            {:error, _} -> :error
          end
        end
      ]

      result =
        callback(options, :push_remote, &GitCore.Remote.push_refs/4).(
          request(sync),
          push_token,
          [update],
          transport_options
        )

      reason =
        case result do
          :ok -> :remote_confirmation_required
          {:ok, _} -> :remote_confirmation_required
          {:error, reason} -> reason
          _ -> :invalid_remote_result
        end

      PullMergeBoundary.defer(marked, now, next(now), reason)
    else
      {:error, reason} -> PullMergeBoundary.defer(marked, now, next(now), reason)
    end
  end

  defp execution_context(context) do
    with true <- context.intent.state == "merge_written",
         base when not is_nil(base) <- Repo.get(RepositoryMirror, context.repository_mirror_id),
         head when not is_nil(head) <-
           Repo.get(
             RepositoryMirror,
             context.expected.pull_eligibility_proof["head"]["repository_mirror_id"]
           ),
         {:ok, repository} <- ForgeRepos.fetch_live_repository(context.repository_id),
         organization when not is_nil(organization) <-
           Repo.get(OrganizationMirror, context.organization_mirror_id),
         {:ok, base_route} <- route(base),
         {:ok, head_route} <- route(head) do
      {:ok,
       Map.merge(context, %{
         routing: %{base: base_route, head: head_route},
         repository_path: ForgeRepos.absolute_storage_path(repository),
         repository_generation: repository.generation,
         remote_owner: base_route.owner,
         remote_repository: base_route.repository,
         ref_name: context.intent.base_ref,
         ref_kind: :branch,
         lfs_enabled: organization.capabilities["lfs"] in [true, "enabled", "active"],
         git_proof:
           Map.new([:base, :head], fn side ->
             proof = context.expected.pull_eligibility_proof[Atom.to_string(side)]

             {side,
              %{
                repository_id: proof["repository_id"],
                repository_generation: proof["repository_generation"],
                ref: proof["ref"],
                oid: proof["oid"]
              }}
           end)
       })}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp route(binding) do
    case String.split(binding.github_full_name || "", "/") do
      [owner, repository] when owner != "" and repository != "" ->
        {:ok, %{owner: owner, repository: repository}}

      _ ->
        {:error, :invalid_remote_repository}
    end
  end

  defp observe(sync, side, token, options) do
    route = sync.routing[side]
    repository = sync.expected.provider_identity[Atom.to_string(side) <> "_repository"]
    identity = %{github_object_id: repository["id"], github_node_id: repository["node_id"]}
    ref = if side == :base, do: sync.intent.base_ref, else: sync.intent.head_ref

    callback(options, :observe_ref, &RefObservation.observe/6).(
      token,
      route.owner,
      route.repository,
      identity,
      ref,
      request_options(sync, options)
    )
  end

  defp pair(sync, token, options) do
    route = sync.routing.base
    number = sync.expected.provider_identity["github_number"]
    opts = request_options(sync, options)

    with {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             route.owner,
             route.repository,
             number,
             opts
           ),
         {:ok, issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             route.owner,
             route.repository,
             number,
             opts
           ),
         true <-
           pull["id"] == sync.provider_pull_identity["id"] and
             pull["node_id"] == sync.provider_pull_identity["node_id"] and
             pull["number"] == number,
         true <-
           issue["id"] == sync.expected.provider_identity["github_issue_object_id"] and
             issue["node_id"] == sync.expected.provider_identity["github_issue_node_id"] and
             issue["number"] == number,
         true <-
           Enum.all?([:base, :head], fn side ->
             name = Atom.to_string(side)
             observed = pull[name] || %{}
             expected = sync.expected.provider_identity[name <> "_repository"]
             ref = if side == :base, do: sync.intent.base_ref, else: sync.intent.head_ref

             observed["ref"] == String.replace_prefix(ref, "refs/heads/", "") and
               Map.take(observed["repo"] || %{}, ["id", "node_id"]) == expected
           end) do
      {:ok, %{pull: pull, issue: issue}}
    else
      {:error, _} = error -> error
      _ -> {:error, :provider_identity_conflict}
    end
  end

  defp open_pair(%{pull: pull, issue: issue}, sync) do
    if pull["state"] == "open" and issue["state"] == "open" and pull["draft"] == false and
         pull["merged"] == false and is_nil(pull["merged_at"]) and
         pull["head"]["sha"] == sync.intent.expected_head_oid and
         pull["base"]["sha"] == sync.intent.expected_base_oid,
       do: :ok,
       else: {:error, :changed_provider_pull}
  end

  defp provider_ready(sync, token, options) do
    with {:ok, base} <- observe(sync, :base, token, options),
         {:ok, head} <- observe(sync, :head, token, options),
         true <-
           base.oid == sync.intent.expected_base_oid and head.oid == sync.intent.expected_head_oid,
         {:ok, pair} <- pair(sync, token, options),
         :ok <- open_pair(pair, sync) do
      :ok
    else
      false -> {:error, :changed_remote_refs}
      {:error, _} = error -> error
    end
  end

  defp local_refs(sync), do: PullSyncWorker.with_ref_fences(sync.git_proof, fn -> :ok end)

  defp lfs(_operation, %{lfs_enabled: false}, _token, _options), do: :ok

  defp lfs(operation, sync, _token, options) do
    marker = operation.external_effect_marker

    authorize = fn ->
      case PullMergeBoundary.authorize_external_effect(
             operation,
             marker,
             DateTime.utc_now(:second)
           ) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    with :ok <- authorize.(),
         {:ok, token} <- push_token(sync, options),
         :ok <- authorize.() do
      callback(options, :lfs_gate, &LFSSync.ensure/7).(
        operation,
        sync,
        :outbound,
        sync.intent.merge_oid,
        token,
        request(sync),
        authorize: authorize
      )
    end
  end

  defp token(sync, options) do
    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           %{
             repository_ids:
               [
                 sync.expected.provider_identity["base_repository"]["id"],
                 sync.expected.provider_identity["head_repository"]["id"]
               ]
               |> Enum.uniq()
               |> Enum.sort(),
             permissions: %{
               "contents" => "read",
               "metadata" => "read",
               "pull_requests" => "read",
               "issues" => "read"
             }
           }
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, _} = error -> error
      _ -> {:error, :credential_unavailable}
    end
  end

  defp push_token(sync, options) do
    scope = %{
      repository_ids: [sync.expected.provider_identity["base_repository"]["id"]],
      permissions: %{"contents" => "write"}
    }

    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           scope
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, _} = error -> error
      _ -> {:error, :credential_unavailable}
    end
  end

  defp metadata_write_token(sync, options) do
    scope = %{
      repository_ids: [sync.expected.provider_identity["base_repository"]["id"]],
      permissions: %{"metadata" => "read", "pull_requests" => "write"}
    }

    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           scope
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, _} = error -> error
      _ -> {:error, :credential_unavailable}
    end
  end

  defp marker(intent),
    do: %{
      "phase" => "remote_cas_pending",
      "merge_operation_id" => intent.id,
      "merge_tree_oid" => intent.merge_tree_oid,
      "merge_oid" => intent.merge_oid
    }

  defp request(sync),
    do: %SyncRequest{
      provider: :github,
      owner: sync.remote_owner,
      repository: sync.remote_repository,
      credential_login: "x-access-token",
      repository_path: sync.repository_path
    }

  defp request_options(sync, options),
    do:
      options
      |> Keyword.get(:request_options, [])
      |> Keyword.put(:gate_key, {:github_installation, sync.github_installation_id})

  defp callback(options, key, default),
    do: if(@test_callbacks, do: Keyword.get(options, key, default), else: default)

  defp persist_unmarked_failure(operation, now, reason, options) do
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
    do: {:fail, "permission_missing", "GitHub denied pull-request merge synchronization"}

  defp failure(reason) when reason in [:revoked, :credential_unavailable],
    do: {:fail, "credential_revoked", "GitHub installation credential is unavailable"}

  defp failure(reason) when reason in [:busy, :timeout, :unavailable, :worker_crash],
    do: {:retry, "network", nil}

  defp failure(_reason), do: {:fail, "local_validation", "coordinated merge state is invalid"}

  defp bounded_option(options, key, default, minimum, maximum) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value >= minimum and value <= maximum -> value
      _invalid -> raise ArgumentError, "invalid #{key}"
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
  defp config(key, default), do: Application.get_env(:forge_github, key, default)
  defp next(now), do: DateTime.add(now, 1, :second)
end
