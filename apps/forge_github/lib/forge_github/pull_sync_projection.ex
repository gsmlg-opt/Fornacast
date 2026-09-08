defmodule ForgeGitHub.PullSyncProjection do
  @moduledoc """
  Canonical pull-request projections shared by bootstrap and live sync.

  Mutable metadata is isolated in `snapshot`. Local and GitHub pull, issue,
  and repository identities remain in the surrounding observation envelope.
  Merge facts and provider merge analysis are not ordinary metadata fields and
  require a dedicated merge coordinator before they can be applied.
  """

  @field_keys ~w(base_ref base_sha body draft head_ref head_sha state state_reason title)
  @issue_fields ~w(title body state state_reason)
  @relationship_fields ~w(label_github_ids assignee_github_ids)
  @oid ~r/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/

  @spec from_local(map()) :: {:ok, map()} | {:error, :invalid_projection}
  def from_local(%{
        repository_id: repository_id,
        resource_kind: :pull,
        local_resource_id: local_resource_id,
        local_resource_type: local_resource_type,
        local_version: local_version,
        issue_id: issue_id,
        issue_number: issue_number,
        head_repository_id: head_repository_id,
        merge_state: merge_state,
        fields: fields
      }) do
    with true <-
           Enum.all?(
             [repository_id, local_resource_id, local_version, issue_id, issue_number],
             &valid_id?/1
           ),
         true <- is_nil(head_repository_id) or valid_id?(head_repository_id),
         true <- local_resource_type in ["ForgePulls.PullRequest", nil],
         :ok <- validate_fields(fields),
         true <-
           distinct_ref_identities?(
             fields["head_ref"],
             head_repository_id,
             fields["base_ref"],
             repository_id
           ),
         {:ok, merge_state} <- local_merge_state(merge_state) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :pull,
         repository_id: repository_id,
         local_resource_id: local_resource_id,
         local_resource_type: "ForgePulls.PullRequest",
         local_version: local_version,
         issue_id: issue_id,
         issue_number: issue_number,
         head_repository_id: head_repository_id,
         snapshot: fields,
         merge_state: merge_state,
         coordinator: unsupported_coordinator(),
         relationship_snapshot: nil
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_local(_projection), do: {:error, :invalid_projection}

  @doc "Composes the actual pull domain projection with resolved canonical issue relationships."
  def from_local(
        %{label_ids: labels, assignee_refs: refs, relationship_preimage: preimage} = projection,
        relationships
      ) do
    with {:ok, pull} <- from_local(projection),
         true <- valid_relationship_preimage?(preimage, labels),
         true <- is_list(refs) and length(refs) <= 512,
         {:ok, issue} <-
           ForgeGitHub.IssueSyncProjection.from_local(
             %{
               resource_kind: :issue,
               local_resource_id: pull.issue_id,
               local_resource_type: "ForgeIssues.Issue",
               local_version: pull.local_version,
               fields: Map.take(pull.snapshot, @issue_fields),
               label_ids: labels,
               assignee_refs: refs
             },
             relationships
           ),
         true <-
           map_size(issue.assignee_catalog) == length(preimage.managed_assignee_identity_ids),
         true <-
           Enum.all?(refs, fn
             %{kind: :github_identity, id: id} -> id in preimage.managed_assignee_identity_ids
             %{kind: :local_user} -> true
             _ -> false
           end) do
      {:ok,
       Map.merge(pull, %{
         snapshot: Map.merge(pull.snapshot, Map.take(issue.snapshot, @issue_fields)),
         issue_snapshot: issue.snapshot,
         relationship_snapshot: Map.take(issue.snapshot, @relationship_fields),
         label_catalog: issue.label_catalog,
         assignee_catalog: issue.assignee_catalog,
         relationship_preimage: preimage
       })}
    else
      _ -> {:error, :invalid_projection}
    end
  end

  def from_local(_, _), do: {:error, :invalid_projection}

  defp valid_relationship_preimage?(
         %{label_ids: ids, managed_assignee_identity_ids: managed} = value,
         labels
       ),
       do:
         map_size(value) == 2 and canonical_ids?(ids) and canonical_ids?(managed) and
           is_list(labels) and ids == Enum.sort(labels)

  defp valid_relationship_preimage?(_, _), do: false

  defp canonical_ids?(ids) when is_list(ids),
    do:
      length(ids) <= 512 and
        Enum.all?(ids, &valid_id?/1) and ids == Enum.sort(Enum.uniq(ids))

  defp canonical_ids?(_), do: false

  @spec from_remote(map(), map()) ::
          {:ok, map()} | {:error, :invalid_projection | :inconsistent_observation}
  def from_remote(
        %{
          "id" => pull_id,
          "node_id" => pull_node_id,
          "number" => number,
          "title" => pull_title,
          "body" => pull_body,
          "state" => pull_state,
          "draft" => draft,
          "created_at" => created_at,
          "updated_at" => updated_at,
          "merged" => merged,
          "merged_at" => merged_at,
          "merge_commit_sha" => merge_commit_sha,
          "mergeable" => mergeable,
          "rebaseable" => rebaseable,
          "mergeable_state" => mergeable_state,
          "head" => head,
          "base" => base
        },
        %{
          presence: :present,
          resource_kind: :issue,
          github_object_id: issue_id,
          github_node_id: issue_node_id,
          github_number: issue_number,
          snapshot: issue_snapshot,
          label_catalog: label_catalog,
          assignee_catalog: assignee_catalog
        } = issue_observation
      ) do
    with true <- Enum.all?([pull_id, number, issue_id, issue_number], &valid_id?/1),
         true <- valid_identity_text?(pull_node_id) and valid_identity_text?(issue_node_id),
         :ok <-
           consistent_issue(
             number,
             pull_title,
             pull_body,
             pull_state,
             issue_number,
             issue_snapshot
           ),
         {:ok, head_ref, head_repository, head_sha} <- remote_head_side(head),
         {:ok, base_ref, base_repository, base_sha} <- remote_side(base),
         true <-
           distinct_ref_identities?(
             head_ref,
             if(head_repository, do: head_repository.github_object_id),
             base_ref,
             base_repository.github_object_id
           ),
         {:ok, created_at} <- datetime(created_at),
         {:ok, updated_at} <- datetime(updated_at),
         {:ok, issue_updated_at} <- issue_observation_time(issue_observation[:remote_updated_at]),
         {:ok, merge_state} <- remote_merge_state(merged, merged_at, merge_commit_sha, pull_state),
         {:ok, coordinator} <- coordinator(mergeable, rebaseable, mergeable_state),
         {:ok, relationship_snapshot} <-
           relationship_snapshot(issue_snapshot, label_catalog, assignee_catalog) do
      fields = %{
        "title" => issue_snapshot["title"],
        "body" => issue_snapshot["body"],
        "state" => issue_snapshot["state"],
        "state_reason" => issue_snapshot["state_reason"],
        "draft" => draft,
        "head_ref" => head_ref,
        "head_sha" => head_sha,
        "base_ref" => base_ref,
        "base_sha" => base_sha
      }

      with :ok <- validate_fields(fields) do
        {:ok,
         %{
           presence: :present,
           resource_kind: :pull,
           github_object_id: pull_id,
           github_node_id: pull_node_id,
           github_number: number,
           github_issue_object_id: issue_id,
           github_issue_node_id: issue_node_id,
           head_repository: head_repository,
           base_repository: base_repository,
           remote_created_at: created_at,
           remote_updated_at: updated_at,
           issue_remote_updated_at: issue_updated_at,
           snapshot: fields,
           issue_snapshot: Map.merge(Map.take(fields, @issue_fields), relationship_snapshot),
           merge_state: merge_state,
           coordinator: coordinator,
           relationship_snapshot: relationship_snapshot,
           label_catalog: label_catalog,
           assignee_catalog: assignee_catalog
         }}
      end
    else
      {:error, :inconsistent_observation} = error -> error
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_remote(_pull, _issue), do: {:error, :invalid_projection}

  defp issue_observation_time(nil), do: {:ok, nil}
  defp issue_observation_time(%DateTime{utc_offset: 0, std_offset: 0} = time), do: {:ok, time}
  defp issue_observation_time(_), do: {:error, :invalid_projection}

  defp local_merge_state(%{merged_at: nil, merge_commit_sha: nil} = state)
       when map_size(state) == 2,
       do: {:ok, %{merged: false, merged_at: nil, merge_commit_sha: nil}}

  defp local_merge_state(
         %{merged_at: %DateTime{} = merged_at, merge_commit_sha: merge_commit_sha} = state
       )
       when map_size(state) == 2 do
    if valid_oid?(merge_commit_sha) do
      {:ok,
       %{
         merged: true,
         merged_at: DateTime.truncate(merged_at, :second),
         merge_commit_sha: merge_commit_sha
       }}
    else
      {:error, :invalid_projection}
    end
  end

  defp local_merge_state(_state), do: {:error, :invalid_projection}

  defp remote_merge_state(false, nil, _synthetic_merge_commit_sha, state)
       when state in ["open", "closed"],
       do: {:ok, %{merged: false, merged_at: nil, merge_commit_sha: nil}}

  defp remote_merge_state(true, merged_at, merge_commit_sha, "closed") do
    with {:ok, merged_at} <- datetime(merged_at),
         true <- valid_oid?(merge_commit_sha) do
      {:ok, %{merged: true, merged_at: merged_at, merge_commit_sha: merge_commit_sha}}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp remote_merge_state(_merged, _merged_at, _merge_commit_sha, _state),
    do: {:error, :invalid_projection}

  defp coordinator(mergeable, rebaseable, mergeable_state)
       when mergeable in [true, false, nil] and rebaseable in [true, false, nil] do
    if valid_text?(mergeable_state, 128) and mergeable_state != "" do
      {:ok,
       %{
         status: :unsupported,
         mergeable: mergeable,
         rebaseable: rebaseable,
         mergeable_state: mergeable_state
       }}
    else
      {:error, :invalid_projection}
    end
  end

  defp coordinator(_mergeable, _rebaseable, _mergeable_state),
    do: {:error, :invalid_projection}

  defp unsupported_coordinator do
    %{
      status: :unsupported,
      mergeable: nil,
      rebaseable: nil,
      mergeable_state: nil
    }
  end

  defp consistent_issue(
         number,
         pull_title,
         pull_body,
         pull_state,
         number,
         %{
           "title" => issue_title,
           "body" => issue_body,
           "state" => issue_state,
           "state_reason" => _state_reason,
           "label_github_ids" => _label_ids,
           "assignee_github_ids" => _assignee_ids
         }
       ) do
    if pull_title == issue_title and normalize_body(pull_body) == issue_body and
         pull_state == issue_state do
      :ok
    else
      {:error, :inconsistent_observation}
    end
  end

  defp consistent_issue(_number, _title, _body, _state, _issue_number, _snapshot),
    do: {:error, :inconsistent_observation}

  defp remote_head_side(%{"ref" => ref, "sha" => sha, "repo" => nil}) do
    with {:ok, ref} <- canonicalize_branch_ref(ref),
         true <- valid_oid?(sha) do
      {:ok, ref, nil, sha}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp remote_head_side(side), do: remote_side(side)

  defp remote_side(%{
         "ref" => ref,
         "sha" => sha,
         "repo" => %{"id" => id, "node_id" => node_id, "full_name" => full_name}
       }) do
    with {:ok, ref} <- canonicalize_branch_ref(ref),
         true <- valid_oid?(sha),
         true <- valid_id?(id),
         true <- valid_identity_text?(node_id),
         true <- valid_full_name?(full_name) do
      {:ok, ref, %{github_object_id: id, github_node_id: node_id, full_name: full_name}, sha}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp remote_side(_side), do: {:error, :invalid_projection}

  defp canonicalize_branch_ref("refs/heads/" <> _name = ref) do
    if canonical_branch_ref?(ref), do: {:ok, ref}, else: {:error, :invalid_projection}
  end

  defp canonicalize_branch_ref(ref) when is_binary(ref) do
    canonical = "refs/heads/" <> ref
    if canonical_branch_ref?(canonical), do: {:ok, canonical}, else: {:error, :invalid_projection}
  end

  defp canonicalize_branch_ref(_ref), do: {:error, :invalid_projection}

  defp relationship_snapshot(issue_snapshot, label_catalog, assignee_catalog)
       when is_map(label_catalog) and is_map(assignee_catalog) do
    label_ids = issue_snapshot["label_github_ids"]
    assignee_ids = issue_snapshot["assignee_github_ids"]

    if valid_identity_set?(label_ids, label_catalog) and
         valid_identity_set?(assignee_ids, assignee_catalog) do
      {:ok,
       %{
         "label_github_ids" => label_ids,
         "assignee_github_ids" => assignee_ids
       }}
    else
      {:error, :invalid_projection}
    end
  end

  defp relationship_snapshot(_snapshot, _label_catalog, _assignee_catalog),
    do: {:error, :invalid_projection}

  defp valid_identity_set?(ids, catalog) when is_list(ids) do
    ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &valid_id?/1) and
      ids == Enum.sort(Map.keys(catalog))
  end

  defp valid_identity_set?(_ids, _catalog), do: false

  defp validate_fields(fields) when is_map(fields) do
    if Enum.sort(Map.keys(fields)) == @field_keys and valid_title?(fields["title"]) and
         valid_body?(fields["body"]) and fields["state"] in ["open", "closed"] and
         valid_state_reason?(fields["state"], fields["state_reason"]) and
         is_boolean(fields["draft"]) and canonical_branch_ref?(fields["head_ref"]) and
         canonical_branch_ref?(fields["base_ref"]) and
         valid_oid?(fields["head_sha"]) and valid_oid?(fields["base_sha"]) do
      :ok
    else
      {:error, :invalid_projection}
    end
  end

  defp validate_fields(_fields), do: {:error, :invalid_projection}

  defp valid_title?(title),
    do: valid_text?(title, 1_024) and title != "" and codepoints_at_most?(title, 256)

  defp valid_body?(nil), do: true
  defp valid_body?(body), do: valid_text?(body, 262_144) and codepoints_at_most?(body, 65_536)

  defp valid_state_reason?("open", reason), do: reason in [nil, "reopened"]
  defp valid_state_reason?("closed", reason), do: reason in [nil, "completed", "not_planned"]
  defp valid_state_reason?(_state, _reason), do: false

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

  defp distinct_ref_identities?(head_ref, head_repository_id, base_ref, base_repository_id),
    do: head_repository_id != base_repository_id or head_ref != base_ref

  defp valid_oid?(oid), do: is_binary(oid) and Regex.match?(@oid, oid)

  defp normalize_body(""), do: nil
  defp normalize_body(body), do: body

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.truncate(datetime, :second)}
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}
  defp datetime(_value), do: {:error, :invalid_projection}

  defp valid_identity_text?(value), do: valid_text?(value, 512) and value != ""

  defp valid_full_name?(value) when is_binary(value) do
    case String.split(value, "/", parts: 3) do
      [owner, repository] ->
        owner != "" and repository != "" and valid_text?(value, 256)

      _invalid ->
        false
    end
  end

  defp valid_full_name?(_value), do: false

  defp valid_text?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) <= max_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp codepoints_at_most?(value, max),
    do: length(Enum.take(String.codepoints(value), max + 1)) <= max

  defp valid_id?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807
end
