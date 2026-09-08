defmodule ForgePulls.Sync do
  @moduledoc """
  Trusted metadata synchronization for existing canonical pull identities.

  The caller owns mirror authorization, ref availability and lease checks. No Git
  effects occur here. Full expected fields are mandatory alongside the canonical
  Issue version as a second check against stale snapshots. Expected merge state
  is also required: observing a
  merged row cannot acknowledge an earlier unmerged baseline. Merge state can be
  observed, but never applied here. Returned fields are normalized by the Issue
  changeset; coordinators must confirm the returned canonical fields.
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
      case resource(Repo, repository_id, id) do
        {:ok, {pull, issue}} -> projection(pull, issue)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def sync_projection(_, _, _), do: {:error, :not_found}

  def append_sync_observe(%Multi{} = multi, key, expected) do
    Multi.run(multi, key, fn repo, _ ->
      with :ok <- validate_observation(expected),
           {:ok, {pull, issue}} <-
             resource(repo, expected.repository_id, expected.local_resource_id),
           :ok <- expected_snapshot(pull, issue, expected) do
        {:ok, projection(pull, issue)}
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
             ) do
        {:ok, projection(pull, issue)}
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
    if valid_fields?(fields) and valid_merge_state?(merge_state),
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
      if valid_fields?(fields) and
           Enum.all?([:causation_id, :correlation_id], &bounded_optional?(provenance[&1], 255)),
         do: :ok,
         else: {:error, :invalid_sync_request}
    end
  end

  defp validate_request(_), do: {:error, :invalid_sync_request}

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
