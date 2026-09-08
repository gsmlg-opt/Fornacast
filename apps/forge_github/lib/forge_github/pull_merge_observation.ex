defmodule ForgeGitHub.PullMergeObservation do
  @moduledoc "Read-only normalization of an observed, exact coordinated merge result."
  import Ecto.Query
  alias ForgeGitHub.{IssueSyncProjection, PullSyncProjection}
  alias Fornacast.Repo

  def build(
        %{
          repository_mirror_id: binding_id,
          expected: %{provider_identity: identity},
          provider_pull_identity: pinned,
          intent: %{
            merge_oid: merge_oid,
            expected_base_oid: base_oid,
            expected_head_oid: head_oid,
            base_ref: base_ref,
            head_ref: head_ref
          }
        } = sync,
        %{pull: raw_pull, issue: raw_issue},
        remote_base_oid
      )
      when is_map(identity) and is_map(pinned) and is_map(raw_pull) and is_map(raw_issue) and
             is_binary(merge_oid) do
    with true <- remote_base_oid == merge_oid,
         {:ok, relationships} <- relationships(binding_id, raw_issue),
         {:ok, issue} <-
           IssueSyncProjection.from_remote_issue(raw_issue, relationships, sync[:correlation_id]),
         {:ok, pull} <- PullSyncProjection.from_remote(raw_pull, issue),
         true <-
           pull.github_object_id == pinned["id"] and pull.github_node_id == pinned["node_id"],
         true <-
           issue.github_object_id == identity["github_issue_object_id"] and
             issue.github_node_id == identity["github_issue_node_id"] and
             issue.github_number == identity["github_number"] and
             pull.github_number == identity["github_number"],
         true <-
           repository_identity(pull.base_repository) == identity["base_repository"] and
             repository_identity(pull.head_repository) == identity["head_repository"],
         true <-
           pull.snapshot["base_ref"] == base_ref and pull.snapshot["head_ref"] == head_ref and
             pull.snapshot["base_sha"] in [base_oid, merge_oid] and
             pull.snapshot["head_sha"] == head_oid,
         %{merged: true, merged_at: %DateTime{} = merged_at, merge_commit_sha: ^merge_oid} <-
           pull.merge_state,
         true <-
           issue.snapshot["state"] == "closed" and
             issue.snapshot["state_reason"] in [nil, "completed"] do
      # GitHub's pull base.sha can retain the pre-merge base, and its paired
      # closed issue can have a null state_reason. Canonical merge facts come
      # from the separately observed branch M together with the merged PR M.
      # Keep both raw provider values for the coordinator's proof validation.
      snapshot =
        Map.merge(pull.snapshot, %{"base_sha" => remote_base_oid, "state_reason" => "completed"})

      {:ok,
       %{
         remote_base_oid: merge_oid,
         pull:
           Map.merge(
             Map.take(pull, [
               :github_object_id,
               :github_node_id,
               :github_number,
               :remote_updated_at
             ]),
             %{
               provider_identity: identity,
               provider_base_oid: pull.snapshot["base_sha"],
               confirmed_snapshot: snapshot,
               confirmed_merge_state: %{
                 "merged_at" => DateTime.to_iso8601(merged_at),
                 "merge_commit_sha" => merge_oid
               }
             }
           ),
         issue:
           Map.merge(
             Map.take(issue, [
               :github_object_id,
               :github_node_id,
               :github_number,
               :remote_updated_at
             ]),
             %{
               confirmed_snapshot: Map.put(issue.snapshot, "state_reason", "completed"),
               provider_state_reason: issue.snapshot["state_reason"]
             }
           )
       }}
    else
      {:error, :merge_metadata_unconfirmed} = error -> error
      {:error, :relationship_lock_busy} = error -> error
      _ -> {:error, :invalid_merge_observation}
    end
  end

  def build(_, _, _), do: {:error, :invalid_merge_observation}

  defp repository_identity(%{github_object_id: id, github_node_id: node}),
    do: %{"id" => id, "node_id" => node}

  defp repository_identity(_), do: nil

  defp relationships(binding_id, %{"labels" => labels, "assignees" => assignees})
       when is_list(labels) and is_list(assignees) and length(labels) <= 512 and
              length(assignees) <= 512 do
    with {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             binding_id,
             :remote,
             labels,
             assignees
           ),
         true <- label_nodes?(binding_id, labels),
         true <- assignee_nodes?(assignees) do
      {:ok, relationships}
    else
      _ -> {:error, :merge_metadata_unconfirmed}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp relationships(_, _), do: {:error, :merge_metadata_unconfirmed}

  # The projection normalizers compare numeric IDs. Preserve their immutable
  # node identity too, without creating or updating provider catalog entries.
  defp label_nodes?(binding_id, labels) do
    ids = Enum.map(labels, & &1["id"])

    rows =
      Repo.all(
        from(m in ForgeMirrors.MirrorResourceState,
          where:
            m.repository_mirror_id == ^binding_id and m.resource_kind == :label and
              m.state == :confirmed and m.github_object_id in ^ids,
          order_by: m.id,
          lock: "FOR SHARE NOWAIT",
          select: {m.github_object_id, m.github_node_id}
        ),
        lock_options()
      )

    exact_nodes?(labels, rows)
  end

  defp assignee_nodes?(assignees) do
    ids = Enum.map(assignees, & &1["id"])

    rows =
      Repo.all(
        from(i in ForgeAccounts.GitHubIdentity,
          where: i.kind == :user and i.github_user_id in ^ids,
          order_by: i.id,
          lock: "FOR SHARE NOWAIT",
          select: {i.github_user_id, i.github_node_id}
        ),
        lock_options()
      )

    exact_nodes?(assignees, rows)
  end

  defp exact_nodes?(raw, rows) do
    nodes = Map.new(rows)

    length(rows) == length(raw) and
      Enum.all?(raw, fn value ->
        node = value["node_id"]
        is_binary(node) and node != "" and nodes[value["id"]] == node
      end)
  end

  # Postgrex savepoints require an active caller transaction. The initial
  # provider observation also runs in autocommit mode before finalization.
  defp lock_options, do: if(Repo.in_transaction?(), do: [mode: :savepoint], else: [])
end
