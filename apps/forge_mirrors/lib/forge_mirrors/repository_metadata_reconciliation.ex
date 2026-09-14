defmodule ForgeMirrors.RepositoryMetadataReconciliation do
  @moduledoc false

  import Ecto.Query

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
    RepositoryMirror,
    ResourceDecision
  }

  alias Fornacast.Repo

  @kind "reconcile.repository.metadata"
  @fields ~w(name description visibility default_branch archived)
  @effect_keys ~w(action baseline_lock_version expected_local_write_version expected_remote expected_remote_updated_at target target_fingerprint)

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
           local_snapshot: local_snapshot(repository),
           local_preimage: local_preimage(repository),
           local_write_version: repository.write_version,
           local_generation: repository.generation,
           owner_user_id: repository.owner_user_id,
           effect_marker: operation.external_effect_marker,
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

  def record(%MirrorOperation{} = supplied, remote, %DateTime{} = now) when is_map(remote) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           {:ok, binding, organization, repository} <- scope(operation),
           {:ok, remote_snapshot, remote_updated_at} <- remote_snapshot(remote, binding),
           local_snapshot <- local_snapshot(repository),
           baseline <- baseline(binding.id) do
        if operation.state == :effect_pending do
          recover_effect(
            operation,
            binding,
            organization,
            repository,
            local_snapshot,
            remote_snapshot,
            remote_updated_at,
            now
          )
        else
          reconcile(
            operation,
            binding,
            organization,
            repository,
            baseline,
            local_snapshot,
            remote_snapshot,
            remote_updated_at,
            now
          )
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def record(_, _, _), do: {:error, :invalid_argument}

  def defer_effect(
        %MirrorOperation{state: :effect_pending} = supplied,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        failure_class
      )
      when failure_class in ["network", "primary_rate_limit", "secondary_rate_limit"] do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           true <- operation.state == :effect_pending and is_map(operation.external_effect_marker),
           {:ok, deferred} <-
             transition(operation, now, :effect_pending,
               next_attempt_at: DateTime.truncate(next_attempt_at, :second),
               lease_owner: nil,
               lease_expires_at: nil,
               failure_class: failure_class,
               failure_disposition: :retry,
               failure_detail: "remote repository metadata effect requires canonical recheck"
             ) do
        deferred
      else
        false -> Repo.rollback(:invalid_transition)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def defer_effect(%MirrorOperation{}, %DateTime{}, %DateTime{}, _failure_class),
    do: {:error, :invalid_transition}

  def defer_effect(_, _, _, _), do: {:error, :invalid_argument}

  defp reconcile(
         operation,
         binding,
         organization,
         repository,
         baseline,
         local,
         remote,
         remote_updated_at,
         now
       ) do
    case decide(baseline, local, remote) do
      {:ok, :confirm, target} ->
        confirm(operation, binding, repository.write_version, target, remote_updated_at, now)

      {:ok, :apply_local, target} ->
        case apply_local(repository, binding, operation, target) do
          {:ok, updated} ->
            case confirm(
                   operation,
                   binding,
                   updated.write_version,
                   target,
                   remote_updated_at,
                   now
                 ) do
              {:ok, result} -> result
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            persist_apply_error(
              reason,
              operation,
              binding,
              organization,
              baseline,
              local,
              remote,
              now
            )
        end

      {:ok, :update_remote, target} ->
        case validate_outbound_target(target) do
          :ok ->
            case mark_remote_effect(
                   operation,
                   binding,
                   baseline,
                   repository.write_version,
                   remote,
                   remote_updated_at,
                   target,
                   now
                 ) do
              {:ok, result} -> result
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            persist_apply_error(
              reason,
              operation,
              binding,
              organization,
              baseline,
              local,
              remote,
              now
            )
        end

      {:ok, :apply_both, target} ->
        with :ok <- validate_outbound_target(target),
             {:ok, updated} <- apply_local(repository, binding, operation, target) do
          case mark_remote_effect(
                 operation,
                 binding,
                 baseline,
                 updated.write_version,
                 remote,
                 remote_updated_at,
                 target,
                 now
               ) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} ->
            persist_apply_error(
              reason,
              operation,
              binding,
              organization,
              baseline,
              local,
              remote,
              now
            )
        end

      {:conflict, kind} ->
        persist_conflict(
          operation,
          binding,
          organization,
          baseline,
          local,
          remote,
          kind,
          "stale_baseline",
          now
        )
    end
  end

  defp recover_effect(
         operation,
         binding,
         organization,
         _repository,
         local,
         remote,
         remote_updated_at,
         now
       ) do
    with {:ok, effect} <- validate_effect(operation.external_effect_marker, binding),
         true <- baseline_lock_version(binding.id) == effect["baseline_lock_version"] do
      cond do
        remote == effect["target"] ->
          confirm(
            operation,
            binding,
            effect["expected_local_write_version"],
            effect["target"],
            remote_updated_at,
            now
          )

        remote == effect["expected_remote"] and
            DateTime.to_iso8601(remote_updated_at) == effect["expected_remote_updated_at"] ->
          {:ok,
           %{
             action: :update_remote,
             operation: operation,
             target: effect["target"]
           }}

        true ->
          persist_conflict(
            operation,
            binding,
            organization,
            baseline(binding.id),
            local,
            remote,
            "repository_metadata_effect_ambiguous",
            "stale_baseline",
            now
          )
      end
    else
      false -> {:error, :stale_baseline}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decide(nil, local, remote) do
    if local == remote,
      do: {:ok, :confirm, remote},
      else: {:conflict, "repository_metadata_diverged"}
  end

  defp decide(%MirrorResourceState{confirmed_snapshot: baseline}, local, remote)
       when is_map(baseline) do
    if Enum.sort(Map.keys(baseline)) == Enum.sort(@fields) do
      decisions =
        Map.new(@fields, fn field ->
          {field, ResourceDecision.scalar(baseline[field], local[field], remote[field])}
        end)

      if Enum.any?(decisions, fn {_field, decision} -> match?({:conflict, _}, decision) end) do
        {:conflict, "repository_metadata_diverged"}
      else
        target = Map.new(decisions, fn {field, decision} -> {field, decision_value(decision)} end)

        action =
          case {target != local, target != remote} do
            {false, false} -> :confirm
            {true, false} -> :apply_local
            {false, true} -> :update_remote
            {true, true} -> :apply_both
          end

        {:ok, action, target}
      end
    else
      {:conflict, "repository_metadata_invalid_baseline"}
    end
  end

  defp decide(%MirrorResourceState{}, _local, _remote),
    do: {:conflict, "repository_metadata_invalid_baseline"}

  defp decision_value(decision), do: elem(decision, tuple_size(decision) - 1)

  defp apply_local(repository, binding, operation, target) do
    if target["archived"] == false and target["visibility"] in ["public", "private"] do
      ForgeRepos.sync_github_repository_metadata(%{
        repository_id: repository.id,
        owner_user_id: repository.owner_user_id,
        generation: repository.generation,
        write_version: repository.write_version,
        expected: local_preimage(repository),
        remote: %{
          name: target["name"],
          description: target["description"],
          visibility: String.to_existing_atom(target["visibility"]),
          default_branch: target["default_branch"]
        },
        causation_id: "github:repository:#{binding.github_repository_id}",
        correlation_id: operation_correlation(operation, binding)
      })
    else
      {:error, :unsupported_remote_metadata}
    end
  end

  defp operation_correlation(operation, binding) do
    operation.cursor["correlation_id"] || "mirror:repository:#{binding.id}"
  end

  defp mark_remote_effect(
         operation,
         _binding,
         baseline,
         local_write_version,
         remote,
         remote_updated_at,
         target,
         now
       ) do
    with {:ok, target_fingerprint} <- ForgeMirrors.resource_fingerprint(target),
         {:ok, marked} <-
           ForgeMirrors.mark_external_effect(operation, now, %{
             "action" => "update_remote_repository_metadata",
             "baseline_lock_version" => if(baseline, do: baseline.lock_version, else: 0),
             "expected_local_write_version" => local_write_version,
             "expected_remote" => remote,
             "expected_remote_updated_at" => DateTime.to_iso8601(remote_updated_at),
             "target" => target,
             "target_fingerprint" => target_fingerprint
           }) do
      {:ok, %{action: :update_remote, operation: marked, target: target}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_outbound_target(target) do
    if target["visibility"] in ["public", "private"] and target["archived"] == false and
         is_binary(target["name"]) and byte_size(target["name"]) in 1..100,
       do: :ok,
       else: {:error, :unsupported_remote_metadata}
  end

  defp validate_effect(marker, binding) when is_map(marker) do
    with true <- Enum.sort(Map.keys(marker)) == Enum.sort(@effect_keys),
         true <- marker["action"] == "update_remote_repository_metadata",
         true <-
           is_integer(marker["baseline_lock_version"]) and marker["baseline_lock_version"] >= 0,
         true <-
           is_integer(marker["expected_local_write_version"]) and
             marker["expected_local_write_version"] >= 0,
         true <- valid_snapshot?(marker["expected_remote"]),
         true <- valid_snapshot?(marker["target"]),
         true <- valid_iso8601?(marker["expected_remote_updated_at"]),
         {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(marker["target"]),
         true <- fingerprint == marker["target_fingerprint"],
         true <- binding.github_repository_id > 0 do
      {:ok, marker}
    else
      _ -> {:error, :invalid_effect_marker}
    end
  end

  defp validate_effect(_marker, _binding), do: {:error, :invalid_effect_marker}

  defp baseline_lock_version(binding_id) do
    case baseline(binding_id) do
      nil -> 0
      state -> state.lock_version
    end
  end

  defp persist_apply_error(
         reason,
         operation,
         binding,
         organization,
         baseline,
         local,
         remote,
         now
       ) do
    {kind, failure_class} =
      case reason do
        :namespace_collision ->
          {"repository_namespace_collision", "namespace_collision"}

        :unsupported_remote_metadata ->
          {"repository_metadata_unsupported", "unsupported_resource"}

        _ ->
          {"repository_metadata_local_rejected", "local_validation"}
      end

    persist_conflict(
      operation,
      binding,
      organization,
      baseline,
      local,
      remote,
      kind,
      failure_class,
      now
    )
  end

  defp confirm(operation, binding, local_version, snapshot, updated_at, now) do
    with {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(snapshot),
         {:ok, binding} <- update_binding_metadata(binding, snapshot, now),
         attrs = %{
           repository_mirror_id: binding.id,
           resource_kind: :repository,
           local_resource_type: "ForgeRepos.Repository",
           local_resource_id: binding.repository_id,
           github_object_id: binding.github_repository_id,
           github_node_id: binding.github_node_id,
           confirmed_local_version: if(local_version > 0, do: local_version),
           confirmed_remote_updated_at: updated_at,
           confirmed_snapshot: snapshot,
           confirmed_fingerprint: fingerprint,
           state: :confirmed,
           lock_version: 1
         },
         state = baseline(binding.id),
         {:ok, state} <- persist_baseline(state, attrs),
         {:ok, completed} <- complete(operation, now),
         :ok <- ForgeMirrors.activate_repository_after_metadata(completed, now) do
      {:ok, %{action: :confirmed, operation: completed, baseline: state}}
    end
  end

  defp update_binding_metadata(binding, snapshot, now) do
    owner = binding.github_full_name |> String.split("/", parts: 2) |> hd()

    binding
    |> RepositoryMirror.metadata_update_changeset(%{
      github_full_name: "#{owner}/#{snapshot["name"]}",
      github_archived: snapshot["archived"],
      last_synced_at: now
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
  end

  defp persist_conflict(
         operation,
         binding,
         organization,
         baseline,
         local,
         remote,
         kind,
         failure_class,
         now
       ) do
    attrs = %{
      organization_mirror_id: organization.id,
      repository_mirror_id: binding.id,
      resource_kind: "repository",
      resource_identity: Integer.to_string(binding.github_repository_id),
      conflict_kind: kind,
      baseline_snapshot: if(baseline, do: baseline.confirmed_snapshot || %{}, else: %{}),
      local_snapshot: local,
      remote_snapshot: remote
    }

    with {:ok, conflict} <- insert_conflict(attrs),
         {:ok, failed} <- fail_conflict(operation, now, failure_class, kind) do
      {:ok, %{action: :conflict, operation: failed, conflict: conflict}}
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
         {:ok, repository} <- ForgeRepos.lock_repository_for_sync(repository_id),
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

    if current && current.kind == @kind && current.state == operation.state &&
         current.state in [:processing, :effect_pending] &&
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
         snapshot <- %{
           "name" => remote[:name] || remote["name"],
           "description" => Map.get(remote, :description, remote["description"]),
           "visibility" => remote[:visibility] || remote["visibility"],
           "default_branch" => remote[:default_branch] || remote["default_branch"],
           "archived" => Map.get(remote, :archived, remote["archived"])
         },
         snapshot <-
           Map.update!(snapshot, "visibility", fn
             value when is_atom(value) -> Atom.to_string(value)
             value -> value
           end),
         true <- valid_snapshot?(snapshot),
         %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = updated_at <-
           remote[:updated_at] || remote["updated_at"] do
      {:ok, snapshot, DateTime.truncate(updated_at, :second)}
    else
      _ -> {:error, :invalid_remote_resource}
    end
  end

  defp local_snapshot(repository) do
    %{
      "name" => repository.slug,
      "description" => repository.description,
      "visibility" => Atom.to_string(repository.visibility),
      "default_branch" => repository.default_branch,
      "archived" => false
    }
  end

  defp local_preimage(repository) do
    Map.take(repository, [:name, :slug, :description, :visibility, :default_branch])
  end

  defp valid_snapshot?(snapshot) when is_map(snapshot) do
    Enum.sort(Map.keys(snapshot)) == Enum.sort(@fields) and valid_string?(snapshot["name"]) and
      (is_nil(snapshot["description"]) or
         (is_binary(snapshot["description"]) and byte_size(snapshot["description"]) <= 1_000 and
            String.valid?(snapshot["description"]) and
            not String.contains?(snapshot["description"], <<0>>))) and
      snapshot["visibility"] in ["public", "private", "internal"] and
      valid_string?(snapshot["default_branch"]) and is_boolean(snapshot["archived"])
  end

  defp valid_snapshot?(_), do: false

  defp valid_iso8601?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_iso8601?(_), do: false

  defp complete(operation, now) do
    transition(operation, now, :completed,
      completed_at: now,
      lease_owner: nil,
      lease_expires_at: nil,
      external_effect_marker: nil,
      effect_marked_at: nil,
      failure_class: nil,
      failure_disposition: nil,
      failure_detail: nil
    )
  end

  defp fail_conflict(operation, now, failure_class, detail) do
    {:ok, disposition} = MirrorOperation.failure_disposition(failure_class)

    transition(operation, now, :failed,
      lease_owner: nil,
      lease_expires_at: nil,
      external_effect_marker: nil,
      effect_marked_at: nil,
      failure_class: failure_class,
      failure_disposition: disposition,
      failure_detail: detail
    )
  end

  defp transition(operation, now, state, attrs) do
    {count, _} =
      Repo.update_all(
        from(candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state == ^operation.state and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lock_version == ^operation.lock_version
        ),
        set: [state: state, updated_at: now] ++ attrs,
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
  defp unwrap({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
