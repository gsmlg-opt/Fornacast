defmodule ForgeGitHub.PullSyncWorker do
  @moduledoc """
  Bounded synchronization for mapped pulls and authenticated pull creation.

  Outbound creation uses its own durable intent and recovery coordinator. This
  worker still excludes ref retargeting, merging, deletion, and reconciliation
  sweeps. GitHub issue metadata and draft
  conversion are separate durable effects. Every effect and confirmation is
  guarded by the same persisted pull/ref eligibility proof.
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
    PullClient,
    PullMetadataDecision,
    PullMetadataRecovery,
    RelationshipClient,
    PullSyncProjection
  }

  alias ForgeMirrors.{MirrorOperation, PullEligibility, ResourceDecision}

  @operation_kinds ["sync.pull", "reconcile.repository.pull_heads"]
  @mutable_fields ~w(title body state state_reason draft)
  @issue_fields ~w(title body state state_reason)
  @ref_fields ~w(head_ref head_sha base_ref base_sha)
  @default_interval_ms 1_000
  @default_lease_seconds 60
  @default_batch_size 4
  @default_max_concurrency 2
  @default_processor_timeout_ms 50_000
  @lease_margin_ms 5_000
  @test_client_options Mix.env() == :test

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
        config(:pull_sync_worker_max_concurrency, @default_max_concurrency),
        1,
        8
      )

    processor_timeout_ms =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:pull_sync_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_599_000
      )

    unless processor_timeout_ms <= lease_seconds * 1_000 - @lease_margin_ms do
      raise ArgumentError, "pull sync processor timeout must finish inside its lease"
    end

    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, lease_seconds, min(batch_size, max_concurrency), @operation_kinds) do
      supervisor = Keyword.get(options, :task_supervisor, ForgeGitHub.IssueSyncTaskSupervisor)

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
  @spec process_operation(MirrorOperation.t(), DateTime.t(), keyword()) :: term()
  def process_operation(
        %MirrorOperation{kind: "reconcile.repository.pull_heads", state: :processing} = operation,
        %DateTime{} = now,
        options
      )
      when is_list(options) do
    callback(options, :reconcile_pull_heads, &ForgeMirrors.reconcile_pull_head_page/2).(
      operation,
      now
    )
  end

  def process_operation(
        %MirrorOperation{kind: "sync.pull", state: state} = operation,
        %DateTime{} = now,
        options
      )
      when state in [:processing, :effect_pending] and is_list(options) do
    with {:ok, sync} <- context(operation, options) do
      case Map.get(sync, :mode) do
        :unsupported_head ->
          reevaluate_unsupported_head(operation, now, sync, options)

        :mapped_label_recovery ->
          recover_mapped_local_label(operation, now, sync, options)

        :inbound_create ->
          create_inbound(operation, now, sync, options)

        :outbound_create ->
          case callback(
                 options,
                 :outbound_create,
                 &ForgeGitHub.PullCreateWorker.process_operation/4
               ).(
                 operation,
                 now,
                 sync,
                 options
               ) do
            {:unmarked_error, reason} when operation.state == :processing ->
              persist_failure(operation, now, reason, options)

            result ->
              result
          end

        _ ->
          process_mapped(operation, now, sync, options)
      end
    else
      {:error,
       {:label_metadata_conflict,
        %{operation: persisted, sync: sync, marker: marker, resource: resource}}} ->
        # Only the dedicated boundary supplies this evidence, after verifying
        # persisted marker, paired mappings, ownership and the final live lease.
        # The intended label is not represented as an observed remote result.
        baseline = %{"pull" => sync.baseline, "intended_label" => marker["proposed_snapshot"]}

        conflict(
          persisted,
          now,
          %{sync | baseline: baseline},
          :label_metadata_conflict,
          %{"label" => if(resource, do: resource.fields)},
          %{"unresolved_label_effect" => true},
          options
        )

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  rescue
    _exception -> persist_failure(operation, now, :worker_crash, options)
  catch
    _kind, _reason -> persist_failure(operation, now, :worker_crash, options)
  end

  def process_operation(%MirrorOperation{} = operation, %DateTime{} = now, options)
      when is_list(options),
      do: persist_failure(operation, now, :unsupported_operation, options)

  defp process_mapped(operation, now, sync, options) do
    with {:ok, token} <- installation_token(sync, options),
         {:ok, local} <- local_observation(sync, options) do
      case local[:unmapped_label] do
        nil ->
          process_ready_mapped(operation, now, sync, token, local, options)

        candidate when operation.state == :processing ->
          materialize_mapped_local_label(operation, now, sync, token, local, candidate, options)

        _ ->
          persist_failure(operation, now, :unsupported_resource, options)
      end
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp process_ready_mapped(operation, now, sync, token, local, options) do
    with {:ok, remote, provider_identity, proof} <-
           observe_authorized(sync, token, local, now, options) do
      case precondition(sync, local, remote, provider_identity, proof) do
        :ok when operation.state == :effect_pending and is_map_key(sync, :metadata_intent) ->
          recover_pair_effect(
            operation,
            now,
            sync,
            token,
            local,
            remote,
            provider_identity,
            proof,
            0,
            options
          )

        :ok when operation.state == :effect_pending ->
          recover_effect(
            operation,
            now,
            sync,
            token,
            local,
            remote,
            provider_identity,
            proof,
            options
          )

        :ok when is_map_key(sync, :pair) ->
          reconcile_pair(
            operation,
            now,
            sync,
            token,
            local,
            remote,
            provider_identity,
            proof,
            options
          )

        :ok ->
          reconcile(
            operation,
            now,
            sync,
            token,
            local,
            remote,
            provider_identity,
            proof,
            false,
            0,
            options
          )

        {:conflict, kind} ->
          conflict(operation, now, sync, kind, local.snapshot, remote.snapshot, options)

        {:error, reason} ->
          persist_failure(operation, now, reason, options)
      end
    else
      {:error, {:pull_label_prerequisite, candidate, local, remote, identity, proof, git_proof}}
      when operation.state == :processing and is_map_key(sync, :pair) and
             not is_map_key(sync, :metadata_intent) ->
        import_mapped_label(
          operation,
          now,
          sync,
          candidate,
          local,
          remote,
          identity,
          proof,
          git_proof,
          options
        )

      {:error, {:pull_label_prerequisite, _, _, _, _, _, _}} ->
        persist_failure(operation, now, :unsupported_resource, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  @impl true
  def init(options) do
    interval_ms = Keyword.get(options, :interval_ms, @default_interval_ms)
    owner = Keyword.get_lazy(options, :owner, &Ecto.UUID.generate/0)
    enabled = Keyword.get(options, :enabled, config(:pull_sync_worker_enabled, false))
    run_options = Keyword.drop(options, [:interval_ms, :owner, :name, :enabled])

    if is_integer(interval_ms) and interval_ms > 0 and is_binary(owner) and is_boolean(enabled) do
      if enabled, do: schedule(0)
      {:ok, %{interval_ms: interval_ms, owner: owner, run_options: run_options, enabled: enabled}}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_info(:tick, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{enabled: true} = state) do
    _ = run_once(state.owner, state.run_options)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp context(operation, options),
    do: callback(options, :context, &default_context/1).(operation)

  defp default_context(operation) do
    if operation.state == :effect_pending and is_map(operation.external_effect_marker) and
         operation.external_effect_marker["action"] == "create_remote_label" do
      with {:ok, context} <- ForgeMirrors.mapped_pull_label_effect_context(operation) do
        {:ok,
         Map.merge(context.sync, %{mode: :mapped_label_recovery, label_resource: context.resource})}
      end
    else
      metadata_or_legacy_context(operation)
    end
  end

  defp metadata_or_legacy_context(operation) do
    if operation.state == :effect_pending and is_map(operation.external_effect_marker) and
         Map.has_key?(operation.external_effect_marker, "metadata_intent_id") do
      with {:ok, context} <- ForgeMirrors.mapped_pull_effect_context(operation) do
        {:ok, Map.put(context.sync, :metadata_intent, context.intent)}
      end
    else
      legacy_or_processing_context(operation)
    end
  end

  defp legacy_or_processing_context(%{state: :processing} = operation) do
    case ForgeMirrors.unsupported_pull_context(operation) do
      {:ok, context} ->
        {:ok, Map.merge(context.sync, %{mode: :unsupported_head, unsupported_context: context})}

      {:error, :unsupported_pull_unavailable} ->
        legacy_resource_context(operation)

      error ->
        error
    end
  end

  defp legacy_or_processing_context(operation), do: legacy_resource_context(operation)

  defp legacy_resource_context(operation) do
    case ForgeMirrors.resource_operation_context(operation) do
      {:error, :invalid_pull_mapping} ->
        missing_pull_context(operation)

      {:ok, _sync} when operation.state == :processing ->
        ForgeMirrors.mapped_pull_pair_context(operation)

      result ->
        result
    end
  end

  defp missing_pull_context(operation) do
    if operation.cursor["trigger"] == "local" do
      with {:ok, context} <- ForgeMirrors.outbound_pull_creation_context(operation),
           do: {:ok, Map.put(context, :mode, :outbound_create)}
    else
      ForgeMirrors.remote_pull_creation_context(operation)
    end
  end

  defp reevaluate_unsupported_head(operation, now, sync, options) do
    context = sync.unsupported_context

    with {:ok, token} <- installation_token(sync, options),
         {:ok, observed} <- unsupported_head_observation(sync, token, options) do
      if is_nil(context.provider_identity["head_repository"]) and
           not is_nil(observed.pull.provider_identity["head_repository"]) do
        ForgeMirrors.pin_unsupported_pull_head(operation, now, context.pair, observed)
      else
        with {:ok, head} <-
               ForgeMirrors.resolve_unsupported_pull_head(operation, context.pair, observed) do
          expected =
            Map.merge(Map.take(head, [:head_repository_id, :pull_eligibility_proof]), %{
              pair: context.pair
            })

          with_ref_fences(head.git_proof, fn ->
            ForgeMirrors.confirm_unsupported_pull_head(operation, now, expected, observed)
          end)
        end
      end
      |> case do
        {:error, reason} -> unsupported_head_failure(operation, now, reason, options)
        result -> result
      end
    else
      {:error, reason} -> unsupported_head_failure(operation, now, reason, options)
    end
  end

  defp unsupported_head_failure(operation, now, reason, options)
       when reason in [:identity_conflict, :invalid_observation, :inconsistent_observation],
       do: persist_failure(operation, now, :invalid_remote_resource, options)

  defp unsupported_head_failure(operation, now, reason, options),
    do: persist_failure(operation, now, reason, options)

  defp unsupported_head_observation(sync, token, options) do
    with {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options(sync)
           ),
         {:ok, issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options(sync)
           ),
         {:ok, scalar} <- inbound_preflight(pull, issue),
         {:ok, identity} <- provider_identity(scalar),
         {:ok, labels} <- observed_relationship_ids(issue["labels"]),
         {:ok, assignees} <- observed_relationship_ids(issue["assignees"]) do
      # Re-evaluation compares canonical provider ID sets without importing labels
      # or observing authors/assignees. The locked boundary proves continuity.
      {:ok,
       %{
         pull: %{
           github_object_id: scalar.github_object_id,
           github_node_id: scalar.github_node_id,
           github_number: scalar.github_number,
           remote_updated_at: scalar.remote_updated_at,
           confirmed_snapshot: scalar.snapshot,
           confirmed_merge_state: persistent_merge_state(scalar.merge_state),
           provider_identity: identity
         },
         issue: %{
           github_object_id: scalar.github_issue_object_id,
           github_node_id: scalar.github_issue_node_id,
           github_number: scalar.github_number,
           remote_updated_at: scalar.issue_remote_updated_at,
           confirmed_snapshot:
             Map.merge(
               Map.take(scalar.snapshot, @issue_fields),
               %{"label_github_ids" => labels, "assignee_github_ids" => assignees}
             )
         }
       }}
    end
  end

  defp observed_relationship_ids(values) when is_list(values) and length(values) <= 512 do
    if Enum.all?(values, &is_map/1) do
      ids = Enum.map(values, & &1["id"])

      if Enum.all?(ids, &(is_integer(&1) and &1 in 1..9_223_372_036_854_775_807)) and
           length(Enum.uniq(ids)) == length(ids),
         do: {:ok, Enum.sort(ids)},
         else: {:error, :invalid_remote_resource}
    else
      {:error, :invalid_remote_resource}
    end
  end

  defp observed_relationship_ids(_), do: {:error, :invalid_remote_resource}

  defp create_inbound(operation, now, sync, options) do
    with {:ok, token} <- installation_token(sync, options),
         {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options(sync)
           ),
         true <- pull["id"] == sync.github_object_id and pull["number"] == sync.github_number,
         true <-
           get_in(pull, ["base", "repo", "id"]) == sync.github_repository_id and
             get_in(pull, ["base", "repo", "node_id"]) == sync.github_repository_node_id,
         {:ok, raw_issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options(sync)
           ),
         {:ok, remote} <- inbound_preflight(pull, raw_issue),
         {:ok, identity} <- provider_identity(remote),
         {:ok, head} <-
           ForgeMirrors.resolve_remote_pull_head(
             operation,
             %{
               github_object_id: remote.github_object_id,
               github_node_id: remote.github_node_id,
               github_number: remote.github_number,
               provider_identity: identity
             },
             remote.snapshot
           ),
         {:ok, relationships} <- remote_relationships(sync, raw_issue, now, options),
         {:ok, issue} <- IssueSyncProjection.from_remote_issue(raw_issue, relationships),
         {:ok, remote} <- PullSyncProjection.from_remote(pull, issue),
         {:ok, author_id} <- inbound_author(issue),
         {:ok, local_relationships} <-
           IssueSyncProjection.local_relationships(
             issue.snapshot,
             issue.label_catalog,
             issue.assignee_catalog
           ),
         request = %{
           repository_id: sync.repository_id,
           resource_kind: :pull,
           head_repository_id: head.head_repository_id,
           author_github_identity_id: author_id,
           fields: remote.snapshot,
           merge_state: Map.take(remote.merge_state, [:merged_at, :merge_commit_sha]),
           inserted_at: remote.remote_created_at,
           updated_at: remote.remote_updated_at,
           local_label_ids: local_relationships.local_label_ids,
           assignee_refs: local_relationships.assignee_refs,
           provenance: provenance(sync, operation)
         },
         {:ok, merge_state} <- json_safe(request.merge_state),
         observation = %{
           pull: %{
             github_object_id: remote.github_object_id,
             github_node_id: remote.github_node_id,
             github_number: remote.github_number,
             remote_updated_at: remote.remote_updated_at,
             confirmed_snapshot: remote.snapshot,
             confirmed_merge_state: merge_state,
             provider_identity: identity
           },
           issue: %{
             github_object_id: issue.github_object_id,
             github_node_id: issue.github_node_id,
             github_number: issue.github_number,
             remote_updated_at: issue.remote_updated_at,
             confirmed_snapshot: issue.snapshot
           }
         },
         {:ok, result} <-
           with_ref_fences(head.git_proof, fn ->
             ForgeMirrors.confirm_remote_pull_creation(
               operation,
               now,
               Map.take(head, [:head_repository_id, :pull_eligibility_proof]),
               observation,
               &ForgePulls.append_sync_create(&1, :resource, request)
             )
           end) do
      {:ok, result}
    else
      false ->
        persist_failure(operation, now, :invalid_remote_resource, options)

      {:error, {:unmapped_label, candidate}} ->
        import_inbound_label(operation, now, sync, candidate, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp import_mapped_label(
         operation,
         now,
         sync,
         candidate,
         local,
         remote,
         identity,
         proof,
         git_proof,
         options
       ) do
    with {:ok, local_fingerprint} <- fingerprint(local.snapshot, options) do
      expected = %{
        pair: sync.pair,
        pull_precondition: %{
          "github_object_id" => remote.github_object_id,
          "github_node_id" => remote.github_node_id,
          "github_number" => remote.github_number,
          "resource_state_lock_version" => sync.resource_state_lock_version,
          "expected_local_version" => local.local_version,
          "expected_local_fingerprint" => local_fingerprint,
          "provider_identity" => identity,
          "pull_eligibility_proof" => proof,
          "expected_merge_state" => persistent_merge_state(local.merge_state)
        }
      }

      case with_ref_fences(git_proof, fn ->
             import_inbound_label(operation, now, sync, candidate, options, expected)
           end) do
        {:error, reason} when reason in [:namespace_collision, :identity_conflict] ->
          mapped_label_conflict(operation, now, sync, reason, candidate, local, remote, options)

        {:error, reason} ->
          persist_failure(operation, now, reason, options)

        result ->
          result
      end
    end
  end

  defp materialize_mapped_local_label(operation, now, sync, token, local, candidate, options) do
    with {:ok, label} <-
           ForgeIssues.label_sync_projection(sync.repository_id, candidate.local_label_id),
         {:ok, remote, identity, proof, git_proof} <-
           label_pull_preflight(sync, token, local, options),
         {:ok, repository} <- pair_repository_identity(sync, token, options) do
      result =
        LabelClient.get_label(
          token,
          sync.remote_owner,
          sync.remote_repository,
          label.fields["name"],
          pair_client_options(sync, options)
        )

      with {:ok, ^repository} <- pair_repository_identity(sync, token, options) do
        case result do
          {:ok, observed} ->
            if canonical_provider_label(observed) == label.fields do
              confirm_local_label(
                operation,
                now,
                sync,
                label,
                observed,
                local,
                remote,
                identity,
                proof,
                git_proof,
                options
              )
            else
              local_label_conflict(
                operation,
                now,
                sync,
                :label_namespace_collision,
                label.fields,
                observed,
                options
              )
            end

          {:error, %Error{kind: :not_found}} ->
            create_mapped_local_label(
              operation,
              now,
              sync,
              token,
              label,
              local,
              remote,
              identity,
              proof,
              git_proof,
              options
            )

          {:error, reason} ->
            persist_failure(operation, now, reason, options)
        end
      else
        {:error, reason} -> persist_failure(operation, now, reason, options)
      end
    else
      {:conflict, kind} -> conflict(operation, now, sync, kind, local.snapshot, %{}, options)
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp label_pull_preflight(sync, token, local, options) do
    with {:ok, git_proof} <- eligibility(sync, local, options),
         :ok <- git_availability(git_proof, options),
         {:ok, proof} <- json_safe(git_proof),
         {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options(sync)
           ),
         {:ok, issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options(sync)
           ),
         {:ok, remote} <- inbound_preflight(pull, issue),
         {:ok, identity} <- provider_identity(remote),
         :ok <- precondition(sync, local, remote, identity, proof),
         do: {:ok, remote, identity, proof, git_proof}
  end

  defp local_label_expected(operation, sync, label, local, remote, identity, proof) do
    {:ok, label_hash} = ForgeMirrors.resource_fingerprint(label.fields)
    {:ok, pull_hash} = ForgeMirrors.resource_fingerprint(local.snapshot)

    %{
      resource_state_lock_version: :missing,
      local_label_id: label.local_resource_id,
      expected_local_version: label.local_version,
      expected_local_fingerprint: label_hash,
      github_object_id: nil,
      effect_marker: operation.external_effect_marker,
      pair: sync.pair,
      pull_precondition: %{
        "github_object_id" => remote.github_object_id,
        "github_node_id" => remote.github_node_id,
        "github_number" => remote.github_number,
        "resource_state_lock_version" => sync.resource_state_lock_version,
        "expected_local_version" => local.local_version,
        "expected_local_fingerprint" => pull_hash,
        "provider_identity" => identity,
        "pull_eligibility_proof" => proof,
        "expected_merge_state" => persistent_merge_state(local.merge_state)
      }
    }
  end

  defp label_observe_request(sync, label) do
    %{
      repository_id: sync.repository_id,
      local_resource_id: label.local_resource_id,
      expected_local_version: label.local_version,
      expected_fields: label.fields
    }
  end

  defp create_mapped_local_label(
         operation,
         now,
         sync,
         token,
         label,
         local,
         remote,
         identity,
         proof,
         git_proof,
         options
       ) do
    expected = local_label_expected(operation, sync, label, local, remote, identity, proof)

    marker = %{
      "v" => 1,
      "action" => "create_remote_label",
      "resource_kind" => "label",
      "local_label_id" => label.local_resource_id,
      "expected_local_version" => label.local_version,
      "expected_local_fingerprint" => expected.expected_local_fingerprint,
      "expected_remote_absent" => true,
      "label_name" => label.fields["name"],
      "proposed_fingerprint" => expected.expected_local_fingerprint,
      "proposed_snapshot" => label.fields
    }

    request = label_observe_request(sync, label)

    result =
      with_ref_fences(git_proof, fn ->
        ForgeMirrors.mark_mapped_pull_label_effect(
          operation,
          now,
          expected,
          marker,
          &ForgeIssues.append_sync_label_observe(&1, :resource, request)
        )
      end)

    case result do
      {:ok, %{operation: marked}} ->
        # Every post-mark exit uses the marked capability. An ambiguous response
        # never sends this prerequisite through the original processing retry.
        try do
          with {:ok, _repository} <- pair_repository_identity(sync, token, options),
               {:ok, _context} <- ForgeMirrors.mapped_pull_label_effect_context(marked) do
            result =
              with_ref_fences(git_proof, fn ->
                with {:ok, observed} <-
                       LabelClient.create_label(
                         token,
                         sync.remote_owner,
                         sync.remote_repository,
                         label.fields,
                         pair_client_options(sync, options)
                       ),
                     {:ok, _repository} <- pair_repository_identity(sync, token, options) do
                  if canonical_provider_label(observed) == label.fields do
                    confirm_local_label(
                      marked,
                      now,
                      sync,
                      label,
                      observed,
                      local,
                      remote,
                      identity,
                      proof,
                      git_proof,
                      options,
                      true
                    )
                  else
                    local_label_conflict(
                      marked,
                      now,
                      sync,
                      :ambiguous_label_create,
                      label.fields,
                      observed,
                      options
                    )
                  end
                end
              end)

            case result do
              {:error, reason} -> persist_failure(marked, now, reason, options)
              result -> result
            end
          else
            {:error, reason} -> persist_failure(marked, now, reason, options)
          end
        rescue
          _ -> persist_failure(marked, now, :worker_crash, options)
        catch
          _, _ -> persist_failure(marked, now, :worker_crash, options)
        end

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp recover_mapped_local_label(operation, now, sync, options) do
    marker = operation.external_effect_marker

    label = %{
      local_resource_id: marker["local_label_id"],
      local_version: marker["expected_local_version"],
      fields: marker["proposed_snapshot"]
    }

    with {:ok, token} <- installation_token(sync, options),
         {:ok, projection} <-
           ForgePulls.sync_projection(sync.repository_id, :pull, sync.local_resource_id),
         {:ok, local} <- PullSyncProjection.from_local(projection),
         {:ok, remote, identity, proof, git_proof} <-
           label_pull_preflight(sync, token, local, options),
         {:ok, repository} <- pair_repository_identity(sync, token, options) do
      result =
        LabelClient.get_label(
          token,
          sync.remote_owner,
          sync.remote_repository,
          marker["label_name"],
          pair_client_options(sync, options)
        )

      with {:ok, ^repository} <- pair_repository_identity(sync, token, options) do
        case result do
          {:ok, observed} ->
            if canonical_provider_label(observed) == label.fields do
              confirm_local_label(
                operation,
                now,
                sync,
                label,
                observed,
                local,
                remote,
                identity,
                proof,
                git_proof,
                options
              )
            else
              local_label_conflict(
                operation,
                now,
                sync,
                :ambiguous_label_create,
                label.fields,
                observed,
                options
              )
            end

          {:error, %Error{kind: :not_found}} ->
            local_label_conflict(
              operation,
              now,
              sync,
              :ambiguous_label_create,
              label.fields,
              %{},
              options
            )

          {:error, reason} ->
            persist_failure(operation, now, reason, options)
        end
      else
        {:error, reason} -> persist_failure(operation, now, reason, options)
      end
    else
      {:conflict, kind} ->
        local_label_conflict(operation, now, sync, kind, label.fields, %{}, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp confirm_local_label(
         operation,
         now,
         sync,
         label,
         observed,
         local,
         remote,
         identity,
         proof,
         git_proof,
         options,
         fenced \\ false
       ) do
    expected = local_label_expected(operation, sync, label, local, remote, identity, proof)

    confirmation = %{
      github_object_id: observed["id"],
      github_node_id: observed["node_id"],
      confirmed_snapshot: label.fields
    }

    request = label_observe_request(sync, label)

    request =
      if operation.state == :effect_pending,
        do:
          request
          |> Map.delete(:expected_local_version)
          |> Map.put(:minimum_local_version, label.local_version),
        else: request

    confirm = fn ->
      ForgeMirrors.confirm_mapped_pull_label(
        operation,
        now,
        expected,
        confirmation,
        &ForgeIssues.append_sync_label_observe(&1, :resource, request)
      )
    end

    result = if fenced, do: confirm.(), else: with_ref_fences(git_proof, confirm)

    case result do
      {:error, reason}
      when reason in [:namespace_collision, :identity_conflict, :label_metadata_conflict] ->
        local_label_conflict(operation, now, sync, reason, label.fields, observed, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)

      result ->
        result
    end
  end

  defp local_label_conflict(operation, now, sync, kind, fields, observed, options) do
    conflict(
      operation,
      now,
      %{sync | baseline: %{"pull" => sync.baseline}},
      kind,
      %{"label" => fields},
      %{"label" => Map.take(observed, ~w(id node_id name color description))},
      options
    )
  end

  defp canonical_provider_label(observed) do
    description = observed["description"]

    description =
      if is_binary(description) and String.trim(description) == "", do: nil, else: description

    %{
      "name" => observed["name"],
      "color" => String.downcase(observed["color"]),
      "description" => description
    }
  end

  defp mapped_label_conflict(operation, now, sync, reason, candidate, local, remote, options) do
    # This is a fresh diagnostic read after the rejected import, not an atomic
    # preimage or authorization to adopt the current namespace occupant.
    label =
      if reason == :namespace_collision do
        Fornacast.Repo.get_by(ForgeIssues.Label,
          repository_id: sync.repository_id,
          normalized_name: ForgeIssues.DefaultLabels.normalize_name(candidate.name)
        )
      else
        Fornacast.Repo.one(
          from label in ForgeIssues.Label,
            join: mapping in ForgeMirrors.MirrorResourceState,
            on: mapping.local_resource_id == label.id,
            where:
              label.repository_id == ^sync.repository_id and
                mapping.repository_mirror_id == ^sync.repository_mirror_id and
                mapping.resource_kind == :label and
                mapping.local_resource_type == "ForgeIssues.Label" and
                mapping.github_node_id == ^candidate.node_id,
            order_by: [asc: mapping.id],
            limit: 1,
            select: label
        )
      end

    local_label =
      if label do
        %{
          "local_resource_id" => label.id,
          "local_version" => label.sync_version,
          "name" => label.name,
          "color" => label.color,
          "description" => label.description
        }
      end

    remote_label = %{
      "github_object_id" => candidate.github_object_id,
      "github_node_id" => candidate.node_id,
      "name" => candidate.name,
      "color" => candidate.color,
      "description" => candidate.description
    }

    kind =
      if reason == :namespace_collision,
        do: :label_namespace_collision,
        else: :label_identity_collision

    conflict(
      operation,
      now,
      %{sync | baseline: %{"pull" => sync.baseline}},
      kind,
      %{"pull" => local.snapshot, "label" => local_label},
      %{"pull" => remote.snapshot, "label" => remote_label},
      options
    )
  end

  defp import_inbound_label(operation, now, sync, candidate, options, extra_expected \\ %{}) do
    fields = %{
      "name" => candidate.name,
      "color" => candidate.color,
      "description" => candidate.description
    }

    expected = %{
      resource_state_lock_version: :missing,
      local_label_id: nil,
      expected_local_version: nil,
      expected_local_fingerprint: nil,
      github_object_id: candidate.github_object_id,
      effect_marker: nil
    }

    confirmation = %{
      github_object_id: candidate.github_object_id,
      github_node_id: candidate.node_id,
      confirmed_snapshot: fields
    }

    request = %{
      repository_id: sync.repository_id,
      fields: fields,
      provenance: provenance(sync, operation)
    }

    case ForgeMirrors.confirm_remote_pull_label(
           operation,
           now,
           Map.merge(expected, extra_expected),
           confirmation,
           &ForgeIssues.append_sync_label_import(&1, :resource, request)
         ) do
      {:error, reason} when map_size(extra_expected) > 0 -> {:error, reason}
      {:error, reason} -> persist_failure(operation, now, reason, options)
      result -> result
    end
  end

  # Validate immutable identity, scalar coherence and refs without resolving any
  # local relationship or writing attribution. This temporary scalar projection
  # is never persisted: the complete relationship projection is rebuilt afterward.
  defp inbound_preflight(pull, raw_issue) do
    scalars = Map.merge(raw_issue, %{"labels" => [], "assignees" => []})

    with {:ok, issue} <-
           IssueSyncProjection.from_remote_issue(scalars, %{labels: [], assignees: []}),
         do: PullSyncProjection.from_remote(pull, issue)
  end

  defp inbound_author(%{author: %{github_identity_id: id}}) when is_integer(id) and id > 0,
    do: {:ok, id}

  defp inbound_author(%{raw_author: nil}) do
    %{id: id} = ForgeAccounts.github_deleted_identity()
    {:ok, id}
  end

  defp inbound_author(_), do: {:error, :invalid_remote_resource}

  # Hold every repository writer fence in stable order until both mappings commit.
  # A successful ref read followed by releasing its fence would leave a race.
  @doc false
  def with_ref_fences(%{base: base, head: head}, fun) when is_function(fun, 0) do
    refs = [base, head] |> Enum.reject(&is_nil/1) |> Enum.group_by(& &1.repository_id)
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:ref_deadline_ms)

    inbound_fences(Enum.sort(refs), %{}, deadline, fn paths ->
      with :ok <-
             Enum.reduce_while(refs, :ok, fn {id, required}, :ok ->
               case Enum.reduce_while(required, :ok, fn ref, :ok ->
                      case verify_required_ref(Map.fetch!(paths, id), ref, deadline) do
                        :ok -> {:cont, :ok}
                        error -> {:halt, error}
                      end
                    end) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end),
           do: fun.()
    end)
  end

  defp inbound_fences([], paths, _deadline, fun), do: fun.(paths)

  defp inbound_fences([{id, refs} | rest], paths, deadline, fun) do
    with true <- System.monotonic_time(:millisecond) < deadline,
         {:ok, repository} <- ForgeRepos.fetch_live_repository(id),
         true <- Enum.all?(refs, &(&1.repository_generation == repository.generation)) do
      ForgeRepos.with_write_fence(repository, :ref, fn path, _remaining ->
        inbound_fences(rest, Map.put(paths, id, path), deadline, fun)
      end)
    else
      _ -> {:error, :required_ref_unavailable}
    end
  end

  defp installation_token(sync, options) do
    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           %{permissions: %{"metadata" => "read", "pull_requests" => "write"}}
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :credential_unavailable}
    end
  end

  defp local_observation(sync, options) do
    callback(options, :local_observe, &default_local_observation/1).(sync)
  end

  defp default_local_observation(sync) do
    with {:ok, projection} <-
           ForgePulls.sync_projection(sync.repository_id, :pull, sync.local_resource_id) do
      cond do
        Map.has_key?(sync, :metadata_intent) and
            projection.local_version > sync.metadata_intent.local_version ->
          # A newer unmapped membership must not block proof of an older effect.
          # Its canonical provider sets are unknown, not empty; only the retained
          # intent supplies the historical baseline used by recovery.
          with {:ok, local} <- PullSyncProjection.from_local(projection) do
            {:ok,
             Map.merge(local, %{
               issue_snapshot: nil,
               relationship_preimage: projection.relationship_preimage
             })}
          end

        Map.has_key?(sync, :pair) ->
          with {:ok, relationships} <-
                 ForgeMirrors.resolve_issue_relationships(
                   sync.repository_mirror_id,
                   :local,
                   projection.label_ids,
                   projection.assignee_refs
                 ) do
            PullSyncProjection.from_local(projection, relationships)
          else
            {:error, {:unmapped_label, candidate}} ->
              with {:ok, local} <- PullSyncProjection.from_local(projection),
                   do: {:ok, Map.put(local, :unmapped_label, candidate)}

            error ->
              error
          end

        true ->
          PullSyncProjection.from_local(projection)
      end
    end
  end

  defp observe_authorized(sync, token, local, now, options) do
    with {:ok, git_proof} <- eligibility(sync, local, options),
         :ok <- git_availability(git_proof, options),
         {:ok, proof} <- json_safe(git_proof) do
      case remote_observation(sync, token, local, proof, now, options) do
        {:ok, remote} ->
          with {:ok, identity} <- provider_identity(remote),
               do: {:ok, remote, identity, proof}

        {:error, {:verified_unmapped_label, candidate, remote, identity}} ->
          {:error,
           {:pull_label_prerequisite, candidate, local, remote, identity, proof, git_proof}}

        error ->
          error
      end
    end
  end

  defp remote_observation(sync, token, local, proof, now, options) do
    request_options = request_options(sync)

    with {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options
           ),
         {:ok, issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             sync.github_number,
             request_options
           ),
         {:ok, scalar} <- inbound_preflight(pull, issue),
         {:ok, identity} <- provider_identity(scalar) do
      case precondition(sync, local, scalar, identity, proof) do
        :ok ->
          with {:ok, relationships} <- remote_relationships(sync, issue, now, options),
               {:ok, issue_observation} <-
                 IssueSyncProjection.from_remote_issue(issue, relationships) do
            PullSyncProjection.from_remote(pull, issue_observation)
          else
            {:error, {:unmapped_label, candidate}} ->
              {:error, {:verified_unmapped_label, candidate, scalar, identity}}

            error ->
              error
          end

        _rejected ->
          # Return only diagnostic scalars to the caller's same precondition.
          # Rejected observations must never write author/assignee attribution.
          {:ok, scalar}
      end
    else
      {:error, :inconsistent_observation} -> {:error, :inconsistent_observation}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, :invalid_remote_resource}
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp remote_relationships(sync, issue, now, options) do
    callback(options, :remote_relationships, &default_remote_relationships/3).(sync, issue, now)
  end

  defp default_remote_relationships(sync, issue, now) do
    with {:ok, author} <- observe_author(issue["user"], now),
         {:ok, assignees} <- observe_assignees(issue["assignees"], now),
         {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             sync.repository_mirror_id,
             :remote,
             issue["labels"],
             assignees
           ) do
      {:ok, Map.put(relationships, :author, author)}
    else
      {:error, {:unmapped_label, candidate}} ->
        if Map.get(sync, :mode) == :inbound_create or
             (Map.has_key?(sync, :pair) and not Map.has_key?(sync, :metadata_intent)),
           do: {:error, {:unmapped_label, candidate}},
           else: {:error, :unsupported_resource}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe_author(nil, _now), do: {:ok, nil}

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

  defp eligibility(sync, local, options) do
    refs = %{
      head_ref: local.snapshot["head_ref"],
      head_sha: local.snapshot["head_sha"],
      base_ref: local.snapshot["base_ref"],
      base_sha: local.snapshot["base_sha"]
    }

    callback(options, :eligibility, &PullEligibility.check/3).(
      sync.repository_mirror_id,
      local.head_repository_id,
      refs
    )
  end

  defp git_availability(proof, options) do
    callback(options, :git_availability, &default_git_availability/1).(proof)
  end

  defp default_git_availability(%{base: base, head: head}) do
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:ref_deadline_ms)

    [base, head]
    |> Enum.group_by(& &1.repository_id)
    |> Enum.reduce_while(:ok, fn {repository_id, refs}, :ok ->
      case verify_repository_refs(repository_id, refs, deadline) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :required_ref_unavailable}}
      end
    end)
  rescue
    _exception -> {:error, :required_ref_unavailable}
  end

  defp default_git_availability(_proof), do: {:error, :required_ref_unavailable}

  defp verify_repository_refs(repository_id, refs, deadline)
       when is_integer(repository_id) and repository_id > 0 and is_list(refs) do
    with {:ok, repository} <- ForgeRepos.fetch_live_repository(repository_id),
         true <-
           Enum.all?(refs, fn
             %{repository_generation: generation} -> generation == repository.generation
             _invalid -> false
           end) do
      ForgeRepos.with_repository_read(repository, deadline, fn handle ->
        path = ForgeRepos.repository_read_path(handle)

        Enum.reduce_while(refs, :ok, fn ref, :ok ->
          case verify_required_ref(path, ref, deadline) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      end)
    else
      _invalid -> {:error, :required_ref_unavailable}
    end
  end

  defp verify_repository_refs(_repository_id, _refs, _deadline),
    do: {:error, :required_ref_unavailable}

  defp verify_required_ref(
         path,
         %{ref: ref, oid: oid, repository_generation: generation},
         deadline
       )
       when is_binary(path) and is_binary(ref) and is_binary(oid) and is_integer(generation) and
              generation > 0 and is_integer(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    with true <- remaining > 0,
         {:ok, ^oid} <- GitCore.exact_ref(path, ref, deadline_ms: remaining),
         remaining = max(deadline - System.monotonic_time(:millisecond), 0),
         true <- remaining > 0,
         {:ok, true} <- GitCore.is_ancestor(path, oid, oid, deadline_ms: remaining) do
      :ok
    else
      _invalid -> {:error, :required_ref_unavailable}
    end
  end

  defp verify_required_ref(_path, _ref, _deadline),
    do: {:error, :required_ref_unavailable}

  defp precondition(sync, local, remote, provider_identity, proof) do
    cond do
      not valid_snapshot?(sync.baseline) or not valid_observation?(local) or
          not valid_observation?(remote) ->
        {:error, :invalid_projection}

      remote.github_object_id != sync.github_object_id or
        remote.github_node_id != sync.github_node_id or
          remote.github_number != sync.github_number ->
        {:conflict, :pull_identity_mismatch}

      not is_nil(sync.provider_identity) and sync.provider_identity != provider_identity ->
        {:conflict, :pull_identity_mismatch}

      ref_fields(sync.baseline) != ref_fields(local.snapshot) or
          ref_fields(local.snapshot) != ref_fields(remote.snapshot) ->
        {:conflict, :pull_ref_mismatch}

      not unmerged?(local.merge_state) or not unmerged?(remote.merge_state) or
        persistent_merge_state(local.merge_state) != sync.confirmed_merge_state or
          local.merge_state != remote.merge_state ->
        {:conflict, :unsupported_merge_state}

      get_in(proof, ["base", "repository_mirror_id"]) != sync.repository_mirror_id or
        get_in(proof, ["base", "github_repository_id"]) !=
          provider_identity["base_repository"]["id"] or
        get_in(proof, ["head", "github_repository_id"]) !=
          provider_identity["head_repository"]["id"] or
          proof["github_installation_id"] != sync.github_installation_id ->
        {:conflict, :pull_identity_mismatch}

      true ->
        :ok
    end
  end

  defp recover_effect(
         operation,
         now,
         sync,
         token,
         local,
         remote,
         provider_identity,
         proof,
         options
       ) do
    marker = operation.external_effect_marker

    with :ok <- validate_marker(marker, sync, local, provider_identity, proof, options),
         {:ok, remote_fingerprint} <- fingerprint(remote.snapshot, options) do
      cond do
        remote_fingerprint == marker["proposed_fingerprint"] ->
          if local.local_version > marker["expected_local_version"] do
            confirm_recovered(
              operation,
              now,
              sync,
              local,
              remote,
              provider_identity,
              proof,
              options
            )
          else
            reconcile(
              operation,
              now,
              sync,
              token,
              local,
              remote,
              provider_identity,
              proof,
              true,
              1,
              options
            )
          end

        remote_fingerprint == marker["expected_remote_fingerprint"] and
          iso8601(remote.remote_updated_at) == marker["expected_remote_updated_at"] and
            local.local_version == marker["expected_local_version"] ->
          reconcile(
            operation,
            now,
            sync,
            token,
            local,
            remote,
            provider_identity,
            proof,
            false,
            0,
            options
          )

        remote_fingerprint == marker["expected_remote_fingerprint"] and
            iso8601(remote.remote_updated_at) == marker["expected_remote_updated_at"] ->
          callback(options, :requeue_effect, &ForgeMirrors.requeue_reconciled_resource_effect/2).(
            operation,
            now
          )

        true ->
          conflict(
            operation,
            now,
            sync,
            :ambiguous_external_effect,
            local.snapshot,
            remote.snapshot,
            options
          )
      end
    else
      _invalid ->
        conflict(
          operation,
          now,
          sync,
          :ambiguous_external_effect,
          local.snapshot,
          remote.snapshot,
          options
        )
    end
  end

  defp reconcile_pair(operation, now, sync, token, local, remote, identity, proof, options) do
    with {:ok, plan} <-
           PullMetadataDecision.decide(
             sync.pair.pull.snapshot,
             local.snapshot,
             remote.snapshot,
             sync.pair.issue.snapshot,
             local[:issue_snapshot],
             remote[:issue_snapshot]
           ) do
      if plan.remote_issue_effect? or plan.draft_effect? do
        start_pair_effect(
          operation,
          now,
          sync,
          token,
          local,
          remote,
          identity,
          proof,
          plan,
          0,
          options
        )
      else
        confirm_pair_observation(
          operation,
          now,
          sync,
          local,
          remote,
          identity,
          proof,
          plan,
          options
        )
      end
    else
      {:conflict, kind} ->
        conflict(
          operation,
          now,
          sync,
          kind,
          local[:issue_snapshot],
          remote[:issue_snapshot],
          options
        )

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp start_pair_effect(
         operation,
         now,
         sync,
         token,
         local,
         remote,
         identity,
         proof,
         plan,
         depth,
         options
       ) do
    action =
      if plan.remote_issue_effect?, do: "update_remote_pull_issue", else: "set_remote_pull_draft"

    proposed_draft =
      if plan.remote_issue_effect?, do: remote.snapshot["draft"], else: plan.target_pull["draft"]

    proposed =
      Map.merge(remote.snapshot, Map.take(plan.target_issue, @issue_fields))
      |> Map.put("draft", proposed_draft)

    with true <- depth < 3,
         %DateTime{utc_offset: 0, std_offset: 0} = issue_time <- remote[:issue_remote_updated_at],
         {:ok, payload} <-
           pair_payload(action, local.issue_snapshot, remote.issue_snapshot, plan.target_issue),
         {:ok, marker} <-
           effect_marker(action, sync, local, remote, proposed, identity, proof, options),
         marker =
           Map.merge(marker, %{
             "expected_remote_issue_updated_at" => DateTime.to_iso8601(issue_time),
             "expected_remote_draft" => remote.snapshot["draft"],
             "proposed_draft" => proposed_draft
           }),
         {:ok, marked_context} <-
           callback(options, :mark_pair_effect, &ForgeMirrors.mark_mapped_pull_effect/5).(
             operation,
             now,
             sync.pair,
             marker,
             payload
           ) do
      marked = marked_context.operation
      marked_sync = Map.put(marked_context.sync, :metadata_intent, marked_context.intent)

      perform_pair_effect(
        marked,
        now,
        marked_sync,
        token,
        local,
        remote,
        identity,
        proof,
        depth,
        options
      )
    else
      false -> persist_failure(operation, now, :invalid_projection, options)
      {:error, reason} -> persist_failure(operation, now, reason, options)
      _ -> persist_failure(operation, now, :invalid_projection, options)
    end
  end

  defp pair_payload("update_remote_pull_issue", local, remote, target),
    do: PullMetadataRecovery.build(local, remote, target)

  defp pair_payload("set_remote_pull_draft", local, remote, remote),
    do:
      {:ok,
       %{
         "v" => 1,
         "expected_local_issue" => local,
         "expected_remote_issue" => remote,
         "target_issue" => remote
       }}

  defp pair_payload(_, _, _, _), do: {:error, :invalid_projection}

  defp perform_pair_effect(
         operation,
         now,
         sync,
         token,
         local,
         _remote,
         _identity,
         _proof,
         depth,
         options
       ) do
    marker = operation.external_effect_marker
    payload = sync.metadata_intent.payload

    result =
      with :ok <- prepare_pair_nodes(operation, now, sync, token, local, options),
           {:ok, attrs} <- pair_effect_attrs(operation, sync, token, payload, options),
           :ok <- fresh_pair_after_relationships(operation, now, sync, token, local, options),
           {:ok, fresh} <-
             callback(options, :pair_effect_context, &ForgeMirrors.mapped_pull_effect_context/1).(
               operation
             ),
           true <- fresh.marker == marker and fresh.intent == sync.metadata_intent do
        case marker["action"] do
          "update_remote_pull_issue" ->
            callback(options, :update_pull_issue, &IssueClient.update_pull_issue/6).(
              token,
              sync.remote_owner,
              sync.remote_repository,
              sync.github_number,
              attrs,
              request_options(sync)
            )

          "set_remote_pull_draft" ->
            callback(options, :set_draft, &PullClient.set_draft/4).(
              token,
              sync.github_node_id,
              marker["proposed_draft"],
              request_options(sync)
            )
        end
      end

    case result do
      {:seeded, saved} ->
        {:ok, saved}

      :relationship_unavailable ->
        conflict(
          operation,
          now,
          sync,
          :relationship_unavailable,
          local[:issue_snapshot],
          payload["target_issue"],
          options
        )

      {:already_applied, remote, identity, proof} ->
        recover_pair_effect(
          operation,
          now,
          sync,
          token,
          local,
          remote,
          identity,
          proof,
          depth + 1,
          options
        )

      {:remote_conflict, remote} ->
        conflict(
          operation,
          now,
          sync,
          :ambiguous_external_effect,
          local[:issue_snapshot],
          remote[:issue_snapshot],
          options
        )

      {:ok, _} ->
        with {:ok, remote, identity, proof} <-
               observe_authorized(sync, token, local, now, options),
             :ok <- normalize_precondition(precondition(sync, local, remote, identity, proof)) do
          recover_pair_effect(
            operation,
            now,
            sync,
            token,
            local,
            remote,
            identity,
            proof,
            depth + 1,
            options
          )
        else
          {:error, reason} -> persist_failure(operation, now, reason, options)
        end

      {:error, reason} ->
        persist_failure(operation, now, reason, options)

      _ ->
        persist_failure(operation, now, :invalid_projection, options)
    end
  rescue
    _ -> persist_failure(operation, now, :worker_crash, options)
  catch
    _, _ -> persist_failure(operation, now, :worker_crash, options)
  end

  defp prepare_pair_nodes(operation, now, sync, token, local, options) do
    if operation.external_effect_marker["action"] == "set_remote_pull_draft" do
      :ok
    else
      prepare_pair_issue_nodes(operation, now, sync, token, local, options)
    end
  end

  defp prepare_pair_issue_nodes(operation, now, sync, token, local, options) do
    target = sync.metadata_intent.payload["target_issue"]

    if target["assignee_github_ids"] == [] do
      prepare_pair_label_nodes(operation, now, sync, token, local, options)
    else
      with {:ok, context} <-
             callback(
               options,
               :mapped_assignee_node_context,
               &ForgeMirrors.mapped_pull_assignee_node_context/1
             ).(operation) do
        case context.target do
          nil ->
            prepare_pair_label_nodes(operation, now, sync, token, local, options)

          target ->
            with {:ok, user} <-
                   IdentityClient.get_user(
                     token,
                     target.github_user_id,
                     pair_client_options(sync, options)
                   ),
                 :ok <-
                   fresh_pair_after_relationships(
                     operation,
                     now,
                     sync,
                     token,
                     local,
                     options,
                     true
                   ),
                 {:ok, saved} <-
                   callback(
                     options,
                     :seed_mapped_assignee_node,
                     &ForgeMirrors.seed_mapped_pull_assignee_node/4
                   ).(
                     operation,
                     now,
                     Map.take(context, [:marker, :target]),
                     Map.from_struct(user)
                   ) do
              {:seeded, saved}
            end
        end
      end
    end
  end

  defp prepare_pair_label_nodes(operation, now, sync, token, local, options) do
    if sync.metadata_intent.payload["target_issue"]["label_github_ids"] == [] do
      :ok
    else
      with {:ok, context} <-
             callback(
               options,
               :mapped_label_node_context,
               &ForgeMirrors.mapped_pull_label_node_context/1
             ).(operation) do
        case context.status do
          :ready ->
            :ok

          :unavailable ->
            :relationship_unavailable

          :scanning ->
            with {:ok, repository} <- pair_repository_identity(sync, token, options),
                 {:ok, page} <-
                   LabelClient.list_labels_page(
                     token,
                     sync.remote_owner,
                     sync.remote_repository,
                     context.checkpoint["page"],
                     pair_client_options(sync, options)
                   ),
                 {:ok, ^repository} <- pair_repository_identity(sync, token, options),
                 :ok <-
                   fresh_pair_after_relationships(
                     operation,
                     now,
                     sync,
                     token,
                     local,
                     options,
                     true
                   ),
                 {:ok, saved} <-
                   callback(
                     options,
                     :seed_mapped_label_nodes,
                     &ForgeMirrors.seed_mapped_pull_label_nodes/4
                   ).(
                     operation,
                     now,
                     Map.take(context, [:marker, :targets, :checkpoint]),
                     Map.put(page, :repository, repository)
                   ) do
              {:seeded, saved}
            end
        end
      end
    end
  end

  defp pair_repository_identity(sync, token, options) do
    expected = sync.provider_identity["base_repository"]

    with {:ok, repo} <-
           Client.repository(
             token,
             sync.remote_owner,
             sync.remote_repository,
             pair_client_options(sync, options)
           ),
         true <-
           repo.id == expected["id"] and repo.node_id == expected["node_id"] and
             repo.full_name == sync.remote_owner <> "/" <> sync.remote_repository do
      {:ok, %{github_object_id: repo.id, github_node_id: repo.node_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :identity_conflict}
    end
  end

  defp pair_client_options(sync, options) do
    extra =
      if @test_client_options,
        do: Keyword.get(options, :relationship_client_options, []),
        else: []

    Keyword.merge(extra, request_options(sync))
  end

  defp fresh_pair_after_relationships(
         operation,
         now,
         sync,
         token,
         local,
         options,
         force? \\ false
       ) do
    marker = operation.external_effect_marker
    payload = sync.metadata_intent.payload
    target_issue = payload["target_issue"]

    if force? or
         (marker["action"] == "update_remote_pull_issue" and
            (target_issue["label_github_ids"] != [] or target_issue["assignee_github_ids"] != [])) do
      with {:ok, remote, identity, proof} <- observe_authorized(sync, token, local, now, options),
           :ok <- normalize_precondition(precondition(sync, local, remote, identity, proof)) do
        before =
          pair_pull_snapshot(
            sync,
            payload["expected_remote_issue"],
            marker["expected_remote_draft"]
          )

        target = pair_pull_snapshot(sync, target_issue, marker["proposed_draft"])

        cond do
          remote.snapshot == target and remote[:issue_snapshot] == target_issue ->
            {:already_applied, remote, identity, proof}

          remote.snapshot == before and
            remote[:issue_snapshot] == payload["expected_remote_issue"] and
              same_pair_remote_versions?(remote, marker) ->
            :ok

          true ->
            {:remote_conflict, remote}
        end
      end
    else
      :ok
    end
  end

  defp recover_pair_effect(
         operation,
         now,
         sync,
         token,
         local,
         remote,
         identity,
         proof,
         depth,
         options
       ) do
    marker = operation.external_effect_marker
    payload = sync.metadata_intent.payload

    before =
      pair_pull_snapshot(sync, payload["expected_remote_issue"], marker["expected_remote_draft"])

    target = pair_pull_snapshot(sync, payload["target_issue"], marker["proposed_draft"])

    cond do
      remote.snapshot == target and remote[:issue_snapshot] == payload["target_issue"] ->
        old_local =
          pair_pull_snapshot(
            sync,
            payload["expected_local_issue"],
            marker["expected_local_draft"]
          )

        with {:ok, plan} <-
               PullMetadataDecision.decide(
                 sync.pair.pull.snapshot,
                 old_local,
                 remote.snapshot,
                 sync.pair.issue.snapshot,
                 payload["expected_local_issue"],
                 remote.issue_snapshot
               ) do
          if local.local_version == marker["expected_local_version"] and
               (plan.remote_issue_effect? or plan.draft_effect?) do
            start_pair_effect(
              operation,
              now,
              sync,
              token,
              local,
              remote,
              identity,
              proof,
              plan,
              depth,
              options
            )
          else
            confirm_pair_effect(
              operation,
              now,
              sync,
              local,
              remote,
              identity,
              proof,
              target,
              old_local,
              options
            )
          end
        else
          {:conflict, kind} ->
            conflict(
              operation,
              now,
              sync,
              kind,
              local.issue_snapshot,
              remote.issue_snapshot,
              options
            )

          {:error, reason} ->
            persist_failure(operation, now, reason, options)
        end

      remote.snapshot == before and remote[:issue_snapshot] == payload["expected_remote_issue"] and
        same_pair_remote_versions?(remote, marker) and depth == 0 ->
        perform_pair_effect(
          operation,
          now,
          sync,
          token,
          local,
          remote,
          identity,
          proof,
          depth,
          options
        )

      true ->
        conflict(
          operation,
          now,
          sync,
          :ambiguous_external_effect,
          local[:issue_snapshot],
          remote[:issue_snapshot],
          options
        )
    end
  end

  defp pair_pull_snapshot(sync, issue, draft),
    do:
      sync.baseline
      |> Map.take(@ref_fields)
      |> Map.merge(Map.take(issue, @issue_fields))
      |> Map.put("draft", draft)

  defp same_pair_remote_versions?(remote, marker) do
    same_remote_time?(remote[:remote_updated_at], marker["expected_remote_updated_at"]) and
      same_remote_time?(
        remote[:issue_remote_updated_at],
        marker["expected_remote_issue_updated_at"]
      )
  end

  defp same_remote_time?(%DateTime{utc_offset: 0, std_offset: 0} = observed, expected),
    do: DateTime.to_iso8601(observed) == expected

  defp same_remote_time?(_, _), do: false

  defp confirm_pair_effect(
         operation,
         now,
         sync,
         local,
         remote,
         identity,
         proof,
         target,
         old_local,
         options
       ) do
    issue_target = sync.metadata_intent.payload["target_issue"]
    advanced? = local.local_version > operation.external_effect_marker["expected_local_version"]
    apply? = not advanced? and (local.snapshot != target or local.issue_snapshot != issue_target)
    plan = %{target_issue: issue_target, apply_local?: apply?}

    with {:ok, request} <- domain_request(operation, sync, local, target, apply?, old_local),
         {:ok, request} <-
           if(advanced?,
             do: {:ok, request},
             else: paired_relationship_request(request, local, remote, plan)
           ),
         {:ok, confirmed} <- confirmation(operation, local, remote, identity, target, apply?),
         %DateTime{} = issue_time <- remote[:issue_remote_updated_at] do
      expected =
        confirmation_expected(operation, sync, local, remote, identity, proof, old_local)
        |> Map.put(:pair, sync.pair)

      confirmed =
        Map.merge(confirmed, %{issue_snapshot: issue_target, issue_remote_updated_at: issue_time})

      callback(options, :confirm_pair, &default_confirm_pair/5).(
        operation,
        now,
        expected,
        confirmed,
        request
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
      _ -> persist_failure(operation, now, :invalid_projection, options)
    end
  end

  defp pair_effect_attrs(operation, sync, token, payload, options) do
    if operation.external_effect_marker["action"] == "set_remote_pull_draft" do
      {:ok, %{}}
    else
      callback(options, :pair_relationship_attrs, &default_pair_relationship_attrs/5).(
        operation,
        sync,
        token,
        payload["target_issue"],
        options
      )
    end
  end

  defp default_pair_relationship_attrs(operation, sync, token, target, options) do
    label_ids = target["label_github_ids"]
    user_ids = target["assignee_github_ids"]

    labels =
      Fornacast.Repo.all(
        from m in ForgeMirrors.MirrorResourceState,
          where:
            m.repository_mirror_id == ^sync.repository_mirror_id and m.resource_kind == :label and
              m.state == :confirmed and m.github_object_id in ^label_ids,
          order_by: m.github_object_id,
          select: %{github_object_id: m.github_object_id, github_node_id: m.github_node_id}
      )

    users =
      Fornacast.Repo.all(
        from u in ForgeAccounts.GitHubIdentity,
          where: u.kind == :user and u.github_user_id in ^user_ids,
          order_by: u.github_user_id,
          select: %{github_user_id: u.github_user_id, github_node_id: u.github_node_id}
      )

    base = sync.provider_identity["base_repository"]

    deadline =
      System.monotonic_time(:millisecond) +
        DateTime.diff(operation.lease_expires_at, DateTime.utc_now(), :millisecond) - 2_000

    extra =
      if @test_client_options,
        do: Keyword.get(options, :relationship_client_options, []),
        else: []

    request_opts =
      Keyword.merge(extra, request_options(sync))
      |> Keyword.put(:deadline_monotonic_ms, deadline)

    with true <-
           Enum.map(labels, & &1.github_object_id) == label_ids and
             Enum.map(users, & &1.github_user_id) == user_ids,
         {:ok, resolved} <-
           RelationshipClient.resolve(
             token,
             %{github_object_id: base["id"], github_node_id: base["node_id"]},
             labels,
             users,
             request_opts
           ) do
      {:ok,
       Map.merge(Map.take(target, @issue_fields), %{
         "labels" => Enum.map(resolved.labels, & &1.name),
         "assignees" => Enum.map(resolved.assignees, & &1.login)
       })}
    else
      false -> {:error, :relationship_prerequisite}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm_pair_observation(
         operation,
         now,
         sync,
         local,
         remote,
         identity,
         proof,
         plan,
         options
       ) do
    with {:ok, request} <-
           domain_request(
             operation,
             sync,
             local,
             plan.target_pull,
             plan.apply_local?,
             local.snapshot
           ),
         {:ok, request} <- paired_relationship_request(request, local, remote, plan),
         {:ok, confirmation} <-
           confirmation(operation, local, remote, identity, plan.target_pull, plan.apply_local?),
         %DateTime{} = issue_time <- remote[:issue_remote_updated_at] do
      expected =
        confirmation_expected(operation, sync, local, remote, identity, proof, local.snapshot)
        |> Map.put(:pair, sync.pair)

      confirmation =
        Map.merge(confirmation, %{
          issue_snapshot: plan.target_issue,
          issue_remote_updated_at: issue_time
        })

      callback(options, :confirm_pair, &default_confirm_pair/5).(
        operation,
        now,
        expected,
        confirmation,
        request
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
      _ -> persist_failure(operation, now, :invalid_projection, options)
    end
  end

  defp paired_relationship_request(request, local, remote, plan) do
    with %{label_ids: labels, managed_assignee_identity_ids: assignees} = preimage <-
           local[:relationship_preimage],
         true <- is_list(labels) and is_list(assignees),
         {:ok, label_ids} <-
           target_relationships(
             local,
             remote,
             :label_catalog,
             :local_label_id,
             plan.target_issue["label_github_ids"]
           ),
         {:ok, refs} <-
           target_relationships(
             local,
             remote,
             :assignee_catalog,
             :ref,
             plan.target_issue["assignee_github_ids"]
           ) do
      request = Map.put(request, :expected_relationships, preimage)

      if plan.apply_local?,
        do:
          {:ok, Map.merge(request, %{local_label_ids: Enum.sort(label_ids), assignee_refs: refs})},
        else: {:ok, request}
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp target_relationships(local, remote, catalog_key, value_key, ids) do
    left = Map.get(local, catalog_key, %{})
    right = Map.get(remote, catalog_key, %{})

    if is_map(left) and is_map(right) do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, values} ->
        old = get_in(left, [id, value_key])
        fresh = get_in(right, [id, value_key])
        value = fresh || old

        if not is_nil(value) and (is_nil(old) or is_nil(fresh) or old == fresh),
          do: {:cont, {:ok, values ++ [value]}},
          else: {:halt, {:error, :invalid_projection}}
      end)
    else
      {:error, :invalid_projection}
    end
  end

  defp default_confirm_pair(operation, now, expected, confirmation, request) do
    domain_multi = fn multi ->
      case request.action do
        :update -> ForgePulls.append_sync_apply(multi, :resource, request)
        :observe -> ForgePulls.append_sync_observe(multi, :resource, request)
      end
    end

    ForgeMirrors.confirm_mapped_pull_pair(operation, now, expected, confirmation, domain_multi)
  end

  defp reconcile(
         operation,
         now,
         sync,
         token,
         local,
         remote,
         provider_identity,
         proof,
         replace_effect?,
         depth,
         options
       ) do
    case decision(sync.baseline, local.snapshot, remote.snapshot) do
      {:ok, plan} when plan.issue_effect? and depth < 2 ->
        issue_effect(
          operation,
          now,
          sync,
          token,
          local,
          remote,
          provider_identity,
          proof,
          plan,
          replace_effect?,
          depth,
          options
        )

      {:ok, plan} when plan.draft_effect? and depth < 2 ->
        draft_effect(
          operation,
          now,
          sync,
          token,
          local,
          remote,
          provider_identity,
          proof,
          plan,
          replace_effect?,
          depth,
          options
        )

      {:ok, %{issue_effect?: false, draft_effect?: false} = plan} ->
        confirm_observation(
          operation,
          now,
          sync,
          local,
          remote,
          provider_identity,
          proof,
          plan.target,
          plan.apply_local?,
          options
        )

      {:ok, _plan} ->
        persist_failure(operation, now, :invalid_projection, options)

      {:conflict, kind} ->
        conflict(operation, now, sync, kind, local.snapshot, remote.snapshot, options)

      {:error, reason} ->
        persist_failure(operation, now, reason, options)
    end
  end

  defp issue_effect(
         operation,
         now,
         sync,
         token,
         local,
         remote,
         provider_identity,
         proof,
         plan,
         replace_effect?,
         depth,
         options
       ) do
    proposed = Map.merge(remote.snapshot, Map.take(plan.target, @issue_fields))

    with {:ok, marker} <-
           effect_marker(
             "update_remote_pull_issue",
             sync,
             local,
             remote,
             proposed,
             provider_identity,
             proof,
             options
           ),
         {:ok, marked} <- prepare_effect(operation, now, marker, replace_effect?, options) do
      result =
        callback(options, :update_pull_issue, &IssueClient.update_pull_issue/6).(
          token,
          sync.remote_owner,
          sync.remote_repository,
          sync.github_number,
          Map.take(plan.target, @issue_fields),
          request_options(sync)
        )

      continue_after_effect(
        result,
        marked,
        now,
        sync,
        token,
        local,
        marker,
        depth,
        options
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp draft_effect(
         operation,
         now,
         sync,
         token,
         local,
         remote,
         provider_identity,
         proof,
         plan,
         replace_effect?,
         depth,
         options
       ) do
    proposed = Map.put(remote.snapshot, "draft", plan.target["draft"])

    with {:ok, marker} <-
           effect_marker(
             "set_remote_pull_draft",
             sync,
             local,
             remote,
             proposed,
             provider_identity,
             proof,
             options
           ),
         {:ok, marked} <- prepare_effect(operation, now, marker, replace_effect?, options) do
      result =
        callback(options, :set_draft, &PullClient.set_draft/4).(
          token,
          remote.github_node_id,
          plan.target["draft"],
          request_options(sync)
        )

      continue_after_effect(
        result,
        marked,
        now,
        sync,
        token,
        local,
        marker,
        depth,
        options
      )
    else
      {:error, reason} -> persist_failure(operation, now, reason, options)
    end
  end

  defp continue_after_effect(
         {:ok, _response},
         marked,
         now,
         sync,
         token,
         local,
         marker,
         depth,
         options
       ) do
    with {:ok, remote, provider_identity, proof} <-
           observe_authorized(sync, token, local, now, options),
         :ok <-
           normalize_precondition(precondition(sync, local, remote, provider_identity, proof)),
         {:ok, fingerprint} <- fingerprint(remote.snapshot, options),
         true <- fingerprint == marker["proposed_fingerprint"] do
      reconcile(
        marked,
        now,
        sync,
        token,
        local,
        remote,
        provider_identity,
        proof,
        true,
        depth + 1,
        options
      )
    else
      false ->
        conflict(
          marked,
          now,
          sync,
          :ambiguous_external_effect,
          local.snapshot,
          %{},
          options
        )

      {:error, reason} ->
        schedule_effect_recovery(marked, now, reason, options)
    end
  end

  defp continue_after_effect(
         {:error, reason},
         marked,
         now,
         _sync,
         _token,
         _local,
         _marker,
         _depth,
         options
       ),
       do: schedule_effect_recovery(marked, now, reason, options)

  defp continue_after_effect(
         _invalid,
         marked,
         now,
         _sync,
         _token,
         _local,
         _marker,
         _depth,
         options
       ),
       do: schedule_effect_recovery(marked, now, :invalid_remote_resource, options)

  defp prepare_effect(
         %MirrorOperation{state: :processing} = operation,
         now,
         marker,
         false,
         options
       ) do
    callback(options, :mark_effect, &ForgeMirrors.mark_external_effect/3).(operation, now, marker)
  end

  defp prepare_effect(
         %MirrorOperation{state: :effect_pending, external_effect_marker: marker} = operation,
         _now,
         marker,
         false,
         _options
       ),
       do: {:ok, operation}

  defp prepare_effect(
         %MirrorOperation{state: :effect_pending, external_effect_marker: previous} = operation,
         now,
         marker,
         true,
         options
       ) do
    if previous == marker do
      {:ok, operation}
    else
      callback(options, :replace_effect, &ForgeMirrors.replace_external_effect/4).(
        operation,
        now,
        previous,
        marker
      )
    end
  end

  defp prepare_effect(_operation, _now, _marker, _replace?, _options),
    do: {:error, :ambiguous_external_effect}

  defp decision(baseline, local, remote) do
    if valid_snapshot?(baseline) and valid_snapshot?(local) and valid_snapshot?(remote) do
      Enum.reduce_while(
        @mutable_fields,
        {:ok, %{target: baseline, apply_local?: false, remote_fields: []}},
        fn field, {:ok, plan} ->
          case ResourceDecision.scalar(baseline[field], local[field], remote[field]) do
            {:confirm, value} ->
              {:cont, {:ok, put_in(plan.target[field], value)}}

            {:apply_local, _current, value} ->
              {:cont,
               {:ok, %{plan | target: Map.put(plan.target, field, value), apply_local?: true}}}

            {:apply_remote, _current, value} ->
              {:cont,
               {:ok,
                %{
                  plan
                  | target: Map.put(plan.target, field, value),
                    remote_fields: [field | plan.remote_fields]
                }}}

            {:conflict, kind} ->
              {:halt, {:conflict, kind}}
          end
        end
      )
      |> case do
        {:ok, plan} ->
          {:ok,
           plan
           |> Map.put(:issue_effect?, Enum.any?(plan.remote_fields, &(&1 in @issue_fields)))
           |> Map.put(:draft_effect?, "draft" in plan.remote_fields)}

        other ->
          other
      end
    else
      {:error, :invalid_projection}
    end
  end

  defp confirm_recovered(operation, now, sync, local, remote, provider_identity, proof, options) do
    with {:ok, expected_fields} <-
           recovery_expected_fields(operation, local, remote, sync.baseline, options) do
      confirm_observation(
        operation,
        now,
        sync,
        local,
        remote,
        provider_identity,
        proof,
        remote.snapshot,
        false,
        Keyword.put(options, :recovery_expected_fields, expected_fields)
      )
    else
      {:error, _reason} ->
        conflict(
          operation,
          now,
          sync,
          :ambiguous_external_effect,
          local.snapshot,
          remote.snapshot,
          options
        )
    end
  end

  defp recovery_expected_fields(operation, local, remote, baseline, options) do
    expected = operation.external_effect_marker["expected_local_fingerprint"]

    reconstructed =
      reconstruct_local_preimage(operation.external_effect_marker, remote.snapshot, baseline)

    Enum.reduce_while(
      [local.snapshot, remote.snapshot, reconstructed],
      {:error, :missing_preimage},
      fn
        snapshot, _acc when is_map(snapshot) ->
          case fingerprint(snapshot, options) do
            {:ok, ^expected} -> {:halt, {:ok, snapshot}}
            _other -> {:cont, {:error, :missing_preimage}}
          end

        _invalid, acc ->
          {:cont, acc}
      end
    )
  end

  defp confirm_observation(
         operation,
         now,
         sync,
         local,
         remote,
         provider_identity,
         proof,
         target,
         apply_local?,
         options
       ) do
    with {:ok, expected_fields} <- expected_fields(operation, sync, local, remote, options),
         {:ok, domain_request} <-
           domain_request(operation, sync, local, target, apply_local?, expected_fields),
         {:ok, confirmation} <-
           confirmation(operation, local, remote, provider_identity, target, apply_local?),
         expected <-
           confirmation_expected(
             operation,
             sync,
             local,
             remote,
             provider_identity,
             proof,
             expected_fields
           ) do
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

  defp expected_fields(operation, sync, local, remote, options) do
    case Keyword.fetch(options, :recovery_expected_fields) do
      {:ok, fields} -> {:ok, fields}
      :error when operation.state == :processing -> {:ok, local.snapshot}
      :error -> recovery_expected_fields(operation, local, remote, sync.baseline, options)
    end
  end

  defp domain_request(operation, sync, local, target, true, _expected_fields) do
    {:ok,
     %{
       action: :update,
       repository_id: sync.repository_id,
       resource_kind: :pull,
       local_resource_id: local.local_resource_id,
       expected_local_version: local.local_version,
       expected_fields: local.snapshot,
       expected_merge_state: strip_merged(local.merge_state),
       fields: target,
       provenance: provenance(sync, operation)
     }}
  end

  defp domain_request(operation, sync, local, _target, false, expected_fields) do
    request = %{
      action: :observe,
      repository_id: sync.repository_id,
      resource_kind: :pull,
      local_resource_id: local.local_resource_id,
      expected_fields: expected_fields,
      expected_merge_state: strip_merged(local.merge_state)
    }

    if operation.state == :effect_pending and
         local.local_version > operation.external_effect_marker["expected_local_version"] do
      {:ok,
       Map.put(
         request,
         :minimum_local_version,
         operation.external_effect_marker["expected_local_version"]
       )}
    else
      {:ok, Map.put(request, :expected_local_version, local.local_version)}
    end
  end

  defp default_confirm(operation, now, expected, confirmation, domain_request) do
    domain_multi = fn multi ->
      case domain_request.action do
        :update -> ForgePulls.append_sync_apply(multi, :resource, domain_request)
        :observe -> ForgePulls.append_sync_observe(multi, :resource, domain_request)
      end
    end

    ForgeMirrors.confirm_pull_operation(operation, now, expected, confirmation, domain_multi)
  end

  defp confirmation(operation, local, remote, provider_identity, target, apply_local?) do
    version =
      cond do
        apply_local? ->
          local.local_version + 1

        operation.state == :effect_pending ->
          operation.external_effect_marker["expected_local_version"]

        true ->
          local.local_version
      end

    {:ok,
     %{
       github_object_id: remote.github_object_id,
       github_node_id: remote.github_node_id,
       github_number: remote.github_number,
       remote_updated_at: remote.remote_updated_at,
       confirmed_local_version: version,
       confirmed_snapshot: target,
       confirmed_merge_state: persistent_merge_state(remote.merge_state),
       provider_identity: provider_identity,
       state: :confirmed
     }}
  end

  defp confirmation_expected(
         operation,
         sync,
         local,
         remote,
         _provider_identity,
         proof,
         expected_fields
       ) do
    expected_version =
      if operation.state == :effect_pending,
        do: operation.external_effect_marker["expected_local_version"],
        else: local.local_version

    %{
      resource_state_lock_version: sync.resource_state_lock_version,
      local_resource_id: local.local_resource_id,
      expected_local_version: expected_version,
      expected_fields: expected_fields,
      expected_merge_state: persistent_merge_state(local.merge_state),
      provider_identity: sync.provider_identity,
      pull_eligibility_proof: proof,
      github_object_id: remote.github_object_id,
      observed_remote_updated_at: remote.remote_updated_at,
      effect_marker: if(operation.state == :effect_pending, do: operation.external_effect_marker)
    }
  end

  defp effect_marker(
         action,
         sync,
         local,
         remote,
         proposed,
         provider_identity,
         proof,
         options
       ) do
    with {:ok, local_fingerprint} <- fingerprint(local.snapshot, options),
         {:ok, remote_fingerprint} <- fingerprint(remote.snapshot, options),
         {:ok, proposed_fingerprint} <- fingerprint(proposed, options) do
      {:ok,
       %{
         "v" => 1,
         "action" => action,
         "resource_kind" => "pull",
         "local_resource_id" => local.local_resource_id,
         "expected_local_version" => local.local_version,
         "expected_local_fingerprint" => local_fingerprint,
         "expected_remote_updated_at" => iso8601(remote.remote_updated_at),
         "expected_remote_fingerprint" => remote_fingerprint,
         "proposed_fingerprint" => proposed_fingerprint,
         "local_changed_fields" => local_changed_fields(sync.baseline, local.snapshot),
         "expected_local_draft" => local.snapshot["draft"],
         "github_object_id" => remote.github_object_id,
         "github_node_id" => remote.github_node_id,
         "github_number" => remote.github_number,
         "resource_state_lock_version" => sync.resource_state_lock_version,
         "provider_identity" => provider_identity,
         "pull_eligibility_proof" => proof,
         "expected_merge_state" => persistent_merge_state(local.merge_state),
         "repository_mirror_id" => sync.repository_mirror_id
       }}
    end
  end

  defp validate_marker(marker, sync, local, provider_identity, proof, options) do
    with true <- is_map(marker) and marker["v"] == 1,
         true <- marker["action"] in ~w(update_remote_pull_issue set_remote_pull_draft),
         true <- marker["resource_kind"] == "pull",
         true <- marker["local_resource_id"] == local.local_resource_id,
         true <- marker["github_object_id"] == sync.github_object_id,
         true <- marker["github_node_id"] == sync.github_node_id,
         true <- marker["github_number"] == sync.github_number,
         true <- marker["resource_state_lock_version"] == sync.resource_state_lock_version,
         true <- marker["provider_identity"] == provider_identity,
         true <- marker["pull_eligibility_proof"] == proof,
         true <- marker["expected_merge_state"] == persistent_merge_state(local.merge_state),
         version when is_integer(version) and version > 0 <- marker["expected_local_version"],
         true <- local.local_version >= version,
         true <- valid_fingerprint?(marker["expected_local_fingerprint"]),
         true <- valid_fingerprint?(marker["expected_remote_fingerprint"]),
         true <- valid_fingerprint?(marker["proposed_fingerprint"]),
         true <- valid_changed_fields?(marker["local_changed_fields"]),
         true <- is_boolean(marker["expected_local_draft"]),
         {:ok, local_fingerprint} <- fingerprint(local.snapshot, options),
         true <-
           local.local_version != version or
             local_fingerprint == marker["expected_local_fingerprint"] do
      :ok
    else
      _invalid -> {:error, :ambiguous_external_effect}
    end
  end

  defp provider_identity(remote) do
    identity = %{
      "github_issue_object_id" => remote.github_issue_object_id,
      "github_issue_node_id" => remote.github_issue_node_id,
      "github_number" => remote.github_number,
      "head_repository" =>
        if remote.head_repository do
          %{
            "id" => remote.head_repository.github_object_id,
            "node_id" => remote.head_repository.github_node_id
          }
        end,
      "base_repository" => %{
        "id" => remote.base_repository.github_object_id,
        "node_id" => remote.base_repository.github_node_id
      }
    }

    case json_safe(identity) do
      {:ok, identity} -> {:ok, identity}
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp provenance(sync, operation) do
    %{
      origin: :github,
      causation_id:
        sync.provenance.delivery_guid || sync.provenance.outbox_event_id ||
          "mirror-operation:#{operation.id}",
      correlation_id:
        sync.provenance.correlation_id || sync.provenance.delivery_guid ||
          "mirror-operation:#{operation.id}"
    }
  end

  defp valid_observation?(%{presence: :present, snapshot: snapshot, merge_state: merge_state}),
    do: valid_snapshot?(snapshot) and is_map(merge_state)

  defp valid_observation?(_), do: false

  defp valid_snapshot?(snapshot) when is_map(snapshot),
    do: Enum.sort(Map.keys(snapshot)) == Enum.sort(@mutable_fields ++ @ref_fields)

  defp valid_snapshot?(_), do: false

  defp unmerged?(%{merged: false, merged_at: nil, merge_commit_sha: nil}), do: true
  defp unmerged?(_), do: false

  defp strip_merged(%{merged_at: merged_at, merge_commit_sha: sha}),
    do: %{merged_at: merged_at, merge_commit_sha: sha}

  defp persistent_merge_state(%{merged_at: merged_at, merge_commit_sha: sha}) do
    %{
      "merged_at" => if(is_nil(merged_at), do: nil, else: iso8601(merged_at)),
      "merge_commit_sha" => sha
    }
  end

  defp ref_fields(snapshot), do: Map.take(snapshot, @ref_fields)

  defp local_changed_fields(baseline, local) do
    @mutable_fields
    |> Enum.filter(&(baseline[&1] != local[&1]))
    |> Enum.sort()
  end

  defp valid_changed_fields?(fields) when is_list(fields) do
    fields == Enum.sort(Enum.uniq(fields)) and Enum.all?(fields, &(&1 in @mutable_fields))
  end

  defp valid_changed_fields?(_fields), do: false

  defp reconstruct_local_preimage(marker, remote, baseline) do
    changed = marker["local_changed_fields"]
    action = marker["action"]

    if valid_snapshot?(remote) and valid_snapshot?(baseline) and valid_changed_fields?(changed) do
      Enum.reduce(changed, baseline, fn field, reconstructed ->
        value =
          if field == "draft" and action == "update_remote_pull_issue",
            do: marker["expected_local_draft"],
            else: remote[field]

        Map.put(reconstructed, field, value)
      end)
    end
  end

  defp normalize_precondition(:ok), do: :ok
  defp normalize_precondition({:error, reason}), do: {:error, reason}
  defp normalize_precondition({:conflict, _kind}), do: {:error, :ambiguous_external_effect}

  defp conflict(operation, now, sync, kind, local, remote, options) do
    baseline = if is_map(sync.baseline), do: sync.baseline, else: %{}

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
    {failure_class, retry_at} = retry_schedule(reason, now)

    callback(options, :checkpoint, &ForgeMirrors.checkpoint_resource_operation/5).(
      operation,
      recovery_checkpoint(reason),
      retry_at,
      failure_class,
      now
    )
  end

  defp persist_failure(operation, now, reason, options) do
    if operation.state == :effect_pending do
      schedule_effect_recovery(operation, now, reason, options)
    else
      persist_unmarked_failure(operation, now, reason, options)
    end
  end

  defp persist_unmarked_failure(operation, now, reason, options) do
    case failure(reason) do
      {:retry, failure_class, retry_at} ->
        retry_at = retry_at || DateTime.add(now, 30, :second)

        callback(options, :retry, &ForgeMirrors.retry_operation/5).(
          operation,
          now,
          retry_at,
          failure_class,
          retry_options(reason)
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
    do: {:fail, "permission_missing", "GitHub denied pull-request synchronization"}

  defp failure(%Error{kind: :not_found}),
    do: {:fail, "provider_validation", "mapped GitHub pull request was not found"}

  defp failure(%Error{}),
    do: {:fail, "provider_validation", "GitHub returned an invalid pull request"}

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
              :inconsistent_observation,
              :ambiguous_external_effect,
              :ineligible_pull
            ],
       do: {:fail, "local_validation", "pull-request synchronization state is invalid"}

  defp failure(:unsupported_resource),
    do: {:fail, "unsupported_resource", "pull request cannot be represented locally"}

  defp failure(:unsupported_metadata_conflict),
    do: {:fail, "local_validation", "read-only pull metadata differs from confirmed baseline"}

  defp failure(:unsupported_operation),
    do: {:fail, "unsupported_resource", "unsupported operation"}

  defp failure(:worker_crash), do: {:retry, "network", nil}
  defp failure(_reason), do: {:retry, "network", nil}

  defp recovery_checkpoint(:required_ref_unavailable),
    do: %{"failure_reason" => "required_ref_unavailable"}

  defp recovery_checkpoint(_reason), do: %{}

  defp retry_options(:required_ref_unavailable),
    do: [failure_detail: "required Git ref or commit is unavailable"]

  defp retry_options(_reason), do: []

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

  defp fingerprint(snapshot, options) do
    case callback(options, :fingerprint, &ForgeMirrors.resource_fingerprint/1).(snapshot) do
      {:ok, fingerprint} when is_binary(fingerprint) -> {:ok, fingerprint}
      fingerprint when is_binary(fingerprint) -> {:ok, fingerprint}
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp valid_fingerprint?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp json_safe(value) do
    {:ok, value |> JSON.encode!() |> JSON.decode!()}
  rescue
    _exception -> {:error, :invalid_projection}
  end

  defp request_options(sync),
    do: [gate_key: {:github_installation, sync.github_installation_id}]

  defp iso8601(%DateTime{} = datetime),
    do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

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
