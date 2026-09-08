defmodule ForgeMirrors.PullMetadataEffects do
  @moduledoc "Leased immutable paired metadata intents and compact effect markers."
  import Ecto.Query
  alias ForgeMirrors.{MirrorOperation, PullMetadataIntent, ResourceDecision}
  alias Fornacast.Repo

  @scalars ~w(title body state state_reason)
  @sets ~w(label_github_ids assignee_github_ids)
  @keys Enum.sort(@scalars ++ @sets)
  @refs ~w(head_ref head_sha base_ref base_sha)
  @tokens ~w(mapping_id lock_version github_object_id github_node_id github_number local_version fingerprint)a

  def mark(
        %MirrorOperation{kind: "sync.pull"} = operation,
        %DateTime{} = now,
        pair,
        marker,
        payload
      )
      when is_map(pair) and is_map(marker) and is_map(payload) do
    Repo.transaction(fn ->
      with {:ok, sync} <- ForgeMirrors.mapped_pull_pair_context(operation),
           :ok <- same_pair(sync.pair, pair),
           persisted = Repo.get!(MirrorOperation, operation.id),
           :ok <- previous(persisted, operation, payload),
           :ok <- valid_payload(payload, marker),
           :ok <- observation_versions(sync.pair, marker),
           {:ok, local} <- local_projection(sync),
           {:ok, snapshot} <- local_issue(sync, local),
           true <- snapshot == payload["expected_local_issue"],
           true <- local.local_version == marker["expected_local_version"],
           :ok <- target(sync.pair, local, marker, payload),
           {:ok, intent} <- insert_intent(persisted, sync, local, payload),
           enriched =
             Map.merge(marker, %{
               "metadata_intent_id" => intent.id,
               "metadata_intent_hash" => intent.payload_fingerprint,
               "paired_mapping_proof" => tokens(sync.pair)
             }),
           {:ok, marked} <- publish(persisted, now, enriched) do
        %{operation: marked, marker: marked.external_effect_marker, intent: intent, sync: sync}
      else
        false -> Repo.rollback(:stale_local_relationships)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def mark(_, _, _, _, _), do: {:error, :invalid_argument}

  def context(%MirrorOperation{kind: "sync.pull"} = operation) do
    Repo.transaction(fn ->
      with {:ok, sync} <- ForgeMirrors.mapped_pull_pair_context(operation),
           %MirrorOperation{state: :effect_pending, external_effect_marker: marker} = persisted <-
             Repo.get!(MirrorOperation, operation.id),
           true <- is_map(marker),
           {:ok, intent} <- intent(persisted, sync, marker),
           :ok <- same_tokens(sync.pair, marker),
           :ok <- observation_versions(sync.pair, marker),
           {:ok, local} <- local_projection(sync),
           true <- local.local_version >= intent.local_version,
           :ok <- recovery_precondition(sync, local, marker),
           {:ok, _} <- ForgeMirrors.mapped_pull_pair_context(operation) do
        %{
          operation: persisted,
          marker: marker,
          intent: intent,
          sync: sync,
          local_projection: local
        }
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_metadata_intent)
      end
    end)
  end

  def context(_), do: {:error, :invalid_argument}

  defp previous(%{state: :processing, external_effect_marker: nil}, %{state: :processing}, _),
    do: :ok

  defp previous(%{state: :effect_pending} = persisted, operation, payload) do
    with true <- persisted.external_effect_marker == operation.external_effect_marker,
         {:ok, evidence} <- context(operation),
         true <- evidence.intent.payload["target_issue"] == payload["expected_remote_issue"] do
      :ok
    else
      _ -> {:error, :invalid_transition}
    end
  end

  defp previous(_, _, _), do: {:error, :invalid_transition}

  defp publish(%{state: :processing} = operation, now, marker),
    do: ForgeMirrors.mark_external_effect(operation, now, marker)

  defp publish(operation, now, marker),
    do:
      ForgeMirrors.replace_external_effect(
        operation,
        now,
        operation.external_effect_marker,
        marker
      )

  defp insert_intent(operation, sync, local, payload) do
    sequence =
      Repo.one(
        from i in PullMetadataIntent,
          where: i.operation_id == ^operation.id,
          select: max(i.sequence)
      ) || 0

    %PullMetadataIntent{}
    |> PullMetadataIntent.create_changeset(%{
      operation_id: operation.id,
      repository_mirror_id: sync.repository_mirror_id,
      pull_id: sync.local_resource_id,
      issue_id: sync.issue_id,
      local_version: local.local_version,
      sequence: sequence + 1,
      payload: payload
    })
    |> Repo.insert()
  end

  defp intent(operation, sync, marker) do
    id = marker["metadata_intent_id"]

    row =
      if is_integer(id) and id > 0,
        do: Repo.one(from i in PullMetadataIntent, where: i.id == ^id, lock: "FOR SHARE")

    with %PullMetadataIntent{} = row <- row,
         true <-
           row.operation_id == operation.id and
             row.repository_mirror_id == sync.repository_mirror_id and
             row.pull_id == sync.local_resource_id and row.issue_id == sync.issue_id,
         true <- row.local_version == marker["expected_local_version"],
         {:ok, hash} <- ForgeMirrors.resource_fingerprint(row.payload),
         true <- hash == row.payload_fingerprint and hash == marker["metadata_intent_hash"],
         :ok <- valid_payload(row.payload, marker) do
      {:ok, row}
    else
      _ -> {:error, :invalid_metadata_intent}
    end
  end

  defp local_projection(sync),
    do: apply(ForgePulls, :sync_projection, [sync.repository_id, :pull, sync.local_resource_id])

  defp local_issue(sync, local) do
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

  defp recovery_precondition(sync, local, marker) do
    # Reuse the complete active identity/ref proof gate while allowing newer
    # local scalar/relationship edits. The original intent is never changed.
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(local.fields)

    proof_marker =
      Map.merge(marker, %{
        "expected_local_version" => local.local_version,
        "expected_local_fingerprint" => fingerprint
      })

    mapping = Repo.get!(ForgeMirrors.MirrorResourceState, sync.pair.pull.mapping_id)
    ForgeMirrors.PullResourceBoundary.validate_precondition(sync, mapping, proof_marker)
  end

  defp target(pair, local, marker, payload) do
    decisions =
      Enum.map(@keys, fn key ->
        values = [
          pair.issue.snapshot[key],
          payload["expected_local_issue"][key],
          payload["expected_remote_issue"][key]
        ]

        decision =
          if key in @sets,
            do: apply(ResourceDecision, :set, Enum.map(values, &MapSet.new/1)),
            else: apply(ResourceDecision, :scalar, values)

        case decision do
          {:conflict, _} ->
            :invalid

          result ->
            value = elem(result, tuple_size(result) - 1)
            {key, if(key in @sets, do: value |> MapSet.to_list() |> Enum.sort(), else: value)}
        end
      end)

    remote_draft = marker["expected_remote_draft"]
    proposed_draft = marker["proposed_draft"]

    draft =
      ResourceDecision.scalar(pair.pull.snapshot["draft"], local.fields["draft"], remote_draft)

    draft_target =
      if elem(draft, 0) == :conflict, do: :invalid, else: elem(draft, tuple_size(draft) - 1)

    expected_proposed =
      if marker["action"] == "update_remote_pull_issue", do: remote_draft, else: draft_target

    pull_target =
      Map.merge(Map.take(local.fields, @refs), Map.take(payload["target_issue"], @scalars))
      |> Map.put("draft", proposed_draft)

    {:ok, hash} = ForgeMirrors.resource_fingerprint(pull_target)

    if :invalid not in decisions and Map.new(decisions) == payload["target_issue"] and
         Map.take(local.fields, @refs) == Map.take(pair.pull.snapshot, @refs) and
         is_boolean(remote_draft) and is_boolean(proposed_draft) and
         marker["expected_local_draft"] == local.fields["draft"] and
         proposed_draft == expected_proposed and
         marker["proposed_fingerprint"] == hash,
       do: :ok,
       else: {:error, :invalid_metadata_payload}
  end

  defp valid_payload(payload, marker) do
    valid =
      Enum.sort(Map.keys(payload)) ==
        ~w(expected_local_issue expected_remote_issue target_issue v) and
        payload["v"] == 1 and
        Enum.all?(
          ~w(expected_local_issue expected_remote_issue target_issue),
          &issue?(payload[&1])
        ) and
        marker["action"] in ~w(update_remote_pull_issue set_remote_pull_draft) and
        utc?(marker["expected_remote_updated_at"]) and
        utc?(marker["expected_remote_issue_updated_at"]) and
        ((marker["action"] == "set_remote_pull_draft" and
            payload["expected_remote_issue"] == payload["target_issue"]) or
           (marker["action"] == "update_remote_pull_issue" and
              payload["expected_remote_issue"] != payload["target_issue"])) and
        byte_size(JSON.encode!(payload)) <= 2_000_000

    if valid, do: :ok, else: {:error, :invalid_metadata_payload}
  end

  defp utc?(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> DateTime.to_iso8601(time) == value
      _ -> false
    end
  end

  defp utc?(_), do: false

  defp observation_versions(pair, marker) do
    valid =
      Enum.all?(
        [{:pull, "expected_remote_updated_at"}, {:issue, "expected_remote_issue_updated_at"}],
        fn {kind, key} ->
          mapping = Repo.get!(ForgeMirrors.MirrorResourceState, pair[kind].mapping_id)
          {:ok, observed, 0} = DateTime.from_iso8601(marker[key])

          is_nil(mapping.confirmed_remote_updated_at) or
            DateTime.compare(observed, mapping.confirmed_remote_updated_at) != :lt
        end
      )

    if valid, do: :ok, else: {:error, :stale_remote_observation}
  end

  defp issue?(value) when is_map(value) do
    Enum.sort(Map.keys(value)) == @keys and text?(value["title"], 256) and value["title"] != "" and
      (is_nil(value["body"]) or text?(value["body"], 65_536)) and
      ((value["state"] == "open" and value["state_reason"] in [nil, "reopened"]) or
         (value["state"] == "closed" and
            value["state_reason"] in [nil, "completed", "not_planned"])) and
      Enum.all?(@sets, &ids?(value[&1]))
  end

  defp issue?(_), do: false

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max * 4 and String.valid?(value) and
        not String.contains?(value, <<0>>) and length(String.codepoints(value)) <= max

  defp ids?(ids) when is_list(ids) and length(ids) <= 512,
    do:
      ids == Enum.sort(Enum.uniq(ids)) and
        Enum.all?(ids, &(is_integer(&1) and &1 in 1..9_223_372_036_854_775_807))

  defp ids?(_), do: false

  defp tokens(pair),
    do:
      Map.new(pair, fn {kind, view} ->
        {Atom.to_string(kind), view |> Map.take(@tokens) |> JSON.encode!() |> JSON.decode!()}
      end)

  defp same_pair(same, same), do: :ok
  defp same_pair(_, _), do: {:error, :stale_paired_mapping}

  defp same_tokens(pair, marker),
    do:
      if(tokens(pair) == marker["paired_mapping_proof"],
        do: :ok,
        else: {:error, :stale_paired_mapping}
      )
end
