defmodule ForgeMirrors.PullMergeConflictResolution do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeMirrors.{MirrorConflict, MirrorOperation, OrganizationMirror, RepositoryMirror}
  alias Fornacast.{Audit, Repo}

  @action "external_recheck"
  @resolution %{"action" => @action, "v" => 1}

  @spec recheck(User.t(), pos_integer(), MirrorConflict.t(), String.t(), DateTime.t(), map()) ::
          {:ok,
           %{
             conflict: MirrorConflict.t(),
             operation: MirrorOperation.t(),
             merge_operation: map()
           }}
          | {:error,
             Ecto.Changeset.t()
             | :busy
             | :forbidden
             | :invalid_argument
             | :invalid_request_metadata
             | :invalid_transition
             | :not_found
             | :stale
             | :unavailable}
  def recheck(
        %User{id: actor_id} = actor,
        organization_id,
        %MirrorConflict{id: conflict_id, lock_version: lock_version},
        @action,
        %DateTime{} = now,
        request_metadata
      )
      when is_integer(actor_id) and actor_id > 0 and is_integer(organization_id) and
             organization_id > 0 and is_integer(conflict_id) and conflict_id > 0 and
             is_integer(lock_version) and lock_version > 0 and is_map(request_metadata) do
    with :ok <- validate_utc(now),
         {:ok, request_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata) do
      now = DateTime.truncate(now, :second)

      Repo.transaction(fn ->
        with %MirrorConflict{} = persisted <- lock_conflict(conflict_id),
             %OrganizationMirror{} = organization <- lock_organization(persisted),
             true <- organization.organization_id == organization_id,
             {:ok, _} <-
               ForgeAccounts.fetch_manageable_organization(actor, organization.organization_id) do
          resolve_or_replay(persisted, lock_version, organization, actor, now, request_metadata)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_transition)
        end
      end)
      |> normalize_transaction()
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def recheck(
        %User{},
        _organization_id,
        %MirrorConflict{},
        _action,
        %DateTime{},
        request_metadata
      )
      when is_map(request_metadata),
      do: {:error, :invalid_argument}

  def recheck(_actor, _organization_id, _conflict, _action, _now, _request_metadata),
    do: {:error, :forbidden}

  defp resolve_or_replay(
         %MirrorConflict{state: :resolved, resolution: @resolution} = conflict,
         _lock_version,
         organization,
         _actor,
         _now,
         _request_metadata
       ) do
    with {:ok, {intent, operation}} <- replay_merge(conflict, organization) do
      %{conflict: conflict, operation: operation, merge_operation: intent}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolve_or_replay(
         %MirrorConflict{state: :open, lock_version: lock_version} = conflict,
         lock_version,
         organization,
         actor,
         now,
         request_metadata
       ) do
    with {:ok, {_binding, intent, operation}} <-
           correlated_merge(conflict, organization, :resolve, now),
         {:ok, resolved} <- resolve(conflict, actor.id, now),
         {:ok, woken} <- wake(operation, now),
         {:ok, _audit} <-
           Audit.record(
             actor,
             "github.pull_merge_conflict.external_recheck",
             "mirror_conflict",
             conflict.id,
             %{
               "organization_mirror_id" => conflict.organization_mirror_id,
               "repository_mirror_id" => conflict.repository_mirror_id,
               "merge_operation_id" => intent.id,
               "mirror_operation_id" => operation.id,
               "conflict_kind" => conflict.conflict_kind
             },
             request_metadata: request_metadata,
             operation_id: "pull-merge-conflict-recheck:#{conflict.id}"
           ) do
      %{conflict: resolved, operation: woken, merge_operation: intent}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolve_or_replay(%MirrorConflict{state: :open}, _version, _org, _actor, _now, _metadata),
    do: Repo.rollback(:stale)

  defp resolve_or_replay(%MirrorConflict{}, _version, _org, _actor, _now, _metadata),
    do: Repo.rollback(:invalid_transition)

  defp correlated_merge(
         %MirrorConflict{
           organization_mirror_id: organization_id,
           repository_mirror_id: repository_id,
           resource_kind: "pull_merge",
           resource_identity: resource_identity
         },
         %OrganizationMirror{id: organization_id, provider: "github", state: state},
         mode,
         now
       )
       when is_integer(repository_id) and repository_id > 0 and
              state in [:active, :degraded, :conflicted] do
    with {:ok, intent_id} <- parse_identity(resource_identity),
         %RepositoryMirror{
           id: ^repository_id,
           organization_mirror_id: ^organization_id,
           state: :active,
           inventory_included: true
         } = binding <- lock_repository(repository_id),
         %{
           id: ^intent_id,
           coordination_mode: coordination_mode,
           coordinator_operation_id: operation_id,
           repository_id: local_repository_id
         } = intent <- lock_intent(intent_id),
         true <- to_string(coordination_mode) == "mirror",
         true <- local_repository_id == binding.repository_id,
         %MirrorOperation{} = operation <- lock_operation(operation_id),
         :ok <- validate_operation(operation, organization_id, repository_id, intent, mode, now) do
      {:ok, {binding, intent, operation}}
    else
      {:error, _} = error -> error
      nil -> {:error, :invalid_transition}
      false -> {:error, :invalid_transition}
      _ -> {:error, :invalid_transition}
    end
  end

  defp correlated_merge(_conflict, _organization, _mode, _now),
    do: {:error, :invalid_transition}

  defp replay_merge(
         %MirrorConflict{
           organization_mirror_id: organization_id,
           repository_mirror_id: repository_id,
           resource_kind: "pull_merge",
           resource_identity: resource_identity
         },
         %OrganizationMirror{id: organization_id, provider: "github"}
       ) do
    with {:ok, intent_id} <- parse_identity(resource_identity),
         %{id: ^intent_id, coordinator_operation_id: operation_id} = intent <-
           lock_intent(intent_id),
         %MirrorOperation{
           id: ^operation_id,
           organization_mirror_id: ^organization_id,
           repository_mirror_id: ^repository_id,
           kind: "merge.pull"
         } = operation <- lock_operation(operation_id) do
      {:ok, {intent, operation}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_transition}
    end
  end

  defp replay_merge(_conflict, _organization), do: {:error, :invalid_transition}

  defp validate_operation(
         %MirrorOperation{
           id: operation_id,
           organization_mirror_id: organization_id,
           repository_mirror_id: repository_id,
           kind: "merge.pull",
           cursor: %{"pull_id" => pull_id, "issue_id" => issue_id},
           state: :effect_pending,
           failure_disposition: :conflict,
           lease_owner: lease_owner,
           lease_expires_at: lease_expires_at,
           external_effect_marker: marker
         },
         organization_id,
         repository_id,
         %{
           id: intent_id,
           pull_request_id: pull_id,
           state: intent_state,
           commit_intent: %{"resource" => %{"issue_id" => issue_id}}
         },
         :resolve,
         now
       )
       when is_map(marker) do
    with true <- to_string(intent_state) == "merge_written",
         true <- marker_merge_operation_id(marker) == intent_id,
         :ok <- validate_lease(operation_id, lease_owner, lease_expires_at, now) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_transition}
    end
  end

  defp validate_operation(
         _operation,
         _organization_id,
         _repository_id,
         _intent,
         _mode,
         _now
       ),
       do: {:error, :invalid_transition}

  defp resolve(conflict, actor_id, now) do
    conflict
    |> MirrorConflict.resolve_changeset(@resolution, actor_id, now)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
    |> case do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if Keyword.has_key?(changeset.errors, :lock_version), do: {:error, :stale}, else: error

      result ->
        result
    end
  end

  defp wake(operation, now) do
    query =
      from op in MirrorOperation,
        where:
          op.id == ^operation.id and op.lock_version == ^operation.lock_version and
            op.state == :effect_pending and op.failure_disposition == :conflict and
            (is_nil(op.lease_owner) or is_nil(op.lease_expires_at) or
               op.lease_expires_at <= ^now or
               op.lease_expires_at <= fragment("timezone('UTC', clock_timestamp())"))

    case Repo.update_all(query,
           set: [
             next_attempt_at: now,
             failure_class: nil,
             failure_disposition: nil,
             failure_detail: nil,
             lease_owner: nil,
             lease_expires_at: nil,
             updated_at: now
           ],
           inc: [lock_version: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
      _ -> {:error, :stale}
    end
  end

  defp lock_conflict(id),
    do: Repo.one(from conflict in MirrorConflict, where: conflict.id == ^id, lock: "FOR UPDATE")

  defp lock_organization(%MirrorConflict{organization_mirror_id: id}),
    do:
      Repo.one(
        from organization in OrganizationMirror,
          where: organization.id == ^id,
          lock: "FOR UPDATE"
      )

  defp lock_repository(id),
    do:
      Repo.one(
        from repository in RepositoryMirror,
          where: repository.id == ^id,
          lock: "FOR UPDATE"
      )

  defp lock_intent(id) do
    Repo.one(
      from intent in "pull_merge_operations",
        where: intent.id == ^id,
        lock: "FOR UPDATE",
        select: %{
          id: intent.id,
          coordination_mode: intent.coordination_mode,
          coordinator_operation_id: intent.coordinator_operation_id,
          repository_id: intent.repository_id,
          pull_request_id: intent.pull_request_id,
          state: intent.state,
          merge_oid: intent.merge_oid,
          commit_intent: intent.commit_intent
        }
    )
  end

  defp lock_operation(id) when is_integer(id) and id > 0,
    do:
      Repo.one(from operation in MirrorOperation, where: operation.id == ^id, lock: "FOR UPDATE")

  defp lock_operation(_id), do: nil

  defp parse_identity(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_transition}
    end
  end

  defp parse_identity(_value), do: {:error, :invalid_transition}

  defp marker_merge_operation_id(%{
         "phase" => "metadata_label_pending",
         "parent_marker" => parent
       }),
       do: marker_merge_operation_id(parent)

  defp marker_merge_operation_id(%{"merge_operation_id" => id}) when is_integer(id), do: id
  defp marker_merge_operation_id(_marker), do: nil

  defp validate_lease(_operation_id, nil, nil, _now), do: :ok

  defp validate_lease(operation_id, owner, %DateTime{} = expires_at, now)
       when is_binary(owner) and byte_size(owner) > 0 do
    active? =
      Repo.exists?(
        from operation in MirrorOperation,
          where:
            operation.id == ^operation_id and operation.lease_owner == ^owner and
              operation.lease_expires_at == ^expires_at and operation.lease_expires_at > ^now and
              operation.lease_expires_at > fragment("timezone('UTC', clock_timestamp())")
      )

    if active?, do: {:error, :busy}, else: :ok
  end

  defp validate_lease(_operation_id, _owner, _expires_at, _now),
    do: {:error, :invalid_transition}

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}
end
