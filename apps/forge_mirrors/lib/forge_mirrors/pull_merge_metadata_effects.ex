defmodule ForgeMirrors.PullMergeMetadataEffects do
  @moduledoc """
  Durable scalar issue-metadata effects subordinate to a coordinated merge.

  The operation marker remains a compact pointer. Full expected-local,
  expected-remote and target evidence is retained in an immutable
  `PullMetadataIntent` row before the marker is replaced atomically.
  """

  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorResourceState,
    PullMergeBoundary,
    PullMergeConfirmation,
    PullMetadataIntent,
    ResourceDecision
  }

  @issue_keys ~w(title body state state_reason label_github_ids assignee_github_ids)
  @sets ~w(label_github_ids assignee_github_ids)
  @scalars ~w(title body)
  @intent_keys ~w(id repository_id pull_request_id actor_user_id coordinator_operation_id commit_intent base_ref head_ref expected_base_oid expected_head_oid merge_tree_oid merge_oid)a

  @doc "Persist an exact outbound title/body effect after authenticating the merged provider pair."
  def mark(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        intent,
        observation,
        expected_local_version,
        target_issue
      )
      when is_map(intent) and is_map(observation) and is_integer(expected_local_version) and
             expected_local_version > 0 and is_map(target_issue) do
    Repo.transaction(fn ->
      with {:ok, merge} <- PullMergeBoundary.finalization_context(operation, now),
           :ok <- require_write_permission(merge.github_installation_id),
           :ok <- same_intent(merge.intent, intent),
           :ok <-
             PullMergeConfirmation.authorize_effect_observation(
               operation,
               now,
               intent,
               observation
             ),
           {:ok, local} <- local_projection(merge),
           true <- local.local_version == expected_local_version,
           {:ok, local_issue} <- merged_issue(merge, local),
           remote_issue when is_map(remote_issue) <-
             get_in(observation, [:issue, :confirmed_snapshot]),
           {:ok, payload} <- build_payload(local_issue, remote_issue, target_issue) do
        case merge.operation.external_effect_marker do
          %{"phase" => "remote_cas_pending"} ->
            persist_exact(merge.operation, now, merge, observation, local, payload)

          %{"phase" => "metadata_issue_pending"} ->
            resume_or_advance(merge, now, observation, local, payload)

          _ ->
            Repo.rollback(:invalid_transition)
        end
      else
        false -> Repo.rollback(:stale_local_projection)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:merge_metadata_unconfirmed)
      end
    end)
  end

  def mark(_, _, _, _, _, _), do: {:error, :invalid_argument}

  @doc "Reload a metadata effect under the current reclaimed merge lease."
  def recovery_context(%MirrorOperation{kind: "merge.pull"} = operation, %DateTime{} = now) do
    Repo.transaction(fn ->
      with {:ok, merge} <- PullMergeBoundary.finalization_context(operation, now),
           %PullMetadataIntent{} = metadata_intent <- merge.metadata_intent,
           :ok <- require_write_permission(merge.github_installation_id),
           {:ok, local} <- local_projection(merge),
           true <- local.local_version >= metadata_intent.local_version,
           {:ok, current_issue} <- merged_issue(merge, local) do
        Map.merge(merge, %{
          marker: merge.operation.external_effect_marker,
          local_projection: local,
          current_local_issue: current_issue
        })
      else
        false -> Repo.rollback(:stale_local_projection)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_metadata_intent)
      end
    end)
  end

  def recovery_context(_, _), do: {:error, :invalid_argument}

  @doc false
  def valid_payload?(payload) when is_map(payload) do
    Enum.sort(Map.keys(payload)) ==
      Enum.sort(~w(v expected_local_issue expected_remote_issue target_issue)) and
      payload["v"] == 1 and
      Enum.all?(~w(expected_local_issue expected_remote_issue target_issue), fn key ->
        valid_issue?(payload[key])
      end) and
      payload["expected_remote_issue"] != payload["target_issue"] and
      scalar_payload?(payload) and byte_size(JSON.encode!(payload)) <= 2_000_000
  end

  def valid_payload?(_), do: false

  defp persist(operation, now, merge, observation, local, payload) do
    sequence =
      Repo.one(
        from i in PullMetadataIntent,
          where: i.operation_id == ^operation.id,
          select: max(i.sequence)
      ) || 0

    with {:ok, metadata_intent} <-
           %PullMetadataIntent{}
           |> PullMetadataIntent.create_changeset(%{
             operation_id: operation.id,
             repository_mirror_id: merge.repository_mirror_id,
             pull_id: merge.expected.pull_id,
             issue_id: merge.expected.issue_id,
             local_version: local.local_version,
             sequence: sequence + 1,
             payload: payload
           })
           |> Repo.insert(),
         {:ok, marked} <-
           PullMergeBoundary.replace_metadata_marker(
             operation,
             now,
             operation.external_effect_marker,
             %{
               "action" => "update_remote_pull_issue",
               "metadata_intent_id" => metadata_intent.id,
               "metadata_intent_hash" => metadata_intent.payload_fingerprint,
               "expected_remote_updated_at" =>
                 DateTime.to_iso8601(observation.pull.remote_updated_at),
               "expected_remote_issue_updated_at" =>
                 DateTime.to_iso8601(observation.issue.remote_updated_at)
             }
           ) do
      %{
        operation: marked,
        marker: marked.external_effect_marker,
        intent: metadata_intent,
        local_projection: local
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_or_advance(merge, now, observation, local, payload) do
    marker = merge.operation.external_effect_marker
    metadata_intent = merge.metadata_intent

    valid =
      metadata_intent.payload == payload and metadata_intent.local_version == local.local_version and
        marker["action"] == "update_remote_pull_issue" and
        marker["expected_remote_updated_at"] ==
          DateTime.to_iso8601(observation.pull.remote_updated_at) and
        marker["expected_remote_issue_updated_at"] ==
          DateTime.to_iso8601(observation.issue.remote_updated_at)

    cond do
      valid ->
        %{
          operation: merge.operation,
          marker: marker,
          intent: metadata_intent,
          local_projection: local
        }

      local.local_version > metadata_intent.local_version and
        payload["expected_remote_issue"] == metadata_intent.payload["target_issue"] and
          observation_versions_current?(marker, observation) ->
        persist_exact(merge.operation, now, merge, observation, local, payload)

      true ->
        Repo.rollback(:merge_metadata_unconfirmed)
    end
  end

  defp persist_exact(operation, now, merge, observation, local, payload) do
    case exact_scalar_target(merge, local, observation, payload) do
      :ok -> persist(operation, now, merge, observation, local, payload)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp observation_versions_current?(marker, observation) do
    with {:ok, expected_pull, 0} <- DateTime.from_iso8601(marker["expected_remote_updated_at"]),
         {:ok, expected_issue, 0} <-
           DateTime.from_iso8601(marker["expected_remote_issue_updated_at"]) do
      DateTime.compare(observation.pull.remote_updated_at, expected_pull) != :lt and
        DateTime.compare(observation.issue.remote_updated_at, expected_issue) != :lt
    else
      _ -> false
    end
  end

  defp require_write_permission(installation_id) do
    case Repo.one(
           from i in GitHubAppInstallation,
             where: i.github_installation_id == ^installation_id,
             lock: "FOR UPDATE"
         ) do
      %{state: :active, permissions: %{"pull_requests" => "write"}} -> :ok
      %{state: :active} -> {:error, :permission_missing}
      _ -> {:error, :credential_revoked}
    end
  end

  defp same_intent(expected, actual) do
    if Map.take(expected, @intent_keys) == Map.take(actual, @intent_keys),
      do: :ok,
      else: {:error, :stale_merge_identity}
  end

  defp local_projection(merge),
    do:
      apply(ForgePulls, :sync_projection, [
        merge.repository_id,
        :pull,
        merge.expected.pull_id
      ])

  defp merged_issue(merge, local) do
    with {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             merge.repository_mirror_id,
             :local,
             local.label_ids,
             local.assignee_refs
           ) do
      {:ok,
       %{
         "title" => local.fields["title"],
         "body" => local.fields["body"],
         "state" => "closed",
         "state_reason" => "completed",
         "label_github_ids" => Enum.sort(Enum.map(relationships.labels, & &1.github_object_id)),
         "assignee_github_ids" =>
           Enum.sort(Enum.map(relationships.assignees, & &1.github_user_id))
       }}
    end
  end

  defp build_payload(local, remote, target) do
    payload = %{
      "v" => 1,
      "expected_local_issue" => local,
      "expected_remote_issue" => remote,
      "target_issue" => target
    }

    if valid_payload?(payload),
      do: {:ok, payload},
      else: {:error, :invalid_metadata_payload}
  end

  defp exact_scalar_target(merge, local, observation, payload) do
    baseline =
      Repo.one(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^merge.repository_mirror_id and
              m.resource_kind == :issue and m.local_resource_id == ^merge.expected.issue_id,
          lock: "FOR UPDATE"
      )

    with %MirrorResourceState{state: :confirmed} <- baseline do
      baseline_issue =
        case merge.metadata_intent do
          %PullMetadataIntent{} = prior -> prior.payload["target_issue"]
          nil -> baseline.confirmed_snapshot
        end

      local_issue = payload["expected_local_issue"]
      remote_issue = payload["expected_remote_issue"]
      target_issue = payload["target_issue"]

      scalar_target =
        Map.new(@scalars, fn field ->
          decision =
            ResourceDecision.scalar(
              baseline_issue[field],
              local_issue[field],
              remote_issue[field]
            )

          {field, decision_value(decision)}
        end)

      valid =
        local.fields["draft"] == false and
          observation.pull.confirmed_snapshot["draft"] == false and
          Map.take(local_issue, ~w(state state_reason)) == closed_state() and
          Map.take(remote_issue, ~w(state state_reason)) == closed_state() and
          Map.take(target_issue, ~w(state state_reason)) == closed_state() and
          Enum.all?(@sets, fn field ->
            baseline_issue[field] == local_issue[field] and
              local_issue[field] == remote_issue[field] and
              remote_issue[field] == target_issue[field]
          end) and scalar_target == Map.take(target_issue, @scalars) and
          Enum.all?(Map.values(scalar_target), &(&1 != :conflict))

      if valid, do: :ok, else: {:error, :invalid_metadata_payload}
    else
      _ -> {:error, :stale_paired_mapping}
    end
  end

  defp decision_value({:conflict, _}), do: :conflict
  defp decision_value(decision), do: elem(decision, tuple_size(decision) - 1)

  defp scalar_payload?(payload) do
    local = payload["expected_local_issue"]
    remote = payload["expected_remote_issue"]
    target = payload["target_issue"]

    Enum.all?([local, remote, target], &(Map.take(&1, ~w(state state_reason)) == closed_state())) and
      Enum.all?(@sets, &(local[&1] == remote[&1] and remote[&1] == target[&1])) and
      Enum.any?(@scalars, &(remote[&1] != target[&1]))
  end

  defp valid_issue?(issue) when is_map(issue) do
    Enum.sort(Map.keys(issue)) == Enum.sort(@issue_keys) and valid_title?(issue["title"]) and
      valid_body?(issue["body"]) and Map.take(issue, ~w(state state_reason)) == closed_state() and
      Enum.all?(@sets, &valid_ids?(issue[&1]))
  end

  defp valid_issue?(_), do: false

  defp valid_title?(value), do: valid_text?(value, 256) and value != ""
  defp valid_body?(nil), do: true
  defp valid_body?(value), do: valid_text?(value, 65_536)

  defp valid_text?(value, max) do
    is_binary(value) and byte_size(value) <= max * 4 and String.valid?(value) and
      not String.contains?(value, <<0>>) and
      length(Enum.take(String.codepoints(value), max + 1)) <= max
  end

  defp valid_ids?(ids) when is_list(ids),
    do:
      length(Enum.take(ids, 513)) <= 512 and ids == Enum.sort(Enum.uniq(ids)) and
        Enum.all?(ids, &(is_integer(&1) and &1 in 1..9_223_372_036_854_775_807))

  defp valid_ids?(_), do: false
  defp closed_state, do: %{"state" => "closed", "state_reason" => "completed"}
end
