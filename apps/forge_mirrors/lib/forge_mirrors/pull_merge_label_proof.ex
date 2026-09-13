defmodule ForgeMirrors.PullMergeLabelProof do
  @moduledoc """
  Seeds immutable label node identities for one leased merge metadata effect.

  Each call consumes at most one provider inventory page. It never changes a
  confirmed resource baseline and always yields the merge lease after a page.
  """

  import Ecto.Query

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    PullMergeMetadataEffects,
    RepositoryMirror
  }

  alias Fornacast.Repo

  @checkpoint_key "pull_merge_metadata_label_nodes"
  @max_page 2_147_483_647

  def context(%MirrorOperation{kind: "merge.pull"} = operation, %DateTime{} = now) do
    if utc?(now) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- PullMergeMetadataEffects.recovery_context(operation, now),
             {:ok, mappings} <- mappings(evidence),
             {:ok, checkpoint} <- checkpoint(evidence.operation, evidence.metadata_intent),
             {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
             :ok <- same_recovery(evidence, fresh) do
          build_context(fresh, mappings, checkpoint)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :invalid_argument}
    end
  end

  def context(_, _), do: {:error, :invalid_argument}

  def seed(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        expected,
        page,
        yield_fun
      )
      when is_map(expected) and is_function(yield_fun, 4) do
    if utc?(now) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- PullMergeMetadataEffects.recovery_context(operation, now),
             {:ok, mappings} <- mappings(evidence),
             {:ok, checkpoint} <- checkpoint(evidence.operation, evidence.metadata_intent),
             :ok <- exact_expected(expected, evidence, mappings, checkpoint),
             :ok <- incomplete(checkpoint),
             {:ok, labels, next} <-
               validate_page(page, checkpoint, base_repository(evidence)),
             {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
             {:ok, fresh_mappings} <- mappings(fresh),
             {:ok, fresh_checkpoint} <- checkpoint(fresh.operation, fresh.metadata_intent),
             :ok <- exact_expected(expected, fresh, fresh_mappings, fresh_checkpoint),
             {:ok, updated} <- seed_mappings(fresh_mappings, labels, fresh),
             next_checkpoint = advance(fresh_checkpoint, next),
             full_checkpoint =
               Map.put(fresh.operation.checkpoint, @checkpoint_key, next_checkpoint),
             {:ok, %MirrorOperation{}} <-
               yield_fun.(fresh.operation, full_checkpoint, now, now),
             %MirrorOperation{} = persisted <-
               Repo.one(
                 from o in MirrorOperation,
                   where: o.id == ^fresh.operation.id,
                   lock: "FOR UPDATE"
               ),
             :ok <- valid_yield(persisted, fresh, full_checkpoint, now),
             :ok <- preserved_intents(fresh) do
          updated
          |> result(next_checkpoint)
          |> Map.put(:operation, persisted)
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_transition)
        end
      end)
    else
      {:error, :invalid_argument}
    end
  end

  def seed(_, _, _, _, _), do: {:error, :invalid_argument}

  defp build_context(evidence, mappings, checkpoint) do
    evidence
    |> Map.merge(result(mappings, checkpoint))
    |> Map.merge(%{
      intent: evidence.metadata_intent,
      marker: evidence.operation.external_effect_marker,
      targets: targets(mappings),
      checkpoint: checkpoint,
      base_repository: base_repository(evidence)
    })
  end

  defp mappings(evidence) do
    ids = evidence.metadata_intent.payload["target_issue"]["label_github_ids"]

    if valid_ids?(ids) do
      rows =
        Repo.all(
          from m in MirrorResourceState,
            join: l in "repository_labels",
            on: l.id == m.local_resource_id,
            where:
              m.repository_mirror_id == ^evidence.repository_mirror_id and
                m.resource_kind == :label and
                m.local_resource_type == "ForgeIssues.Label" and
                m.state == :confirmed and l.repository_id == ^evidence.repository_id and
                m.github_object_id in ^ids,
            order_by: [asc: m.github_object_id],
            lock: "FOR UPDATE",
            select: m
        )

      cond do
        Enum.map(rows, & &1.github_object_id) != Enum.sort(ids) ->
          {:error, :label_mapping_unavailable}

        not Enum.all?(rows, &(is_nil(&1.github_node_id) or valid_node?(&1.github_node_id, 255))) ->
          {:error, :label_mapping_unavailable}

        known_collision?(rows, evidence.organization_mirror_id) ->
          {:error, :identity_conflict}

        true ->
          {:ok, rows}
      end
    else
      {:error, :invalid_metadata_intent}
    end
  end

  defp known_collision?(mappings, organization_mirror_id) do
    known = Enum.reject(mappings, &is_nil(&1.github_node_id))
    nodes = Enum.map(known, & &1.github_node_id)
    mapping_ids = Enum.map(known, & &1.id)

    length(nodes) != length(Enum.uniq(nodes)) or
      (nodes != [] and
         Repo.exists?(
           from m in MirrorResourceState,
             join: r in RepositoryMirror,
             on: r.id == m.repository_mirror_id,
             where:
               r.organization_mirror_id == ^organization_mirror_id and
                 m.resource_kind == :label and m.github_node_id in ^nodes and
                 m.id not in ^mapping_ids
         ))
  end

  defp checkpoint(operation, intent) do
    initial = %{
      "intent_id" => intent.id,
      "intent_fingerprint" => intent.payload_fingerprint,
      "page" => 1,
      "complete" => false
    }

    value = Map.get(operation.checkpoint, @checkpoint_key, initial)

    value =
      if is_map(value) and is_integer(value["intent_id"]) and value["intent_id"] != intent.id,
        do: initial,
        else: value

    if is_map(value) and map_size(value) == 4 and value["intent_id"] == intent.id and
         value["intent_fingerprint"] == intent.payload_fingerprint and
         is_integer(value["page"]) and value["page"] in 1..@max_page and
         is_boolean(value["complete"]),
       do: {:ok, value},
       else: {:error, :invalid_label_checkpoint}
  end

  defp exact_expected(expected, evidence, mappings, checkpoint) do
    actual = %{
      marker: evidence.operation.external_effect_marker,
      targets: targets(mappings),
      checkpoint: checkpoint
    }

    if map_size(expected) == 3 and
         Enum.sort(Map.keys(expected)) == [:checkpoint, :marker, :targets] and
         expected == actual,
       do: :ok,
       else: {:error, :stale_label_proof}
  end

  defp incomplete(%{"complete" => false}), do: :ok
  defp incomplete(_), do: {:error, :label_inventory_complete}

  defp validate_page(
         %{labels: labels, next_cursor: next, repository: repository} = page,
         checkpoint,
         base_repository
       )
       when map_size(page) == 3 and is_list(labels) and length(labels) <= 100 do
    with :ok <-
           require_equal(
             repository,
             %{
               github_object_id: base_repository["id"],
               github_node_id: base_repository["node_id"]
             },
             :identity_conflict
           ),
         true <-
           is_nil(next) or
             (is_integer(next) and next == checkpoint["page"] + 1 and next <= @max_page),
         true <- Enum.all?(labels, &valid_label?/1),
         true <- length(labels) == length(Enum.uniq_by(labels, & &1["id"])),
         true <- length(labels) == length(Enum.uniq_by(labels, & &1["node_id"])) do
      {:ok, Map.new(labels, &{&1["id"], &1["node_id"]}), next}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_label_page}
    end
  end

  defp validate_page(_, _, _), do: {:error, :invalid_label_page}

  defp seed_mappings(mappings, labels, evidence) do
    Enum.reduce_while(mappings, {:ok, []}, fn mapping, {:ok, seeded} ->
      case seed_mapping(mapping, Map.get(labels, mapping.github_object_id), evidence) do
        {:ok, updated} -> {:cont, {:ok, [updated | seeded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, seeded} -> {:ok, Enum.reverse(seeded)}
      {:error, _} = error -> error
    end
  end

  defp seed_mapping(mapping, nil, _evidence), do: {:ok, mapping}

  defp seed_mapping(mapping, node, evidence) do
    cond do
      not valid_node?(node, 255) ->
        {:error, :invalid_label_page}

      not is_nil(mapping.github_node_id) and mapping.github_node_id != node ->
        {:error, :identity_conflict}

      collision?(mapping, node, evidence.organization_mirror_id) ->
        {:error, :identity_conflict}

      mapping.github_node_id == node ->
        {:ok, mapping}

      true ->
        mapping
        |> Ecto.Changeset.change(github_node_id: node)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
    end
  end

  defp collision?(mapping, node, organization_mirror_id) do
    Repo.exists?(
      from m in MirrorResourceState,
        join: r in RepositoryMirror,
        on: r.id == m.repository_mirror_id,
        where:
          r.organization_mirror_id == ^organization_mirror_id and
            m.resource_kind == :label and m.github_node_id == ^node and m.id != ^mapping.id
    )
  end

  defp result(mappings, checkpoint) do
    missing =
      mappings
      |> Enum.filter(&is_nil(&1.github_node_id))
      |> Enum.map(& &1.github_object_id)

    status =
      cond do
        missing == [] -> :ready
        checkpoint["complete"] -> :unavailable
        true -> :scanning
      end

    %{status: status, missing_github_ids: missing}
  end

  defp targets(mappings) do
    Enum.map(mappings, fn mapping ->
      %{
        mapping_id: mapping.id,
        lock_version: mapping.lock_version,
        github_object_id: mapping.github_object_id,
        expected_node_id: mapping.github_node_id
      }
    end)
  end

  defp base_repository(evidence), do: evidence.expected.provider_identity["base_repository"]

  defp same_recovery(first, second) do
    if first.operation.external_effect_marker == second.operation.external_effect_marker and
         first.metadata_intent.id == second.metadata_intent.id and
         first.metadata_intent.payload_fingerprint == second.metadata_intent.payload_fingerprint,
       do: :ok,
       else: {:error, :stale_label_proof}
  end

  defp advance(checkpoint, next) do
    %{checkpoint | "page" => next || checkpoint["page"], "complete" => is_nil(next)}
  end

  defp valid_yield(%MirrorOperation{} = yielded, evidence, checkpoint, now) do
    expected = evidence.operation

    valid =
      yielded.id == expected.id and yielded.kind == "merge.pull" and
        yielded.organization_mirror_id == expected.organization_mirror_id and
        yielded.repository_mirror_id == expected.repository_mirror_id and
        yielded.cursor == expected.cursor and yielded.state == :effect_pending and
        yielded.external_effect_marker == expected.external_effect_marker and
        yielded.effect_marked_at == expected.effect_marked_at and
        yielded.checkpoint == checkpoint and is_nil(yielded.lease_owner) and
        is_nil(yielded.lease_expires_at) and
        yielded.next_attempt_at == DateTime.truncate(now, :second) and
        yielded.lock_version == expected.lock_version + 1

    if valid, do: :ok, else: {:error, :invalid_transition}
  end

  defp preserved_intents(evidence) do
    coordinator_module = Module.concat(["ForgePulls", "MergeOperation"])

    coordinator =
      coordinator_module
      |> Repo.get(evidence.intent.id)
      |> compact_coordinator(Map.keys(evidence.intent))

    metadata = Repo.get(evidence.metadata_intent.__struct__, evidence.metadata_intent.id)

    if coordinator == evidence.intent and metadata == evidence.metadata_intent,
      do: :ok,
      else: {:error, :invalid_transition}
  end

  defp compact_coordinator(%{__struct__: _} = intent, keys) do
    intent
    |> Map.take(keys)
    |> Map.update(:state, nil, &to_string/1)
    |> Map.update(:coordination_mode, nil, &to_string/1)
  end

  defp compact_coordinator(_, _), do: nil

  defp valid_ids?(ids) do
    is_list(ids) and length(ids) <= 512 and Enum.all?(ids, &positive?/1) and
      length(ids) == length(Enum.uniq(ids))
  end

  defp valid_label?(%{"id" => id, "node_id" => node}),
    do: positive?(id) and valid_node?(node, 512)

  defp valid_label?(_), do: false

  defp valid_node?(node, limit) when is_binary(node) do
    byte_size(node) in 1..limit and String.valid?(node) and String.trim(node) == node and
      not String.contains?(node, <<0>>)
  end

  defp valid_node?(_, _), do: false
  defp positive?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807
  defp utc?(now), do: now.utc_offset == 0 and now.std_offset == 0
  defp require_equal(value, value, _reason), do: :ok
  defp require_equal(_, _, reason), do: {:error, reason}
end
