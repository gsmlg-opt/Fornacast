defmodule ForgePulls.CoordinatedMergeFinalization do
  @moduledoc """
  Trusted, retryable local completion of an already written coordinated merge.

  The coordinator supplies `authorize/1` and `confirm/2`. Both run inside the
  transaction and must perform no network I/O. Authorization locks the remote
  proof, lease and mirror eligibility before domain locks. Confirmation receives
  the actual projection, including newer metadata, and must atomically confirm
  its own operation/mapping or return an error. It must not acknowledge newer
  metadata as remotely synchronized without proof. Positive IDs are not grants.

  A SQL rollback after ref advancement deliberately leaves M recoverable. This
  boundary never constructs a commit. Completed replay requires replay-safe
  callbacks and does not repeat domain mutations or events.

  Optional `metadata_request` is a trusted exact-preimage Sync update applied
  before closure in this same transaction. It may change title, body and
  relationships, never state or refs. Metadata and closure each advance the
  canonical version once; confirmation receives the final actual projection.
  """
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest, Sync}
  alias ForgeRepos.Repository
  alias Fornacast.{Audit, DomainOutbox, Repo}

  @max_id 9_223_372_036_854_775_807
  @oid ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def finalize_coordinated_merge(id, coordinator_id, merged_at, opts) when is_list(opts) do
    cond do
      Repo.in_transaction?() ->
        {:error, :uncommitted_merge_intent}

      not Keyword.keyword?(opts) or not is_function(opts[:authorize], 1) or
          not is_function(opts[:confirm], 2) ->
        {:error, :invalid_coordinator_capability}

      not valid_time?(merged_at) ->
        {:error, :invalid_merged_at}

      not positive?(id) or not positive?(coordinator_id) ->
        {:error, :stale_merge_identity}

      true ->
        with %MergeOperation{} = intent <- Repo.get(MergeOperation, id),
             true <- valid_intent?(intent, coordinator_id),
             {:ok, repositories} <- repositories(intent) do
          with_fences(repositories, %{}, nil, fn paths, deadline ->
            finalize_transaction(intent, merged_at, opts, paths, deadline)
          end)
        else
          _ -> {:error, :stale_merge_identity}
        end
    end
  end

  def finalize_coordinated_merge(_, _, _, _), do: {:error, :invalid_coordinator_capability}

  defp finalize_transaction(expected, merged_at, opts, paths, deadline) do
    Repo.transaction(fn ->
      with :ok <- opts[:authorize].(expected),
           {:ok, issue, pull, intent} <- lock_resource(expected),
           {:ok, _} <- repositories(intent),
           :ok <- validate_snapshot(issue, pull, intent, merged_at),
           :ok <- validate_objects(intent, paths[intent.repository_id], deadline),
           :ok <- validate_refs(intent, paths, deadline),
           :ok <- opts[:authorize].(intent),
           :ok <- advance_ref(intent, paths[intent.repository_id], deadline),
           :ok <- apply_metadata(intent, Keyword.fetch(opts, :metadata_request)),
           {:ok, issue, pull, ^intent} <- lock_resource(intent),
           :ok <- validate_snapshot(issue, pull, intent, merged_at),
           :ok <- apply_domain(issue, pull, intent, merged_at),
           {:ok, projection} <- Sync.sync_projection(intent.repository_id, :pull, pull.id),
           :ok <- remaining(deadline),
           :ok <- opts[:authorize].(intent),
           {:ok, confirmation} <- opts[:confirm].(projection, intent),
           {:ok, completed} <- complete_intent(intent) do
        %{resource: projection, intent: completed, confirmation: confirmation}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:stale_merge_identity)
      end
    end)
  end

  defp lock_resource(expected) do
    resource = expected.commit_intent["resource"]
    issue = Repo.one(from i in Issue, where: i.id == ^resource["issue_id"], lock: "FOR UPDATE")

    pull =
      Repo.one(
        from p in PullRequest, where: p.id == ^expected.pull_request_id, lock: "FOR UPDATE"
      )

    intent = Repo.one(from m in MergeOperation, where: m.id == ^expected.id, lock: "FOR UPDATE")

    if match?(%Issue{}, issue) and match?(%PullRequest{}, pull) and
         intent == expected and valid_intent?(intent, expected.coordinator_operation_id),
       do: {:ok, issue, pull, intent},
       else: {:error, :stale_merge_identity}
  end

  defp validate_snapshot(issue, pull, intent, merged_at) do
    resource = intent.commit_intent["resource"]

    identity =
      issue.repository_id == intent.repository_id and issue.kind == :pull_request and
        issue.id == pull.issue_id and pull.repository_id == intent.repository_id and
        pull.head_repository_id == resource["head_repository_id"] and
        pull.base_ref == intent.base_ref and pull.head_ref == intent.head_ref and
        pull.head_sha == intent.expected_head_oid and
        pull.base_sha in [intent.expected_base_oid, intent.merge_oid] and
        issue.sync_version >= resource["expected_local_version"]

    merge_state =
      case intent.state do
        :merge_written ->
          is_nil(pull.merged_at) and is_nil(pull.merge_commit_sha)

        :completed ->
          pull.merged_at == merged_at and pull.merge_commit_sha == intent.merge_oid and
            pull.merged_by_user_id == intent.actor_user_id and pull.base_sha == intent.merge_oid and
            issue.state == :closed and issue.state_reason == :completed
      end

    if identity and merge_state, do: :ok, else: {:error, :stale_merge_identity}
  end

  defp validate_objects(intent, path, deadline) do
    namespace = "merge-#{intent.id}"

    with :ok <- remaining(deadline),
         {:ok, oid} <-
           GitCore.exact_tracking_ref(path, namespace, "refs/heads/result",
             deadline_ms: budget(deadline)
           ),
         true <- oid == intent.merge_oid,
         {:ok, tree} <-
           GitCore.exact_tracking_ref(path, namespace, "refs/tags/tree",
             deadline_ms: budget(deadline)
           ),
         true <- tree == intent.merge_tree_oid,
         {:ok, %{object_kind: :commit, next_offset: nil, children: children}} <-
           GitCore.expand_lfs_scan_object(path, intent.merge_oid, :commit, 0, 3),
         true <-
           children == [
             %{kind: :tree, oid: intent.merge_tree_oid},
             %{kind: :commit, oid: intent.expected_base_oid},
             %{kind: :commit, oid: intent.expected_head_oid}
           ] do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :merge_intent_conflict}
    end
  end

  defp validate_refs(intent, paths, deadline) do
    with :ok <- remaining(deadline),
         {:ok, head} <-
           GitCore.exact_ref(
             paths[intent.commit_intent["resource"]["head_repository_id"]],
             intent.head_ref,
             deadline_ms: budget(deadline)
           ),
         true <- head == intent.expected_head_oid,
         {:ok, base} <-
           GitCore.exact_ref(paths[intent.repository_id], intent.base_ref,
             deadline_ms: budget(deadline)
           ),
         true <- base in [intent.expected_base_oid, intent.merge_oid],
         true <- intent.state != :completed or base == intent.merge_oid do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_merge_ref}
    end
  end

  defp advance_ref(intent, path, deadline) do
    with :ok <- remaining(deadline),
         {:ok, actual} <- GitCore.exact_ref(path, intent.base_ref, deadline_ms: budget(deadline)) do
      case actual do
        oid when oid == intent.merge_oid ->
          GitCore.invalidate_repository_cache(path)

        oid when oid == intent.expected_base_oid and intent.state == :merge_written ->
          case GitCore.compare_and_swap_ref(
                 path,
                 intent.base_ref,
                 oid,
                 intent.merge_oid,
                 :fast_forward,
                 deadline_ms: budget(deadline)
               ) do
            {:ok, _} -> GitCore.invalidate_repository_cache(path)
            {:error, _} = error -> error
          end

        _ ->
          {:error, :stale_merge_ref}
      end
    end
  end

  defp apply_metadata(%{state: :completed}, _), do: :ok
  defp apply_metadata(_, :error), do: :ok

  defp apply_metadata(intent, {:ok, request}) do
    with :ok <- validate_metadata_request(intent, request) do
      case Multi.new() |> Sync.append_sync_apply(:metadata, request) |> Repo.transaction() do
        {:ok, _} -> :ok
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  defp validate_metadata_request(
         intent,
         %{
           repository_id: repository_id,
           resource_kind: :pull,
           local_resource_id: pull_id,
           action: :update,
           expected_local_version: version,
           expected_fields: expected,
           expected_merge_state: merge_state,
           fields: fields
         } = request
       )
       when is_map(expected) and is_map(fields) and is_map(merge_state) do
    protected = ~w(state state_reason head_ref head_sha base_ref base_sha)
    relationships = [:expected_relationships, :local_label_ids, :assignee_refs]
    relationship_count = Enum.count(relationships, &Map.has_key?(request, &1))

    if repository_id == intent.repository_id and pull_id == intent.pull_request_id and
         positive?(version) and not Map.has_key?(request, :minimum_local_version) and
         Map.take(fields, protected) == Map.take(expected, protected) and
         expected["draft"] == false and fields["draft"] == false and relationship_count in [0, 3],
       do: :ok,
       else: {:error, :invalid_metadata_request}
  end

  defp validate_metadata_request(_, _), do: {:error, :invalid_metadata_request}

  defp apply_domain(_, _, %{state: :completed}, _), do: :ok

  defp apply_domain(issue, pull, intent, merged_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    actor = Repo.get(ForgeAccounts.User, intent.actor_user_id)

    multi =
      Multi.new()
      |> Multi.update(
        :issue,
        issue
        |> Issue.update_changeset(%{state: :closed, state_reason: :completed})
        |> Changeset.put_change(:closed_at, merged_at),
        force: true,
        stale_error_field: :id
      )
      |> Multi.update(
        :pull,
        Changeset.change(pull,
          merged_at: merged_at,
          merge_commit_sha: intent.merge_oid,
          merged_by_user_id: intent.actor_user_id,
          base_sha: intent.merge_oid
        )
      )
      |> Multi.update_all(
        :repository,
        from(r in Repository,
          where:
            r.id == ^intent.repository_id and
              r.generation == ^intent.commit_intent["resource"]["repository_generation"] and
              r.lifecycle == :ready and is_nil(r.deleted_at)
        ),
        set: [last_pushed_at: now, updated_at: now],
        inc: [write_version: 1]
      )
      |> Multi.run(:repository_identity, fn _, %{repository: count} ->
        if match?({1, _}, count), do: {:ok, :current}, else: {:error, :stale_merge_identity}
      end)
      |> DomainOutbox.record_multi(:outbox, fn %{issue: updated} ->
        %{
          event_id: Ecto.UUID.generate(),
          aggregate_type: "issue",
          aggregate_id: to_string(issue.id),
          event_type: "issue.updated",
          origin: :github,
          payload: %{
            "repository_id" => intent.repository_id,
            "issue_id" => issue.id,
            "issue_number" => issue.number,
            "issue_kind" => "pull_request",
            "sync_version" => updated.sync_version
          }
        }
      end)
      |> Audit.record_multi(
        :audit,
        actor,
        "pull_request.merged",
        "repository",
        intent.repository_id,
        %{
          "pull_request_id" => pull.id,
          "ref" => intent.base_ref,
          "oid" => intent.merge_oid,
          "result" => "success"
        },
        operation_id: "coordinated-merge-#{intent.id}"
      )

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  defp complete_intent(%{state: :completed} = intent), do: {:ok, intent}

  defp complete_intent(intent),
    do:
      intent
      |> Changeset.change(state: :completed)
      |> Changeset.optimistic_lock(:lock_version)
      |> Repo.update()

  defp repositories(intent) do
    resource = intent.commit_intent["resource"]
    ids = Enum.sort(Enum.uniq([intent.repository_id, resource["head_repository_id"]]))

    repositories =
      Repo.all(
        from r in Repository,
          where: r.id in ^ids and r.lifecycle == :ready and is_nil(r.deleted_at),
          order_by: r.id
      )

    by_id = Map.new(repositories, &{&1.id, &1})

    with %Repository{} = base <- by_id[intent.repository_id],
         %Repository{} = head <- by_id[resource["head_repository_id"]],
         true <-
           base.generation == resource["repository_generation"] and
             head.generation == resource["head_repository_generation"] and
             head.owner_user_id == base.owner_user_id do
      {:ok, repositories}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp with_fences([], paths, deadline, fun), do: fun.(paths, deadline)

  defp with_fences([repository | rest], paths, deadline, fun) do
    ForgeRepos.with_write_fence(repository, :merge, fn path, remaining ->
      current = System.monotonic_time(:millisecond) + remaining
      deadline = if deadline, do: min(deadline, current), else: current
      with_fences(rest, Map.put(paths, repository.id, path), deadline, fun)
    end)
  end

  defp valid_intent?(intent, coordinator_id) do
    resource = if is_map(intent.commit_intent), do: intent.commit_intent["resource"]
    fields = if is_map(resource), do: resource["expected_fields"]

    intent.coordination_mode == :mirror and intent.coordinator_operation_id == coordinator_id and
      intent.state in [:merge_written, :completed] and is_nil(intent.lease_owner) and
      is_nil(intent.lease_expires_at) and
      is_map(resource) and is_map(fields) and positive?(resource["issue_id"]) and
      positive?(resource["head_repository_id"]) and positive?(resource["expected_local_version"]) and
      oid?(intent.merge_oid) and oid?(intent.merge_tree_oid) and
      oid?(intent.expected_base_oid) and oid?(intent.expected_head_oid) and
      intent.base_ref == fields["base_ref"] and intent.head_ref == fields["head_ref"] and
      intent.expected_base_oid == fields["base_sha"] and
      intent.expected_head_oid == fields["head_sha"]
  end

  defp valid_time?(
         %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0, microsecond: {0, 0}} = time
       ) do
    case DateTime.from_iso8601(DateTime.to_iso8601(time)) do
      {:ok, ^time, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_time?(_), do: false
  defp positive?(id), do: is_integer(id) and id > 0 and id <= @max_id
  defp oid?(oid), do: is_binary(oid) and Regex.match?(@oid, oid)
  defp budget(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp remaining(deadline),
    do: if(budget(deadline) > 0, do: :ok, else: {:error, :deadline_exceeded})
end
