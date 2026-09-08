defmodule ForgePulls.CoordinatedMerge do
  @moduledoc """
  Durable intent only: never writes Git objects, refs, or merged PR state.

  This is a trusted Multi boundary, like Sync. Its caller must hold and validate
  the coordinator operation capability and current mirror/ref eligibility in the
  same transaction. A positive coordinator ID alone is not authorization.
  Commit the resulting intent before any later deterministic object writer runs.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias ForgePulls.{MergeOperation, Sync}
  alias ForgeRepos.Repository

  @max_id 9_223_372_036_854_775_807
  @immutable_fields [
    :pull_request_id,
    :repository_id,
    :actor_user_id,
    :request_id,
    :coordinator_operation_id,
    :commit_intent,
    :base_ref,
    :head_ref,
    :expected_base_oid,
    :expected_head_oid
  ]

  def append_prepare_coordinated_merge(%Multi{} = multi, key, request) when is_map(request) do
    multi
    |> Multi.run({key, :request}, fn _, _ ->
      if valid_request?(request), do: {:ok, :validated}, else: {:error, :invalid_merge_intent}
    end)
    |> Sync.append_sync_observe({key, :snapshot}, request)
    |> Multi.run(key, fn repo, changes ->
      projection = Map.fetch!(changes, {key, :snapshot})

      with {:ok, repository, head_repository} <- repositories(repo, projection, request),
           %ForgeAccounts.User{} = actor <-
             repo.get_by(ForgeAccounts.User,
               id: request.actor_user_id,
               state: :active,
               kind: :user
             ),
           true <- Fornacast.Access.allowed?(actor, :repository_write, repository),
           true <-
             projection.fields["state"] == "open" and projection.fields["draft"] == false and
               projection.merge_state == %{merged_at: nil, merge_commit_sha: nil} do
        attrs = intent_attrs(request, projection, repository, head_repository)

        case repo.one(
               from operation in MergeOperation,
                 where: operation.coordinator_operation_id == ^request.coordinator_operation_id,
                 lock: "FOR UPDATE"
             ) do
          nil ->
            repo.insert(MergeOperation.prepare_coordinated_changeset(%MergeOperation{}, attrs))

          existing ->
            if existing.coordination_mode == :mirror and
                 Map.take(existing, @immutable_fields) == Map.take(attrs, @immutable_fields),
               do: {:ok, existing},
               else: {:error, :merge_intent_conflict}
        end
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :forbidden}
      end
    end)
  end

  def append_prepare_coordinated_merge(%Multi{} = multi, key, _),
    do: Multi.error(multi, key, :invalid_merge_intent)

  defp repositories(repo, projection, request) do
    with true <-
           positive?(projection.head_repository_id) and
             projection.head_repository_id == request[:expected_head_repository_id],
         %Repository{} = repository <- live_repository(repo, projection.repository_id),
         %Repository{} = head <- live_repository(repo, projection.head_repository_id),
         true <- head.owner_user_id == repository.owner_user_id do
      {:ok, repository, head}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp live_repository(repo, id),
    do:
      repo.one(
        from repository in Repository,
          where:
            repository.id == ^id and repository.lifecycle == :ready and
              is_nil(repository.deleted_at)
      )

  defp intent_attrs(request, projection, repository, head) do
    resource = %{
      "issue_id" => projection.issue_id,
      "expected_local_version" => projection.local_version,
      "head_repository_id" => projection.head_repository_id,
      "repository_generation" => repository.generation,
      "head_repository_generation" => head.generation,
      "expected_fields" => projection.fields
    }

    %{
      pull_request_id: projection.local_resource_id,
      repository_id: projection.repository_id,
      actor_user_id: request.actor_user_id,
      request_id: request.request_id,
      coordinator_operation_id: request.coordinator_operation_id,
      commit_intent: Map.put(request.commit_intent, "resource", resource),
      base_ref: projection.fields["base_ref"],
      head_ref: projection.fields["head_ref"],
      expected_base_oid: projection.fields["base_sha"],
      expected_head_oid: projection.fields["head_sha"],
      state: :prepared
    }
  end

  defp valid_request?(request) do
    positive?(request[:coordinator_operation_id]) and positive?(request[:actor_user_id]) and
      text?(request[:request_id], 255) and valid_commit?(request[:commit_intent]) and
      not Map.has_key?(request, :minimum_local_version)
  end

  defp valid_commit?(
         %{"message" => message, "author" => author, "committer" => committer} = intent
       ),
       do:
         map_size(intent) == 3 and text?(message, 65_794) and signature?(author) and
           signature?(committer)

  defp valid_commit?(_), do: false

  defp signature?(
         %{"name" => name, "email" => email, "seconds" => seconds, "offset_minutes" => offset} =
           signature
       ),
       do:
         map_size(signature) == 4 and identity_text?(name) and identity_text?(email) and
           is_integer(seconds) and seconds >= 0 and seconds <= @max_id and
           is_integer(offset) and offset in -1439..1439

  defp signature?(_), do: false

  defp identity_text?(value),
    do: text?(value, 1024) and not String.contains?(value, ["<", ">", "\r", "\n"])

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp positive?(value), do: is_integer(value) and value > 0 and value <= @max_id
end
