defmodule ForgeMirrors.PullHeadReevaluation do
  @moduledoc "Leased one-way head discovery and conservative activation of read-only pulls."
  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    PullPairBoundary,
    PullCreationBoundary,
    PullHeadResolution,
    RepositoryMirror
  }

  @refs ~w(head_ref head_sha base_ref base_sha)
  @scalars ~w(title body state state_reason)

  def context(operation, lock_fun), do: transaction(fn -> load(operation, lock_fun) end)

  def resolve(operation, pair, observation, lock_fun) do
    transaction(fn ->
      with {:ok, context} <- load(operation, lock_fun),
           :ok <- same_pair(context, pair),
           :ok <- observation(context, observation, false),
           {:ok, result} <- resolve_head(context, observation),
           {:ok, _, _} <- lock_fun.(operation) do
        {:ok, result}
      end
    end)
  end

  def pin(operation, now, pair, observation, lock_fun, finish_fun) do
    transaction(fn ->
      with {:ok, context} <- load(operation, lock_fun),
           :ok <- same_pair(context, pair),
           :ok <- observation(context, observation, true),
           true <- is_nil(context.provider_identity["head_repository"]),
           head when is_map(head) <- observation.pull.provider_identity["head_repository"],
           {:ok, _base} <- base_proof(context),
           {:ok, mapping} <-
             Repo.update(MirrorResourceState.reveal_head_changeset(context.pull_state, head)),
           {:ok, persisted, _} <- lock_fun.(operation),
           {:ok, yielded} <- finish_fun.(persisted, now, :pending) do
        {:ok, %{operation: yielded, pull_state: mapping}}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :identity_conflict}
      end
    end)
  end

  def confirm(operation, now, expected, observation, lock_fun, finish_fun) do
    transaction(fn ->
      with {:ok, context} <- load(operation, lock_fun),
           :ok <- same_pair(context, expected[:pair]),
           :ok <- observation(context, observation, false),
           {:ok, resolution} <- resolve_head(context, observation),
           true <-
             resolution.head_repository_id == expected[:head_repository_id] and
               resolution.pull_eligibility_proof == expected[:pull_eligibility_proof],
           :ok <- exact_metadata(context, observation),
           {:ok, result} <- represent(context, resolution, observation),
           {:ok, ^resolution} <- resolve_head(context, observation),
           {:ok, persisted, _} <- lock_fun.(operation),
           {:ok, completed} <- finish_fun.(persisted, now, :completed) do
        {:ok, Map.put(result, :operation, completed)}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :identity_conflict}
      end
    end)
  end

  defp load(%MirrorOperation{kind: "sync.pull"} = operation, lock_fun) do
    with {:ok, persisted, scope} <- lock_fun.(operation),
         true <- persisted.state == :processing and is_nil(persisted.external_effect_marker),
         {:ok, pull} <- unsupported(scope),
         :ok <- reservations(scope, pull),
         {:ok, resource} <-
           apply(ForgePulls, :sync_projection, [
             scope.repository_id,
             :pull,
             pull.local_resource_id
           ]),
         true <- is_nil(resource.head_repository_id),
         %MirrorResourceState{state: :confirmed} = issue <-
           Repo.one(
             from m in MirrorResourceState,
               where:
                 m.repository_mirror_id == ^scope.repository_mirror_id and
                   m.resource_kind == :issue and m.local_resource_type == "ForgeIssues.Issue" and
                   m.local_resource_id == ^resource.issue_id,
               lock: "FOR UPDATE"
           ),
         :ok <- PullPairBoundary.baselines(pull, issue),
         {:ok, p} <- PullPairBoundary.view(pull),
         {:ok, i} <- PullPairBoundary.view(issue),
         sync =
           Map.merge(scope, %{
             local_resource_id: pull.local_resource_id,
             issue_id: resource.issue_id,
             github_object_id: pull.github_object_id,
             github_node_id: pull.github_node_id,
             github_number: pull.github_number,
             provider_identity: pull.provider_identity,
             confirmed_snapshot: pull.confirmed_snapshot,
             confirmed_merge_state: pull.confirmed_merge_state,
             pair: %{pull: p, issue: i}
           }),
         context = %{
           operation: persisted,
           sync: sync,
           pair: %{pull: p, issue: i},
           resource: resource,
           provider_identity: pull.provider_identity,
           pull_state: pull,
           issue_state: issue
         },
         :ok <- stored_identity(context),
         {:ok, _, _} <- lock_fun.(operation) do
      {:ok, context}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_unsupported_pull}
    end
  end

  defp load(_, _), do: {:error, :invalid_transition}

  defp unsupported(scope) do
    case scope[:reevaluation_mapping] do
      %MirrorResourceState{state: :unsupported, local_resource_type: "ForgePulls.PullRequest"} =
          mapping ->
        {:ok,
         Repo.one!(from m in MirrorResourceState, where: m.id == ^mapping.id, lock: "FOR UPDATE")}

      %MirrorResourceState{state: :unsupported} ->
        {:error, :invalid_unsupported_pull}

      _ ->
        {:error, :unsupported_pull_unavailable}
    end
  end

  defp reservations(scope, pull) do
    binding = Repo.get!(RepositoryMirror, scope.repository_mirror_id)
    head = pull.provider_identity && pull.provider_identity["head_repository"]

    heads =
      case head do
        %{"id" => id, "node_id" => node} when is_integer(id) and is_binary(node) ->
          Repo.all(
            from b in RepositoryMirror,
              where:
                b.organization_mirror_id == ^binding.organization_mirror_id and
                  (b.github_repository_id == ^id or b.github_node_id == ^node),
              order_by: b.id,
              limit: 4,
              select: b.repository_id
          )

        _ ->
          []
      end

    # Resolve candidates only to select lock keys; full immutable identity and
    # active eligibility are still independently checked before representation.
    keys = Enum.sort(Enum.uniq([scope.repository_id | heads])) |> Enum.reject(&is_nil/1)

    acquired =
      Enum.all?(keys, fn id ->
        %{rows: [[locked]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))",
            ["fornacast:merge-reservation:#{id}"]
          )

        locked
      end)

    if acquired,
      do:
        ForgeMirrors.PullMergeBoundary.check_pull_unreserved(
          scope.repository_id,
          pull.local_resource_id
        ),
      else: {:error, :busy}
  end

  defp stored_identity(c) do
    binding = Repo.get!(RepositoryMirror, c.sync.repository_mirror_id)

    obs = %{
      pull: %{
        github_object_id: c.pull_state.github_object_id,
        github_node_id: c.pull_state.github_node_id,
        github_number: c.pull_state.github_number,
        provider_identity: c.provider_identity,
        confirmed_snapshot: c.pull_state.confirmed_snapshot,
        confirmed_merge_state: c.pull_state.confirmed_merge_state,
        remote_updated_at: c.pull_state.confirmed_remote_updated_at
      },
      issue: %{
        github_object_id: c.issue_state.github_object_id,
        github_node_id: c.issue_state.github_node_id,
        github_number: c.issue_state.github_number,
        confirmed_snapshot: c.issue_state.confirmed_snapshot,
        remote_updated_at: c.issue_state.confirmed_remote_updated_at
      }
    }

    with :ok <-
           PullCreationBoundary.validate_pair(
             %{head_repository_id: nil, pull_eligibility_proof: nil},
             obs
           ),
         true <-
           c.provider_identity["base_repository"] == %{
             "id" => binding.github_repository_id,
             "node_id" => binding.github_node_id
           } do
      :ok
    else
      _ -> {:error, :identity_conflict}
    end
  end

  defp observation(c, %{pull: p, issue: i} = obs, reveal) do
    with :ok <-
           PullCreationBoundary.validate_pair(
             %{head_repository_id: nil, pull_eligibility_proof: nil},
             obs
           ),
         true <-
           Enum.all?([:github_object_id, :github_node_id, :github_number], fn key ->
             p[key] == Map.fetch!(c.pull_state, key) and i[key] == Map.fetch!(c.issue_state, key)
           end),
         true <-
           Map.delete(p.provider_identity, "head_repository") ==
             Map.delete(c.provider_identity, "head_repository"),
         true <-
           (reveal and is_nil(c.provider_identity["head_repository"])) or
             p.provider_identity["head_repository"] == c.provider_identity["head_repository"],
         true <-
           Map.take(p.confirmed_snapshot, @refs) ==
             Map.take(c.pull_state.confirmed_snapshot, @refs),
         true <- p.confirmed_merge_state == c.pull_state.confirmed_merge_state,
         true <-
           fresh?(p.remote_updated_at, c.pull_state.confirmed_remote_updated_at) and
             fresh?(i.remote_updated_at, c.issue_state.confirmed_remote_updated_at) do
      :ok
    else
      _ -> {:error, :identity_conflict}
    end
  end

  defp observation(_, _, _), do: {:error, :identity_conflict}
  defp fresh?(_time, nil), do: true
  defp fresh?(time, old), do: DateTime.compare(time, old) != :lt

  defp resolve_head(c, observation),
    do:
      PullHeadResolution.resolve_existing(
        c.sync,
        Map.take(observation.pull, [
          :github_object_id,
          :github_node_id,
          :github_number,
          :provider_identity
        ]),
        observation.pull.confirmed_snapshot
      )

  defp base_proof(c),
    do:
      PullHeadResolution.resolve_existing(
        c.sync,
        %{
          github_object_id: c.pull_state.github_object_id,
          github_node_id: c.pull_state.github_node_id,
          github_number: c.pull_state.github_number,
          provider_identity: Map.put(c.provider_identity, "head_repository", nil)
        },
        c.pull_state.confirmed_snapshot
      )

  defp exact_metadata(c, obs) do
    merge = %{
      "merged_at" =>
        if(c.resource.merge_state.merged_at,
          do: DateTime.to_iso8601(c.resource.merge_state.merged_at)
        ),
      "merge_commit_sha" => c.resource.merge_state.merge_commit_sha
    }

    with true <-
           c.resource.local_version == c.pull_state.confirmed_local_version and
             c.resource.fields == c.pull_state.confirmed_snapshot and
             obs.pull.confirmed_snapshot == c.pull_state.confirmed_snapshot and
             obs.issue.confirmed_snapshot == c.issue_state.confirmed_snapshot and
             merge == c.pull_state.confirmed_merge_state,
         {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             c.sync.repository_mirror_id,
             :local,
             c.resource.label_ids,
             c.resource.assignee_refs
           ),
         snapshot =
           Map.merge(Map.take(c.resource.fields, @scalars), %{
             "label_github_ids" =>
               Enum.sort(Enum.map(relationships.labels, & &1.github_object_id)),
             "assignee_github_ids" =>
               Enum.sort(Enum.map(relationships.assignees, & &1.github_user_id))
           }),
         true <- snapshot == c.issue_state.confirmed_snapshot do
      :ok
    else
      false -> {:error, :unsupported_metadata_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp represent(c, %{head_repository_id: nil}, _),
    do: {:ok, %{resource: c.resource, pull_state: c.pull_state, issue_state: c.issue_state}}

  defp represent(c, resolution, _) do
    with true <-
           is_nil(c.resource.merge_state.merged_at) and
             is_nil(c.resource.merge_state.merge_commit_sha),
         proof = resolution.git_proof,
         request = %{
           repository_id: c.sync.repository_id,
           resource_kind: :pull,
           local_resource_id: c.resource.local_resource_id,
           issue_id: c.resource.issue_id,
           expected_local_version: c.resource.local_version,
           expected_fields: c.resource.fields,
           expected_merge_state: c.resource.merge_state,
           expected_head_repository_id: nil,
           head_repository_id: resolution.head_repository_id,
           expected_repository_generation: proof.base.repository_generation,
           expected_head_repository_generation: proof.head.repository_generation,
           provenance: %{origin: :github}
         },
         multi =
           apply(ForgePulls, :append_sync_represent_head, [Ecto.Multi.new(), :resource, request]),
         {:ok, %{resource: resource}} <- Repo.transaction(multi),
         {:ok, pull} <- advance(c.pull_state, resource.local_version, :confirmed),
         {:ok, issue} <- advance(c.issue_state, resource.local_version, :confirmed) do
      {:ok, %{resource: resource, pull_state: pull, issue_state: issue}}
    else
      false -> {:error, :unsupported_metadata_conflict}
      {:error, reason} -> {:error, reason}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  defp advance(mapping, version, state),
    do:
      mapping
      |> MirrorResourceState.persistence_changeset(%{
        confirmed_local_version: version,
        state: state,
        lock_version: mapping.lock_version + 1
      })
      |> Repo.update()

  defp same_pair(c, pair), do: if(c.pair == pair, do: :ok, else: {:error, :stale_paired_mapping})

  defp transaction(fun),
    do:
      Repo.transaction(fn ->
        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
end
