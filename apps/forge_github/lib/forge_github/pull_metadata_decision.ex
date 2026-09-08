defmodule ForgeGitHub.PullMetadataDecision do
  @moduledoc """
  Pure three-way metadata decision for a pull and its canonical issue identity.

  Pull snapshots retain scalar and ref metadata. Relationship sets remain in the
  paired issue snapshots so callers can fence and confirm the two mappings
  independently.
  """

  alias ForgeMirrors.ResourceDecision

  @issue_scalar_fields ~w(title body state state_reason)
  @set_fields ~w(label_github_ids assignee_github_ids)
  @issue_fields @issue_scalar_fields ++ @set_fields
  @ref_fields ~w(head_ref head_sha base_ref base_sha)
  @pull_fields @issue_scalar_fields ++ ["draft"] ++ @ref_fields
  @max_relationships 512
  @max_id 9_223_372_036_854_775_807
  @oid ~r/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/

  @type result ::
          {:ok,
           %{
             target_pull: map(),
             target_issue: map(),
             apply_local?: boolean(),
             remote_issue_effect?: boolean(),
             draft_effect?: boolean(),
             local_issue: map(),
             remote_issue: map()
           }}
          | {:conflict, :concurrent_edit | :pull_ref_mismatch}
          | {:error, :invalid_projection}

  @spec decide(map(), map(), map(), map(), map(), map()) :: result()
  def decide(
        pull_baseline,
        pull_local,
        pull_remote,
        issue_baseline,
        issue_local,
        issue_remote
      ) do
    with :ok <- validate_pull_views(pull_baseline, pull_local, pull_remote),
         :ok <- validate_issue_views(issue_baseline, issue_local, issue_remote),
         true <- companion?(pull_baseline, issue_baseline),
         true <- companion?(pull_local, issue_local),
         true <- companion?(pull_remote, issue_remote) do
      if refs(pull_baseline) == refs(pull_local) and refs(pull_local) == refs(pull_remote) do
        decide_metadata(
          pull_baseline,
          pull_local,
          pull_remote,
          issue_baseline,
          issue_local,
          issue_remote
        )
      else
        {:conflict, :pull_ref_mismatch}
      end
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp decide_metadata(
         pull_baseline,
         pull_local,
         pull_remote,
         issue_baseline,
         issue_local,
         issue_remote
       ) do
    initial = %{target: issue_baseline, apply_local?: false, remote_issue_effect?: false}

    with {:ok, issue_decision} <-
           Enum.reduce_while(@issue_fields, {:ok, initial}, fn field, {:ok, decision} ->
             result =
               if field in @set_fields do
                 ResourceDecision.set(
                   MapSet.new(issue_baseline[field]),
                   MapSet.new(issue_local[field]),
                   MapSet.new(issue_remote[field])
                 )
               else
                 ResourceDecision.scalar(
                   issue_baseline[field],
                   issue_local[field],
                   issue_remote[field]
                 )
               end

             case merge_issue_decision(decision, field, result) do
               {:ok, next} -> {:cont, {:ok, next}}
               {:conflict, _kind} = conflict -> {:halt, conflict}
             end
           end),
         {:ok, draft, draft_local?, draft_remote?} <-
           decision_flags(
             ResourceDecision.scalar(
               pull_baseline["draft"],
               pull_local["draft"],
               pull_remote["draft"]
             )
           ) do
      target_issue = issue_decision.target

      target_pull =
        pull_baseline
        |> Map.merge(Map.take(target_issue, @issue_scalar_fields))
        |> Map.put("draft", draft)

      if valid_issue?(target_issue) and valid_pull?(target_pull) do
        {:ok,
         %{
           target_pull: target_pull,
           target_issue: target_issue,
           apply_local?: issue_decision.apply_local? or draft_local?,
           remote_issue_effect?: issue_decision.remote_issue_effect?,
           draft_effect?: draft_remote?,
           local_issue: issue_local,
           remote_issue: issue_remote
         }}
      else
        {:error, :invalid_projection}
      end
    end
  end

  defp merge_issue_decision(decision, field, result) do
    case decision_flags(result) do
      {:ok, value, local?, remote?} ->
        value =
          if is_struct(value, MapSet), do: value |> MapSet.to_list() |> Enum.sort(), else: value

        {:ok,
         %{
           decision
           | target: Map.put(decision.target, field, value),
             apply_local?: decision.apply_local? or local?,
             remote_issue_effect?: decision.remote_issue_effect? or remote?
         }}

      {:conflict, _kind} = conflict ->
        conflict
    end
  end

  defp decision_flags({:confirm, value}), do: {:ok, value, false, false}
  defp decision_flags({:apply_local, _expected, value}), do: {:ok, value, true, false}
  defp decision_flags({:apply_remote, _expected, value}), do: {:ok, value, false, true}
  defp decision_flags({:apply_both, _local, _remote, value}), do: {:ok, value, true, true}
  defp decision_flags({:conflict, kind}), do: {:conflict, kind}

  defp validate_pull_views(baseline, local, remote) do
    if Enum.all?([baseline, local, remote], &valid_pull?/1),
      do: :ok,
      else: {:error, :invalid_projection}
  end

  defp validate_issue_views(baseline, local, remote) do
    if Enum.all?([baseline, local, remote], &valid_issue?/1),
      do: :ok,
      else: {:error, :invalid_projection}
  end

  defp valid_pull?(snapshot) when is_map(snapshot) do
    Enum.sort(Map.keys(snapshot)) == Enum.sort(@pull_fields) and valid_scalars?(snapshot) and
      is_boolean(snapshot["draft"]) and canonical_branch_ref?(snapshot["head_ref"]) and
      canonical_branch_ref?(snapshot["base_ref"]) and valid_oid?(snapshot["head_sha"]) and
      valid_oid?(snapshot["base_sha"])
  end

  defp valid_pull?(_snapshot), do: false

  defp valid_issue?(snapshot) when is_map(snapshot) do
    Enum.sort(Map.keys(snapshot)) == Enum.sort(@issue_fields) and valid_scalars?(snapshot) and
      Enum.all?(@set_fields, &valid_identity_set?(snapshot[&1]))
  end

  defp valid_issue?(_snapshot), do: false

  defp valid_scalars?(snapshot) do
    valid_text?(snapshot["title"], 1_024) and snapshot["title"] != "" and
      codepoints_at_most?(snapshot["title"], 256) and valid_body?(snapshot["body"]) and
      snapshot["state"] in ["open", "closed"] and
      valid_state_reason?(snapshot["state"], snapshot["state_reason"])
  end

  defp valid_body?(nil), do: true

  defp valid_body?(body),
    do: valid_text?(body, 262_144) and codepoints_at_most?(body, 65_536)

  defp valid_state_reason?("open", reason), do: reason in [nil, "reopened"]
  defp valid_state_reason?("closed", reason), do: reason in [nil, "completed", "not_planned"]
  defp valid_state_reason?(_state, _reason), do: false

  defp valid_identity_set?(ids) when is_list(ids) do
    length(Enum.take(ids, @max_relationships + 1)) <= @max_relationships and
      ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &valid_id?/1)
  end

  defp valid_identity_set?(_ids), do: false

  defp companion?(pull, issue),
    do: Map.take(pull, @issue_scalar_fields) == Map.take(issue, @issue_scalar_fields)

  defp refs(pull), do: Map.take(pull, @ref_fields)

  defp canonical_branch_ref?("refs/heads/" <> name) do
    name != "" and byte_size(name) <= 4_096 and String.valid?(name) and
      not String.contains?(name, ["..", "@{"]) and not String.ends_with?(name, ".") and
      not Regex.match?(~r/[\x00-\x20\x7f ~^:?*\[\\]/u, name) and
      Enum.all?(String.split(name, "/"), fn component ->
        component not in ["", ".", ".."] and not String.starts_with?(component, ".") and
          not String.ends_with?(component, ".lock")
      end)
  end

  defp canonical_branch_ref?(_ref), do: false
  defp valid_oid?(oid), do: is_binary(oid) and Regex.match?(@oid, oid)
  defp valid_id?(id), do: is_integer(id) and id > 0 and id <= @max_id

  defp valid_text?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) <= max_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp codepoints_at_most?(value, max),
    do: length(Enum.take(String.codepoints(value), max + 1)) <= max
end
