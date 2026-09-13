defmodule ForgeMirrors.PullMergeRemoteLabelObservation do
  @moduledoc """
  Atomically materializes one authenticated remote label during merge recovery.

  The label is a local prerequisite, not a merge effect. A successful import
  therefore releases the current lease while retaining the merge marker,
  coordinator reservation, metadata intent and paired baselines unchanged.
  """

  import Ecto.Query
  alias Ecto.Multi

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    PullMergeConfirmation,
    RepositoryMirror
  }

  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  @candidate_keys [:color, :description, :github_object_id, :name, :node_id]

  def import(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        intent,
        observation,
        candidate,
        domain_multi_fun
      )
      when is_map(intent) and is_map(observation) and is_map(candidate) and
             is_function(domain_multi_fun, 1) do
    with :ok <- valid_utc(now),
         :ok <- valid_candidate(candidate) do
      Repo.transaction(fn ->
        with {:ok, before} <- PullMergeConfirmation.context(operation, now),
             {:ok, local_before} <- local_projection(before),
             :ok <- authorize(operation, now, intent, observation),
             :ok <- safe_phase(before, observation),
             :ok <- first_missing_label(before, observation, candidate),
             :ok <- identity_available(before, candidate, nil),
             admission <- admission(before.repository_id),
             {:ok, %{resource: projection}} <-
               Repo.transaction(domain_multi_fun.(Multi.new())),
             :ok <- verify_projection(projection, candidate, admission),
             {:ok, fresh} <- PullMergeConfirmation.context(operation, now),
             {:ok, local_after} <- local_projection(fresh),
             true <- local_after == local_before,
             :ok <- unchanged_context(before, fresh),
             :ok <- authorize(operation, now, intent, observation),
             :ok <- safe_phase(fresh, observation),
             :ok <- first_missing_label(fresh, observation, candidate),
             :ok <- identity_available(fresh, candidate, nil),
             {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(projection.fields),
             {:ok, mapping} <- insert_mapping(fresh, candidate, projection, fingerprint),
             :ok <- identity_available(fresh, candidate, mapping.id),
             {:ok, yielded} <- yield_merge(fresh.operation, now) do
          %{operation: yielded, resource_state: mapping, resource: projection}
        else
          {:error, _step, reason, _changes} -> Repo.rollback(reason)
          {:error, reason} -> Repo.rollback(reason)
          false -> Repo.rollback(:stale_relationship_proof)
          _ -> Repo.rollback(:invalid_projection)
        end
      end)
    end
  end

  def import(_, _, _, _, _, _), do: {:error, :invalid_argument}

  defp authorize(operation, now, intent, observation) do
    PullMergeConfirmation.authorize_effect_observation(operation, now, intent, observation)
  end

  defp local_projection(context) do
    with {:ok, projection} <-
           apply(ForgePulls, :sync_projection, [
             context.repository_id,
             :pull,
             context.expected.pull_id
           ]),
         true <-
           projection.local_resource_id == context.expected.pull_id and
             projection.issue_id == context.expected.issue_id and
             projection.local_version >= context.expected.local_version do
      {:ok, projection}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp safe_phase(
         %{operation: %{external_effect_marker: %{"phase" => "remote_cas_pending"}}} = context,
         _observation
       ) do
    if is_nil(context.metadata_intent),
      do: :ok,
      else: {:error, :stale_relationship_proof}
  end

  defp safe_phase(
         %{
           operation: %{external_effect_marker: %{"phase" => "metadata_issue_pending"} = marker},
           metadata_intent: metadata_intent
         },
         observation
       )
       when not is_nil(metadata_intent) do
    payload = metadata_intent.payload
    remote = observation.issue.confirmed_snapshot

    with {:ok, pull_time, 0} <- DateTime.from_iso8601(marker["expected_remote_updated_at"]),
         {:ok, issue_time, 0} <-
           DateTime.from_iso8601(marker["expected_remote_issue_updated_at"]) do
      exact_time =
        DateTime.compare(observation.pull.remote_updated_at, pull_time) == :eq and
          DateTime.compare(observation.issue.remote_updated_at, issue_time) == :eq

      nonregressed_time =
        DateTime.compare(observation.pull.remote_updated_at, pull_time) != :lt and
          DateTime.compare(observation.issue.remote_updated_at, issue_time) != :lt

      cond do
        remote == payload["expected_remote_issue"] and exact_time -> :ok
        remote == payload["target_issue"] and nonregressed_time -> :ok
        true -> {:error, :ambiguous_external_effect}
      end
    else
      _ -> {:error, :stale_relationship_proof}
    end
  end

  defp safe_phase(_, _), do: {:error, :stale_relationship_proof}

  defp first_missing_label(context, observation, candidate) do
    ids = observation.issue.confirmed_snapshot["label_github_ids"]

    valid_ids =
      is_list(ids) and length(ids) <= 512 and ids == Enum.sort(ids) and
        length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &positive_id?/1)

    if valid_ids do
      mapped_ids =
        Repo.all(
          from mapping in MirrorResourceState,
            where:
              mapping.repository_mirror_id == ^context.repository_mirror_id and
                mapping.resource_kind == :label and mapping.state == :confirmed and
                mapping.github_object_id in ^ids,
            order_by: mapping.github_object_id,
            select: mapping.github_object_id,
            lock: "FOR UPDATE"
        )

      if Enum.find(ids, &(&1 not in mapped_ids)) == candidate.github_object_id,
        do: :ok,
        else: {:error, :stale_relationship_proof}
    else
      {:error, :invalid_relationships}
    end
  end

  defp identity_available(context, candidate, own_id) do
    own_id = own_id || 0

    remote_collision =
      Repo.exists?(
        from mapping in MirrorResourceState,
          where:
            mapping.repository_mirror_id == ^context.repository_mirror_id and
              mapping.resource_kind == :label and
              mapping.github_object_id == ^candidate.github_object_id and mapping.id != ^own_id
      )

    node_collision =
      Repo.exists?(
        from mapping in MirrorResourceState,
          join: binding in RepositoryMirror,
          on: binding.id == mapping.repository_mirror_id,
          where:
            binding.organization_mirror_id == ^context.organization_mirror_id and
              mapping.resource_kind == :label and mapping.github_node_id == ^candidate.node_id and
              mapping.id != ^own_id
      )

    if remote_collision or node_collision,
      do: {:error, :identity_conflict},
      else: :ok
  end

  defp admission(repository_id) do
    %{
      repository_id: repository_id,
      label: maximum_id("repository_labels", repository_id),
      issue: maximum_id("issues", repository_id),
      pull: maximum_id("pull_requests", repository_id)
    }
  end

  defp maximum_id(table, repository_id) do
    Repo.one(
      from row in table,
        where: row.repository_id == ^repository_id,
        select: max(row.id)
    ) || 0
  end

  defp verify_projection(projection, candidate, before) when is_map(projection) do
    id = projection[:local_resource_id]
    expected_fields = fields(candidate)

    with true <- positive_id?(id),
         %{
           id: ^id,
           repository_id: repository_id,
           sync_version: version,
           name: name,
           color: color,
           description: description
         } <-
           Repo.one(
             from label in "repository_labels",
               where: label.id == ^id and label.repository_id == ^before.repository_id,
               select: %{
                 id: label.id,
                 repository_id: label.repository_id,
                 sync_version: label.sync_version,
                 name: label.name,
                 color: label.color,
                 description: label.description
               },
               lock: "FOR UPDATE"
           ),
         true <-
           projection == %{
             repository_id: repository_id,
             resource_kind: :label,
             local_resource_type: "ForgeIssues.Label",
             local_resource_id: id,
             local_version: version,
             fields: %{"name" => name, "color" => color, "description" => description}
           },
         true <- projection.fields == expected_fields,
         new_labels <-
           Repo.all(
             from label in "repository_labels",
               where: label.repository_id == ^repository_id and label.id > ^before.label,
               order_by: label.id,
               limit: 2,
               select: label.id
           ),
         true <- new_labels == if(id > before.label, do: [id], else: []),
         false <-
           Repo.exists?(
             from issue in "issues",
               where: issue.repository_id == ^repository_id and issue.id > ^before.issue
           ),
         false <-
           Repo.exists?(
             from pull in "pull_requests",
               where: pull.repository_id == ^repository_id and pull.id > ^before.pull
           ) do
      :ok
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp verify_projection(_, _, _), do: {:error, :invalid_projection}

  defp insert_mapping(context, candidate, projection, fingerprint) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: context.repository_mirror_id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: projection.local_resource_id,
      github_object_id: candidate.github_object_id,
      github_node_id: candidate.node_id,
      confirmed_local_version: projection.local_version,
      confirmed_snapshot: projection.fields,
      confirmed_fingerprint: fingerprint,
      state: :confirmed,
      lock_version: 1
    })
    |> Repo.insert()
    |> case do
      {:ok, mapping} -> {:ok, mapping}
      {:error, _changeset} -> {:error, :identity_conflict}
    end
  end

  defp unchanged_context(before, fresh) do
    fields = [
      :organization_mirror_id,
      :repository_id,
      :repository_mirror_id,
      :github_installation_id,
      :intent,
      :metadata_intent,
      :provider_pull_identity,
      :expected,
      :pull,
      :issue,
      :base_ref,
      :operation
    ]

    if Map.take(before, fields) == Map.take(fresh, fields),
      do: :ok,
      else: {:error, :stale_relationship_proof}
  end

  defp yield_merge(operation, now) do
    query =
      from current in MirrorOperation,
        where:
          current.id == ^operation.id and current.kind == "merge.pull" and
            current.state == :effect_pending and current.lease_owner == ^operation.lease_owner and
            current.lease_expires_at == ^operation.lease_expires_at and
            current.lock_version == ^operation.lock_version and
            current.cursor == ^operation.cursor and
            current.external_effect_marker == ^operation.external_effect_marker and
            current.lease_expires_at > ^now and
            current.lease_expires_at > fragment("timezone('UTC', clock_timestamp())")

    case Repo.update_all(query,
           set: [next_attempt_at: now, lease_owner: nil, lease_expires_at: nil, updated_at: now],
           inc: [lock_version: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
      _ -> {:error, :lost_lease}
    end
  end

  defp valid_candidate(candidate) do
    valid =
      Enum.sort(Map.keys(candidate)) == @candidate_keys and
        positive_id?(candidate[:github_object_id]) and nonempty_text?(candidate[:node_id], 255) and
        nonempty_text?(candidate[:name], 255) and valid_color?(candidate[:color]) and
        (is_nil(candidate[:description]) or text?(candidate[:description], 100))

    if valid, do: :ok, else: {:error, :invalid_label_observation}
  end

  defp fields(candidate),
    do: %{
      "name" => candidate.name,
      "color" => String.downcase(candidate.color),
      "description" => candidate.description
    }

  defp valid_color?(color),
    do: is_binary(color) and byte_size(color) == 6 and Regex.match?(~r/^[0-9a-fA-F]{6}$/, color)

  defp positive_id?(id), do: is_integer(id) and id in 1..@max_id

  defp nonempty_text?(value, maximum),
    do: text?(value, maximum) and String.trim(value) != ""

  defp text?(value, maximum) when is_binary(value),
    do:
      byte_size(value) <= maximum * 4 and String.valid?(value) and
        length(String.codepoints(value)) <= maximum and :binary.match(value, <<0>>) == :nomatch

  defp text?(_, _), do: false

  defp valid_utc(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok
  defp valid_utc(_), do: {:error, :invalid_argument}
end
