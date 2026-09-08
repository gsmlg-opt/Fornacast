defmodule ForgeMirrors.PullLabelEffects do
  @moduledoc "Mapped pull label prerequisites retain their own immutable effect evidence."
  import Ecto.Query
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, PullResourceBoundary}
  alias Fornacast.Repo

  @tokens ~w(mapping_id lock_version github_object_id github_node_id github_number local_version fingerprint)a

  def mark(operation, now, expected, marker, callback, lock, publish)
      when is_map(expected) and is_map(marker) and is_function(callback, 1) do
    Repo.transaction(fn ->
      with {:ok, evidence} <- processing(operation, expected, lock),
           false <- mapped?(evidence.sync, expected.local_label_id),
           {:ok, %{resource: projection}} <- Repo.transaction(callback.(Ecto.Multi.new())),
           {:ok, actual} <- label(evidence.sync, expected.local_label_id),
           true <- projection == actual,
           :ok <- label_expected(actual, expected),
           :ok <- marker_label(marker, actual, false),
           enriched =
             Map.merge(marker, %{
               "paired_mapping_proof" => tokens(evidence.sync.pair),
               "pull_precondition" => expected.pull_precondition
             }),
           true <- byte_size(JSON.encode!(enriched)) <= 65_536,
           {:ok, fresh} <- processing(operation, expected, lock),
           {:ok, marked} <- publish.(fresh.operation, now, enriched) do
        %{operation: marked, resource: actual}
      else
        {:error, _, reason, _} -> Repo.rollback(reason)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:stale_baseline)
      end
    end)
  end

  def mark(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  def context(
        %MirrorOperation{state: :effect_pending, external_effect_marker: supplied} = operation,
        lock
      )
      when is_map(supplied) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope} <- lock.(operation),
           %MirrorOperation{state: :effect_pending, external_effect_marker: marker}
           when is_map(marker) <- persisted,
           true <- marker == supplied,
           :ok <- saved_marker(marker),
           {:ok, sync} <- ForgeMirrors.mapped_pull_pair_context(operation),
           true <- marker["paired_mapping_proof"] == tokens(sync.pair),
           proof when is_map(proof) <- marker["pull_precondition"],
           {:ok, current} <-
             apply(ForgePulls, :sync_projection, [
               scope.repository_id,
               :pull,
               sync.local_resource_id
             ]),
           true <-
             is_integer(proof["expected_local_version"]) and
               current.local_version >= proof["expected_local_version"],
           {:ok, hash} <- ForgeMirrors.resource_fingerprint(current.fields),
           observed =
             if(current.local_version > proof["expected_local_version"],
               do:
                 Map.merge(proof, %{
                   "expected_local_version" => current.local_version,
                   "expected_local_fingerprint" => hash
                 }),
               else: proof
             ),
           :ok <- PullResourceBoundary.validate_precondition(scope, mapping(sync), observed),
           {:ok, actual, conflict?} <- recovery_label(sync, marker),
           {:ok, fresh, _} <- lock.(operation),
           true <- fresh.external_effect_marker == marker do
        evidence = %{operation: fresh, sync: sync, marker: marker, resource: actual}
        if conflict?, do: Repo.rollback({:label_metadata_conflict, evidence}), else: evidence
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_label_effect)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_label_effect}

  defp saved_marker(marker) do
    original = %{
      local_resource_id: marker["local_label_id"],
      local_version: marker["expected_local_version"],
      fields: marker["proposed_snapshot"]
    }

    if is_integer(original.local_resource_id) and original.local_resource_id > 0 and
         marker_label(marker, original, false) == :ok,
       do: :ok,
       else: {:error, :invalid_label_effect}
  end

  defp recovery_label(sync, marker) do
    # Expected deletion must not call a nested domain transaction that rolls
    # back the caller before the final lease check and conflict evidence.
    id =
      Repo.one(
        from l in "repository_labels",
          where: l.repository_id == ^sync.repository_id and l.id == ^marker["local_label_id"],
          select: l.id,
          lock: "FOR UPDATE"
      )

    if is_nil(id) do
      {:ok, nil, true}
    else
      case label(sync, id) do
        {:ok, actual} -> {:ok, actual, marker_label(marker, actual, true) != :ok}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def lock_confirmation(operation, expected, confirmation, lock) do
    with {:ok, evidence} <- confirmation_context(operation, expected, lock),
         true <- evidence.operation.external_effect_marker == expected[:effect_marker],
         :ok <- confirmation_label(evidence, expected, confirmation) do
      {:ok, evidence.operation, evidence.sync}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_label_effect}
    end
  end

  def normalize(operation, expected, projection, lock) do
    with {:ok, evidence} <- confirmation_context(operation, expected, lock),
         true <- projection == evidence.resource do
      case evidence.operation.external_effect_marker do
        nil ->
          {:ok, projection}

        marker ->
          {:ok,
           %{
             projection
             | local_version: marker["expected_local_version"],
               fields: marker["proposed_snapshot"]
           }}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_projection}
    end
  end

  defp confirmation_context(%{state: :effect_pending} = operation, expected, lock) do
    with {:ok, evidence} <- context(operation, lock),
         true <- evidence.marker == expected[:effect_marker] do
      {:ok, evidence}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_label_effect}
    end
  end

  defp confirmation_context(operation, expected, lock), do: processing(operation, expected, lock)

  defp processing(operation, expected, lock) do
    with {:ok, %MirrorOperation{state: :processing, external_effect_marker: nil} = persisted,
          scope} <- lock.(operation),
         {:ok, sync} <- ForgeMirrors.mapped_pull_pair_context(operation),
         true <- sync.pair == expected[:pair],
         proof when is_map(proof) <- expected[:pull_precondition],
         :ok <- PullResourceBoundary.validate_precondition(scope, mapping(sync), proof),
         :ok <- membership(sync.issue_id, expected[:local_label_id]),
         {:ok, actual} <- label(sync, expected.local_label_id),
         :ok <- label_expected(actual, expected) do
      {:ok, %{operation: persisted, sync: sync, resource: actual}}
    else
      false -> {:error, :stale_paired_mapping}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_transition}
    end
  end

  defp membership(issue_id, label_id) do
    exists =
      Repo.one(
        from l in "issue_labels",
          where: l.issue_id == ^issue_id and l.label_id == ^label_id,
          select: l.label_id,
          lock: "FOR UPDATE"
      )

    if exists, do: :ok, else: {:error, :label_not_assigned}
  end

  defp label(sync, id), do: apply(ForgeIssues, :label_sync_projection, [sync.repository_id, id])
  defp mapping(sync), do: Repo.get!(MirrorResourceState, sync.pair.pull.mapping_id)

  defp mapped?(sync, id),
    do:
      Repo.exists?(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^sync.repository_mirror_id and m.resource_kind == :label and
              m.local_resource_id == ^id
      )

  defp label_expected(actual, expected) do
    with {:ok, hash} <- ForgeMirrors.resource_fingerprint(actual.fields),
         true <-
           actual.local_resource_id == expected[:local_label_id] and
             actual.local_version == expected[:expected_local_version] and
             hash == expected[:expected_local_fingerprint] do
      :ok
    else
      _ -> {:error, :label_metadata_conflict}
    end
  end

  defp marker_label(marker, actual, minimum) do
    fields = marker["proposed_snapshot"]
    version = marker["expected_local_version"]

    with true <-
           marker["v"] == 1 and marker["action"] == "create_remote_label" and
             marker["resource_kind"] == "label" and marker["expected_remote_absent"] == true,
         true <-
           marker["local_label_id"] == actual.local_resource_id and is_integer(version) and
             version > 0,
         true <- is_map(fields) and Enum.sort(Map.keys(fields)) == ~w(color description name),
         {:ok, hash} <- ForgeMirrors.resource_fingerprint(fields),
         true <-
           hash == marker["expected_local_fingerprint"] and hash == marker["proposed_fingerprint"] and
             marker["label_name"] == fields["name"],
         true <-
           (actual.local_version == version and actual.fields == fields) or
             (minimum and actual.local_version > version) do
      :ok
    else
      _ -> {:error, :label_metadata_conflict}
    end
  end

  defp confirmation_label(
         %{operation: %{external_effect_marker: nil}, resource: actual},
         expected,
         confirmation
       ) do
    with :ok <- label_expected(actual, expected),
         true <- actual.fields == confirmation[:confirmed_snapshot] do
      :ok
    else
      _ -> {:error, :label_metadata_conflict}
    end
  end

  defp confirmation_label(%{marker: marker}, expected, confirmation) do
    if expected[:local_label_id] == marker["local_label_id"] and
         expected[:expected_local_version] == marker["expected_local_version"] and
         expected[:expected_local_fingerprint] == marker["expected_local_fingerprint"] and
         confirmation[:confirmed_snapshot] == marker["proposed_snapshot"],
       do: :ok,
       else: {:error, :label_metadata_conflict}
  end

  defp tokens(pair),
    do:
      Map.new(pair, fn {key, value} ->
        {Atom.to_string(key), value |> Map.take(@tokens) |> JSON.encode!() |> JSON.decode!()}
      end)
end
