defmodule ForgeMirrors.RepositoryMetadataReconciliation do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
    RepositoryMetadataRepresentationPolicy,
    RepositoryMirror,
    ResourceDecision
  }

  alias Fornacast.Repo

  @kind "reconcile.repository.metadata"
  @fields ~w(name description visibility default_branch archived)
  @representation_conflict_kinds ~w(
    repository_archived_unrepresentable
    repository_internal_visibility_unrepresentable
    repository_archived_internal_unrepresentable
  )
  @resolution_actions ~w(accept_github keep_fornacast external_recheck)
  @resolution_keys ~w(action actor_id baseline_fingerprint conflict_id conflict_lock_version local_fingerprint remote_fingerprint v)
  @legacy_effect_keys ~w(action baseline_lock_version expected_local_write_version expected_remote expected_remote_updated_at target target_fingerprint)
  @effect_keys ~w(action attempt_state baseline_lock_version expected_local_write_version expected_remote expected_remote_updated_at target target_fingerprint)

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
           {:ok, binding} <- observe_remote_metadata(binding, remote_snapshot, now),
           local_snapshot <- local_snapshot(repository),
           baseline <- baseline(binding.id) do
        operator_resolution(
          operation,
          binding,
          organization,
          baseline,
          local_snapshot,
          remote_snapshot
        )
        |> case do
          :none ->
            reconcile_observation(
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

          {:ok, %{action: "external_recheck"}} ->
            reconcile_observation(
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

          {:ok, _directive} when operation.state == :effect_pending ->
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

          {:ok, directive} ->
            resolve_operator_decision(
              directive,
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

          {:stale, _conflict} ->
            persist_conflict(
              operation,
              binding,
              organization,
              baseline,
              local_snapshot,
              remote_snapshot,
              "repository_metadata_resolution_stale",
              "stale_baseline",
              now
            )

          {:unauthorized, _conflict} ->
            persist_conflict(
              operation,
              binding,
              organization,
              baseline,
              local_snapshot,
              remote_snapshot,
              "repository_metadata_resolution_unauthorized",
              "permission_missing",
              now
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
        |> finalize_operator_outcome(operation)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def record(_, _, _), do: {:error, :invalid_argument}

  def defer(
        %MirrorOperation{state: :processing} = supplied,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        "paused"
      ) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           true <- operation.state == :processing and is_nil(operation.external_effect_marker),
           {:ok, deferred} <-
             transition(operation, now, :pending,
               next_attempt_at: DateTime.truncate(next_attempt_at, :second),
               lease_owner: nil,
               lease_expires_at: nil,
               failure_class: nil,
               failure_disposition: nil,
               failure_detail: nil
             ) do
        deferred
      else
        false -> Repo.rollback(:invalid_transition)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def defer(%MirrorOperation{}, %DateTime{}, %DateTime{}, _reason),
    do: {:error, :invalid_transition}

  def defer(_, _, _, _), do: {:error, :invalid_argument}

  def defer_effect(
        %MirrorOperation{state: :effect_pending} = supplied,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        failure_class
      )
      when failure_class in ["network", "paused", "primary_rate_limit", "secondary_rate_limit"] do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           true <- operation.state == :effect_pending and is_map(operation.external_effect_marker),
           {:ok, deferred} <-
             transition(
               operation,
               now,
               :effect_pending,
               deferred_effect_attrs(next_attempt_at, failure_class)
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

  @doc false
  def fail(%MirrorOperation{} = operation, %DateTime{} = now, failure_class, failure_detail) do
    Repo.transaction(fn ->
      with {:ok, failed} <-
             ForgeMirrors.fail_operation(operation, now, failure_class, failure_detail),
           {:ok, _audit} <-
             maybe_audit_operator_outcome(operation, :failed, %{
               "failure_class" => failure_class,
               "failure_detail" => failure_detail
             }) do
        failed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def fail(_, _, _, _), do: {:error, :invalid_argument}

  @doc false
  def authorize_effect(
        %MirrorOperation{state: :effect_pending} = supplied,
        %DateTime{} = now
      ) do
    Repo.transaction(fn ->
      with {:ok, operation} <- lock_owned(supplied),
           {:ok, binding, organization, _repository} <- scope(operation),
           {:ok, effect} <- validate_effect(operation.external_effect_marker, binding) do
        case operation.cursor["operator_resolution"] do
          nil ->
            operation

          marker when is_map(marker) ->
            authorize_operator_effect(operation, binding, organization, marker, effect, now)

          _invalid ->
            Repo.rollback(:invalid_resolution)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap()
  end

  def authorize_effect(%MirrorOperation{}, %DateTime{}), do: {:error, :invalid_transition}
  def authorize_effect(_, _), do: {:error, :invalid_argument}

  defp reconcile_observation(
         operation,
         binding,
         organization,
         repository,
         baseline,
         local_snapshot,
         remote_snapshot,
         remote_updated_at,
         now
       ) do
    case RepositoryMetadataRepresentationPolicy.classify(remote_snapshot) do
      :representable ->
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

      {:unrepresentable, kind} ->
        persist_conflict(
          operation,
          binding,
          organization,
          baseline,
          local_snapshot,
          remote_snapshot,
          kind,
          "unsupported_resource",
          now
        )
    end
  end

  defp resolve_operator_decision(
         %{action: "accept_github"},
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
    case apply_local(repository, binding, operation, remote) do
      {:ok, updated} ->
        case confirm(operation, binding, updated.write_version, remote, remote_updated_at, now) do
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
  end

  defp resolve_operator_decision(
         %{action: "keep_fornacast"},
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
    case validate_outbound_target(local) do
      :ok ->
        case mark_remote_effect(
               operation,
               binding,
               baseline,
               repository.write_version,
               remote,
               remote_updated_at,
               local,
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
  end

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
             "attempt_state" => "prepared",
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
    marker = normalize_effect_marker(marker)

    with true <- Enum.sort(Map.keys(marker)) == Enum.sort(@effect_keys),
         true <- marker["action"] == "update_remote_repository_metadata",
         true <- marker["attempt_state"] in ["prepared", "attempted"],
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

  defp normalize_effect_marker(marker) do
    if Enum.sort(Map.keys(marker)) == Enum.sort(@legacy_effect_keys),
      do: Map.put(marker, "attempt_state", "attempted"),
      else: marker
  end

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
         :ok <- resolve_operator_conflict(operation, binding, now),
         :ok <- resolve_reconciled_conflict(binding, now),
         {:ok, completed} <- complete(operation, now),
         :ok <- ForgeMirrors.activate_repository_after_metadata(completed, now) do
      {:ok, %{action: :confirmed, operation: completed, baseline: state}}
    end
  end

  defp observe_remote_metadata(binding, snapshot, now) do
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

  defp operator_resolution(operation, binding, organization, baseline, local, remote) do
    case {operation.cursor["trigger"], operation.cursor["operator_resolution"]} do
      {"operator_resolution", marker} when is_map(marker) ->
        validate_operator_resolution(
          marker,
          operation.state,
          binding,
          organization,
          baseline,
          local,
          remote
        )

      {"operator_resolution", _invalid} ->
        {:error, :invalid_resolution}

      {_trigger, nil} ->
        :none

      {_trigger, _unexpected} ->
        {:error, :invalid_resolution}
    end
  end

  defp validate_operator_resolution(
         marker,
         operation_state,
         binding,
         organization,
         baseline,
         local,
         remote
       ) do
    with true <- Enum.sort(Map.keys(marker)) == Enum.sort(@resolution_keys),
         %{
           "v" => 1,
           "conflict_id" => conflict_id,
           "conflict_lock_version" => conflict_version,
           "actor_id" => actor_id,
           "action" => action,
           "baseline_fingerprint" => baseline_fingerprint,
           "local_fingerprint" => local_fingerprint,
           "remote_fingerprint" => remote_fingerprint
         } <- marker,
         true <- action in @resolution_actions,
         true <- positive?(conflict_id) and positive?(conflict_version) and positive?(actor_id),
         %MirrorConflict{} = conflict <- lock_resolution_conflict(conflict_id),
         true <-
           conflict.state == :open and conflict.lock_version == conflict_version and
             conflict.organization_mirror_id == organization.id and
             conflict.repository_mirror_id == binding.id and
             conflict.resource_kind == "repository" and
             conflict.resource_identity == Integer.to_string(binding.github_repository_id),
         {:ok, ^baseline_fingerprint} <-
           ForgeMirrors.resource_fingerprint(conflict.baseline_snapshot),
         {:ok, ^local_fingerprint} <- ForgeMirrors.resource_fingerprint(conflict.local_snapshot),
         {:ok, ^remote_fingerprint} <-
           ForgeMirrors.resource_fingerprint(conflict.remote_snapshot) do
      directive = %{action: action, actor_id: actor_id, conflict: conflict}

      cond do
        operation_state != :effect_pending and
            not resolution_actor_authorized?(actor_id, organization.organization_id) ->
          {:unauthorized, conflict}

        operation_state == :effect_pending or action == "external_recheck" or
            (baseline_snapshot(baseline) == conflict.baseline_snapshot and
               local == conflict.local_snapshot and remote == conflict.remote_snapshot) ->
          {:ok, directive}

        true ->
          {:stale, conflict}
      end
    else
      nil -> {:error, :invalid_resolution}
      false -> {:error, :invalid_resolution}
      {:error, _reason} -> {:error, :invalid_resolution}
      _ -> {:error, :invalid_resolution}
    end
  end

  defp resolve_operator_conflict(operation, binding, now) do
    case operation.cursor["operator_resolution"] do
      %{
        "conflict_id" => conflict_id,
        "conflict_lock_version" => conflict_version,
        "actor_id" => actor_id,
        "action" => action,
        "v" => 1
      }
      when action in @resolution_actions ->
        case lock_resolution_conflict(conflict_id) do
          %MirrorConflict{
            state: :open,
            lock_version: ^conflict_version,
            organization_mirror_id: organization_id,
            repository_mirror_id: repository_id,
            resource_kind: "repository",
            resource_identity: identity
          } = conflict
          when organization_id == binding.organization_mirror_id and repository_id == binding.id ->
            if identity == Integer.to_string(binding.github_repository_id) and positive?(actor_id) do
              conflict
              |> MirrorConflict.resolve_changeset(%{"action" => action, "v" => 1}, actor_id, now)
              |> Ecto.Changeset.optimistic_lock(:lock_version)
              |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
              |> case do
                {:ok, _resolved} -> :ok
                {:error, _changeset} -> {:error, :stale_conflict}
              end
            else
              {:error, :invalid_resolution}
            end

          _ ->
            {:error, :stale_conflict}
        end

      nil ->
        :ok

      _invalid ->
        {:error, :invalid_resolution}
    end
  end

  defp authorize_operator_effect(operation, binding, organization, resolution, effect, now) do
    with %{
           "v" => 1,
           "conflict_id" => conflict_id,
           "conflict_lock_version" => conflict_version,
           "actor_id" => actor_id,
           "action" => "keep_fornacast",
           "local_fingerprint" => local_fingerprint,
           "remote_fingerprint" => remote_fingerprint
         } <- resolution,
         true <- Enum.sort(Map.keys(resolution)) == Enum.sort(@resolution_keys),
         true <- positive?(conflict_id) and positive?(conflict_version) and positive?(actor_id),
         %MirrorConflict{} = conflict <- lock_resolution_conflict(conflict_id),
         true <-
           conflict.state == :open and conflict.lock_version == conflict_version and
             conflict.organization_mirror_id == organization.id and
             conflict.repository_mirror_id == binding.id and
             conflict.resource_kind == "repository" and
             conflict.resource_identity == Integer.to_string(binding.github_repository_id),
         {:ok, ^local_fingerprint} <-
           ForgeMirrors.resource_fingerprint(conflict.local_snapshot),
         {:ok, ^remote_fingerprint} <-
           ForgeMirrors.resource_fingerprint(conflict.remote_snapshot),
         true <- effect["target_fingerprint"] == local_fingerprint,
         {:ok, ^remote_fingerprint} <-
           ForgeMirrors.resource_fingerprint(effect["expected_remote"]) do
      case effect["attempt_state"] do
        "attempted" ->
          operation

        "prepared" ->
          if resolution_actor_authorized?(actor_id, organization.organization_id) do
            case transition(operation, now, :effect_pending,
                   external_effect_marker: Map.put(effect, "attempt_state", "attempted")
                 ) do
              {:ok, authorized} -> authorized
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            persist_conflict(
              operation,
              binding,
              organization,
              baseline(binding.id),
              effect["target"],
              effect["expected_remote"],
              "repository_metadata_resolution_unauthorized",
              "permission_missing",
              now
            )
            |> finalize_operator_outcome(operation)
          end
      end
    else
      nil -> Repo.rollback(:invalid_resolution)
      false -> Repo.rollback(:invalid_resolution)
      {:error, _reason} -> Repo.rollback(:invalid_resolution)
      _ -> Repo.rollback(:invalid_resolution)
    end
  end

  defp resolution_actor_authorized?(actor_id, organization_id) do
    case Repo.get(User, actor_id) do
      %User{} = actor ->
        match?(
          {:ok, _organization},
          ForgeAccounts.fetch_manageable_organization(actor, organization_id)
        )

      nil ->
        false
    end
  end

  defp finalize_operator_outcome({:ok, %{action: :confirmed}} = result, operation) do
    with {:ok, _audit} <- maybe_audit_operator_outcome(operation, :completed, %{}) do
      result
    end
  end

  defp finalize_operator_outcome(%{action: :confirmed} = result, operation) do
    with {:ok, _audit} <- maybe_audit_operator_outcome(operation, :completed, %{}) do
      result
    end
  end

  defp finalize_operator_outcome(
         {:ok, %{action: :conflict, operation: failed, conflict: conflict}} = result,
         operation
       ) do
    with {:ok, _audit} <-
           maybe_audit_operator_outcome(operation, :failed, %{
             "conflict_kind" => conflict.conflict_kind,
             "failure_class" => failed.failure_class,
             "failure_detail" => failed.failure_detail
           }) do
      result
    end
  end

  defp finalize_operator_outcome(
         %{action: :conflict, operation: failed, conflict: conflict} = result,
         operation
       ) do
    with {:ok, _audit} <-
           maybe_audit_operator_outcome(operation, :failed, %{
             "conflict_kind" => conflict.conflict_kind,
             "failure_class" => failed.failure_class,
             "failure_detail" => failed.failure_detail
           }) do
      result
    end
  end

  defp finalize_operator_outcome(result, _operation), do: result

  defp maybe_audit_operator_outcome(operation, outcome, metadata) do
    case operation.cursor["operator_resolution"] do
      marker when is_map(marker) ->
        ForgeMirrors.RepositoryMetadataConflictResolution.audit_outcome(
          operation,
          outcome,
          metadata
        )

      nil ->
        {:ok, nil}

      _invalid ->
        {:error, :invalid_resolution}
    end
  end

  defp resolve_reconciled_conflict(binding, now) do
    conflict =
      Repo.one(
        from conflict in MirrorConflict,
          where:
            conflict.organization_mirror_id == ^binding.organization_mirror_id and
              conflict.repository_mirror_id == ^binding.id and
              conflict.resource_kind == "repository" and
              conflict.resource_identity == ^Integer.to_string(binding.github_repository_id) and
              conflict.conflict_kind in ^@representation_conflict_kinds and
              conflict.state == :open,
          lock: "FOR UPDATE"
      )

    case conflict do
      nil ->
        :ok

      %MirrorConflict{} = conflict ->
        conflict
        |> MirrorConflict.resolve_changeset(
          %{"action" => "system_reconciled", "v" => 1},
          nil,
          now
        )
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
        |> case do
          {:ok, _resolved} -> :ok
          {:error, _changeset} -> {:error, :stale_conflict}
        end
    end
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
         :ok <- repository_metadata_lifecycle(organization_state),
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

  defp repository_metadata_lifecycle(state)
       when state in [:catching_up, :active, :degraded, :conflicted],
       do: :ok

  defp repository_metadata_lifecycle(:paused), do: {:error, :paused}
  defp repository_metadata_lifecycle(_state), do: {:error, :invalid_transition}

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

  defp lock_resolution_conflict(id) when is_integer(id) and id > 0,
    do: Repo.one(from conflict in MirrorConflict, where: conflict.id == ^id, lock: "FOR UPDATE")

  defp lock_resolution_conflict(_id), do: nil

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

  defp baseline_snapshot(nil), do: %{}
  defp baseline_snapshot(%MirrorResourceState{confirmed_snapshot: snapshot}), do: snapshot || %{}

  defp positive?(value), do: is_integer(value) and value > 0

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

  defp deferred_effect_attrs(next_attempt_at, "paused") do
    [
      next_attempt_at: DateTime.truncate(next_attempt_at, :second),
      lease_owner: nil,
      lease_expires_at: nil,
      failure_class: nil,
      failure_disposition: nil,
      failure_detail: nil
    ]
  end

  defp deferred_effect_attrs(next_attempt_at, failure_class) do
    [
      next_attempt_at: DateTime.truncate(next_attempt_at, :second),
      lease_owner: nil,
      lease_expires_at: nil,
      failure_class: failure_class,
      failure_disposition: :retry,
      failure_detail: "remote repository metadata effect requires canonical recheck"
    ]
  end

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
