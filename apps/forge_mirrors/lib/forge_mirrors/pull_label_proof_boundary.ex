defmodule ForgeMirrors.PullLabelProofBoundary do
  @moduledoc "One leased label inventory page, preserving its immutable intent and all resource baselines."
  import Ecto.Query

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    PullOutboundCreation,
    RepositoryMirror
  }

  alias Fornacast.Repo

  @key "pull_creation_label_nodes"
  @mapped_key "pull_metadata_label_nodes"
  @max_page 2_147_483_647

  def context(%MirrorOperation{} = operation, lock_fun) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope, intent, current} <- recover(operation, lock_fun),
           {:ok, mappings} <- mappings(scope, intent),
           {:ok, checkpoint} <- checkpoint(persisted, intent),
           {:ok, _, _} <- recheck(operation, lock_fun) do
        scope
        |> Map.merge(current)
        |> Map.merge(result(mappings, checkpoint))
        |> Map.merge(%{
          intent: intent,
          marker: persisted.external_effect_marker,
          targets: targets(mappings),
          checkpoint: checkpoint
        })
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_argument}

  def seed(
        %MirrorOperation{} = operation,
        %DateTime{} = now,
        %{marker: marker, targets: expected_targets, checkpoint: expected_checkpoint} = expected,
        page,
        lock_fun,
        yield_fun
      )
      when map_size(expected) == 3 do
    if now.utc_offset == 0 and now.std_offset == 0 do
      Repo.transaction(fn ->
        with {:ok, persisted, scope, intent, _} <- recover(operation, lock_fun),
             :ok <-
               require_equal(marker, persisted.external_effect_marker, :invalid_creation_intent),
             {:ok, mappings} <- mappings(scope, intent),
             {:ok, checkpoint} <- checkpoint(persisted, intent),
             :ok <- require_equal(expected_targets, targets(mappings), :stale_label_proof),
             :ok <- require_equal(expected_checkpoint, checkpoint, :stale_label_proof),
             :ok <- incomplete(checkpoint),
             {:ok, labels, next} <-
               validate_page(page, checkpoint, expected_repository(scope, intent)),
             {:ok, updated} <- seed_mappings(mappings, labels, scope),
             checkpoint = %{
               checkpoint
               | "page" => next || checkpoint["page"],
                 "complete" => is_nil(next)
             },
             {:ok, persisted, _} <- recheck(operation, lock_fun),
             {:ok, saved} <-
               yield_fun.(
                 persisted,
                 Map.put(persisted.checkpoint, checkpoint_key(intent), checkpoint),
                 now,
                 now
               ) do
          result(updated, checkpoint) |> Map.put(:operation, saved)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :invalid_argument}
    end
  end

  def seed(_, _, _, _, _, _), do: {:error, :invalid_argument}

  defp recover(operation, :mapped) do
    with {:ok, evidence} <- ForgeMirrors.mapped_pull_effect_context(operation) do
      scope =
        Map.put(evidence.sync, :organization_mirror_id, evidence.operation.organization_mirror_id)

      {:ok, evidence.operation, scope, evidence.intent, %{}}
    end
  end

  defp recover(operation, lock_fun) do
    with {:ok, persisted, scope} <- lock_fun.(operation),
         :ok <- require_equal(persisted.state, :effect_pending, :invalid_transition),
         {:ok, intent} <-
           PullOutboundCreation.lock_recovery(persisted, scope, persisted.external_effect_marker),
         {:ok, current} <- PullOutboundCreation.active_recovery(persisted, scope, intent) do
      {:ok, persisted, Map.put(scope, :organization_mirror_id, persisted.organization_mirror_id),
       intent, current}
    end
  end

  defp recheck(operation, :mapped) do
    with {:ok, evidence} <- ForgeMirrors.mapped_pull_effect_context(operation),
         do: {:ok, evidence.operation, evidence.sync}
  end

  defp recheck(operation, lock_fun), do: lock_fun.(operation)

  defp desired_snapshot(%ForgeMirrors.PullMetadataIntent{payload: payload}),
    do: payload["target_issue"]

  defp desired_snapshot(intent), do: intent.payload["issue_snapshot"]

  defp checkpoint_key(%ForgeMirrors.PullMetadataIntent{}), do: @mapped_key
  defp checkpoint_key(_), do: @key

  defp expected_repository(scope, %ForgeMirrors.PullMetadataIntent{}),
    do: scope.provider_identity["base_repository"]

  defp expected_repository(_scope, intent),
    do: intent.payload["provider_repositories"]["base_repository"]

  defp mappings(scope, intent) do
    ids = desired_snapshot(intent)["label_github_ids"]

    if is_list(ids) and length(ids) <= 512 and Enum.all?(ids, &positive?/1) and
         length(ids) == length(Enum.uniq(ids)) do
      rows =
        Repo.all(
          from m in MirrorResourceState,
            join: l in "repository_labels",
            on: l.id == m.local_resource_id,
            where:
              m.repository_mirror_id == ^scope.repository_mirror_id and
                m.resource_kind == :label and m.local_resource_type == "ForgeIssues.Label" and
                m.state == :confirmed and l.repository_id == ^scope.repository_id and
                m.github_object_id in ^ids,
            order_by: [asc: m.github_object_id],
            lock: "FOR UPDATE",
            select: m
        )

      cond do
        length(rows) != length(ids) or
            not Enum.all?(rows, &(is_nil(&1.github_node_id) or node?(&1.github_node_id, 255))) ->
          {:error, :label_mapping_unavailable}

        known_collisions?(rows, scope) ->
          {:error, :identity_conflict}

        true ->
          {:ok, rows}
      end
    else
      {:error, :invalid_creation_intent}
    end
  end

  defp targets(mappings),
    do:
      Enum.map(mappings, fn m ->
        %{
          mapping_id: m.id,
          lock_version: m.lock_version,
          github_object_id: m.github_object_id,
          expected_node_id: m.github_node_id
        }
      end)

  defp known_collisions?(rows, scope) do
    known = Enum.reject(rows, &is_nil(&1.github_node_id))
    nodes = Enum.map(known, & &1.github_node_id)
    ids = Enum.map(known, & &1.id)

    length(nodes) != length(Enum.uniq(nodes)) or
      (nodes != [] and
         Repo.exists?(
           from m in MirrorResourceState,
             join: r in RepositoryMirror,
             on: r.id == m.repository_mirror_id,
             where:
               r.organization_mirror_id == ^scope.organization_mirror_id and
                 m.resource_kind == :label and m.github_node_id in ^nodes and m.id not in ^ids
         ))
  end

  defp checkpoint(operation, intent) do
    initial = %{
      "intent_id" => intent.id,
      "intent_fingerprint" => intent.payload_fingerprint,
      "page" => 1,
      "complete" => false
    }

    value = Map.get(operation.checkpoint, checkpoint_key(intent), initial)

    # A replacement metadata effect is a new inventory attempt. Never carry an
    # earlier intent's cursor into it; seeded immutable mapping nodes survive.
    value =
      if match?(%ForgeMirrors.PullMetadataIntent{}, intent) and is_map(value) and
           is_integer(value["intent_id"]) and value["intent_id"] != intent.id,
         do: initial,
         else: value

    if is_map(value) and map_size(value) == 4 and value["intent_id"] == intent.id and
         value["intent_fingerprint"] == intent.payload_fingerprint and
         is_integer(value["page"]) and value["page"] in 1..@max_page and
         is_boolean(value["complete"]),
       do: {:ok, value},
       else: {:error, :invalid_label_checkpoint}
  end

  defp incomplete(%{"complete" => false}), do: :ok
  defp incomplete(_), do: {:error, :label_inventory_complete}

  defp validate_page(
         %{labels: labels, next_cursor: next, repository: repository} = page,
         checkpoint,
         expected_repo
       )
       when map_size(page) == 3 and is_list(labels) and length(labels) <= 100 do
    with :ok <-
           require_equal(
             repository,
             %{github_object_id: expected_repo["id"], github_node_id: expected_repo["node_id"]},
             :identity_conflict
           ),
         true <-
           is_nil(next) or
             (is_integer(next) and next == checkpoint["page"] + 1 and next <= @max_page),
         true <- Enum.all?(labels, &label?/1),
         true <- length(labels) == length(Enum.uniq_by(labels, & &1["id"])),
         true <- length(labels) == length(Enum.uniq_by(labels, & &1["node_id"])) do
      {:ok, Map.new(labels, &{&1["id"], &1["node_id"]}), next}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_label_page}
    end
  end

  defp validate_page(_, _, _), do: {:error, :invalid_label_page}
  defp label?(%{"id" => id, "node_id" => node}), do: positive?(id) and node?(node, 512)
  defp label?(_), do: false

  defp seed_mappings(mappings, labels, scope) do
    Enum.reduce_while(mappings, {:ok, []}, fn mapping, {:ok, result} ->
      case seed_mapping(mapping, Map.get(labels, mapping.github_object_id), scope) do
        {:ok, updated} -> {:cont, {:ok, [updated | result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp seed_mapping(mapping, nil, _scope), do: {:ok, mapping}

  defp seed_mapping(mapping, node, scope) do
    cond do
      not node?(node, 255) ->
        {:error, :invalid_label_page}

      not is_nil(mapping.github_node_id) and mapping.github_node_id != node ->
        {:error, :identity_conflict}

      collision?(mapping, node, scope) ->
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

  # The shared organization lock serializes node seeding with scoped mappings;
  # inventory never creates a new local label or writes a resource baseline.
  defp collision?(mapping, node, scope) do
    Repo.exists?(
      from m in MirrorResourceState,
        join: r in RepositoryMirror,
        on: r.id == m.repository_mirror_id,
        where:
          r.organization_mirror_id == ^scope.organization_mirror_id and
            m.resource_kind == :label and m.github_node_id == ^node and m.id != ^mapping.id
    )
  end

  defp result(mappings, checkpoint) do
    missing =
      mappings |> Enum.filter(&is_nil(&1.github_node_id)) |> Enum.map(& &1.github_object_id)

    status =
      cond do
        missing == [] -> :ready
        checkpoint["complete"] -> :unavailable
        true -> :scanning
      end

    %{status: status, missing_github_ids: missing}
  end

  defp node?(node, limit) when is_binary(node),
    do:
      byte_size(node) in 1..limit and
        String.valid?(node) and String.trim(node) == node and not String.contains?(node, <<0>>)

  defp node?(_, _), do: false
  defp positive?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807
  defp require_equal(value, value, _reason), do: :ok
  defp require_equal(_, _, reason), do: {:error, reason}
end
