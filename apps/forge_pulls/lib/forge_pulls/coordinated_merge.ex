defmodule ForgePulls.CoordinatedMerge do
  @moduledoc """
  Durable intent preparation and private, staged merge-object publication.

  This is a trusted Multi boundary, like Sync. Its caller must hold and validate
  the coordinator operation capability and current mirror/ref eligibility in the
  same transaction. A positive coordinator ID alone is not authorization.
  Commit the resulting intent before any later deterministic object writer runs.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias ForgePulls.{MergeOperation, Sync}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

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

  if Mix.env() == :test do
    @writer_hook {__MODULE__, :writer_hook}
    def with_test_writer_hook(hook, fun) do
      previous = Process.get(@writer_hook)
      Process.put(@writer_hook, hook)

      try do
        fun.()
      after
        if previous, do: Process.put(@writer_hook, previous), else: Process.delete(@writer_hook)
      end
    end

    defp writer_hook(stage, oid) do
      if hook = Process.get(@writer_hook), do: hook.(stage, oid)
      :ok
    end
  else
    defp writer_hook(_, _), do: :ok
  end

  @doc """
  Writes only private objects/pins for an already committed mirror-owned intent.

  `:authorize` is mandatory trusted coordinator code. It must lock and recheck
  its capability, mirror/ref eligibility and permission proof, without network
  calls. It runs before domain row locks in EACH transaction. A durable tree
  checkpoint commits before any merge commit is constructed, so configuration
  changes after a crash cannot choose a different merge tree for this intent.
  This API never advances a public branch or marks a pull request merged.
  """
  def write_coordinated_merge(id, coordinator_id, opts) when is_list(opts) do
    cond do
      Repo.in_transaction?() ->
        {:error, :uncommitted_merge_intent}

      not Keyword.keyword?(opts) or not is_function(opts[:authorize], 1) ->
        {:error, :invalid_coordinator_capability}

      not positive?(id) or not positive?(coordinator_id) ->
        {:error, :stale_merge_identity}

      true ->
        with %MergeOperation{} = intent <- Repo.get(MergeOperation, id),
             true <- writable_intent?(intent, coordinator_id),
             %Repository{} = repository <- live_repository(Repo, intent.repository_id),
             true <-
               repository.generation == intent.commit_intent["resource"]["repository_generation"] do
          ForgeRepos.with_write_fence(repository, :merge, fn path, remaining ->
            deadline = System.monotonic_time(:millisecond) + remaining

            with {:ok, checkpoint} <-
                   writer_transaction(intent, opts[:authorize], path, deadline, :tree),
                 :ok <- writer_hook(:after_tree_checkpoint, checkpoint.merge_tree_oid) do
              writer_transaction(checkpoint, opts[:authorize], path, deadline, :commit)
            end
          end)
        else
          _ -> {:error, :stale_merge_identity}
        end
    end
  end

  def write_coordinated_merge(_, _, _), do: {:error, :invalid_coordinator_capability}

  defp writable_intent?(intent, coordinator_id) do
    intent.coordination_mode == :mirror and intent.coordinator_operation_id == coordinator_id and
      intent.state in [:prepared, :merge_written] and is_nil(intent.lease_owner) and
      is_nil(intent.lease_expires_at) and is_map(intent.commit_intent) and
      valid_commit?(Map.delete(intent.commit_intent, "resource")) and
      is_map(intent.commit_intent["resource"]) and
      (intent.state != :merge_written or
         (is_binary(intent.merge_tree_oid) and is_binary(intent.merge_oid)))
  end

  defp writer_transaction(expected, authorize, path, deadline, stage) do
    Repo.transaction(fn ->
      with :ok <- authorize.(expected),
           {:ok, projection} <- observe_intent(expected),
           {:ok, repository, head} <-
             repositories(Repo, projection, %{
               expected_head_repository_id:
                 expected.commit_intent["resource"]["head_repository_id"]
             }),
           true <-
             repository.generation == expected.commit_intent["resource"]["repository_generation"] and
               head.generation == expected.commit_intent["resource"]["head_repository_generation"] and
               projection.issue_id == expected.commit_intent["resource"]["issue_id"],
           %MergeOperation{} = locked <-
             Repo.one(
               from operation in MergeOperation,
                 where: operation.id == ^expected.id,
                 lock: "FOR UPDATE"
             ),
           true <- same_writer_intent?(locked, expected),
           {:ok, result} <- write_stage(locked, path, deadline, stage) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:stale_merge_identity)
      end
    end)
  end

  defp observe_intent(intent) do
    resource = intent.commit_intent["resource"]

    expected = %{
      repository_id: intent.repository_id,
      resource_kind: :pull,
      local_resource_id: intent.pull_request_id,
      expected_local_version: resource["expected_local_version"],
      expected_fields: resource["expected_fields"],
      expected_merge_state: %{merged_at: nil, merge_commit_sha: nil}
    }

    case Multi.new() |> Sync.append_sync_observe(:resource, expected) |> Repo.transaction() do
      {:ok, %{resource: projection}} -> {:ok, projection}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  defp same_writer_intent?(locked, expected) do
    fields =
      @immutable_fields ++
        [:state, :merge_tree_oid, :merge_oid, :lock_version, :lease_owner, :lease_expires_at]

    writable_intent?(locked, expected.coordinator_operation_id) and
      Map.take(locked, fields) == Map.take(expected, fields) and
      locked.base_ref == locked.commit_intent["resource"]["expected_fields"]["base_ref"] and
      locked.head_ref == locked.commit_intent["resource"]["expected_fields"]["head_ref"] and
      locked.expected_base_oid == locked.commit_intent["resource"]["expected_fields"]["base_sha"] and
      locked.expected_head_oid == locked.commit_intent["resource"]["expected_fields"]["head_sha"]
  end

  defp write_stage(%{merge_tree_oid: nil} = intent, path, deadline, :tree) do
    with {:ok, remaining} <- writer_remaining(deadline),
         {:ok, tree} <-
           GitCore.write_merge_tree(path, intent.expected_base_oid, intent.expected_head_oid,
             deadline_ms: remaining
           ),
         :ok <- writer_hook(:after_tree_write, tree),
         {:ok, saved} <- persist_writer_fields(intent, merge_tree_oid: tree) do
      {:ok, saved}
    end
  end

  # Commit T before creating its pin, so a crash cannot leave an unproved pin
  # whose tree conflicts with a later merge configuration. The held writer
  # fence and nonterminal intent block repository cleanup/replacement. There is
  # no production object GC; any future GC must honor this durable checkpoint.
  defp write_stage(intent, _path, _deadline, :tree), do: {:ok, intent}

  defp write_stage(intent, path, deadline, :commit) do
    with :ok <- pin(intent, path, "refs/tags/tree", intent.merge_tree_oid, deadline),
         :ok <- writer_hook(:after_tree_pin, intent.merge_tree_oid),
         {:ok, remaining} <- writer_remaining(deadline),
         {:ok, oid} <-
           GitCore.write_commit_from_tree(
             path,
             intent.merge_tree_oid,
             intent.expected_base_oid,
             intent.expected_head_oid,
             stored_signature(intent.commit_intent["author"]),
             stored_signature(intent.commit_intent["committer"]),
             intent.commit_intent["message"],
             deadline_ms: remaining
           ),
         true <- is_nil(intent.merge_oid) or intent.merge_oid == oid,
         :ok <- writer_hook(:after_object_write, oid),
         :ok <- pin(intent, path, "refs/heads/result", oid, deadline),
         :ok <- writer_hook(:after_pin, oid) do
      if intent.merge_oid == oid,
        do: {:ok, intent},
        else: persist_writer_fields(intent, merge_oid: oid, state: :merge_written)
    else
      false -> {:error, :merge_intent_conflict}
      {:error, _} = error -> error
    end
  end

  defp pin(intent, path, source, oid, deadline) do
    namespace = "merge-#{intent.id}"

    with {:ok, remaining} <- writer_remaining(deadline),
         {:ok, current} <-
           GitCore.exact_tracking_ref(path, namespace, source, deadline_ms: remaining) do
      case current do
        ^oid ->
          :ok

        nil ->
          with {:ok, remaining} <- writer_remaining(deadline),
               {:ok, ^oid} <-
                 GitCore.compare_and_swap_tracking_ref(path, namespace, source, nil, oid,
                   deadline_ms: remaining
                 ),
               do: :ok

        _ ->
          {:error, :merge_pin_conflict}
      end
    end
  end

  defp persist_writer_fields(intent, fields),
    do:
      intent
      |> Ecto.Changeset.change(fields)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update()

  defp stored_signature(signature),
    do: %GitCore.Signature{
      name: signature["name"],
      email: signature["email"],
      seconds: signature["seconds"],
      offset_minutes: signature["offset_minutes"]
    }

  defp writer_remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _ -> {:error, :merge_write_timeout}
    end
  end

  def append_prepare_coordinated_merge(%Multi{} = multi, key, request) when is_map(request) do
    multi
    |> Multi.run({key, :request}, fn repo, _ ->
      if valid_request?(request) and positive?(request[:repository_id]) do
        # Same transaction advisory key as ForgeMirrors.PullMergeBoundary.
        # Acquire before Issue/Pull locks, never a repository-row -> Issue inversion.
        [request.repository_id, request[:expected_head_repository_id]]
        |> Enum.filter(&positive?/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.each(fn id ->
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["fornacast:merge-reservation:#{id}"]
          )
        end)

        {:ok, :validated}
      else
        {:error, :invalid_merge_intent}
      end
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
            if repo.exists?(
                 from operation in MergeOperation,
                   where:
                     operation.coordination_mode == :mirror and
                       operation.state not in [:completed, :failed] and
                       (operation.pull_request_id == ^attrs.pull_request_id or
                          (operation.repository_id == ^attrs.repository_id and
                             operation.base_ref == ^attrs.base_ref) or
                          (operation.head_ref == ^attrs.base_ref and
                             fragment(
                               "?->'resource'->>'head_repository_id' = ?",
                               operation.commit_intent,
                               ^to_string(attrs.repository_id)
                             )) or
                          (operation.repository_id == ^head_repository.id and
                             operation.base_ref == ^attrs.head_ref))
               ) do
              {:error, :merge_reserved}
            else
              repo.insert(MergeOperation.prepare_coordinated_changeset(%MergeOperation{}, attrs))
            end

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
