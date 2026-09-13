defmodule ForgeMirrors.PullMergeRemoteAssigneeObservation do
  @moduledoc """
  Atomically retains authenticated remote assignee identities for merge recovery.

  This boundary neither consumes the merge effect nor yields its lease. The
  operation, coordinator intent, metadata intent and marker must remain exact
  across the complete identity observation batch.
  """

  import Ecto.Query

  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.{MirrorOperation, PullMergeBoundary}
  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  @max_profiles 512
  @profile_keys [:avatar_url, :html_url, :id, :login, :name, :node_id]
  @expected_keys [:coordinator_intent, :marker, :metadata_intent]

  def context(%MirrorOperation{kind: "merge.pull"} = operation, %DateTime{} = now) do
    with :ok <- valid_utc(now) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- PullMergeBoundary.finalization_context(operation, now),
             {:ok, fresh} <- PullMergeBoundary.finalization_context(operation, now),
             true <- proof(evidence) == proof(fresh) do
          Map.merge(proof(evidence), %{operation: evidence.operation})
        else
          false -> Repo.rollback(:stale_relationship_proof)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def context(_, _), do: {:error, :invalid_argument}

  def observe(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        expected,
        profiles,
        validation_fun
      )
      when is_map(expected) and is_list(profiles) and is_function(validation_fun, 0) do
    with :ok <- valid_utc(now),
         :ok <- valid_expected(expected),
         :ok <- valid_profiles(profiles) do
      Repo.transaction(fn ->
        with {:ok, evidence} <- PullMergeBoundary.finalization_context(operation, now),
             :ok <- exact_proof(evidence, expected),
             {:ok, validation} <- validation(validation_fun),
             {:ok, _locked} <- lock_existing(profiles),
             {:ok, identities} <- observe_profiles(profiles, now),
             {:ok, fresh} <- PullMergeBoundary.finalization_context(operation, now),
             :ok <- exact_proof(fresh, expected),
             {:ok, fresh_validation} <- validation(validation_fun),
             true <- fresh_validation == validation,
             :ok <- exact_identities(identities, profiles),
             true <- fresh.operation == evidence.operation do
          %{operation: fresh.operation, identities: identities, validation: validation}
        else
          false -> Repo.rollback(:stale_relationship_proof)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def observe(_, _, _, _, _), do: {:error, :invalid_argument}

  defp validation(validation_fun) do
    case validation_fun.() do
      {:ok, validation} -> {:ok, validation}
      {:error, _} = error -> error
      _ -> {:error, :stale_relationship_proof}
    end
  end

  defp proof(evidence) do
    %{
      marker: evidence.operation.external_effect_marker,
      coordinator_intent: evidence.intent,
      metadata_intent: evidence.metadata_intent
    }
  end

  defp exact_proof(evidence, expected) do
    if proof(evidence) == expected,
      do: :ok,
      else: {:error, :stale_relationship_proof}
  end

  defp lock_existing(profiles) do
    ids = Enum.map(profiles, & &1.id)
    nodes = Enum.map(profiles, & &1.node_id)

    identities =
      Repo.all(
        from(identity in GitHubIdentity,
          where:
            identity.kind == :user and
              (identity.github_user_id in ^ids or identity.github_node_id in ^nodes),
          order_by: identity.github_user_id,
          limit: @max_profiles + 1,
          lock: "FOR UPDATE NOWAIT"
        ),
        mode: :savepoint
      )

    by_id = Map.new(profiles, &{&1.id, &1.node_id})
    by_node = Map.new(profiles, &{&1.node_id, &1.id})

    if Enum.all?(identities, fn identity ->
         Map.has_key?(by_id, identity.github_user_id) and
           identity.github_node_id in [nil, by_id[identity.github_user_id]] and
           (is_nil(identity.github_node_id) or
              by_node[identity.github_node_id] == identity.github_user_id)
       end) do
      {:ok, identities}
    else
      {:error, :identity_conflict}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp observe_profiles(profiles, now) do
    Enum.reduce_while(profiles, {:ok, []}, fn profile, {:ok, identities} ->
      case ForgeAccounts.observe_github_identity(profile, now) do
        {:ok, %GitHubIdentity{} = identity} ->
          {:cont, {:ok, [identity | identities]}}

        {:error, %Ecto.Changeset{}} ->
          {:halt, {:error, :identity_conflict}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_identity_observation}}
      end
    end)
    |> case do
      {:ok, identities} -> {:ok, Enum.reverse(identities)}
      error -> error
    end
  end

  defp exact_identities(identities, profiles) do
    exact =
      Enum.zip(identities, profiles)
      |> Enum.all?(fn
        {%GitHubIdentity{kind: :user} = identity, profile} ->
          identity.github_user_id == profile.id and identity.github_node_id == profile.node_id

        _ ->
          false
      end)

    if length(identities) == length(profiles) and exact,
      do: :ok,
      else: {:error, :identity_conflict}
  end

  defp valid_expected(expected) do
    if Enum.sort(Map.keys(expected)) == @expected_keys and is_map(expected.marker) and
         is_map(expected.coordinator_intent) and
         (is_nil(expected.metadata_intent) or is_struct(expected.metadata_intent)),
       do: :ok,
       else: {:error, :stale_relationship_proof}
  end

  defp valid_profiles(profiles) do
    valid =
      if length(profiles) <= @max_profiles and Enum.all?(profiles, &is_map/1) do
        ids = Enum.map(profiles, & &1[:id])
        nodes = Enum.map(profiles, & &1[:node_id])

        ids == Enum.sort(ids) and length(ids) == length(Enum.uniq(ids)) and
          length(nodes) == length(Enum.uniq(nodes)) and Enum.all?(profiles, &valid_profile/1)
      else
        false
      end

    if valid, do: :ok, else: {:error, :invalid_identity_observation}
  end

  defp valid_profile(profile) when is_map(profile) do
    Enum.sort(Map.keys(profile)) == @profile_keys and positive_id?(profile.id) and
      nonempty_text?(profile.node_id, 512) and nonempty_text?(profile.login, 255) and
      ForgeAccounts.GitHubProfileSafety.validate(profile) == :ok
  end

  defp valid_profile(_), do: false

  defp valid_utc(date) do
    if date.utc_offset == 0 and date.std_offset == 0,
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp positive_id?(id), do: is_integer(id) and id in 1..@max_id

  defp nonempty_text?(value, max) do
    is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
      String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch
  end
end
