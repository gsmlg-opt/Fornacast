defmodule ForgeMirrors.PullMappedAssigneeProof do
  @moduledoc "One authenticated assignee node observation for an immutable mapped pull effect."
  import Ecto.Query
  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.MirrorOperation
  alias Fornacast.Repo

  @profile_keys [:avatar_url, :html_url, :id, :login, :name, :node_id]

  def context(%MirrorOperation{} = operation) do
    Repo.transaction(fn ->
      with {:ok, evidence} <- ForgeMirrors.mapped_pull_effect_context(operation),
           {:ok, target} <- target(evidence.intent),
           {:ok, _} <- ForgeMirrors.mapped_pull_effect_context(operation) do
        %{
          operation: evidence.operation,
          intent: evidence.intent,
          marker: evidence.marker,
          github_installation_id: evidence.sync.github_installation_id,
          target: target
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def context(_), do: {:error, :invalid_argument}

  def seed(%MirrorOperation{} = operation, %DateTime{} = now, expected, profile, yield_fun)
      when is_map(expected) and is_map(profile) and is_function(yield_fun, 2) do
    with true <- now.utc_offset == 0 and now.std_offset == 0,
         :ok <- valid_profile(profile) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- context(operation),
             :ok <- expected_target(evidence, expected),
             true <- profile.id == evidence.target.github_user_id,
             {:ok, identity} <- observe(profile, now, evidence.target),
             {:ok, fresh} <- ForgeMirrors.mapped_pull_effect_context(operation),
             true <- fresh.marker == expected.marker,
             {:ok, yielded} <- yield_fun.(fresh.operation, now) do
          %{operation: yielded, identity: identity}
        else
          false -> Repo.rollback(:invalid_identity_observation)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      false -> {:error, :invalid_argument}
      {:error, reason} -> {:error, reason}
    end
  end

  def seed(_, _, _, _, _), do: {:error, :invalid_argument}

  defp target(intent) do
    # The mapped intent validator has already checked exact shape and bounded,
    # sorted numeric IDs. Current local membership is deliberately irrelevant.
    ids = intent.payload["target_issue"]["assignee_github_ids"]

    identities =
      Repo.all(
        from(i in GitHubIdentity,
          where: i.kind == :user and i.github_user_id in ^ids,
          order_by: i.github_user_id,
          lock: "FOR UPDATE NOWAIT"
        ),
        mode: :savepoint
      )

    if Enum.map(identities, & &1.github_user_id) == ids do
      missing = Enum.find(identities, &is_nil(&1.github_node_id))

      {:ok,
       if(missing,
         do: %{
           identity_id: missing.id,
           github_user_id: missing.github_user_id,
           expected_node_id: nil
         }
       )}
    else
      {:error, :assignee_identity_unavailable}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp expected_target(evidence, expected) do
    if Enum.sort(Map.keys(expected)) == [:marker, :target] and
         expected.marker == evidence.marker and expected.target == evidence.target and
         not is_nil(evidence.target), do: :ok, else: {:error, :stale_relationship_proof}
  end

  defp valid_profile(profile) do
    node = profile[:node_id]

    if Enum.sort(Map.keys(profile)) == @profile_keys and
         is_integer(profile[:id]) and profile.id in 1..9_223_372_036_854_775_807 and
         is_binary(node) and byte_size(node) in 1..512 and String.valid?(node) and
         String.trim(node) == node and not String.contains?(node, <<0>>) and
         ForgeAccounts.GitHubProfileSafety.validate(profile) == :ok,
       do: :ok,
       else: {:error, :invalid_identity_observation}
  end

  defp observe(profile, now, target) do
    case ForgeAccounts.observe_github_identity(profile, now) do
      {:ok,
       %GitHubIdentity{id: id, kind: :user, github_user_id: provider_id, github_node_id: node} =
           identity}
      when id == target.identity_id and provider_id == target.github_user_id and
             node == profile.node_id ->
        {:ok, identity}

      {:ok, _} ->
        {:error, :identity_conflict}

      {:error, %Ecto.Changeset{}} ->
        {:error, :identity_conflict}

      {:error, _} ->
        {:error, :invalid_identity_observation}
    end
  end
end
