defmodule ForgeMirrors.PullPairBoundary do
  @moduledoc "Leased paired mapping observations; never silently repairs divergent baselines."
  import Ecto.Query
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, PullEligibility, RepositoryMirror}
  alias Fornacast.Repo

  @scalars ~w(title body state state_reason)
  @pull_keys Enum.sort(@scalars ++ ~w(draft head_ref head_sha base_ref base_sha))
  @issue_keys Enum.sort(@scalars ++ ~w(label_github_ids assignee_github_ids))

  def context(%MirrorOperation{kind: "sync.pull"} = operation, context_fun) do
    Repo.transaction(fn ->
      with {:ok, sync} <- context_fun.(operation),
           {:ok, pull, issue} <- pair(sync),
           :ok <- identity(sync, pull, issue),
           :ok <- baselines(pull, issue),
           {:ok, pull_view} <- view(pull),
           {:ok, issue_view} <- view(issue),
           {:ok, _fresh} <- context_fun.(operation) do
        Map.put(sync, :pair, %{pull: pull_view, issue: issue_view})
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_argument}

  # Internal trusted domain composition, like confirm_resource_operation/5.
  # Callers must append only the target's ForgePulls apply/observe operation;
  # this is not a sandbox for arbitrary callback writes or external effects.
  def confirm(
        %MirrorOperation{kind: "sync.pull"} = operation,
        %DateTime{} = now,
        expected,
        confirmation,
        callback
      )
      when is_map(expected) and is_map(confirmation) and is_function(callback, 1) do
    Repo.transaction(fn ->
      with {:ok, sync} <- ForgeMirrors.mapped_pull_pair_context(operation),
           :ok <- same_pair(sync, expected),
           :ok <- confirmation_effect(operation, expected, confirmation),
           {:ok, saved} <-
             ForgeMirrors.confirm_pull_operation(
               operation,
               now,
               Map.delete(expected, :pair),
               Map.drop(confirmation, [:issue_snapshot, :issue_remote_updated_at]),
               fn multi ->
                 multi
                 |> callback.()
                 |> Ecto.Multi.run(:paired_issue_confirmation, fn _, _ ->
                   confirm_issue(operation, sync, expected, confirmation)
                 end)
               end
             ) do
        Map.put(
          saved,
          :issue_resource_state,
          Repo.get!(MirrorResourceState, sync.pair.issue.mapping_id)
        )
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_transition)
      end
    end)
  end

  def confirm(_, _, _, _, _), do: {:error, :invalid_argument}

  defp same_pair(sync, expected) do
    if sync.pair == expected[:pair], do: :ok, else: {:error, :stale_paired_mapping}
  end

  defp confirmation_effect(operation, expected, confirmation) do
    case Repo.get(MirrorOperation, operation.id) do
      %MirrorOperation{state: :processing, external_effect_marker: nil} ->
        if is_nil(expected[:effect_marker]), do: :ok, else: {:error, :invalid_transition}

      %MirrorOperation{state: :effect_pending} ->
        with {:ok, evidence} <- ForgeMirrors.mapped_pull_effect_context(operation),
             true <- evidence.marker == expected[:effect_marker],
             true <- evidence.intent.payload["target_issue"] == confirmation[:issue_snapshot],
             true <- evidence.intent.local_version == expected[:expected_local_version],
             true <- is_map(confirmation[:confirmed_snapshot]),
             true <-
               Map.take(confirmation.confirmed_snapshot, @scalars) ==
                 Map.take(confirmation.issue_snapshot, @scalars) do
          :ok
        else
          false -> {:error, :invalid_paired_projection}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_transition}
    end
  end

  defp confirm_issue(operation, sync, expected, confirmation) do
    # forge_pulls depends on forge_mirrors; resolve its trusted public projection
    # at runtime rather than introducing an umbrella compile dependency cycle.
    with {:ok, local} <-
           apply(ForgePulls, :sync_projection, [sync.repository_id, :pull, sync.local_resource_id]),
         {:ok, snapshot} <- result_snapshot(local, sync, confirmation),
         true <- valid_result?(local, snapshot, expected, confirmation),
         :ok <- confirmation_effect(operation, expected, confirmation),
         {:ok, fresh} <- ForgeMirrors.mapped_pull_pair_context(operation),
         :ok <- same_pair(fresh, expected),
         mapping = Repo.get!(MirrorResourceState, sync.pair.issue.mapping_id),
         true <- valid_observation_time?(confirmation[:issue_remote_updated_at], mapping),
         pull_mapping = Repo.get!(MirrorResourceState, sync.pair.pull.mapping_id),
         true <- valid_observation_time?(confirmation[:remote_updated_at], pull_mapping),
         {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(confirmation.issue_snapshot) do
      mapping
      |> MirrorResourceState.persistence_changeset(%{
        confirmed_snapshot: confirmation.issue_snapshot,
        confirmed_fingerprint: fingerprint,
        confirmed_local_version: confirmation.confirmed_local_version,
        confirmed_remote_updated_at: confirmation.issue_remote_updated_at,
        lock_version: mapping.lock_version + 1
      })
      |> Repo.update()
    else
      false -> {:error, :invalid_paired_projection}
      {:error, reason} -> {:error, reason}
    end
  end

  defp result_snapshot(local, sync, confirmation) do
    if local.local_version > confirmation[:confirmed_local_version] do
      # No claim is made about the newer membership's provider mapping. It may
      # legitimately contain a newly created label not yet exported to GitHub.
      {:ok, nil}
    else
      with {:ok, relationships} <-
             ForgeMirrors.resolve_issue_relationships(
               sync.repository_mirror_id,
               :local,
               local.label_ids,
               local.assignee_refs
             ) do
        {:ok,
         Map.merge(Map.take(local.fields, @scalars), %{
           "label_github_ids" => Enum.sort(Enum.map(relationships.labels, & &1.github_object_id)),
           "assignee_github_ids" =>
             Enum.sort(Enum.map(relationships.assignees, & &1.github_user_id))
         })}
      end
    end
  end

  defp valid_result?(local, snapshot, expected, confirmation) do
    if local.local_version == confirmation[:confirmed_local_version] do
      snapshot == confirmation[:issue_snapshot] and
        local.fields == confirmation[:confirmed_snapshot]
    else
      # A recovered effect confirms its immutable old target, not the newer
      # local edit. Its outbox event remains responsible for subsequent convergence.
      is_map(expected[:effect_marker]) and
        local.local_version > confirmation[:confirmed_local_version] and
        confirmation[:confirmed_local_version] == expected[:expected_local_version] and
        Map.take(local.fields, ~w(head_ref head_sha base_ref base_sha)) ==
          Map.take(confirmation.confirmed_snapshot, ~w(head_ref head_sha base_ref base_sha))
    end
  end

  defp valid_observation_time?(%DateTime{utc_offset: 0, std_offset: 0} = time, mapping),
    do:
      is_nil(mapping.confirmed_remote_updated_at) or
        DateTime.compare(time, mapping.confirmed_remote_updated_at) != :lt

  defp valid_observation_time?(_, _), do: false

  defp pair(sync) do
    # Existing context has acquired the organization operation lock. Acquire
    # both mapping rows in deterministic order and retain them to transaction end.
    rows =
      Repo.all(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^sync.repository_mirror_id and
              ((m.resource_kind == :pull and m.local_resource_type == "ForgePulls.PullRequest" and
                  m.local_resource_id == ^sync.local_resource_id) or
                 (m.resource_kind == :issue and m.local_resource_type == "ForgeIssues.Issue" and
                    m.local_resource_id == ^sync.issue_id)),
          order_by: m.id,
          lock: "FOR UPDATE"
      )

    pull = Enum.find(rows, &(&1.resource_kind == :pull))
    issue = Enum.find(rows, &(&1.resource_kind == :issue))

    if length(rows) == 2 and match?(%{state: :confirmed}, pull) and
         match?(%{state: :confirmed}, issue),
       do: {:ok, pull, issue},
       else: {:error, :paired_mapping_unavailable}
  end

  defp identity(sync, pull, issue) do
    provider = pull.provider_identity
    binding = Repo.get!(RepositoryMirror, sync.repository_mirror_id)

    if valid_provider?(provider) and
         provider["base_repository"] == %{
           "id" => binding.github_repository_id,
           "node_id" => binding.github_node_id
         } and
         pull.github_object_id == sync.github_object_id and
         pull.github_node_id == sync.github_node_id and
         issue.github_object_id == provider["github_issue_object_id"] and
         issue.github_node_id == provider["github_issue_node_id"] and
         is_integer(issue.github_object_id) and issue.github_object_id > 0 and
         is_binary(issue.github_node_id) and byte_size(issue.github_node_id) > 0 and
         pull.github_number == issue.github_number and
         issue.github_number == provider["github_number"],
       do: :ok,
       else: {:error, :paired_identity_mismatch}
  end

  defp baselines(pull, issue) do
    p = pull.confirmed_snapshot
    i = issue.confirmed_snapshot

    if is_map(p) and is_map(i) and Enum.sort(Map.keys(p)) == @pull_keys and
         Enum.sort(Map.keys(i)) == @issue_keys and
         scalar_values?(p) and is_boolean(p["draft"]) and
         PullEligibility.valid_refs?(%{
           base_ref: p["base_ref"],
           head_ref: p["head_ref"],
           base_sha: p["base_sha"],
           head_sha: p["head_sha"]
         }) and
         Map.take(p, @scalars) == Map.take(i, @scalars) and
         is_integer(pull.confirmed_local_version) and pull.confirmed_local_version > 0 and
         pull.confirmed_local_version == issue.confirmed_local_version and
         ids?(i["label_github_ids"]) and ids?(i["assignee_github_ids"]),
       do: :ok,
       else: {:error, :paired_baseline_mismatch}
  end

  defp ids?(ids) when is_list(ids) and length(ids) <= 512,
    do:
      ids == Enum.sort(Enum.uniq(ids)) and
        Enum.all?(ids, &(is_integer(&1) and &1 in 1..9_223_372_036_854_775_807))

  defp ids?(_), do: false

  defp valid_provider?(
         %{
           "github_issue_object_id" => id,
           "github_issue_node_id" => node,
           "github_number" => number,
           "base_repository" => base,
           "head_repository" => head
         } = value
       ),
       do:
         map_size(value) == 5 and positive?(id) and positive?(number) and node?(node) and
           repository?(base) and repository?(head)

  defp valid_provider?(_), do: false

  defp repository?(%{"id" => id, "node_id" => node} = value),
    do: map_size(value) == 2 and positive?(id) and node?(node)

  defp repository?(_), do: false
  defp positive?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807
  defp node?(node), do: text?(node, 255) and node != "" and String.trim(node) == node

  defp text?(text, max),
    do:
      is_binary(text) and byte_size(text) <= max and String.valid?(text) and
        not String.contains?(text, <<0>>)

  defp scalar_values?(snapshot) do
    text?(snapshot["title"], 1024) and snapshot["title"] != "" and
      length(String.codepoints(snapshot["title"])) <= 256 and
      (is_nil(snapshot["body"]) or
         (text?(snapshot["body"], 262_144) and
            length(String.codepoints(snapshot["body"])) <= 65_536)) and
      ((snapshot["state"] == "open" and snapshot["state_reason"] in [nil, "reopened"]) or
         (snapshot["state"] == "closed" and
            snapshot["state_reason"] in [nil, "completed", "not_planned"]))
  end

  defp view(mapping) do
    with {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(mapping.confirmed_snapshot),
         true <-
           is_nil(mapping.confirmed_fingerprint) or mapping.confirmed_fingerprint == fingerprint do
      # Legacy nil hashes are read-derived fingerprints, not evidence of an
      # earlier stored confirmation. They are never written back by this gate.
      {:ok,
       %{
         mapping_id: mapping.id,
         lock_version: mapping.lock_version,
         github_object_id: mapping.github_object_id,
         github_node_id: mapping.github_node_id,
         github_number: mapping.github_number,
         local_version: mapping.confirmed_local_version,
         snapshot: mapping.confirmed_snapshot,
         fingerprint: fingerprint,
         fingerprint_source:
           if(is_nil(mapping.confirmed_fingerprint), do: :derived, else: :stored)
       }}
    else
      _ -> {:error, :paired_baseline_mismatch}
    end
  end
end
