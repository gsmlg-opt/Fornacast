defmodule ForgeMirrors.PullMergeAssigneeProof do
  @moduledoc """
  Seeds authenticated node identity for assignees retained by a merge metadata intent.

  The immutable metadata intent remains authoritative. Seeding one missing
  identity releases the merge lease without consuming or changing its remote
  metadata effect marker.
  """

  import Ecto.Query

  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.{MirrorOperation, PullMergeMetadataEffects, PullMetadataIntent}
  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  @profile_keys [:avatar_url, :html_url, :id, :login, :name, :node_id]

  def context(%MirrorOperation{} = operation, %DateTime{} = now) do
    with :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- PullMergeMetadataEffects.recovery_context(operation, now),
             {:ok, target} <- missing_target(evidence.metadata_intent),
             {:ok, _fresh} <- PullMergeMetadataEffects.recovery_context(operation, now) do
          %{
            operation: evidence.operation,
            intent: evidence.metadata_intent,
            marker: evidence.marker,
            github_installation_id: evidence.github_installation_id,
            target: target
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def context(_, _), do: {:error, :invalid_argument}

  def seed(
        %MirrorOperation{} = operation,
        %DateTime{} = now,
        expected,
        profile,
        yield_fun
      )
      when is_map(expected) and is_map(profile) and is_function(yield_fun, 2) do
    with :ok <- valid_utc(now),
         :ok <- valid_profile(profile) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- PullMergeMetadataEffects.recovery_context(operation, now),
             {:ok, target} <- missing_target(evidence.metadata_intent),
             :ok <- expected_target(evidence, target, expected),
             :ok <- profile_target(profile, target),
             {:ok, identity} <- observe(profile, now, target),
             {:ok, fresh} <- PullMergeMetadataEffects.recovery_context(operation, now),
             true <- fresh.marker == expected.marker,
             {:ok, %MirrorOperation{}} <- yield_fun.(fresh.operation, now),
             %MirrorOperation{} = persisted <-
               Repo.one(
                 from o in MirrorOperation,
                   where: o.id == ^fresh.operation.id,
                   lock: "FOR UPDATE"
               ),
             :ok <- valid_yield(persisted, fresh, now),
             :ok <- preserved_intents(fresh) do
          %{operation: persisted, identity: identity}
        else
          false -> Repo.rollback(:stale_relationship_proof)
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_transition)
        end
      end)
    end
  end

  def seed(_, _, _, _, _), do: {:error, :invalid_argument}

  defp missing_target(%PullMetadataIntent{
         payload: %{"target_issue" => %{"assignee_github_ids" => ids}}
       })
       when is_list(ids) and length(ids) <= 512 do
    with true <- valid_ids?(ids),
         identities <-
           Repo.all(
             from(identity in GitHubIdentity,
               where: identity.kind == :user and identity.github_user_id in ^ids,
               order_by: identity.github_user_id,
               limit: 513,
               lock: "FOR UPDATE NOWAIT"
             ),
             mode: :savepoint
           ),
         true <- Enum.map(identities, & &1.github_user_id) == ids do
      target =
        identities
        |> Enum.find(&is_nil(&1.github_node_id))
        |> case do
          nil ->
            nil

          identity ->
            %{
              identity_id: identity.id,
              github_user_id: identity.github_user_id,
              expected_node_id: nil
            }
        end

      {:ok, target}
    else
      false -> {:error, :assignee_identity_unavailable}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp missing_target(_), do: {:error, :assignee_identity_unavailable}

  defp expected_target(evidence, target, expected) do
    if Enum.sort(Map.keys(expected)) == [:marker, :target] and
         expected.marker == evidence.marker and expected.target == target and not is_nil(target),
       do: :ok,
       else: {:error, :stale_relationship_proof}
  end

  defp profile_target(profile, target) do
    if profile.id == target.github_user_id and target.expected_node_id == nil,
      do: :ok,
      else: {:error, :invalid_identity_observation}
  end

  defp observe(profile, now, target) do
    case ForgeAccounts.observe_github_identity(profile, now) do
      {:ok,
       %GitHubIdentity{
         id: id,
         kind: :user,
         github_user_id: github_user_id,
         github_node_id: node_id
       } = identity}
      when id == target.identity_id and github_user_id == target.github_user_id and
             node_id == profile.node_id ->
        {:ok, identity}

      {:ok, _identity} ->
        {:error, :identity_conflict}

      {:error, %Ecto.Changeset{}} ->
        {:error, :identity_conflict}

      {:error, _reason} ->
        {:error, :invalid_identity_observation}
    end
  end

  defp valid_yield(%MirrorOperation{} = yielded, evidence, now) do
    expected = evidence.operation

    valid =
      yielded.id == expected.id and yielded.kind == "merge.pull" and
        yielded.organization_mirror_id == expected.organization_mirror_id and
        yielded.repository_mirror_id == expected.repository_mirror_id and
        yielded.cursor == expected.cursor and yielded.state == :effect_pending and
        yielded.external_effect_marker == expected.external_effect_marker and
        yielded.effect_marked_at == expected.effect_marked_at and
        yielded.checkpoint == expected.checkpoint and is_nil(yielded.lease_owner) and
        is_nil(yielded.lease_expires_at) and
        yielded.next_attempt_at == DateTime.truncate(now, :second) and
        yielded.lock_version == expected.lock_version + 1 and
        is_nil(yielded.failure_class) and is_nil(yielded.failure_disposition) and
        is_nil(yielded.failure_detail)

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

  defp valid_profile(profile) do
    if Enum.sort(Map.keys(profile)) == @profile_keys and positive_id?(profile[:id]) and
         nonempty_node?(profile[:node_id]) and
         ForgeAccounts.GitHubProfileSafety.validate(profile) == :ok,
       do: :ok,
       else: {:error, :invalid_identity_observation}
  end

  defp valid_ids?(ids) do
    ids == Enum.sort(ids) and length(ids) == length(Enum.uniq(ids)) and
      Enum.all?(ids, &positive_id?/1)
  end

  defp valid_utc(date) do
    if date.utc_offset == 0 and date.std_offset == 0,
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp positive_id?(id), do: is_integer(id) and id in 1..@max_id

  defp nonempty_node?(node),
    do:
      is_binary(node) and byte_size(node) in 1..512 and String.valid?(node) and
        String.trim(node) == node and :binary.match(node, <<0>>) == :nomatch
end
