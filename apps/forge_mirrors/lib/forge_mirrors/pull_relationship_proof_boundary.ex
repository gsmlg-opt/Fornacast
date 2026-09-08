defmodule ForgeMirrors.PullRelationshipProofBoundary do
  @moduledoc """
  Seeds authenticated node identity for an assignee retained by a pull-creation intent.

  This boundary never grants or consumes the pull POST. It releases the lease
  with the exact creation marker and checkpoint still attached so recovery can
  continue from durable identity progress.
  """

  import Ecto.Query

  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.{MirrorOperation, PullOutboundCreation}
  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  @profile_keys [:avatar_url, :html_url, :id, :login, :name, :node_id]

  def context(%MirrorOperation{} = operation, lock_fun) when is_function(lock_fun, 1) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope, intent, target} <- locked_context(operation, lock_fun),
           {:ok, _, _} <- lock_fun.(operation) do
        %{
          operation: persisted,
          intent: intent,
          marker: persisted.external_effect_marker,
          github_installation_id: scope.github_installation_id,
          target: target
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_argument}

  def seed(
        %MirrorOperation{} = operation,
        %DateTime{} = now,
        expected,
        profile,
        lock_fun,
        yield_fun
      )
      when is_map(expected) and is_map(profile) and is_function(lock_fun, 1) and
             is_function(yield_fun, 2) do
    with :ok <- valid_utc(now),
         :ok <- valid_profile(profile) do
      Repo.transaction(fn ->
        with {:ok, persisted, _scope, _intent, target} <- locked_context(operation, lock_fun),
             :ok <- expected_target(persisted, target, expected),
             :ok <- profile_target(profile, target),
             {:ok, identity} <- observe(profile, now, target),
             {:ok, persisted, _scope} <- lock_fun.(operation),
             true <- persisted.external_effect_marker == expected.marker,
             {:ok, yielded} <- yield_fun.(persisted, now) do
          %{operation: yielded, identity: identity}
        else
          false -> Repo.rollback(:stale_relationship_proof)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def seed(_, _, _, _, _, _), do: {:error, :invalid_argument}

  defp locked_context(operation, lock_fun) do
    with {:ok, persisted, scope} <- lock_fun.(operation),
         true <- persisted.state == :effect_pending,
         {:ok, intent} <-
           PullOutboundCreation.lock_recovery(
             persisted,
             scope,
             persisted.external_effect_marker
           ),
         :ok <- original_installation(persisted, scope, intent),
         {:ok, _active} <- PullOutboundCreation.active_recovery(persisted, scope, intent),
         {:ok, target} <- missing_target(intent) do
      {:ok, persisted, scope, intent, target}
    else
      false -> {:error, :invalid_transition}
      {:error, reason} -> {:error, reason}
    end
  end

  defp original_installation(operation, scope, intent) do
    proof = get_in(intent.payload, ["pull_eligibility_proof"])

    if is_map(proof) and proof["organization_mirror_id"] == operation.organization_mirror_id and
         proof["github_installation_id"] == scope.github_installation_id,
       do: :ok,
       else: {:error, :ineligible_pull}
  end

  defp missing_target(intent) do
    with {:ok, ids} <- desired_ids(intent),
         identities <-
           Repo.all(
             from identity in GitHubIdentity,
               where: identity.kind == :user and identity.github_user_id in ^ids,
               order_by: identity.github_user_id,
               limit: 513,
               lock: "FOR UPDATE"
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
      {:error, reason} -> {:error, reason}
    end
  end

  defp desired_ids(%{
         payload: %{"issue_snapshot" => %{"assignee_github_ids" => ids}}
       })
       when is_list(ids) and length(ids) <= 512 do
    if ids == Enum.sort(ids) and length(ids) == length(Enum.uniq(ids)) and
         Enum.all?(ids, &positive_id?/1),
       do: {:ok, ids},
       else: {:error, :invalid_creation_intent}
  end

  defp desired_ids(_), do: {:error, :invalid_creation_intent}

  defp expected_target(operation, target, expected) do
    if Map.keys(expected) |> Enum.sort() == [:marker, :target] and
         expected.marker == operation.external_effect_marker and expected.target == target and
         not is_nil(target),
       do: :ok,
       else: {:error, :stale_relationship_proof}
  end

  defp profile_target(profile, target) do
    if profile.id == target.github_user_id and nonempty_node?(profile.node_id),
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

  defp valid_profile(profile) do
    if Map.keys(profile) |> Enum.sort() == @profile_keys and positive_id?(profile[:id]) and
         nonempty_node?(profile[:node_id]) and
         ForgeAccounts.GitHubProfileSafety.validate(profile) == :ok,
       do: :ok,
       else: {:error, :invalid_identity_observation}
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
