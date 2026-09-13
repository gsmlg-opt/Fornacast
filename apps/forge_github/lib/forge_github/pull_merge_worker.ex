defmodule ForgeGitHub.PullMergeWorker do
  @moduledoc """
  Bounded remote CAS execution for an already written coordinated merge.

  A successful push only yields the durable pre-push marker. A subsequent
  authenticated observation of the exact merged result and shared metadata can
  finalize locally through the coordinator boundary. Ref-only readiness never
  closes a pull. This module is not yet admitted by the worker pool.
  """
  alias ForgeGitHub.{
    InstallationToken,
    InstallationTokenBroker,
    IssueClient,
    IssueSyncProjection,
    LFSSync,
    PullClient,
    PullMetadataDecision,
    PullMetadataRecovery,
    PullMergeObservation,
    PullSyncWorker,
    RefObservation
  }

  alias ForgeMirrors.{
    MirrorOperation,
    OrganizationMirror,
    PullMergeBoundary,
    PullMergeConfirmation,
    PullMergeMetadataEffects,
    RepositoryMirror
  }

  alias Fornacast.Repo
  alias GitCore.Remote.{RefUpdate, SyncRequest}

  @test_callbacks Mix.env() == :test
  @max_metadata_effects 3

  def process_operation(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        options
      )
      when is_list(options) do
    case operation.external_effect_marker do
      %{"phase" => "metadata_issue_pending"} ->
        recover_metadata(operation, now, options, 0)

      marker when is_map(marker) ->
        recover(operation, now, options)

      nil ->
        with {:ok, context} <- PullMergeBoundary.context(operation, now),
             {:ok, sync} <- execution_context(context),
             {:ok, token} <- token(sync, options) do
          push(operation, now, sync, token, options)
        end
    end
  end

  def process_operation(_, _, _), do: {:error, :invalid_argument}

  defp recover(operation, now, options) do
    result =
      with {:ok, context} <- PullMergeBoundary.recovery_context(operation, now),
           {:ok, sync} <- execution_context(context),
           {:ok, token} <- token(sync, options),
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
    with {:ok, observation} <- PullMergeObservation.build(sync, pair, remote_base_oid) do
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

        {:error, _} = error ->
          error
      end
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
           {:ok, observation} <- PullMergeObservation.build(sync, pair, remote.oid),
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

    if context.current_local_issue in [payload["expected_local_issue"], payload["target_issue"]] do
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
      with {:ok, write_token} <- metadata_write_token(sync, options),
           {:ok, current} <- PullMergeMetadataEffects.recovery_context(operation, now),
           true <- metadata_intent(current).id == metadata_intent(context).id,
           attrs = scalar_effect_attrs(metadata_intent(current).payload),
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

    case result do
      {:error, reason} -> PullMergeBoundary.defer(operation, now, next(now), reason)
      other -> other
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
         {:ok, observation} <- PullMergeObservation.build(sync, pair, remote.oid),
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

  defp scalar_effect_attrs(payload) do
    expected = payload["expected_remote_issue"]
    target = payload["target_issue"]

    Map.new(~w(title body), fn field -> {field, target[field]} end)
    |> Enum.reject(fn {field, value} -> expected[field] == value end)
    |> Map.new()
  end

  defp retained_metadata_timestamps?(marker, observation) do
    marker["expected_remote_updated_at"] ==
      DateTime.to_iso8601(observation.pull.remote_updated_at) and
      marker["expected_remote_issue_updated_at"] ==
        DateTime.to_iso8601(observation.issue.remote_updated_at)
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
         :ok <- lfs(operation, sync, token, options) do
      # Remote.push_refs owns its own repository fence; nesting it under
      # with_ref_fences would deadlock its supervised transport task.
      with :ok <- local_refs(sync),
           :ok <- provider_ready(sync, token, options),
           {:ok, marked} <-
             PullMergeBoundary.mark(
               operation,
               now,
               operation.external_effect_marker,
               marker(sync.intent)
             ) do
        execute(marked, now, sync, token, options)
      end
    else
      {:incomplete, checkpoint} ->
        PullMergeBoundary.checkpoint_lfs(operation, now, checkpoint)

      {:error, _} = error ->
        error
    end
  end

  defp execute(marked, now, sync, _token, options) do
    # Recheck after marking: a slow LFS scan or provider request can outlive
    # the lease or installation permission that initially admitted the claim.
    with {:ok, push_token} <- push_token(sync, options),
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
    authorize = fn ->
      case PullMergeBoundary.context(operation, DateTime.utc_now(:second)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    with {:ok, token} <- push_token(sync, options),
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

  defp next(now), do: DateTime.add(now, 1, :second)
end
