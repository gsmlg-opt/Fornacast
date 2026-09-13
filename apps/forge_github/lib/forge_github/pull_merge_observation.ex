defmodule ForgeGitHub.PullMergeObservation do
  @moduledoc "Read-only normalization of an observed, exact coordinated merge result."
  import Ecto.Query
  alias ForgeGitHub.{IssueSyncProjection, PullSyncProjection, User}
  alias Fornacast.Repo

  def build(
        %{repository_mirror_id: binding_id} = sync,
        %{pull: raw_pull, issue: raw_issue},
        remote_base_oid
      )
      when is_integer(binding_id) and binding_id > 0 and is_map(raw_pull) and is_map(raw_issue) do
    with {:ok, relationships} <- relationships(binding_id, raw_issue),
         {:ok, issue} <-
           IssueSyncProjection.from_remote_issue(raw_issue, relationships, sync[:correlation_id]),
         {:ok, pull} <- PullSyncProjection.from_remote(raw_pull, issue),
         {:ok, merged_at} <- exact_observation(sync, pull, issue, remote_base_oid) do
      {:ok, build_observation(sync, pull, issue, remote_base_oid, merged_at)}
    else
      {:error, :merge_metadata_unconfirmed} = error -> error
      {:error, :relationship_lock_busy} = error -> error
      _ -> {:error, :invalid_merge_observation}
    end
  end

  def build(_, _, _), do: {:error, :invalid_merge_observation}

  @doc "Returns the first missing provider label and its authenticated merge observation."
  def label_candidate(
        %{repository_mirror_id: binding_id} = sync,
        %{pull: raw_pull, issue: %{"labels" => labels, "assignees" => assignees} = raw_issue},
        remote_base_oid
      )
      when is_integer(binding_id) and binding_id > 0 and is_map(raw_pull) and is_list(labels) and
             is_list(assignees) and length(labels) <= 512 and length(assignees) <= 512 do
    with {:ok, profiles} <- normalize_assignee_profiles(assignees),
         {:ok, candidates} <- normalize_label_candidates(labels),
         {:ok, relationships} <- transient_relationships(labels, profiles),
         {:ok, issue} <-
           IssueSyncProjection.from_remote_issue(raw_issue, relationships, sync[:correlation_id]),
         {:ok, pull} <- PullSyncProjection.from_remote(raw_pull, issue),
         {:ok, merged_at} <- exact_observation(sync, pull, issue, remote_base_oid),
         true <- known_assignee_nodes?(profiles),
         {:ok, status} <- label_status(sync, candidates) do
      observation = build_observation(sync, pull, issue, remote_base_oid, merged_at)

      case status do
        :ready -> {:ok, %{status: :ready, observation: observation}}
        candidate -> {:ok, %{status: :missing, candidate: candidate, observation: observation}}
      end
    else
      {:error, :invalid_merge_observation} = error -> error
      {:error, :relationship_lock_busy} = error -> error
      {:error, :invalid_projection} -> {:error, :invalid_merge_observation}
      _ -> {:error, :merge_metadata_unconfirmed}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  def label_candidate(_, _, _), do: {:error, :invalid_merge_observation}

  @doc "Returns normalized assignee transport profiles from an exact merged pair without writing."
  def assignee_profiles(
        %{repository_mirror_id: binding_id} = sync,
        %{pull: raw_pull, issue: %{"labels" => labels, "assignees" => assignees} = raw_issue},
        remote_base_oid
      )
      when is_integer(binding_id) and binding_id > 0 and is_map(raw_pull) and is_list(labels) and
             is_list(assignees) and length(labels) <= 512 and length(assignees) <= 512 do
    with {:ok, profiles} <- normalize_assignee_profiles(assignees),
         {:ok, relationships} <- transient_relationships(labels, profiles),
         {:ok, issue} <-
           IssueSyncProjection.from_remote_issue(raw_issue, relationships, sync[:correlation_id]),
         {:ok, pull} <- PullSyncProjection.from_remote(raw_pull, issue),
         {:ok, _merged_at} <- exact_observation(sync, pull, issue, remote_base_oid),
         true <- label_nodes?(binding_id, labels),
         true <- known_assignee_nodes?(profiles) do
      {:ok, profiles}
    else
      {:error, :invalid_merge_observation} = error -> error
      {:error, :relationship_lock_busy} = error -> error
      {:error, :invalid_projection} -> {:error, :invalid_merge_observation}
      _ -> {:error, :merge_metadata_unconfirmed}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  def assignee_profiles(_, _, _), do: {:error, :invalid_merge_observation}

  defp exact_observation(
         %{
           expected: %{provider_identity: identity},
           provider_pull_identity: pinned,
           intent: %{
             merge_oid: merge_oid,
             expected_base_oid: base_oid,
             expected_head_oid: head_oid,
             base_ref: base_ref,
             head_ref: head_ref
           }
         },
         pull,
         issue,
         remote_base_oid
       )
       when is_map(identity) and is_map(pinned) and is_binary(merge_oid) do
    with true <- remote_base_oid == merge_oid,
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
      {:ok, merged_at}
    else
      _ -> {:error, :invalid_merge_observation}
    end
  end

  defp exact_observation(_, _, _, _), do: {:error, :invalid_merge_observation}

  defp repository_identity(%{github_object_id: id, github_node_id: node}),
    do: %{"id" => id, "node_id" => node}

  defp repository_identity(_), do: nil

  defp build_observation(sync, pull, issue, remote_base_oid, merged_at) do
    merge_oid = sync.intent.merge_oid
    identity = sync.expected.provider_identity

    snapshot =
      Map.merge(pull.snapshot, %{"base_sha" => remote_base_oid, "state_reason" => "completed"})

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
    }
  end

  defp normalize_label_candidates(labels) do
    labels
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, candidates} ->
      case normalize_label_candidate(label) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, candidates} ->
        candidates = Enum.sort_by(candidates, & &1.github_object_id)
        ids = Enum.map(candidates, & &1.github_object_id)
        nodes = Enum.map(candidates, & &1.node_id)

        if length(ids) == length(Enum.uniq(ids)) and length(nodes) == length(Enum.uniq(nodes)),
          do: {:ok, candidates},
          else: {:error, :merge_metadata_unconfirmed}

      error ->
        error
    end
  end

  defp normalize_label_candidate(
         %{
           "id" => id,
           "node_id" => node,
           "name" => name,
           "color" => color
         } = label
       ) do
    description = Map.get(label, "description")

    valid =
      positive_id?(id) and nonempty_text?(node, 255) and nonempty_text?(name, 255) and
        valid_color?(color) and (is_nil(description) or text?(description, 100)) and
        Enum.all?([node, name, color, description], fn value ->
          ForgeAccounts.GitHubProfileSafety.validate(%{description: value}) == :ok
        end)

    if valid do
      {:ok,
       %{
         github_object_id: id,
         node_id: node,
         name: name,
         color: String.downcase(color),
         description: if(description == "", do: nil, else: description)
       }}
    else
      {:error, :merge_metadata_unconfirmed}
    end
  end

  defp normalize_label_candidate(_), do: {:error, :merge_metadata_unconfirmed}

  defp normalize_assignee_profiles(assignees) do
    assignees
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, profiles} ->
      case User.from_json(raw) do
        {:ok, %User{node_id: node_id} = user} when is_binary(node_id) ->
          profile = Map.from_struct(user)

          if ForgeAccounts.GitHubProfileSafety.validate(profile) == :ok,
            do: {:cont, {:ok, [profile | profiles]}},
            else: {:halt, {:error, :merge_metadata_unconfirmed}}

        _ ->
          {:halt, {:error, :merge_metadata_unconfirmed}}
      end
    end)
    |> case do
      {:ok, profiles} ->
        profiles = Enum.sort_by(profiles, & &1.id)

        if unique_profiles?(profiles),
          do: {:ok, profiles},
          else: {:error, :merge_metadata_unconfirmed}

      error ->
        error
    end
  end

  defp unique_profiles?(profiles) do
    ids = Enum.map(profiles, & &1.id)
    nodes = Enum.map(profiles, & &1.node_id)
    length(ids) == length(Enum.uniq(ids)) and length(nodes) == length(Enum.uniq(nodes))
  end

  defp transient_relationships(labels, profiles) do
    if Enum.all?(labels, &is_map/1) do
      {:ok,
       %{
         labels:
           Enum.map(labels, fn label ->
             %{
               github_object_id: Map.get(label, "id"),
               local_label_id: Map.get(label, "id"),
               name: Map.get(label, "name")
             }
           end),
         assignees:
           Enum.map(profiles, fn profile ->
             %{
               github_user_id: profile.id,
               login: profile.login,
               ref: %{kind: :github_identity, id: profile.id}
             }
           end)
       }}
    else
      {:error, :merge_metadata_unconfirmed}
    end
  end

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
          join: binding in ForgeMirrors.RepositoryMirror,
          on: binding.id == m.repository_mirror_id,
          join: label in "repository_labels",
          on: label.id == m.local_resource_id,
          where:
            m.repository_mirror_id == ^binding_id and m.resource_kind == :label and
              m.local_resource_type == "ForgeIssues.Label" and m.state == :confirmed and
              label.repository_id == binding.repository_id and m.github_object_id in ^ids,
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

  defp known_assignee_nodes?(profiles) do
    ids = Enum.map(profiles, & &1.id)
    nodes = Enum.map(profiles, & &1.node_id)

    rows =
      Repo.all(
        from(i in ForgeAccounts.GitHubIdentity,
          where: i.kind == :user and (i.github_user_id in ^ids or i.github_node_id in ^nodes),
          order_by: i.github_user_id,
          lock: "FOR SHARE NOWAIT",
          select: {i.github_user_id, i.github_node_id}
        ),
        lock_options()
      )

    by_id = Map.new(profiles, &{&1.id, &1.node_id})
    by_node = Map.new(profiles, &{&1.node_id, &1.id})

    Enum.all?(rows, fn {id, node} ->
      Map.has_key?(by_id, id) and node in [nil, by_id[id]] and
        (is_nil(node) or by_node[node] == id)
    end)
  end

  defp label_status(
         %{repository_id: repository_id, repository_mirror_id: binding_id},
         candidates
       ) do
    with %ForgeMirrors.RepositoryMirror{} = binding <-
           Repo.get(ForgeMirrors.RepositoryMirror, binding_id),
         true <- binding.repository_id == repository_id,
         {:ok, mappings} <- existing_label_mappings(binding, candidates),
         true <- label_nodes_match?(mappings, candidates),
         true <- no_label_node_collision?(binding, mappings, candidates) do
      known_ids = MapSet.new(mappings, & &1.github_object_id)

      case Enum.find(candidates, &(not MapSet.member?(known_ids, &1.github_object_id))) do
        nil -> {:ok, :ready}
        candidate -> {:ok, candidate}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :merge_metadata_unconfirmed}
    end
  end

  defp label_status(_, _), do: {:error, :merge_metadata_unconfirmed}

  defp existing_label_mappings(binding, candidates) do
    ids = Enum.map(candidates, & &1.github_object_id)

    mappings =
      Repo.all(
        from(m in ForgeMirrors.MirrorResourceState,
          where:
            m.repository_mirror_id == ^binding.id and m.resource_kind == :label and
              m.github_object_id in ^ids,
          order_by: [asc: m.github_object_id, asc: m.id],
          lock: "FOR SHARE NOWAIT",
          select: %{
            id: m.id,
            github_object_id: m.github_object_id,
            github_node_id: m.github_node_id,
            local_resource_id: m.local_resource_id,
            local_resource_type: m.local_resource_type,
            state: m.state
          }
        ),
        lock_options()
      )

    joined =
      Repo.all(
        from(m in ForgeMirrors.MirrorResourceState,
          join: label in "repository_labels",
          on: label.id == m.local_resource_id,
          where:
            m.repository_mirror_id == ^binding.id and m.resource_kind == :label and
              m.local_resource_type == "ForgeIssues.Label" and m.state == :confirmed and
              label.repository_id == ^binding.repository_id and m.github_object_id in ^ids,
          order_by: [asc: m.github_object_id, asc: m.id],
          lock: "FOR SHARE NOWAIT",
          select: %{
            id: m.id,
            github_object_id: m.github_object_id,
            github_node_id: m.github_node_id,
            local_resource_id: m.local_resource_id,
            local_resource_type: m.local_resource_type,
            state: m.state
          }
        ),
        lock_options()
      )

    if mappings == joined and
         length(mappings) == length(Enum.uniq_by(mappings, & &1.github_object_id)),
       do: {:ok, mappings},
       else: {:error, :merge_metadata_unconfirmed}
  end

  defp label_nodes_match?(mappings, candidates) do
    nodes = Map.new(candidates, &{&1.github_object_id, &1.node_id})

    Enum.all?(mappings, fn mapping ->
      is_binary(mapping.github_node_id) and
        nodes[mapping.github_object_id] == mapping.github_node_id
    end)
  end

  defp no_label_node_collision?(binding, mappings, candidates) do
    nodes = Enum.map(candidates, & &1.node_id)
    own = Map.new(mappings, &{&1.github_node_id, &1.id})

    collisions =
      Repo.all(
        from(m in ForgeMirrors.MirrorResourceState,
          join: repository in ForgeMirrors.RepositoryMirror,
          on: repository.id == m.repository_mirror_id,
          where:
            repository.organization_mirror_id == ^binding.organization_mirror_id and
              m.resource_kind == :label and m.github_node_id in ^nodes,
          order_by: [asc: m.github_node_id, asc: m.id],
          lock: "FOR SHARE NOWAIT",
          select: {m.github_node_id, m.id}
        ),
        lock_options()
      )

    Enum.all?(collisions, fn {node, mapping_id} -> own[node] == mapping_id end)
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

  defp positive_id?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807

  defp valid_color?(color),
    do: is_binary(color) and byte_size(color) == 6 and Regex.match?(~r/^[0-9a-fA-F]{6}$/, color)

  defp nonempty_text?(value, maximum), do: text?(value, maximum) and String.trim(value) != ""

  defp text?(value, maximum) when is_binary(value),
    do:
      byte_size(value) <= maximum * 4 and String.valid?(value) and
        length(String.codepoints(value)) <= maximum and
        :binary.match(value, <<0>>) == :nomatch

  defp text?(_, _), do: false
end
