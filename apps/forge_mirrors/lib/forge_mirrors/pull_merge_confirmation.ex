defmodule ForgeMirrors.PullMergeConfirmation do
  @moduledoc "Confirms a marked merge only against the exact current paired domain projection."
  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    MirrorRefState,
    PullMergeBoundary,
    PullEligibility,
    PullPairBoundary
  }

  @scalars ~w(title body state state_reason)
  @intent_keys ~w(id repository_id pull_request_id actor_user_id coordinator_operation_id commit_intent base_ref head_ref expected_base_oid expected_head_oid merge_tree_oid merge_oid)a

  def context(operation, now) do
    Repo.transaction(fn ->
      case load(operation, now) do
        {:ok, context} -> context
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Record only independently proven concurrent metadata edits for a marked merge."
  def record_metadata_conflict(
        operation,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        observation
      ) do
    Repo.transaction(fn ->
      with true <- DateTime.compare(next_attempt_at, now) != :lt,
           {:ok, context} <- load(operation, now),
           :ok <- validate_observation(context, observation),
           {:ok, local} <- locked_projection(context),
           {:ok, relationships} <-
             ForgeMirrors.resolve_issue_relationships(
               context.repository_mirror_id,
               :local,
               local.label_ids,
               local.assignee_refs
             ),
           {:ok, kind} <- metadata_conflict_kind(context, local, observation),
           issue =
             Map.merge(Map.take(local.fields, @scalars), %{
               "label_github_ids" =>
                 Enum.sort(Enum.map(relationships.labels, & &1.github_object_id)),
               "assignee_github_ids" =>
                 Enum.sort(Enum.map(relationships.assignees, & &1.github_user_id))
             }),
           {:ok, _} <-
             %ForgeMirrors.MirrorConflict{}
             |> ForgeMirrors.MirrorConflict.record_changeset(%{
               organization_mirror_id: context.organization_mirror_id,
               repository_mirror_id: context.repository_mirror_id,
               resource_kind: "pull_merge",
               resource_identity: to_string(context.intent.id),
               conflict_kind: kind,
               baseline_snapshot: %{
                 "pull" => context.pull.confirmed_snapshot,
                 "issue" => context.issue.confirmed_snapshot
               },
               local_snapshot: %{"pull" => local.fields, "issue" => issue},
               remote_snapshot: %{
                 "pull" => observation.pull.confirmed_snapshot,
                 "issue" => observation.issue.confirmed_snapshot
               }
             })
             |> Repo.insert(),
           {:ok, yielded} <- yield_conflict(context.operation, now, next_attempt_at, kind) do
        yielded
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_transition)
      end
    end)
  end

  def record_metadata_conflict(_, _, _, _), do: {:error, :invalid_transition}

  defp metadata_conflict_kind(context, local, observation) do
    baseline = context.pull.confirmed_snapshot
    remote = observation.pull.confirmed_snapshot

    cond do
      baseline["draft"] == false and
        local.fields["draft"] == true and remote["draft"] == false ->
        {:ok, "merged_draft_conflict"}

      not compatible_merge_state?(baseline, local.fields) ->
        {:ok, "merged_state_conflict"}

      Enum.any?(~w(title body), fn field ->
        ForgeMirrors.ResourceDecision.scalar(baseline[field], local.fields[field], remote[field]) ==
            {:conflict, :concurrent_edit}
      end) ->
        {:ok, "concurrent_edit"}

      true ->
        {:error, :merge_metadata_not_conflicting}
    end
  end

  defp yield_conflict(operation, now, next_attempt_at, kind) do
    query =
      from op in MirrorOperation,
        where:
          op.id == ^operation.id and op.state == :effect_pending and
            op.lease_owner == ^operation.lease_owner and
            op.lock_version == ^operation.lock_version and
            op.lease_expires_at == ^operation.lease_expires_at and op.lease_expires_at > ^now and
            op.lease_expires_at > fragment("timezone('UTC', clock_timestamp())")

    case Repo.update_all(query,
           set: [
             lease_owner: nil,
             lease_expires_at: nil,
             next_attempt_at: next_attempt_at,
             updated_at: now,
             failure_disposition: :conflict,
             failure_class: "stale_baseline",
             failure_detail: kind
           ],
           inc: [lock_version: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
      _ -> {:error, :lost_lease}
    end
  end

  def authorize(operation, now, intent, observation) do
    if Repo.in_transaction?() do
      with {:ok, context} <- load(operation, now),
           :ok <- same_intent(context.intent, intent),
           :ok <- validate_observation(context, observation),
           {:ok, local} <- locked_projection(context),
           true <- compatible_merge_state?(context.pull.confirmed_snapshot, local.fields) do
        :ok
      else
        false -> {:error, :merge_metadata_unconfirmed}
        {:error, _} = error -> error
      end
    else
      {:error, :transaction_required}
    end
  end

  defp compatible_merge_state?(baseline, fields) do
    state = Map.take(fields, ~w(state state_reason))

    state == Map.take(baseline, ~w(state state_reason)) or
      state == %{"state" => "closed", "state_reason" => "completed"}
  end

  defp locked_projection(context) do
    # Sync.resource/3 locks canonical Issue then Pull. Its nested transaction
    # retains both locks until this enclosing confirmation transaction ends.
    with {:ok, local} <-
           apply(ForgePulls, :sync_projection, [
             context.repository_id,
             :pull,
             context.expected.pull_id
           ]),
         true <-
           local.issue_id == context.expected.issue_id and
             local.local_version >= context.expected.local_version do
      {:ok, local}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  def confirm(operation, now, intent, observation, actual_projection) do
    if Repo.in_transaction?() do
      with {:ok, context} <- load(operation, now),
           :ok <- same_intent(context.intent, intent),
           :ok <- validate_observation(context, observation),
           {:ok, actual} <- actual_projection(context, actual_projection, observation) do
        # Any write failure aborts the caller's enclosing domain transaction too.
        Repo.transaction(fn ->
          with {:ok, pull} <- save_mapping(context.pull, observation.pull, actual.local_version),
               {:ok, issue} <-
                 save_mapping(context.issue, observation.issue, actual.local_version),
               {:ok, _} <- advance_ref(context.base_ref, intent.merge_oid, now),
               {:ok, completed} <- complete(context.operation, now) do
            %{operation: completed, pull_resource_state: pull, issue_resource_state: issue}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    else
      {:error, :transaction_required}
    end
  end

  defp load(operation, now) do
    with {:ok, context} <- PullMergeBoundary.finalization_context(operation, now),
         :ok <- no_conflict(context),
         {:ok, base_ref} <- eligibility(context),
         {:ok, pull, issue} <- pair(context) do
      {:ok, Map.merge(context, %{pull: pull, issue: issue, base_ref: base_ref})}
    end
  end

  defp no_conflict(context) do
    if Repo.exists?(
         from conflict in ForgeMirrors.MirrorConflict,
           where:
             conflict.organization_mirror_id == ^context.organization_mirror_id and
               conflict.resource_kind == "pull_merge" and
               conflict.resource_identity == ^to_string(context.intent.id) and
               conflict.state == :open
       ), do: {:error, :merge_conflict_unresolved}, else: :ok
  end

  defp same_intent(expected, actual) when is_map(actual) do
    if Map.take(expected, @intent_keys) == Map.take(actual, @intent_keys),
      do: :ok,
      else: {:error, :stale_merge_identity}
  end

  defp same_intent(_, _), do: {:error, :stale_merge_identity}

  defp eligibility(context) do
    original = context.expected.pull_eligibility_proof

    binding_ids =
      Enum.uniq([context.repository_mirror_id, original["head"]["repository_mirror_id"]])

    names = Enum.uniq([context.intent.base_ref, context.intent.head_ref])
    # Keep mirror locks before ref and resource locks throughout finalization.
    Repo.all(
      from m in ForgeMirrors.RepositoryMirror,
        where: m.id in ^binding_ids,
        order_by: m.id,
        lock: "FOR UPDATE"
    )

    refs =
      Repo.all(
        from r in MirrorRefState,
          where: r.repository_mirror_id in ^binding_ids and r.ref_name in ^names,
          order_by: r.id,
          lock: "FOR UPDATE"
      )

    with {:ok, fresh} <-
           PullEligibility.check(
             context.repository_mirror_id,
             original["head"]["repository_id"],
             %{
               base_ref: context.intent.base_ref,
               head_ref: context.intent.head_ref,
               base_sha: context.intent.expected_base_oid,
               head_sha: context.intent.expected_head_oid
             }
           ),
         true <- immutable_proof(json(fresh)) == immutable_proof(original),
         %MirrorRefState{} = base <-
           Enum.find(
             refs,
             &(&1.repository_mirror_id == context.repository_mirror_id and
                 &1.ref_name == context.intent.base_ref)
           ) do
      {:ok, base}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp immutable_proof(proof) do
    proof
    |> Map.delete("organization_lock_version")
    |> Map.update!("base", &Map.delete(&1, "mirror_lock_version"))
    |> Map.update!("head", &Map.delete(&1, "mirror_lock_version"))
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp pair(context) do
    rows =
      Repo.all(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^context.repository_mirror_id and
              ((m.resource_kind == :pull and m.local_resource_id == ^context.expected.pull_id) or
                 (m.resource_kind == :issue and m.local_resource_id == ^context.expected.issue_id)),
          order_by: m.id,
          lock: "FOR UPDATE"
      )

    pull = Enum.find(rows, &(&1.resource_kind == :pull))
    issue = Enum.find(rows, &(&1.resource_kind == :issue))
    identity = context.expected.provider_identity
    pinned = context.provider_pull_identity

    with 2 <- length(rows),
         %{state: :confirmed, local_resource_type: "ForgePulls.PullRequest"} <- pull,
         %{state: :confirmed, local_resource_type: "ForgeIssues.Issue"} <- issue,
         true <-
           pull.github_object_id == pinned["id"] and pull.github_node_id == pinned["node_id"] and
             pull.github_number == identity["github_number"],
         true <-
           issue.github_object_id == identity["github_issue_object_id"] and
             issue.github_node_id == identity["github_issue_node_id"] and
             issue.github_number == identity["github_number"],
         true <- pull.provider_identity == identity,
         true <- pull.lock_version == context.expected.resource_state_lock_version,
         true <-
           pull.confirmed_local_version == context.expected.local_version and
             pull.confirmed_snapshot == context.expected.fields,
         true <- pull.confirmed_merge_state == %{"merged_at" => nil, "merge_commit_sha" => nil},
         :ok <- PullPairBoundary.baselines(pull, issue),
         true <- fingerprint?(pull) and fingerprint?(issue) do
      {:ok, pull, issue}
    else
      _ -> {:error, :stale_paired_mapping}
    end
  end

  defp fingerprint?(mapping) do
    case ForgeMirrors.resource_fingerprint(mapping.confirmed_snapshot) do
      {:ok, fingerprint} ->
        is_nil(mapping.confirmed_fingerprint) or mapping.confirmed_fingerprint == fingerprint

      _ ->
        false
    end
  end

  defp validate_observation(
         context,
         %{remote_base_oid: oid, pull: pull, issue: issue} = observation
       )
       when is_map(pull) and is_map(issue) do
    with true <- map_size(observation) == 3 and oid == context.intent.merge_oid,
         true <-
           keys?(
             pull,
             ~w(github_object_id github_node_id github_number provider_identity provider_base_oid confirmed_snapshot confirmed_merge_state remote_updated_at)a
           ),
         true <-
           keys?(
             issue,
             ~w(github_object_id github_node_id github_number provider_state_reason confirmed_snapshot remote_updated_at)a
           ),
         true <-
           pull.provider_base_oid in [context.intent.expected_base_oid, context.intent.merge_oid],
         true <- issue.provider_state_reason in [nil, "completed"],
         true <-
           observation_identity?(pull, context.pull) and
             observation_identity?(issue, context.issue),
         true <- pull.provider_identity == context.expected.provider_identity,
         true <-
           observation_time?(pull.remote_updated_at, context.pull) and
             observation_time?(issue.remote_updated_at, context.issue),
         :ok <-
           PullPairBoundary.baselines(
             %{confirmed_snapshot: pull.confirmed_snapshot, confirmed_local_version: 1},
             %{confirmed_snapshot: issue.confirmed_snapshot, confirmed_local_version: 1}
           ),
         true <-
           pull.confirmed_snapshot["state"] == "closed" and
             pull.confirmed_snapshot["state_reason"] == "completed",
         true <-
           Map.take(pull.confirmed_snapshot, ~w(base_ref base_sha head_ref head_sha)) == %{
             "base_ref" => context.intent.base_ref,
             "base_sha" => oid,
             "head_ref" => context.intent.head_ref,
             "head_sha" => context.intent.expected_head_oid
           },
         %{"merged_at" => merged_at, "merge_commit_sha" => ^oid} = merge <-
           pull.confirmed_merge_state,
         true <- map_size(merge) == 2 and is_binary(merged_at),
         {:ok, %DateTime{utc_offset: 0, std_offset: 0}, 0} <- DateTime.from_iso8601(merged_at) do
      :ok
    else
      _ -> {:error, :merge_metadata_unconfirmed}
    end
  end

  defp validate_observation(_, _), do: {:error, :merge_metadata_unconfirmed}
  defp keys?(value, keys), do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp observation_identity?(observation, mapping),
    do:
      Enum.all?(
        ~w(github_object_id github_node_id github_number)a,
        &(Map.fetch!(observation, &1) == Map.fetch!(mapping, &1))
      )

  defp observation_time?(%DateTime{utc_offset: 0, std_offset: 0} = time, mapping),
    do:
      is_nil(mapping.confirmed_remote_updated_at) or
        DateTime.compare(time, mapping.confirmed_remote_updated_at) != :lt

  defp observation_time?(_, _), do: false

  defp actual_projection(context, supplied, observation) do
    with {:ok, actual} <-
           apply(ForgePulls, :sync_projection, [
             context.repository_id,
             :pull,
             context.expected.pull_id
           ]),
         true <- actual == supplied and actual.local_version >= context.expected.local_version,
         true <- actual.fields == observation.pull.confirmed_snapshot,
         %{merged_at: %DateTime{} = time, merge_commit_sha: sha} <- actual.merge_state,
         true <-
           %{"merged_at" => DateTime.to_iso8601(time), "merge_commit_sha" => sha} ==
             observation.pull.confirmed_merge_state,
         {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             context.repository_mirror_id,
             :local,
             actual.label_ids,
             actual.assignee_refs
           ),
         issue =
           Map.merge(Map.take(actual.fields, @scalars), %{
             "label_github_ids" =>
               Enum.sort(Enum.map(relationships.labels, & &1.github_object_id)),
             "assignee_github_ids" =>
               Enum.sort(Enum.map(relationships.assignees, & &1.github_user_id))
           }),
         true <- issue == observation.issue.confirmed_snapshot do
      {:ok, actual}
    else
      _ -> {:error, :merge_metadata_unconfirmed}
    end
  end

  defp save_mapping(mapping, observation, version) do
    with {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(observation.confirmed_snapshot) do
      attrs = %{
        confirmed_snapshot: observation.confirmed_snapshot,
        confirmed_fingerprint: fingerprint,
        confirmed_local_version: version,
        confirmed_remote_updated_at: observation.remote_updated_at,
        lock_version: mapping.lock_version + 1
      }

      attrs =
        if mapping.resource_kind == :pull,
          do: Map.put(attrs, :confirmed_merge_state, observation.confirmed_merge_state),
          else: attrs

      mapping |> MirrorResourceState.persistence_changeset(attrs) |> Repo.update()
    end
  end

  defp advance_ref(ref, oid, now) do
    ref
    |> MirrorRefState.persistence_changeset(%{
      state: :confirmed,
      confirmed_oid: oid,
      last_local_oid: oid,
      last_remote_oid: oid,
      last_confirmed_at: now,
      lock_version: ref.lock_version + 1
    })
    |> Repo.update()
  end

  defp complete(operation, now) do
    query =
      from op in MirrorOperation,
        where:
          op.id == ^operation.id and op.state == :effect_pending and
            op.lease_owner == ^operation.lease_owner and
            op.lock_version == ^operation.lock_version and
            op.lease_expires_at == ^operation.lease_expires_at and op.lease_expires_at > ^now and
            op.lease_expires_at > fragment("timezone('UTC', clock_timestamp())")

    case Repo.update_all(query,
           set: [
             state: :completed,
             completed_at: now,
             updated_at: now,
             external_effect_marker: nil,
             effect_marked_at: nil,
             lease_owner: nil,
             lease_expires_at: nil,
             failure_class: nil,
             failure_disposition: nil,
             failure_detail: nil
           ],
           inc: [lock_version: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
      _ -> {:error, :lost_lease}
    end
  end
end
