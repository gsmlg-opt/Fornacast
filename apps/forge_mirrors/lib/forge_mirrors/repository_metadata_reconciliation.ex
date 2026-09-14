defmodule ForgeMirrors.RepositoryMetadataReconciliation do
  @moduledoc false

  import Ecto.Query

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
    RepositoryMirror
  }

  alias Fornacast.Repo

  @kind "reconcile.repository.metadata"
  @fields ~w(name description visibility default_branch archived)

  def context(%MirrorOperation{} = operation) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(operation),
           {:ok, binding, organization, repository} <- scope(operation),
           %GitHubAppInstallation{state: :active} <-
             Repo.get_by(GitHubAppInstallation,
               github_installation_id: organization.github_installation_id
             ) do
        {:ok,
         %{
           repository_mirror_id: binding.id,
           repository_id: repository.id,
           github_installation_id: organization.github_installation_id,
           github_repository_id: binding.github_repository_id,
           github_node_id: binding.github_node_id,
           remote_owner: binding.github_full_name |> String.split("/", parts: 2) |> hd(),
           remote_repository:
             binding.github_full_name |> String.split("/", parts: 2) |> List.last(),
           local_snapshot: local_snapshot(repository, binding),
           baseline: baseline(binding.id)
         }}
      else
        nil -> Repo.rollback(:invalid_transition)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_transition)
      end
    end)
    |> unwrap()
  end

  def context(_), do: {:error, :invalid_transition}

  def record(%MirrorOperation{} = operation, remote, %DateTime{} = now) when is_map(remote) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(operation),
           {:ok, binding, organization, repository} <- scope(operation),
           {:ok, remote_snapshot, remote_updated_at} <- remote_snapshot(remote, binding),
           local_snapshot <- local_snapshot(repository, binding),
           baseline <- baseline(binding.id),
           result <- decide(baseline, local_snapshot, remote_snapshot),
           {:ok, response} <-
             persist(
               result,
               operation,
               binding,
               organization,
               repository,
               local_snapshot,
               remote_snapshot,
               remote_updated_at,
               now
             ) do
        response
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def record(_, _, _), do: {:error, :invalid_argument}

  defp decide(nil, local, remote) when local == remote, do: :confirm

  defp decide(%MirrorResourceState{}, local, remote)
       when local == remote, do: :confirm

  defp decide(_baseline, _local, _remote), do: :conflict

  defp persist(
         :confirm,
         operation,
         binding,
         _organization,
         repository,
         _local,
         remote,
         updated_at,
         now
       ) do
    with {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(remote),
         attrs = %{
           repository_mirror_id: binding.id,
           resource_kind: :repository,
           local_resource_type: "ForgeRepos.Repository",
           local_resource_id: repository.id,
           github_object_id: binding.github_repository_id,
           github_node_id: binding.github_node_id,
           confirmed_remote_updated_at: updated_at,
           confirmed_snapshot: remote,
           confirmed_fingerprint: fingerprint,
           state: :confirmed,
           lock_version: 1
         },
         baseline = baseline(binding.id),
         {:ok, baseline} <- persist_baseline(baseline, attrs),
         {:ok, completed} <- complete(operation, now) do
      {:ok, %{operation: completed, baseline: baseline}}
    end
  end

  defp persist(
         :conflict,
         operation,
         binding,
         organization,
         _repository,
         local,
         remote,
         _updated_at,
         now
       ) do
    baseline = baseline(binding.id)
    baseline_snapshot = if baseline, do: baseline.confirmed_snapshot || %{}, else: %{}

    attrs = %{
      organization_mirror_id: organization.id,
      repository_mirror_id: binding.id,
      resource_kind: "repository",
      resource_identity: Integer.to_string(binding.github_repository_id),
      conflict_kind: "repository_metadata_diverged",
      baseline_snapshot: baseline_snapshot,
      local_snapshot: local,
      remote_snapshot: remote
    }

    with {:ok, conflict} <- insert_conflict(attrs),
         {:ok, failed} <- fail_conflict(operation, now) do
      {:ok, %{operation: failed, conflict: conflict}}
    end
  end

  defp scope(operation) do
    binding =
      Repo.one(
        from binding in RepositoryMirror,
          where: binding.id == ^operation.repository_mirror_id,
          lock: "FOR UPDATE"
      )

    organization =
      Repo.one(
        from organization in OrganizationMirror,
          where: organization.id == ^operation.organization_mirror_id,
          lock: "FOR UPDATE"
      )

    with %RepositoryMirror{
           repository_id: repository_id,
           github_repository_id: github_id,
           github_node_id: node,
           github_full_name: full_name,
           inventory_included: true,
           state: state
         } = binding <- binding,
         true <- state in [:discovered, :active],
         %OrganizationMirror{provider: "github", state: organization_state} = organization <-
           organization,
         true <- organization_state in [:catching_up, :active, :degraded, :conflicted],
         true <- binding.organization_mirror_id == organization.id,
         true <-
           is_integer(repository_id) and repository_id > 0 and is_integer(github_id) and
             github_id > 0,
         true <- valid_string?(node) and valid_string?(full_name),
         {:ok, repository} <- ForgeRepos.fetch_live_repository(repository_id),
         true <-
           repository.owner_user_id == organization.organization_id and
             repository.lifecycle in [:ready, :synchronizing] do
      {:ok, binding, organization, repository}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_transition}
    end
  end

  defp lock_owned(operation) do
    current =
      Repo.one(
        from candidate in MirrorOperation,
          where: candidate.id == ^operation.id,
          lock: "FOR UPDATE"
      )

    if current && current.kind == @kind && current.state == :processing &&
         current.lease_owner == operation.lease_owner &&
         current.lease_expires_at == operation.lease_expires_at &&
         current.lock_version == operation.lock_version && current.cursor == operation.cursor &&
         current.lease_expires_at > DateTime.utc_now(:second),
       do: {:ok, current},
       else: {:error, :lost_lease}
  end

  defp baseline(mirror_id) do
    Repo.one(
      from state in MirrorResourceState,
        where: state.repository_mirror_id == ^mirror_id and state.resource_kind == :repository,
        lock: "FOR UPDATE"
    )
  end

  defp remote_snapshot(remote, binding) do
    with id when id == binding.github_repository_id <- remote[:id] || remote["id"],
         node when node == binding.github_node_id <- remote[:node_id] || remote["node_id"],
         snapshot <-
           Map.new(@fields, fn field ->
             value = Map.get(remote, field, Map.get(remote, String.to_existing_atom(field)))

             {field,
              if(field == "visibility" and is_atom(value), do: Atom.to_string(value), else: value)}
           end),
         true <-
           is_binary(snapshot["name"]) and is_binary(snapshot["visibility"]) and
             is_binary(snapshot["default_branch"]),
         true <- is_nil(snapshot["description"]) or is_binary(snapshot["description"]),
         true <- is_boolean(snapshot["archived"]),
         %DateTime{} = updated_at <- remote[:updated_at] || remote["updated_at"] do
      {:ok, snapshot, DateTime.truncate(updated_at, :second)}
    else
      _ -> {:error, :invalid_remote_resource}
    end
  end

  defp local_snapshot(repository, binding) do
    %{
      "name" => repository.name,
      "description" => repository.description,
      "visibility" => Atom.to_string(repository.visibility),
      "default_branch" => repository.default_branch,
      "archived" => binding.github_archived || false
    }
  end

  defp complete(operation, now) do
    transition(operation, now, :completed,
      completed_at: now,
      failure_class: nil,
      failure_disposition: nil,
      failure_detail: nil
    )
  end

  defp fail_conflict(operation, now) do
    transition(operation, now, :failed,
      failure_class: "stale_baseline",
      failure_disposition: :conflict,
      failure_detail: "repository metadata differs from the confirmed baseline"
    )
  end

  defp transition(operation, now, state, attrs) do
    {count, _} =
      Repo.update_all(
        from(candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state == :processing and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lock_version == ^operation.lock_version
        ),
        set: [state: state, lease_owner: nil, lease_expires_at: nil, updated_at: now] ++ attrs,
        inc: [lock_version: 1]
      )

    if count == 1,
      do: {:ok, Repo.get!(MirrorOperation, operation.id)},
      else: {:error, :lost_lease}
  end

  defp insert_conflict(attrs) do
    existing =
      Repo.one(
        from conflict in MirrorConflict,
          where:
            conflict.organization_mirror_id == ^attrs.organization_mirror_id and
              conflict.repository_mirror_id == ^attrs.repository_mirror_id and
              conflict.resource_kind == "repository" and
              conflict.resource_identity == ^attrs.resource_identity and conflict.state == :open,
          lock: "FOR UPDATE"
      )

    case existing do
      nil ->
        Repo.insert(MirrorConflict.record_changeset(%MirrorConflict{}, attrs))

      %MirrorConflict{} = conflict ->
        if conflict.conflict_kind == attrs.conflict_kind and
             conflict.baseline_snapshot == attrs.baseline_snapshot and
             conflict.local_snapshot == attrs.local_snapshot and
             conflict.remote_snapshot == attrs.remote_snapshot,
           do: {:ok, conflict},
           else: refresh_conflict(conflict, attrs)
    end
  end

  defp persist_baseline(nil, attrs),
    do: Repo.insert(MirrorResourceState.persistence_changeset(%MirrorResourceState{}, attrs))

  defp persist_baseline(%MirrorResourceState{} = state, attrs) do
    state
    |> MirrorResourceState.persistence_changeset(
      Map.put(attrs, :lock_version, state.lock_version + 1)
    )
    |> Repo.update()
  end

  defp refresh_conflict(conflict, attrs) do
    conflict
    |> Ecto.Changeset.change(
      conflict_kind: attrs.conflict_kind,
      baseline_snapshot: attrs.baseline_snapshot,
      local_snapshot: attrs.local_snapshot,
      remote_snapshot: attrs.remote_snapshot
    )
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
    |> case do
      {:ok, refreshed} -> {:ok, refreshed}
      {:error, _changeset} -> {:error, :stale_conflict}
    end
  end

  defp valid_string?(value),
    do:
      is_binary(value) and byte_size(value) in 1..255 and String.valid?(value) and
        value == String.trim(value)

  defp unwrap({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
