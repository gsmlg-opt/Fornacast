defmodule ForgeMirrors.RepositoryMetadataConflictResolution do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    OrganizationMirror,
    RepositoryMetadataRepresentationPolicy,
    RepositoryMirror
  }

  alias Fornacast.{Audit, Repo}

  @actions ~w(accept_github keep_fornacast external_recheck)
  @active_operation_states [:pending, :processing, :effect_pending]

  @spec request(User.t(), pos_integer(), MirrorConflict.t(), String.t(), DateTime.t(), map()) ::
          {:ok, %{conflict: MirrorConflict.t(), operation: MirrorOperation.t()}}
          | {:error, term()}
  def request(
        %User{id: actor_id} = actor,
        organization_id,
        %MirrorConflict{id: conflict_id, lock_version: supplied_version},
        action,
        %DateTime{} = now,
        request_metadata
      )
      when is_integer(actor_id) and actor_id > 0 and is_integer(organization_id) and
             organization_id > 0 and is_integer(conflict_id) and conflict_id > 0 and
             is_integer(supplied_version) and supplied_version > 0 and action in @actions and
             is_map(request_metadata) do
    with :ok <- validate_utc(now),
         {:ok, request_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata) do
      now = DateTime.truncate(now, :second)

      Repo.transaction(fn ->
        with %MirrorConflict{} = lookup <- Repo.get(MirrorConflict, conflict_id),
             %RepositoryMirror{} = binding <- lock_binding(lookup),
             %OrganizationMirror{} = organization <- lock_organization(lookup),
             %MirrorConflict{} = conflict <- lock_conflict(conflict_id),
             true <- organization.organization_id == organization_id,
             {:ok, _organization} <-
               ForgeAccounts.fetch_manageable_organization(actor, organization_id),
             :ok <- validate_organization(organization),
             :ok <- validate_conflict(conflict, supplied_version, organization, binding, action),
             {:ok, cursor} <- resolution_cursor(conflict, actor_id, action),
             {:ok, operation} <- enqueue_or_replay(organization, binding, conflict, cursor, now),
             {:ok, _audit} <-
               audit_outcome(operation, :requested, %{
                 "conflict_kind" => conflict.conflict_kind,
                 "request_metadata" => request_metadata
               }) do
          %{conflict: conflict, operation: operation}
        else
          nil -> Repo.rollback(:not_found)
          false -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
          _invalid -> Repo.rollback(:invalid_transition)
        end
      end)
      |> normalize_transaction()
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def request(
        %User{},
        _organization_id,
        %MirrorConflict{},
        _action,
        %DateTime{},
        request_metadata
      )
      when is_map(request_metadata),
      do: {:error, :invalid_argument}

  def request(_actor, _organization_id, _conflict, _action, _now, _request_metadata),
    do: {:error, :forbidden}

  defp validate_organization(%OrganizationMirror{
         provider: "github",
         state: state,
         github_installation_id: installation_id
       })
       when state in [:active, :paused, :degraded, :conflicted] and is_integer(installation_id) do
    case Repo.get_by(GitHubAppInstallation, github_installation_id: installation_id) do
      %GitHubAppInstallation{state: :active} -> :ok
      _ -> {:error, :invalid_transition}
    end
  end

  defp validate_organization(_organization), do: {:error, :invalid_transition}

  defp validate_conflict(
         %MirrorConflict{
           state: :open,
           lock_version: version,
           organization_mirror_id: organization_mirror_id,
           repository_mirror_id: repository_mirror_id,
           resource_kind: "repository",
           resource_identity: identity,
           conflict_kind: kind,
           baseline_snapshot: baseline,
           local_snapshot: local,
           remote_snapshot: remote
         },
         version,
         %OrganizationMirror{id: organization_mirror_id, organization_id: owner_id},
         %RepositoryMirror{
           id: repository_mirror_id,
           organization_mirror_id: organization_mirror_id,
           repository_id: repository_id,
           github_repository_id: github_repository_id,
           inventory_included: true,
           state: state
         },
         action
       )
       when state in [:discovered, :active] and is_integer(repository_id) and repository_id > 0 and
              is_integer(github_repository_id) and github_repository_id > 0 and is_binary(kind) do
    with true <- identity == Integer.to_string(github_repository_id),
         true <- String.starts_with?(kind, "repository_"),
         true <- valid_baseline?(baseline),
         true <- RepositoryMetadataRepresentationPolicy.valid_snapshot?(local),
         true <- RepositoryMetadataRepresentationPolicy.valid_snapshot?(remote),
         :ok <- validate_action_snapshot(action, local, remote),
         {:ok, repository} <- ForgeRepos.fetch_live_repository(repository_id),
         true <- repository.owner_user_id == owner_id do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_transition}
    end
  end

  defp validate_conflict(
         %MirrorConflict{state: :open, lock_version: actual},
         supplied,
         _organization,
         _binding,
         _action
       )
       when actual != supplied,
       do: {:error, :stale}

  defp validate_conflict(_conflict, _version, _organization, _binding, _action),
    do: {:error, :invalid_transition}

  defp validate_action_snapshot("accept_github", _local, remote) do
    case RepositoryMetadataRepresentationPolicy.classify(remote) do
      :representable -> :ok
      _ -> {:error, :invalid_transition}
    end
  end

  defp validate_action_snapshot("keep_fornacast", local, _remote) do
    case RepositoryMetadataRepresentationPolicy.classify(local) do
      :representable -> :ok
      _ -> {:error, :invalid_transition}
    end
  end

  defp validate_action_snapshot("external_recheck", _local, _remote), do: :ok

  defp valid_baseline?(baseline),
    do: baseline == %{} or RepositoryMetadataRepresentationPolicy.valid_snapshot?(baseline)

  defp resolution_cursor(conflict, actor_id, action) do
    with {:ok, baseline_fingerprint} <-
           ForgeMirrors.resource_fingerprint(conflict.baseline_snapshot),
         {:ok, local_fingerprint} <- ForgeMirrors.resource_fingerprint(conflict.local_snapshot),
         {:ok, remote_fingerprint} <- ForgeMirrors.resource_fingerprint(conflict.remote_snapshot) do
      {:ok,
       %{
         "trigger" => "operator_resolution",
         "sweep_key" => "repository-conflict:#{conflict.id}:#{conflict.lock_version}",
         "operator_resolution" => %{
           "v" => 1,
           "conflict_id" => conflict.id,
           "conflict_lock_version" => conflict.lock_version,
           "actor_id" => actor_id,
           "action" => action,
           "baseline_fingerprint" => baseline_fingerprint,
           "local_fingerprint" => local_fingerprint,
           "remote_fingerprint" => remote_fingerprint
         }
       }}
    end
  end

  defp enqueue_or_replay(organization, binding, conflict, cursor, now) do
    case active_resolution_operation(conflict.id) do
      %MirrorOperation{cursor: ^cursor} = operation ->
        {:ok, operation}

      %MirrorOperation{} ->
        {:error, :busy}

      nil ->
        with {:ok, digest} <- ForgeMirrors.resource_fingerprint(cursor) do
          ForgeMirrors.enqueue_operation(%{
            organization_mirror_id: organization.id,
            repository_mirror_id: binding.id,
            kind: "reconcile.repository.metadata",
            dedupe_key: "repository-metadata-conflict:#{conflict.id}:#{digest}",
            cursor: cursor,
            next_attempt_at: now
          })
        end
    end
  end

  defp active_resolution_operation(conflict_id) do
    conflict_id = Integer.to_string(conflict_id)

    Repo.one(
      from operation in MirrorOperation,
        where:
          operation.kind == "reconcile.repository.metadata" and
            operation.state in ^@active_operation_states and
            fragment(
              "?->'operator_resolution'->>'conflict_id' = ?",
              operation.cursor,
              ^conflict_id
            ),
        order_by: [desc: operation.id],
        limit: 1
    )
  end

  @doc false
  def audit_outcome(operation, outcome, metadata \\ %{})

  def audit_outcome(%MirrorOperation{} = operation, outcome, metadata)
      when outcome in [:requested, :completed, :failed] and is_map(metadata) do
    with %{
           "actor_id" => actor_id,
           "action" => action,
           "conflict_id" => conflict_id,
           "conflict_lock_version" => conflict_version,
           "v" => 1
         } <- operation.cursor["operator_resolution"],
         true <- action in @actions and is_integer(actor_id) and actor_id > 0,
         true <- is_integer(conflict_id) and conflict_id > 0,
         true <- is_integer(conflict_version) and conflict_version > 0 do
      request_metadata = Map.get(metadata, "request_metadata", %{})

      audit_metadata =
        metadata
        |> Map.delete("request_metadata")
        |> Map.merge(%{
          "organization_mirror_id" => operation.organization_mirror_id,
          "repository_mirror_id" => operation.repository_mirror_id,
          "mirror_operation_id" => operation.id,
          "outcome" => Atom.to_string(outcome)
        })

      Audit.record(
        %{id: actor_id},
        "github.repository_metadata_conflict.#{action}.#{outcome}",
        "mirror_conflict",
        conflict_id,
        audit_metadata,
        request_metadata: request_metadata,
        operation_id:
          "repository-metadata-conflict:#{conflict_id}:#{conflict_version}:#{action}:#{outcome}"
      )
    else
      _ -> {:error, :invalid_resolution}
    end
  end

  def audit_outcome(%MirrorOperation{}, _outcome, _metadata),
    do: {:error, :invalid_resolution}

  defp lock_conflict(id),
    do: Repo.one(from conflict in MirrorConflict, where: conflict.id == ^id, lock: "FOR UPDATE")

  defp lock_organization(%MirrorConflict{organization_mirror_id: id}),
    do:
      Repo.one(
        from organization in OrganizationMirror,
          where: organization.id == ^id,
          lock: "FOR UPDATE"
      )

  defp lock_binding(%MirrorConflict{repository_mirror_id: id}) when is_integer(id),
    do: Repo.one(from binding in RepositoryMirror, where: binding.id == ^id, lock: "FOR UPDATE")

  defp lock_binding(_conflict), do: nil

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}
end
