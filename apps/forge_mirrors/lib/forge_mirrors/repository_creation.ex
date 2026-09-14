defmodule ForgeMirrors.RepositoryCreation do
  @moduledoc false

  import Ecto.Query

  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
    RepositoryCreationPolicy,
    RepositoryMirror
  }

  @kind "sync.repository.create"

  def context(%MirrorOperation{} = supplied) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           {:ok, scope} <- lock_scope(operation) do
        scope
        |> Map.put(:effect_marker, operation.external_effect_marker)
        |> recovery_target(operation)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def context(_), do: {:error, :invalid_transition}

  def mark_effect(%MirrorOperation{} = supplied, expected, %DateTime{} = now)
      when is_map(expected) do
    Repo.transaction(fn ->
      with :ok <- validate_utc(now),
           {:ok, operation} <- lock_owned(supplied),
           true <- operation.state == :processing and is_nil(operation.external_effect_marker),
           {:ok, scope} <- lock_scope(operation),
           true <- same_scope?(scope, expected),
           {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(scope.target),
           marker = marker(scope, fingerprint),
           {:ok, marked} <- transition_to_effect(operation, marker, now) do
        marked
      else
        false -> Repo.rollback(:stale)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def mark_effect(%MirrorOperation{}, _expected, %DateTime{}),
    do: {:error, :invalid_argument}

  def mark_effect(_, _, _), do: {:error, :invalid_argument}

  def authorize_effect(%MirrorOperation{state: :effect_pending} = supplied) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           {:ok, scope} <- lock_scope(operation),
           {:ok, marker} <- validate_marker(operation.external_effect_marker, scope) do
        scope
        |> Map.put(:effect_marker, marker)
        |> recovery_target(operation)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def authorize_effect(%MirrorOperation{}), do: {:error, :invalid_transition}
  def authorize_effect(_), do: {:error, :invalid_argument}

  def confirm(%MirrorOperation{state: :effect_pending} = supplied, remote, %DateTime{} = now)
      when is_map(remote) do
    Repo.transaction(fn ->
      with :ok <- validate_utc(now),
           {:ok, operation} <- lock_owned(supplied),
           {:ok, scope} <- lock_scope(operation),
           {:ok, marker} <- validate_marker(operation.external_effect_marker, scope),
           {:ok, remote} <- normalize_remote(remote, scope),
           :ok <- validate_remote_unmapped(remote, scope.repository_mirror_id),
           true <- creation_matches?(marker["target"], remote.snapshot),
           {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(remote.snapshot),
           {:ok, binding} <- bind_remote(scope.binding, remote, now),
           {:ok, baseline} <- persist_baseline(binding, scope, marker, remote, fingerprint),
           {:ok, completed} <- ForgeMirrors.complete_operation(operation, now),
           {:ok, git_reconciliation} <- enqueue_git_reconciliation(completed, binding, now) do
        %{
          operation: completed,
          binding: binding,
          baseline: baseline,
          git_reconciliation: git_reconciliation
        }
      else
        false -> Repo.rollback(:namespace_collision)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def confirm(%MirrorOperation{}, _remote, %DateTime{}),
    do: {:error, :invalid_transition}

  def confirm(_, _, _), do: {:error, :invalid_argument}

  def defer_effect(
        %MirrorOperation{state: :effect_pending} = supplied,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        failure_class
      )
      when failure_class in ["network", "primary_rate_limit", "secondary_rate_limit"] do
    Repo.transaction(fn ->
      with :ok <- validate_utc(now),
           :ok <- validate_utc(next_attempt_at),
           {:ok, operation} <- lock_owned(supplied),
           true <- is_map(operation.external_effect_marker),
           {:ok, deferred} <-
             defer_transition(operation, now, next_attempt_at, failure_class) do
        deferred
      else
        false -> Repo.rollback(:invalid_effect_marker)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def defer_effect(%MirrorOperation{}, %DateTime{}, %DateTime{}, _failure_class),
    do: {:error, :invalid_transition}

  def defer_effect(_, _, _, _), do: {:error, :invalid_argument}

  def conflict(
        %MirrorOperation{} = supplied,
        remote,
        kind,
        %DateTime{} = now
      )
      when is_map(remote) and is_binary(kind) and byte_size(kind) in 1..255 do
    Repo.transaction(fn ->
      with :ok <- validate_utc(now),
           {:ok, operation} <- lock_owned(supplied),
           {:ok, scope} <- lock_scope(operation),
           {:ok, remote} <- normalize_remote(remote, scope),
           {:ok, conflict} <- persist_conflict(operation, scope, remote, kind),
           {:ok, failed} <-
             ForgeMirrors.fail_operation(operation, now, "namespace_collision", kind) do
        %{operation: failed, conflict: conflict}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def conflict(%MirrorOperation{}, _remote, _kind, %DateTime{}),
    do: {:error, :invalid_argument}

  def conflict(_, _, _, _), do: {:error, :invalid_argument}

  def halt_effect(
        %MirrorOperation{state: :effect_pending} = supplied,
        %DateTime{} = now,
        failure_class
      )
      when failure_class in ["credential_revoked", "permission_missing", "local_validation"] do
    Repo.transaction(fn ->
      with :ok <- validate_utc(now),
           {:ok, disposition} <- ForgeMirrors.failure_disposition(failure_class),
           {:ok, operation} <- lock_owned(supplied),
           true <- is_map(operation.external_effect_marker),
           {:ok, halted} <- halt_transition(operation, now, failure_class, disposition) do
        halted
      else
        false -> Repo.rollback(:invalid_effect_marker)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def halt_effect(%MirrorOperation{}, %DateTime{}, _failure_class),
    do: {:error, :invalid_transition}

  def halt_effect(_, _, _), do: {:error, :invalid_argument}

  def pause(%MirrorOperation{} = supplied, %DateTime{} = now) do
    Repo.transaction(fn ->
      with :ok <- validate_utc(now),
           {:ok, operation} <- lock_owned(supplied),
           {:ok, paused} <- pause_transition(operation, now) do
        paused
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def pause(_, _), do: {:error, :invalid_argument}

  defp lock_scope(operation) do
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
           organization_mirror_id: organization_mirror_id,
           repository_id: repository_id,
           github_repository_id: nil,
           github_node_id: nil,
           state: :discovered
         } = binding <- binding,
         true <- organization_mirror_id == operation.organization_mirror_id,
         %OrganizationMirror{
           provider: "github",
           state: organization_state,
           github_installation_id: installation_id,
           github_account_id: account_id,
           github_account_login: account_login
         } = organization <- organization,
         :ok <- validate_organization_state(organization_state),
         :ok <- RepositoryCreationPolicy.authorize(organization.policy, organization.capabilities),
         installation <-
           Repo.one(
             from installation in GitHubAppInstallation,
               where: installation.github_installation_id == ^installation_id,
               lock: "FOR UPDATE"
           ),
         {:ok, permissions} <- validate_installation(installation, account_id),
         :ok <- validate_admin_permission(permissions),
         {:ok, repository} <- ForgeRepos.lock_repository_for_sync(repository_id),
         true <- repository.owner_user_id == organization.organization_id do
      {:ok,
       %{
         binding: binding,
         repository_mirror_id: binding.id,
         repository_id: repository.id,
         repository_generation: repository.generation,
         local_write_version: repository.write_version,
         github_repository_id: nil,
         github_installation_id: installation_id,
         github_account_id: account_id,
         github_account_login: account_login,
         target: local_snapshot(repository)
       }}
    else
      false -> {:error, :invalid_transition}
      nil -> {:error, :invalid_transition}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_transition}
    end
  end

  defp validate_organization_state(:paused), do: {:error, :paused}
  defp validate_organization_state(:revoked), do: {:error, :revoked}

  defp validate_organization_state(state)
       when state in [:catching_up, :active, :degraded, :conflicted],
       do: :ok

  defp validate_organization_state(_state), do: {:error, :invalid_transition}

  defp validate_installation(
         %GitHubAppInstallation{state: :active, github_account_id: account_id} = installation,
         account_id
       ),
       do: {:ok, installation.permissions}

  defp validate_installation(%GitHubAppInstallation{state: :revoked}, _account_id),
    do: {:error, :revoked}

  defp validate_installation(%GitHubAppInstallation{state: :suspended}, _account_id),
    do: {:error, :credential_unavailable}

  defp validate_installation(_installation, _account_id), do: {:error, :invalid_transition}

  defp validate_admin_permission(%{"administration" => "write"}), do: :ok
  defp validate_admin_permission(_permissions), do: {:error, :permission_missing}

  defp lock_owned(operation) do
    current =
      Repo.one(
        from candidate in MirrorOperation,
          where: candidate.id == ^operation.id,
          lock: "FOR UPDATE"
      )

    if current && current.kind == @kind && current.state == operation.state &&
         current.state in [:processing, :effect_pending] &&
         current.repository_mirror_id == operation.repository_mirror_id &&
         current.organization_mirror_id == operation.organization_mirror_id &&
         current.lease_owner == operation.lease_owner &&
         current.lease_expires_at == operation.lease_expires_at &&
         current.lock_version == operation.lock_version && current.cursor == operation.cursor &&
         current.lease_expires_at > DateTime.utc_now(:second),
       do: {:ok, current},
       else: {:error, :lost_lease}
  end

  defp transition_to_effect(operation, marker, now) do
    now = DateTime.truncate(now, :second)

    {count, _} =
      Repo.update_all(
        from(candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state == :processing and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lock_version == ^operation.lock_version
        ),
        set: [
          state: :effect_pending,
          external_effect_marker: marker,
          effect_marked_at: now,
          updated_at: now
        ],
        inc: [lock_version: 1]
      )

    if count == 1,
      do: {:ok, Repo.get!(MirrorOperation, operation.id)},
      else: {:error, :lost_lease}
  end

  defp defer_transition(operation, now, next_attempt_at, failure_class) do
    now = DateTime.truncate(now, :second)
    next_attempt_at = DateTime.truncate(next_attempt_at, :second)

    {count, _} =
      Repo.update_all(
        from(candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state == :effect_pending and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lock_version == ^operation.lock_version
        ),
        set: [
          next_attempt_at: next_attempt_at,
          lease_owner: nil,
          lease_expires_at: nil,
          failure_class: failure_class,
          failure_disposition: :retry,
          failure_detail: "remote repository creation requires canonical recheck",
          updated_at: now
        ],
        inc: [lock_version: 1]
      )

    if count == 1,
      do: {:ok, Repo.get!(MirrorOperation, operation.id)},
      else: {:error, :lost_lease}
  end

  defp halt_transition(operation, now, failure_class, disposition) do
    now = DateTime.truncate(now, :second)

    checkpoint =
      Map.put(
        operation.checkpoint || %{},
        "halted_external_effect",
        operation.external_effect_marker
      )

    {count, _} =
      Repo.update_all(
        from(candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state == :effect_pending and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lock_version == ^operation.lock_version
        ),
        set: [
          state: :failed,
          lease_owner: nil,
          lease_expires_at: nil,
          checkpoint: checkpoint,
          external_effect_marker: nil,
          effect_marked_at: nil,
          failure_class: failure_class,
          failure_disposition: disposition,
          failure_detail: "remote repository creation outcome remains ambiguous",
          updated_at: now
        ],
        inc: [lock_version: 1]
      )

    if count == 1,
      do: {:ok, Repo.get!(MirrorOperation, operation.id)},
      else: {:error, :lost_lease}
  end

  defp pause_transition(operation, now) do
    now = DateTime.truncate(now, :second)
    target_state = if operation.state == :effect_pending, do: :effect_pending, else: :pending

    {count, _} =
      Repo.update_all(
        from(candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state == ^operation.state and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lock_version == ^operation.lock_version
        ),
        set: [
          state: target_state,
          next_attempt_at: now,
          lease_owner: nil,
          lease_expires_at: nil,
          failure_class: nil,
          failure_disposition: nil,
          failure_detail: nil,
          updated_at: now
        ],
        inc: [lock_version: 1]
      )

    if count == 1,
      do: {:ok, Repo.get!(MirrorOperation, operation.id)},
      else: {:error, :lost_lease}
  end

  defp bind_remote(binding, remote, now) do
    binding
    |> RepositoryMirror.update_changeset(%{
      github_repository_id: remote.id,
      github_node_id: remote.node_id,
      github_full_name: remote.full_name,
      github_archived: remote.snapshot["archived"],
      last_synced_at: DateTime.truncate(now, :second)
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp persist_baseline(binding, scope, marker, remote, fingerprint) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: binding.id,
      resource_kind: :repository,
      local_resource_type: "ForgeRepos.Repository",
      local_resource_id: scope.repository_id,
      github_object_id: remote.id,
      github_node_id: remote.node_id,
      confirmed_local_version:
        if(marker["expected_local_write_version"] > 0,
          do: marker["expected_local_write_version"],
          else: nil
        ),
      confirmed_remote_updated_at: remote.updated_at,
      confirmed_snapshot: remote.snapshot,
      confirmed_fingerprint: fingerprint,
      state: :confirmed,
      lock_version: 1
    })
    |> Repo.insert()
  end

  defp enqueue_git_reconciliation(operation, binding, now) do
    ForgeMirrors.enqueue_operation(%{
      organization_mirror_id: operation.organization_mirror_id,
      repository_mirror_id: binding.id,
      kind: "reconcile.repository.git",
      dedupe_key: "repository-create:#{operation.id}:git",
      cursor: %{
        "trigger" => "repository_creation",
        "repository_creation_operation_id" => operation.id,
        "post_git_metadata_reconciliation" => true
      },
      next_attempt_at: DateTime.truncate(now, :second)
    })
  end

  defp persist_conflict(operation, scope, remote, kind) do
    attrs = %{
      organization_mirror_id: operation.organization_mirror_id,
      repository_mirror_id: scope.repository_mirror_id,
      resource_kind: "repository",
      resource_identity: Integer.to_string(remote.id),
      conflict_kind: kind,
      baseline_snapshot: %{},
      local_snapshot: scope.target,
      remote_snapshot: remote.snapshot
    }

    existing =
      Repo.one(
        from conflict in MirrorConflict,
          where:
            conflict.organization_mirror_id == ^operation.organization_mirror_id and
              conflict.repository_mirror_id == ^scope.repository_mirror_id and
              conflict.resource_kind == "repository" and
              conflict.resource_identity == ^attrs.resource_identity and conflict.state == :open,
          lock: "FOR UPDATE"
      )

    case existing do
      nil ->
        Repo.insert(MirrorConflict.record_changeset(%MirrorConflict{}, attrs))

      %MirrorConflict{} = conflict ->
        conflict
        |> Ecto.Changeset.change(
          conflict_kind: kind,
          local_snapshot: scope.target,
          remote_snapshot: remote.snapshot
        )
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
    end
  end

  defp normalize_remote(remote, scope) do
    visibility = remote[:visibility] || remote["visibility"]
    visibility = if is_atom(visibility), do: Atom.to_string(visibility), else: visibility

    snapshot = %{
      "name" => remote[:name] || remote["name"],
      "description" => Map.get(remote, :description, remote["description"]),
      "visibility" => visibility,
      "default_branch" => remote[:default_branch] || remote["default_branch"],
      "archived" => Map.get(remote, :archived, remote["archived"])
    }

    id = remote[:id] || remote["id"]
    node_id = remote[:node_id] || remote["node_id"]
    owner_id = remote[:owner_id] || remote["owner_id"]
    owner_login = remote[:owner_login] || remote["owner_login"]
    full_name = remote[:full_name] || remote["full_name"]
    updated_at = remote[:updated_at] || remote["updated_at"]

    if positive?(id) and valid_string?(node_id, 255) and owner_id == scope.github_account_id and
         owner_login == scope.github_account_login and
         full_name == "#{owner_login}/#{snapshot["name"]}" and valid_snapshot?(snapshot) and
         valid_utc?(updated_at) do
      {:ok,
       %{
         id: id,
         node_id: node_id,
         full_name: full_name,
         snapshot: snapshot,
         updated_at: DateTime.truncate(updated_at, :second)
       }}
    else
      {:error, :invalid_remote_resource}
    end
  end

  defp validate_remote_unmapped(remote, binding_id) do
    conflict =
      Repo.exists?(
        from binding in RepositoryMirror,
          where:
            binding.id != ^binding_id and binding.state != :tombstoned and
              (binding.github_repository_id == ^remote.id or
                 binding.github_node_id == ^remote.node_id)
      )

    if conflict, do: {:error, :identity_conflict}, else: :ok
  end

  defp validate_marker(marker, scope) when is_map(marker) do
    with true <- marker["action"] == "create_remote_repository",
         true <- marker["expected_absence"] == true,
         true <- marker["repository_id"] == scope.repository_id,
         true <- marker["repository_generation"] == scope.repository_generation,
         expected_version when is_integer(expected_version) and expected_version >= 0 <-
           marker["expected_local_write_version"],
         true <- expected_version <= scope.local_write_version,
         true <- marker["github_account_id"] == scope.github_account_id,
         true <- marker["github_account_login"] == scope.github_account_login,
         target when is_map(target) <- marker["target"],
         true <- valid_snapshot?(target),
         {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(target),
         true <- marker["target_fingerprint"] == fingerprint do
      {:ok, marker}
    else
      _invalid -> {:error, :invalid_effect_marker}
    end
  end

  defp validate_marker(_marker, _scope), do: {:error, :invalid_effect_marker}

  defp marker(scope, fingerprint) do
    %{
      "action" => "create_remote_repository",
      "expected_absence" => true,
      "repository_id" => scope.repository_id,
      "repository_generation" => scope.repository_generation,
      "expected_local_write_version" => scope.local_write_version,
      "github_account_id" => scope.github_account_id,
      "github_account_login" => scope.github_account_login,
      "target" => scope.target,
      "target_fingerprint" => fingerprint
    }
  end

  defp same_scope?(scope, expected) do
    Enum.all?(
      [
        :repository_mirror_id,
        :repository_id,
        :repository_generation,
        :local_write_version,
        :github_installation_id,
        :github_account_id,
        :github_account_login,
        :target
      ],
      &(Map.get(scope, &1) == Map.get(expected, &1))
    )
  end

  defp recovery_target(
         scope,
         %MirrorOperation{state: :effect_pending, external_effect_marker: marker}
       )
       when is_map(marker) do
    case marker["target"] do
      target when is_map(target) -> Map.put(scope, :target, target)
      _invalid -> scope
    end
  end

  defp recovery_target(scope, _operation), do: scope

  defp local_snapshot(repository) do
    %{
      "name" => repository.slug,
      "description" => repository.description,
      "visibility" => Atom.to_string(repository.visibility),
      "default_branch" => repository.default_branch,
      "archived" => false
    }
  end

  defp creation_matches?(target, remote) do
    Enum.all?(~w(name description visibility archived), &(target[&1] == remote[&1]))
  end

  defp valid_snapshot?(snapshot) do
    valid_string?(snapshot["name"], 100) and
      (is_nil(snapshot["description"]) or valid_optional_string?(snapshot["description"], 1_000)) and
      snapshot["visibility"] in ["public", "private"] and
      valid_string?(snapshot["default_branch"], 255) and is_boolean(snapshot["archived"])
  end

  defp positive?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807

  defp valid_string?(value, maximum) when is_binary(value) do
    byte_size(value) in 1..maximum and String.valid?(value) and value == String.trim(value) and
      not String.contains?(value, <<0>>)
  end

  defp valid_string?(_, _), do: false

  defp valid_optional_string?(value, maximum) when is_binary(value) do
    byte_size(value) <= maximum and String.valid?(value) and value == String.trim(value) and
      not String.contains?(value, <<0>>)
  end

  defp valid_optional_string?(_, _), do: false

  defp valid_utc?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: true
  defp valid_utc?(_), do: false
  defp validate_utc(value), do: if(valid_utc?(value), do: :ok, else: {:error, :invalid_argument})

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
