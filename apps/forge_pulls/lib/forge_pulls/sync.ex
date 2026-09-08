defmodule ForgePulls.Sync do
  @moduledoc """
  Trusted metadata synchronization for canonical pull identities.

  The caller owns mirror authorization, ref availability and lease checks. No Git
  effects occur here. Full expected fields are mandatory alongside the canonical
  Issue version as a second check against stale snapshots. Expected merge state
  is also required: observing a
  merged row cannot acknowledge an earlier unmerged baseline. Merge state can be
  observed, but never applied here. Returned fields are normalized by the Issue
  changeset; coordinators must confirm the returned canonical fields.

  Relationship updates require all of `local_label_ids`, `assignee_refs`, and
  `expected_relationships`. The expected preimage contains sorted local label
  IDs and `managed_assignee_identity_ids` (local GitHubIdentity row IDs), so a
  verified link's user/identity representations compare equally. Unmanaged local
  assignees are retained using the shared Issue replacement rules. Scalar-only
  legacy requests leave membership unchanged. Every projection includes actual
  `label_ids`, `assignee_refs`, and `relationship_preimage`.

  Minimum-version effect recovery may return newer membership, never certify it
  as the older baseline. The outer coordinator must validate the returned actual
  projection. Shared relationship helpers hold user FK fences and known identity
  locks; contention returns `:relationship_lock_busy` for a fresh retry.
  """
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.PullRequest
  alias Fornacast.{Audit, DomainOutbox, Repo}

  @keys ~w(base_ref base_sha body draft head_ref head_sha state state_reason title)
  @max_id 9_223_372_036_854_775_807
  @oid ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  defguardp valid_id(id) when is_integer(id) and id > 0 and id <= @max_id

  def sync_projection(repository_id, :pull, id) when valid_id(repository_id) and valid_id(id) do
    Repo.transaction(fn ->
      with {:ok, {pull, issue}} <- resource(Repo, repository_id, id),
           {:ok, result} <- relationship_projection(Repo, pull, issue) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def sync_projection(_, _, _), do: {:error, :not_found}

  @doc """
  Appends a trusted inbound creation. No provider or local number is accepted:
  the canonical issue uses the repository's shared local number sequence.

  `head_repository_id` is explicit (including nil for read-only metadata).
  `local_label_ids` and `assignee_refs` are required observed relationships;
  empty lists explicitly mean none. The caller must prove mirror eligibility
  and provider identity before committing this Multi. Merge facts here describe
  a newly discovered aggregate; this never merges an existing pull or writes Git.
  """
  def append_sync_create(%Multi{} = multi, key, request) do
    multi
    |> Multi.run(key, fn repo, _ ->
      with :ok <- validate_creation(request),
           {:ok, repository} <- creation_repository(repo, request),
           %ForgeAccounts.GitHubIdentity{} = author <-
             repo.get(ForgeAccounts.GitHubIdentity, request.author_github_identity_id),
           {:ok, number} <- allocate_number(repo, repository.id),
           {:ok, issue} <-
             repo.insert(
               Issue.import_changeset(
                 %Issue{repository_id: repository.id, kind: :pull_request},
                 Map.merge(Map.take(request.fields, ~w(title body state state_reason)), %{
                   "number" => number,
                   "author_github_identity_id" => author.id,
                   "inserted_at" => request.inserted_at,
                   "updated_at" => request.updated_at,
                   "closed_at" => if(request.fields["state"] == "closed", do: request.updated_at)
                 })
               )
             ),
           {:ok, pull} <-
             repo.insert(
               PullRequest.import_changeset(
                 %PullRequest{repository_id: repository.id, issue_id: issue.id},
                 Map.merge(request.fields, %{
                   "inserted_at" => request.inserted_at,
                   "updated_at" => request.updated_at,
                   "merged_at" => request.merge_state.merged_at,
                   "merge_commit_sha" => request.merge_state.merge_commit_sha
                 }),
                 issue,
                 repository,
                 request.head_repository_id
               )
             ),
           {:ok, _relationships} <- create_relationships(repo, issue, request) do
        relationship_projection(repo, pull, issue)
      else
        nil -> {:error, :invalid_author}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> DomainOutbox.record_multi({key, :outbox}, fn changes ->
      result = Map.fetch!(changes, key)

      %{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "issue",
        aggregate_id: to_string(result.issue_id),
        event_type: "issue.created",
        origin: :github,
        causation_id: request.provenance[:causation_id],
        correlation_id: request.provenance[:correlation_id],
        payload: %{
          "repository_id" => result.repository_id,
          "issue_id" => result.issue_id,
          "issue_number" => result.issue_number,
          "issue_kind" => "pull_request",
          "sync_version" => result.local_version
        }
      }
    end)
    |> Audit.record_multi(
      {key, :audit},
      nil,
      "github_sync.applied",
      "repository",
      fn changes -> Map.fetch!(changes, key).repository_id end,
      fn changes ->
        result = Map.fetch!(changes, key)

        %{
          "repository_id" => result.repository_id,
          "resource_id" => result.local_resource_id,
          "resource_kind" => "pull",
          "action" => "create"
        }
      end
    )
  end

  defp validate_creation(
         %{
           resource_kind: :pull,
           repository_id: repository_id,
           head_repository_id: head_id,
           author_github_identity_id: author_id,
           fields: fields,
           merge_state: merge,
           local_label_ids: labels,
           assignee_refs: refs,
           inserted_at: inserted_at,
           updated_at: updated_at,
           provenance: %{origin: :github} = provenance
         } = request
       )
       when valid_id(repository_id) and valid_id(author_id) and
              (is_nil(head_id) or valid_id(head_id)) do
    if map_size(request) == 11 and valid_fields?(fields) and valid_merge_state?(merge) and
         valid_creation_time?(inserted_at) and valid_creation_time?(updated_at) and
         DateTime.compare(inserted_at, updated_at) != :gt and
         (is_nil(merge.merged_at) or
            (valid_creation_time?(merge.merged_at) and fields["state"] == "closed" and
               DateTime.compare(merge.merged_at, updated_at) != :gt)) and
         is_list(labels) and length(labels) <= 100 and
         Enum.all?(labels, fn id -> valid_id(id) end) and
         is_list(refs) and length(refs) <= 100 and Enum.all?(refs, &valid_assignee?/1) and
         Enum.all?(Map.keys(provenance), &(&1 in [:origin, :causation_id, :correlation_id])) and
         Enum.all?([:causation_id, :correlation_id], &bounded_optional?(provenance[&1], 255)),
       do: :ok,
       else: {:error, :invalid_sync_request}
  end

  defp validate_creation(_), do: {:error, :invalid_sync_request}

  defp valid_creation_time?(%DateTime{
         time_zone: "Etc/UTC",
         utc_offset: 0,
         std_offset: 0,
         microsecond: {0, _}
       }),
       do: true

  defp valid_creation_time?(_), do: false

  defp valid_assignee?(%{kind: kind, id: id} = ref)
       when kind in [:local_user, :github_identity] and valid_id(id), do: map_size(ref) == 2

  defp valid_assignee?(_), do: false

  defp creation_repository(repo, request) do
    ids =
      [request.repository_id, request.head_repository_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      repo.all(
        from r in ForgeRepos.Repository,
          where:
            r.id in ^ids and is_nil(r.deleted_at) and r.lifecycle in [:ready, :synchronizing],
          order_by: r.id,
          lock: "FOR UPDATE"
      )

    if length(rows) == length(ids),
      do: {:ok, Enum.find(rows, &(&1.id == request.repository_id))},
      else: {:error, :not_found}
  end

  defp allocate_number(repo, repository_id) do
    alias ForgeIssues.NumberSequence

    with {:ok, _} <-
           repo.insert(
             NumberSequence.changeset(%NumberSequence{}, %{repository_id: repository_id}),
             on_conflict: :nothing,
             conflict_target: [:repository_id]
           ) do
      sequence =
        repo.one!(
          from s in NumberSequence, where: s.repository_id == ^repository_id, lock: "FOR UPDATE"
        )

      if sequence.next_number < @max_id do
        case repo.update(
               NumberSequence.finalize_changeset(sequence, %{
                 next_number: sequence.next_number + 1
               })
             ) do
          {:ok, _} -> {:ok, sequence.next_number}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :number_sequence_exhausted}
      end
    end
  end

  defp create_relationships(repo, issue, request) do
    labels = Enum.sort(Enum.uniq(request.local_label_ids))
    refs = Enum.sort(Enum.uniq(request.assignee_refs))

    identities =
      Enum.map(refs, fn
        %{kind: :local_user, id: id} -> {:user, id}
        %{kind: :github_identity, id: id} -> {:github, id}
      end)

    if repo.aggregate(
         from(l in ForgeIssues.Label,
           where: l.repository_id == ^issue.repository_id and l.id in ^labels
         ),
         :count
       ) == length(labels) and
         map_size(ForgeAccounts.resolve_attributions(identities)) == length(refs) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      repo.insert_all(
        ForgeIssues.IssueLabel,
        Enum.map(labels, &%{issue_id: issue.id, label_id: &1, inserted_at: now, updated_at: now})
      )

      repo.insert_all(
        ForgeIssues.IssueAssignee,
        Enum.map(refs, fn ref ->
          %{
            issue_id: issue.id,
            user_id: if(ref.kind == :local_user, do: ref.id),
            github_identity_id: if(ref.kind == :github_identity, do: ref.id),
            inserted_at: now,
            updated_at: now
          }
        end)
      )

      {:ok, %{label_ids: labels, assignee_refs: refs}}
    else
      {:error, :invalid_relationship}
    end
  end

  def append_sync_observe(%Multi{} = multi, key, expected) do
    Multi.run(multi, key, fn repo, _ ->
      with :ok <- validate_observation(expected),
           {:ok, {pull, issue}} <-
             resource(repo, expected.repository_id, expected.local_resource_id),
           :ok <- expected_snapshot(pull, issue, expected),
           {:ok, result} <- relationship_projection(repo, pull, issue),
           :ok <- expected_relationships(result, expected) do
        {:ok, result}
      end
    end)
  end

  def append_sync_apply(%Multi{} = multi, key, request) do
    multi
    |> Multi.run(key, fn repo, _ ->
      with :ok <- validate_request(request),
           {:ok, {pull, issue}} <-
             resource(repo, request.repository_id, request.local_resource_id),
           :ok <- expected_snapshot(pull, issue, request),
           {:ok, before} <- relationship_projection(repo, pull, issue),
           :ok <- expected_relationships(before, request),
           :ok <- mutable_metadata(pull, request.fields),
           {:ok, issue} <-
             repo.update(Issue.update_changeset(issue, request.fields),
               force: true,
               stale_error_field: :id
             ),
           {:ok, pull} <-
             repo.update(
               pull
               |> PullRequest.update_changeset(request.fields)
               |> Changeset.put_change(:mergeable, nil)
               |> Changeset.put_change(:mergeable_state, :unknown)
             ),
           :ok <- apply_relationships(repo, issue, request) do
        relationship_projection(repo, pull, issue)
      end
    end)
    |> DomainOutbox.record_multi({key, :outbox}, fn changes ->
      result = Map.fetch!(changes, key)

      %{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "issue",
        aggregate_id: to_string(result.issue_id),
        event_type: "issue.updated",
        origin: :github,
        causation_id: request.provenance[:causation_id],
        correlation_id: request.provenance[:correlation_id],
        payload: %{
          "repository_id" => result.repository_id,
          "issue_id" => result.issue_id,
          "issue_number" => result.issue_number,
          "issue_kind" => "pull_request",
          "sync_version" => result.local_version
        }
      }
    end)
    |> Audit.record_multi(
      {key, :audit},
      nil,
      "github_sync.applied",
      "repository",
      fn changes -> Map.fetch!(changes, key).repository_id end,
      fn changes ->
        result = Map.fetch!(changes, key)

        %{
          "repository_id" => result.repository_id,
          "resource_id" => result.local_resource_id,
          "resource_kind" => "pull",
          "action" => "update"
        }
      end
    )
  end

  defp validate_expected(
         %{
           repository_id: repository_id,
           resource_kind: :pull,
           local_resource_id: id,
           expected_local_version: version,
           expected_fields: fields,
           expected_merge_state: merge_state
         } = expected
       )
       when valid_id(repository_id) and valid_id(id) and valid_id(version) and version < @max_id and
              not is_map_key(expected, :minimum_local_version) do
    if valid_fields?(fields) and valid_merge_state?(merge_state) and
         (not Map.has_key?(expected, :expected_relationships) or
            valid_relationship_preimage?(expected.expected_relationships)),
       do: :ok,
       else: {:error, :invalid_sync_request}
  end

  defp validate_expected(_), do: {:error, :invalid_sync_request}

  defp validate_observation(%{minimum_local_version: minimum} = expected)
       when not is_map_key(expected, :expected_local_version) do
    expected
    |> Map.delete(:minimum_local_version)
    |> Map.put(:expected_local_version, minimum)
    |> validate_expected()
  end

  defp validate_observation(expected), do: validate_expected(expected)

  defp validate_request(
         %{action: :update, fields: fields, provenance: %{origin: :github} = provenance} = request
       ) do
    with :ok <- validate_expected(request) do
      if valid_fields?(fields) and valid_relationship_request?(request) and
           Enum.all?([:causation_id, :correlation_id], &bounded_optional?(provenance[&1], 255)),
         do: :ok,
         else: {:error, :invalid_sync_request}
    end
  end

  defp validate_request(_), do: {:error, :invalid_sync_request}

  defp valid_relationship_request?(request) do
    group = [:expected_relationships, :local_label_ids, :assignee_refs]

    case Enum.count(group, &Map.has_key?(request, &1)) do
      0 ->
        true

      3 ->
        valid_relationship_preimage?(request.expected_relationships) and
          is_list(request.local_label_ids) and length(request.local_label_ids) <= 512 and
          Enum.all?(request.local_label_ids, &valid_id/1) and
          is_list(request.assignee_refs) and length(request.assignee_refs) <= 512 and
          Enum.all?(request.assignee_refs, &valid_assignee?/1)

      _ ->
        false
    end
  end

  defp valid_relationship_preimage?(
         %{label_ids: labels, managed_assignee_identity_ids: identities} = value
       ),
       do: map_size(value) == 2 and canonical_ids?(labels) and canonical_ids?(identities)

  defp valid_relationship_preimage?(_), do: false

  defp canonical_ids?(ids) when is_list(ids),
    do:
      length(ids) <= 512 and
        Enum.all?(ids, &valid_id/1) and ids == Enum.sort(Enum.uniq(ids))

  defp canonical_ids?(_), do: false

  defp expected_relationships(%{local_version: current}, %{minimum_local_version: minimum})
       when current > minimum, do: :ok

  defp expected_relationships(projection, %{expected_relationships: expected}) do
    if projection.relationship_preimage == expected,
      do: :ok,
      else: {:error, :stale_local_relationships}
  end

  defp expected_relationships(_, _), do: :ok

  defp apply_relationships(repo, issue, %{expected_relationships: _} = request),
    do: ForgeIssues.Sync.replace_relationships(repo, issue, request)

  defp apply_relationships(_, _, _), do: :ok

  defp relationship_projection(repo, pull, issue) do
    with {:ok, relationships} <- ForgeIssues.Sync.relationship_projection(repo, issue),
         do: {:ok, Map.merge(projection(pull, issue), relationships)}
  end

  defp valid_fields?(fields) when is_map(fields) do
    Enum.sort(Map.keys(fields)) == @keys and bounded_string?(fields["title"], 1024) and
      valid_body?(fields["body"]) and is_boolean(fields["draft"]) and
      fields["state"] in ~w(open closed) and
      fields["state_reason"] in [nil, "completed", "not_planned", "reopened"] and
      Enum.all?(~w(head_ref base_ref), &bounded_string?(fields[&1], 1024)) and
      Enum.all?(
        ~w(head_sha base_sha),
        &(is_binary(fields[&1]) and Regex.match?(@oid, fields[&1]))
      )
  end

  defp valid_fields?(_), do: false
  defp valid_body?(nil), do: true

  defp valid_body?(body),
    do: bounded_string?(body, 262_144) and length(String.codepoints(body)) <= 65_536

  defp valid_merge_state?(%{merged_at: nil, merge_commit_sha: nil} = state),
    do: map_size(state) == 2

  defp valid_merge_state?(%{merged_at: %DateTime{}, merge_commit_sha: sha} = state),
    do: map_size(state) == 2 and is_binary(sha) and Regex.match?(@oid, sha)

  defp valid_merge_state?(_), do: false
  defp bounded_optional?(nil, _), do: true
  defp bounded_optional?(value, max), do: bounded_string?(value, max)

  defp bounded_string?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp resource(repo, repository_id, id) do
    repository =
      repo.one(
        from r in ForgeRepos.Repository,
          where:
            r.id == ^repository_id and is_nil(r.deleted_at) and
              r.lifecycle in [:ready, :synchronizing]
      )

    if repository do
      pull_identity =
        from p in PullRequest,
          where: p.id == ^id and p.repository_id == ^repository_id,
          select: p.issue_id

      # Match local updates and SnapshotRefresh: canonical Issue before extension.
      with %Issue{} = issue <-
             repo.one(
               from i in Issue,
                 where:
                   i.id in subquery(pull_identity) and i.repository_id == ^repository_id and
                     i.kind == :pull_request,
                 lock: "FOR UPDATE"
             ),
           %PullRequest{} = pull <-
             repo.one(
               from p in PullRequest,
                 where:
                   p.id == ^id and p.repository_id == ^repository_id and p.issue_id == ^issue.id,
                 lock: "FOR UPDATE"
             ) do
        {:ok, {pull, issue}}
      else
        nil -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # Only observation of an already-proven external effect may tolerate newer
  # local metadata. Ref and merge facts must still match the recovery evidence.
  defp expected_snapshot(pull, issue, %{minimum_local_version: minimum} = expected) do
    refs = ~w(head_ref base_ref head_sha base_sha)

    cond do
      issue.sync_version < minimum ->
        {:error, :stale_local_version}

      Map.take(fields(pull, issue), refs) != Map.take(expected.expected_fields, refs) ->
        {:error, :stale_local_snapshot}

      merge_state(pull) != expected.expected_merge_state ->
        {:error, :stale_local_snapshot}

      true ->
        :ok
    end
  end

  defp expected_snapshot(pull, issue, expected) do
    cond do
      issue.sync_version != expected.expected_local_version -> {:error, :stale_local_version}
      fields(pull, issue) != expected.expected_fields -> {:error, :stale_local_snapshot}
      merge_state(pull) != expected.expected_merge_state -> {:error, :stale_local_snapshot}
      true -> :ok
    end
  end

  defp mutable_metadata(pull, fields) do
    cond do
      not is_nil(pull.merged_at) or not is_nil(pull.merge_commit_sha) ->
        {:error, :unsupported_merge_state}

      pull.head_ref != fields["head_ref"] ->
        {:error, :immutable_identity}

      true ->
        :ok
    end
  end

  defp projection(pull, issue),
    do: %{
      repository_id: pull.repository_id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      local_resource_type: "ForgePulls.PullRequest",
      local_version: issue.sync_version,
      issue_id: issue.id,
      issue_number: issue.number,
      head_repository_id: pull.head_repository_id,
      merged_at: pull.merged_at,
      merge_commit_sha: pull.merge_commit_sha,
      merge_state: merge_state(pull),
      fields: fields(pull, issue)
    }

  defp merge_state(pull), do: Map.take(pull, [:merged_at, :merge_commit_sha])

  defp fields(pull, issue),
    do: %{
      "title" => issue.title,
      "body" => issue.body,
      "state" => Atom.to_string(issue.state),
      "state_reason" => if(issue.state_reason, do: Atom.to_string(issue.state_reason)),
      "draft" => pull.draft,
      "head_ref" => pull.head_ref,
      "base_ref" => pull.base_ref,
      "head_sha" => pull.head_sha,
      "base_sha" => pull.base_sha
    }
end
