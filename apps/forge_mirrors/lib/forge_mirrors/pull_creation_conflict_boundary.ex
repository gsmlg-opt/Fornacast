defmodule ForgeMirrors.PullCreationConflictBoundary do
  @moduledoc """
  Visible conflict recording for an ambiguous outbound creation intent.

  Candidate provider identities are evidence, not mappings. Failing the operation
  preserves its exact marker and scan checkpoint; the immutable intent continues
  to reserve this local pull until an explicit recovery owner resolves it.
  """
  import Ecto.Query
  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, PullOutboundCreation}

  @reasons %{
    "ambiguous_external_effect" => ~w(zero_complete_scan multiple_uuid_matches),
    "identity_conflict" => ~w(pair_mismatch refs_changed),
    "third_party_metadata" => ~w(third_party_metadata)
  }

  def conflict(
        %MirrorOperation{} = operation,
        %DateTime{} = now,
        marker,
        kind,
        evidence,
        lock_fun,
        fail_fun
      )
      when is_map(marker) and is_map(evidence) do
    if now.utc_offset == 0 and now.std_offset == 0 and valid_evidence?(kind, evidence) do
      Repo.transaction(fn ->
        with {:ok, persisted, scope} <- lock_fun.(operation),
             true <- persisted.state == :effect_pending,
             {:ok, intent} <- PullOutboundCreation.lock_recovery(persisted, scope, marker),
             :ok <- scan_evidence(persisted, evidence),
             {:ok, local} <- current_local(intent),
             {:ok, evidence} <- relationship_evidence(persisted, intent, evidence),
             {:ok, conflict} <-
               ForgeMirrors.record_conflict(%{
                 organization_mirror_id: persisted.organization_mirror_id,
                 repository_mirror_id: persisted.repository_mirror_id,
                 resource_kind: "pull",
                 resource_identity:
                   "#{persisted.repository_mirror_id}:pull:local:#{intent.pull_id}",
                 conflict_kind: kind,
                 baseline_snapshot:
                   Map.take(intent.payload, ~w(pull_snapshot issue_snapshot merge_state)),
                 local_snapshot: local,
                 remote_snapshot: evidence
               }),
             {:ok, persisted, _} <- lock_fun.(operation),
             {:ok, failed} <- fail_fun.(persisted, now) do
          %{operation: failed, conflict: conflict}
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_transition)
        end
      end)
    else
      {:error, :invalid_conflict_evidence}
    end
  end

  def conflict(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  defp current_local(intent) do
    issue =
      Repo.one(
        from i in "issues",
          where: i.id == ^intent.issue_id and i.repository_id == ^intent.repository_id,
          select: %{
            id: i.id,
            kind: i.kind,
            version: i.sync_version,
            title: i.title,
            body: i.body,
            state: i.state,
            state_reason: i.state_reason
          },
          lock: "FOR UPDATE"
      )

    pull =
      Repo.one(
        from p in "pull_requests",
          where:
            p.id == ^intent.pull_id and p.issue_id == ^intent.issue_id and
              p.repository_id == ^intent.repository_id,
          select: %{
            id: p.id,
            issue_id: p.issue_id,
            head_repository_id: p.head_repository_id,
            draft: p.draft,
            head_ref: p.head_ref,
            base_ref: p.base_ref,
            head_sha: p.head_sha,
            base_sha: p.base_sha,
            merged_at: type(p.merged_at, :utc_datetime),
            merge_commit_sha: p.merge_commit_sha
          },
          lock: "FOR UPDATE"
      )

    if issue && pull && issue.kind == "pull_request" do
      labels =
        Repo.all(
          from l in "issue_labels",
            where: l.issue_id == ^intent.issue_id,
            select: l.label_id,
            order_by: l.label_id,
            limit: 513
        )

      assignees =
        Repo.all(
          from a in "issue_assignees",
            where: a.issue_id == ^intent.issue_id,
            select: %{local_user_id: a.user_id, github_identity_id: a.github_identity_id},
            order_by: a.id,
            limit: 513
        )

      fields =
        Map.merge(
          Map.take(issue, ~w(title body state state_reason)a),
          Map.take(pull, ~w(draft head_ref base_ref head_sha base_sha)a)
        )

      {:ok,
       %{
         "pull_id" => pull.id,
         "issue_id" => issue.id,
         "local_version" => issue.version,
         "head_repository_id" => pull.head_repository_id,
         "pull_snapshot" => json(fields),
         "merge_state" => %{
           "merged_at" => if(pull.merged_at, do: DateTime.to_iso8601(pull.merged_at)),
           "merge_commit_sha" => pull.merge_commit_sha
         },
         "local_relationships" => %{"label_ids" => labels, "assignee_refs" => json(assignees)}
       }}
    else
      {:error, :invalid_local_identity}
    end
  end

  defp valid_evidence?("relationship_unavailable", evidence),
    do: evidence == %{"reason" => "missing_labels"}

  defp valid_evidence?(kind, evidence) do
    reasons = Map.get(@reasons, kind, [])

    Map.keys(evidence) -- ~w(reason candidates observation) == [] and
      evidence["reason"] in reasons and candidates?(Map.get(evidence, "candidates", [])) and
      (not Map.has_key?(evidence, "observation") or is_map(evidence["observation"])) and
      match?({:ok, _}, ForgeMirrors.resource_fingerprint(evidence))
  end

  defp relationship_evidence(operation, intent, %{"reason" => "missing_labels"}) do
    checkpoint = operation.checkpoint["pull_creation_label_nodes"]
    ids = intent.payload["issue_snapshot"]["label_github_ids"]

    with %{"intent_id" => id, "intent_fingerprint" => hash, "page" => page, "complete" => true} <-
           checkpoint,
         true <-
           map_size(checkpoint) == 4 and id == intent.id and hash == intent.payload_fingerprint,
         true <- is_integer(page) and page in 1..2_147_483_647,
         true <- is_list(ids) and length(ids) in 1..512 and Enum.all?(ids, &positive?/1),
         true <- length(ids) == length(Enum.uniq(ids)) do
      represented =
        Repo.all(
          from m in MirrorResourceState,
            join: l in "repository_labels",
            on: l.id == m.local_resource_id,
            where:
              m.repository_mirror_id == ^operation.repository_mirror_id and
                m.resource_kind == :label and
                m.local_resource_type == "ForgeIssues.Label" and m.state == :confirmed and
                l.repository_id == ^intent.repository_id and m.github_object_id in ^ids,
            select: %{id: m.github_object_id, node: m.github_node_id},
            lock: "FOR UPDATE"
        )

      known = represented |> Enum.filter(&valid_label_node?(&1.node)) |> Enum.map(& &1.id)
      missing = Enum.sort(ids -- known)

      if missing != [],
        do:
          {:ok,
           %{
             "reason" => "missing_labels",
             "missing_label_github_ids" => missing,
             "label_inventory" => checkpoint
           }},
        else: {:error, :invalid_conflict_evidence}
    else
      _ -> {:error, :invalid_conflict_evidence}
    end
  end

  defp relationship_evidence(_, _, evidence), do: {:ok, evidence}

  defp valid_label_node?(node) when is_binary(node),
    do:
      byte_size(node) in 1..255 and
        String.valid?(node) and String.trim(node) == node and not String.contains?(node, <<0>>)

  defp valid_label_node?(_), do: false

  defp scan_evidence(operation, %{"reason" => "zero_complete_scan"}) do
    case operation.checkpoint["pull_creation_recovery"] do
      %{"complete" => true, "candidate" => nil, "page" => page}
      when is_integer(page) and page in 1..1_000_000 ->
        :ok

      _ ->
        {:error, :invalid_conflict_evidence}
    end
  end

  defp scan_evidence(_, %{"reason" => "multiple_uuid_matches"} = evidence) do
    case evidence["candidates"] do
      [first, second] when first != second -> :ok
      _ -> {:error, :invalid_conflict_evidence}
    end
  end

  defp scan_evidence(_, _), do: :ok

  defp candidates?(values) when is_list(values) and length(values) <= 2,
    do: Enum.all?(values, &candidate?/1)

  defp candidates?(_), do: false

  defp candidate?(
         %{"github_object_id" => id, "github_node_id" => node, "github_number" => number} = value
       ),
       do:
         map_size(value) == 3 and positive?(id) and positive?(number) and is_binary(node) and
           byte_size(node) in 1..255 and String.valid?(node) and String.trim(node) == node and
           not String.contains?(node, <<0>>)

  defp candidate?(_), do: false
  defp positive?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807
  defp json(value), do: JSON.decode!(JSON.encode!(value))
end
