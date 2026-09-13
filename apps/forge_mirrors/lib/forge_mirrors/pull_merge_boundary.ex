defmodule ForgeMirrors.PullMergeBoundary do
  @moduledoc """
  Trusted leased preparation, pre-push fencing and marked-effect recovery.

  The caller supplies a domain Multi with key `:intent`; this module does not
  depend on ForgePulls or mutate its tables. No Git or provider effects occur
  here. Remote ref observations can record confirmation readiness, but never
  complete a merge or infer that the provider pull has merged.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
    PullMetadataIntent,
    PullResourceBoundary,
    RepositoryMirror
  }

  @expected_keys [
    :pull_id,
    :issue_id,
    :local_version,
    :fields,
    :provider_identity,
    :resource_state_lock_version,
    :pull_eligibility_proof
  ]
  @intent_fields [
    :id,
    :repository_id,
    :pull_request_id,
    :actor_user_id,
    :coordinator_operation_id,
    :commit_intent,
    :base_ref,
    :head_ref,
    :expected_base_oid,
    :expected_head_oid,
    :merge_tree_oid,
    :merge_oid
  ]

  def append_prepare(%Multi{} = multi, key, operation, now, expected, %Multi{} = domain) do
    Multi.run(multi, key, fn _, _ ->
      with {:ok, scope} <- lock_scope(operation, now),
           true <- scope.operation.state == :processing,
           :ok <- lock_reservations(scope.repository_id, expected),
           :ok <- validate_expected(scope, expected),
           :ok <-
             check_unreserved(
               scope.repository_id,
               expected.fields["base_ref"],
               expected.pull_id,
               operation.id,
               expected.pull_eligibility_proof["head"]["repository_id"],
               expected.fields["head_ref"]
             ),
           :ok <- no_ref_effect(scope, expected),
           {:ok, %{intent: intent}} <- Repo.transaction(domain),
           true <- valid_intent?(intent, scope, expected),
           stored when is_map(stored) <- load_intent(operation.id),
           true <- Map.take(stored, @intent_fields) == Map.take(intent, @intent_fields),
           :ok <- live_capability(scope.operation),
           :ok <- save_preparation(scope.operation, expected, intent.id) do
        {:ok, intent}
      else
        {:error, _, reason, _} -> {:error, reason}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_merge_intent}
      end
    end)
  end

  def context(operation, now) do
    transaction(fn -> load_context(operation, now) end)
  end

  @doc "Load durable marked evidence under its lease; this grants no permission to push."
  def recovery_context(operation, now), do: transaction(fn -> load_recovery(operation, now) end)

  @doc false
  def finalization_context(operation, now) do
    if Repo.in_transaction?() do
      with {:ok, scope} <- lock_scope(operation, now),
           {:ok, recovery} <- load_recovery(operation, now),
           true <- scope.github_installation_id == recovery.github_installation_id,
           :ok <- lock_reservations(scope.repository_id, recovery.expected),
           :ok <- authorize_requester(recovery.intent, scope),
           :ok <-
             check_unreserved(
               scope.repository_id,
               recovery.intent.base_ref,
               recovery.expected.pull_id,
               operation.id,
               recovery.expected.pull_eligibility_proof["head"]["repository_id"],
               recovery.intent.head_ref
             ),
           :ok <- no_ref_effect(scope, recovery.expected),
           :ok <- live_capability(scope.operation) do
        {:ok, recovery}
      else
        {:error, _} = error -> error
        _ -> {:error, :stale_merge_identity}
      end
    else
      {:error, :transaction_required}
    end
  end

  def defer(operation, now, next_attempt_at, reason) do
    transaction(fn ->
      with {:ok, context} <- load_recovery(operation, now),
           true <- valid_retry?(now, next_attempt_at) do
        attrs =
          if reason == :remote_confirmation_required or
               context.operation.failure_disposition == :conflict,
             do: confirmation_diagnostics(context.operation),
             else: [
               failure_class: "network",
               failure_disposition: :retry,
               failure_detail: diagnostic(reason)
             ]

        yield_recovery(context.operation, now, next_attempt_at, attrs)
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_transition}
      end
    end)
  end

  def record_observation(operation, now, next_attempt_at, observation) do
    transaction(fn ->
      with {:ok, context} <- load_recovery(operation, now),
           true <- valid_retry?(now, next_attempt_at),
           %{remote_base_oid: oid, provider_pull_id: provider_id} <- observation,
           true <- map_size(observation) == 2 and oid?(oid),
           %MirrorResourceState{} = mapping <-
             Repo.get_by(MirrorResourceState,
               repository_mirror_id: context.repository_mirror_id,
               resource_kind: :pull,
               local_resource_id: context.expected.pull_id
             ),
           true <-
             mapping.provider_identity == context.expected.provider_identity and
               provider_pull_identity(mapping) == context.provider_pull_identity and
               context.provider_pull_identity["id"] == provider_id do
        cond do
          oid == context.intent.expected_base_oid ->
            {:error, :remote_base_unchanged}

          oid == context.intent.merge_oid ->
            checkpoint =
              Map.put(context.operation.checkpoint, "merge_observation", %{
                "remote_base_oid" => oid,
                "provider_pull_id" => provider_id,
                "confirmation_ready" => true,
                "observed_at" => DateTime.to_iso8601(now)
              })

            yield_recovery(
              context.operation,
              now,
              next_attempt_at,
              Keyword.put(confirmation_diagnostics(context.operation), :checkpoint, checkpoint)
            )

          true ->
            with {:ok, _} <- observation_conflict(context, oid) do
              yield_recovery(context.operation, now, next_attempt_at,
                checkpoint: Map.delete(context.operation.checkpoint, "merge_observation"),
                failure_class: "git_divergence",
                failure_disposition: :conflict,
                failure_detail: "Remote base differs from the prepared base and merge commit"
              )
            end
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :stale_merge_identity}
      end
    end)
  end

  def checkpoint_lfs(operation, now, checkpoint) do
    transaction(fn ->
      loader = if operation.external_effect_marker, do: &load_recovery/2, else: &load_context/2

      with {:ok, context} <- loader.(operation, now),
           true <- valid_lfs_checkpoint?(checkpoint) do
        update_operation(context.operation,
          checkpoint: Map.merge(context.operation.checkpoint, checkpoint),
          state:
            if(context.operation.external_effect_marker, do: :effect_pending, else: :pending),
          lease_owner: nil,
          lease_expires_at: nil,
          next_attempt_at: DateTime.add(now, 1, :second),
          updated_at: now
        )
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_transition}
      end
    end)
  end

  defp load_recovery(operation, now), do: load_recovery(operation, now, :current)

  defp load_recovery(
         %MirrorOperation{
           lease_owner: owner,
           lease_expires_at: %DateTime{},
           id: id,
           organization_mirror_id: org_id,
           repository_mirror_id: binding_id,
           lock_version: version
         } = operation,
         %DateTime{} = now,
         sequence_mode
       )
       when is_binary(owner) and byte_size(owner) > 0 and is_integer(id) and id > 0 and
              is_integer(org_id) and org_id > 0 and is_integer(binding_id) and binding_id > 0 and
              is_integer(version) and version > 0 do
    with %MirrorOperation{} = current <-
           Repo.one(capability_query(operation) |> lock("FOR UPDATE")),
         true <-
           current.state == :effect_pending and current.cursor == operation.cursor and
             DateTime.compare(current.lease_expires_at, now) == :gt,
         %RepositoryMirror{} = binding <- Repo.get(RepositoryMirror, current.repository_mirror_id),
         true <- binding.organization_mirror_id == current.organization_mirror_id,
         preparation when is_map(preparation) <- current.checkpoint["merge_preparation"],
         intent when is_map(intent) <- load_intent(current.id),
         expected =
           Map.new(@expected_keys, fn key ->
             {key,
              if(key == :fields,
                do: intent.commit_intent["resource"]["expected_fields"],
                else: preparation[Atom.to_string(key)]
              )}
           end),
         provider_identity when is_map(provider_identity) <- preparation["provider_pull_identity"],
         true <- is_map(expected.pull_eligibility_proof),
         true <-
           is_map(expected.pull_eligibility_proof["base"]) and
             is_map(expected.pull_eligibility_proof["head"]),
         true <- valid_provider_pull_identity?(provider_identity),
         true <-
           preparation ==
             Map.merge(compact(expected), %{
               "merge_operation_id" => intent.id,
               "provider_pull_identity" => provider_identity
             }),
         scope = %{
           operation: current,
           repository_id: binding.repository_id,
           repository_mirror_id: binding.id,
           organization_mirror_id: current.organization_mirror_id,
           github_installation_id: expected.pull_eligibility_proof["github_installation_id"]
         },
         true <- positive?(scope.github_installation_id),
         true <-
           current.cursor == %{"issue_id" => expected.issue_id, "pull_id" => expected.pull_id},
         true <- valid_intent?(intent, scope, expected),
         marker when is_map(marker) <- current.external_effect_marker,
         {:ok, metadata_intent} <-
           recovery_marker(
             current,
             binding,
             expected,
             intent,
             provider_identity,
             marker,
             sequence_mode
           ),
         :ok <- live_capability(current) do
      {:ok,
       Map.merge(scope, %{
         intent: intent,
         expected: expected,
         provider_pull_identity: provider_identity,
         metadata_intent: metadata_intent
       })}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp load_recovery(_, _, _), do: {:error, :lost_lease}

  defp yield_recovery(operation, now, next_attempt_at, attrs) do
    update_operation(
      operation,
      Keyword.merge(
        [
          next_attempt_at: next_attempt_at,
          lease_owner: nil,
          lease_expires_at: nil,
          updated_at: now
        ],
        attrs
      )
    )
  end

  defp update_operation(operation, attrs) do
    case Repo.update_all(capability_query(operation), set: attrs, inc: [lock_version: 1]) do
      {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
      _ -> {:error, :lost_lease}
    end
  end

  defp observation_conflict(context, oid) do
    attrs = %{
      organization_mirror_id: context.organization_mirror_id,
      repository_mirror_id: context.repository_mirror_id,
      resource_kind: "pull_merge",
      resource_identity: to_string(context.intent.id),
      conflict_kind: "git_divergence",
      baseline_snapshot: %{"oid" => context.intent.expected_base_oid},
      local_snapshot: %{"oid" => context.intent.merge_oid},
      remote_snapshot: %{"oid" => oid}
    }

    case Repo.get_by(ForgeMirrors.MirrorConflict,
           organization_mirror_id: context.organization_mirror_id,
           resource_kind: "pull_merge",
           resource_identity: to_string(context.intent.id),
           state: :open
         ) do
      nil ->
        %ForgeMirrors.MirrorConflict{}
        |> ForgeMirrors.MirrorConflict.record_changeset(attrs)
        |> Repo.insert()

      existing ->
        if Map.take(existing, Map.keys(attrs)) == attrs,
          do: {:ok, existing},
          else: {:error, :dedupe_conflict}
    end
  end

  defp valid_retry?(%DateTime{} = now, %DateTime{} = next), do: DateTime.compare(next, now) != :lt
  defp valid_retry?(_, _), do: false
  defp confirmation_diagnostics(%{failure_disposition: :conflict}), do: []

  defp confirmation_diagnostics(_),
    do: [failure_class: nil, failure_disposition: nil, failure_detail: nil]

  defp diagnostic(reason) when is_atom(reason), do: diagnostic(Atom.to_string(reason))
  defp diagnostic(reason) when is_binary(reason), do: diagnostic_prefix(reason, 512, 255, "")
  defp diagnostic(_), do: "Unresolved remote merge effect"

  # PostgreSQL stores this as varchar(255); additionally bound UTF-8 bytes.
  defp diagnostic_prefix(<<codepoint::utf8, rest::binary>>, bytes, count, acc) when count > 0 do
    encoded = <<codepoint::utf8>>

    if byte_size(encoded) <= bytes,
      do: diagnostic_prefix(rest, bytes - byte_size(encoded), count - 1, acc <> encoded),
      else: acc
  end

  defp diagnostic_prefix(_, _, _, acc), do: acc

  defp valid_lfs_checkpoint?(checkpoint) when is_map(checkpoint) do
    Enum.sort(Map.keys(checkpoint)) ==
      Enum.sort(["baseline_fingerprint", "direction", "phase", "requirement_cursor", "scan_key"]) and
      checkpoint["direction"] == "outbound" and checkpoint["phase"] in ["scan", "transfer"] and
      is_binary(checkpoint["baseline_fingerprint"]) and is_binary(checkpoint["scan_key"]) and
      (is_nil(checkpoint["requirement_cursor"]) or is_binary(checkpoint["requirement_cursor"])) and
      Enum.all?(Map.values(checkpoint), &(is_nil(&1) or String.valid?(&1))) and
      byte_size(JSON.encode!(checkpoint)) <= 16_384
  end

  defp valid_lfs_checkpoint?(_), do: false

  @doc "Recheck the coordinator capability inside the staged writer's transaction."
  def authorize(operation, now, intent) do
    if Repo.in_transaction?() do
      with {:ok, context} <- load_context(operation, now),
           true <- Map.take(intent, @intent_fields) == Map.take(context.intent, @intent_fields) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :stale_merge_identity}
      end
    else
      {:error, :transaction_required}
    end
  end

  @doc "Persist only the exact committed tree/commit pre-push marker."
  def mark(operation, now, expected_marker, marker) do
    transaction(fn ->
      with {:ok, context} <- load_context(operation, now),
           true <- context.operation.external_effect_marker == expected_marker,
           true <- valid_marker?(marker, context.intent),
           full =
             Map.merge(marker, %{
               "preparation" => compact(context.expected),
               "provider_pull_identity" => context.provider_pull_identity,
               "expected_base_oid" => context.intent.expected_base_oid,
               "expected_head_oid" => context.intent.expected_head_oid,
               "base_ref" => context.intent.base_ref,
               "head_ref" => context.intent.head_ref
             }),
           true <- is_nil(expected_marker) or expected_marker == full,
           :ok <- live_capability(context.operation) do
        if expected_marker == full do
          {:ok, context.operation}
        else
          case Repo.update_all(capability_query(context.operation),
                 set: [
                   state: :effect_pending,
                   external_effect_marker: full,
                   effect_marked_at: now,
                   updated_at: now
                 ],
                 inc: [lock_version: 1]
               ) do
            {1, _} -> {:ok, Repo.get!(MirrorOperation, context.operation.id)}
            {0, _} -> {:error, :lost_lease}
          end
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :stale_merge_identity}
      end
    end)
  end

  @doc false
  def replace_metadata_marker(
        %MirrorOperation{kind: "merge.pull", state: :effect_pending} = operation,
        %DateTime{} = now,
        expected_marker,
        metadata
      )
      when is_map(expected_marker) and is_map(metadata) do
    transaction(fn ->
      with {:ok, context} <- load_recovery(operation, now, :current_or_previous),
           true <- context.operation.external_effect_marker == expected_marker,
           true <- expected_marker["phase"] in ["remote_cas_pending", "metadata_issue_pending"],
           true <-
             Enum.sort(Map.keys(metadata)) ==
               Enum.sort([
                 "action",
                 "metadata_intent_id",
                 "metadata_intent_hash",
                 "expected_remote_updated_at",
                 "expected_remote_issue_updated_at"
               ]),
           replacement =
             expected_marker
             |> Map.put("phase", "metadata_issue_pending")
             |> Map.merge(metadata),
           {:ok, _metadata_intent} <-
             recovery_marker(
               context.operation,
               Repo.get!(RepositoryMirror, context.repository_mirror_id),
               context.expected,
               context.intent,
               context.provider_pull_identity,
               replacement,
               :current
             ),
           true <- byte_size(JSON.encode!(replacement)) <= 65_536,
           :ok <- live_capability(context.operation) do
        case Repo.update_all(capability_query(context.operation),
               set: [external_effect_marker: replacement, effect_marked_at: now, updated_at: now],
               inc: [lock_version: 1]
             ) do
          {1, _} -> {:ok, Repo.get!(MirrorOperation, context.operation.id)}
          {0, _} -> {:error, :lost_lease}
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :stale_merge_identity}
      end
    end)
  end

  def replace_metadata_marker(_, _, _, _), do: {:error, :invalid_transition}

  @doc false
  def check_unreserved(repository_id, base_ref, pull_id, coordinator_id, head_id, head_ref) do
    if Repo.in_transaction?() do
      [repository_id, head_id] |> Enum.uniq() |> Enum.sort() |> Enum.each(&reservation_lock/1)

      query =
        from intent in "pull_merge_operations",
          where:
            intent.coordination_mode == "mirror" and intent.state not in ["completed", "failed"],
          where:
            intent.pull_request_id == ^pull_id or
              (intent.repository_id == ^repository_id and intent.base_ref == ^base_ref) or
              (intent.head_ref == ^base_ref and
                 fragment(
                   "?->'resource'->>'head_repository_id' = ?",
                   intent.commit_intent,
                   ^to_string(repository_id)
                 )) or
              (intent.repository_id == ^head_id and intent.base_ref == ^head_ref)

      query =
        if coordinator_id,
          do: where(query, [intent], intent.coordinator_operation_id != ^coordinator_id),
          else: query

      if Repo.exists?(query), do: {:error, :merge_reserved}, else: :ok
    else
      {:error, :transaction_required}
    end
  end

  @doc false
  def check_ref_unreserved(repository_id, ref) when is_binary(ref) do
    if Repo.in_transaction?() do
      reservation_lock(repository_id)

      reserved =
        Repo.exists?(
          from intent in "pull_merge_operations",
            where:
              intent.coordination_mode == "mirror" and intent.state not in ["completed", "failed"],
            where:
              (intent.repository_id == ^repository_id and intent.base_ref == ^ref) or
                (intent.head_ref == ^ref and
                   fragment(
                     "?->'resource'->>'head_repository_id' = ?",
                     intent.commit_intent,
                     ^to_string(repository_id)
                   ))
        )

      if reserved, do: {:error, :merge_reserved}, else: :ok
    else
      {:error, :transaction_required}
    end
  end

  def check_ref_unreserved(_, _), do: {:error, :invalid_transition}

  @doc false
  def check_pull_unreserved(repository_id, pull_id) do
    if Repo.in_transaction?() do
      reservation_lock(repository_id)

      reserved =
        Repo.exists?(
          from intent in "pull_merge_operations",
            where:
              intent.coordination_mode == "mirror" and intent.state not in ["completed", "failed"] and
                intent.repository_id == ^repository_id and intent.pull_request_id == ^pull_id
        )

      if reserved, do: {:error, :merge_reserved}, else: :ok
    else
      {:error, :transaction_required}
    end
  end

  defp lock_scope(
         %MirrorOperation{
           lease_owner: owner,
           lease_expires_at: %DateTime{},
           id: id,
           organization_mirror_id: organization_id,
           repository_mirror_id: binding_id,
           lock_version: version
         } = operation,
         %DateTime{} = now
       )
       when is_binary(owner) and byte_size(owner) > 0 and is_integer(id) and id > 0 and
              is_integer(organization_id) and organization_id > 0 and is_integer(binding_id) and
              binding_id > 0 and is_integer(version) and version > 0 do
    with %MirrorOperation{} = initial <- Repo.get(MirrorOperation, operation.id),
         %OrganizationMirror{state: :active} = organization <-
           Repo.one(
             from org in OrganizationMirror,
               where: org.id == ^initial.organization_mirror_id,
               lock: "FOR UPDATE"
           ),
         %RepositoryMirror{state: :active, inventory_included: true} = binding <-
           Repo.one(
             from binding in RepositoryMirror,
               where:
                 binding.id == ^initial.repository_mirror_id and
                   binding.organization_mirror_id == ^organization.id,
               lock: "FOR UPDATE"
           ),
         %MirrorOperation{} = current <-
           Repo.one(
             from op in MirrorOperation,
               where:
                 op.id == ^operation.id and op.kind == "merge.pull" and
                   op.organization_mirror_id == ^operation.organization_mirror_id and
                   op.repository_mirror_id == ^operation.repository_mirror_id and
                   op.state in [:processing, :effect_pending] and
                   op.lease_owner == ^operation.lease_owner and
                   op.lock_version == ^operation.lock_version and
                   op.lease_expires_at == ^operation.lease_expires_at and
                   op.lease_expires_at > ^now and
                   op.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
               lock: "FOR UPDATE"
           ),
         true <- current.cursor == operation.cursor,
         :ok <- permission(organization) do
      {:ok,
       %{
         operation: current,
         repository_id: binding.repository_id,
         repository_mirror_id: binding.id,
         github_installation_id: organization.github_installation_id,
         organization_mirror_id: organization.id
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :lost_lease}
    end
  end

  defp lock_scope(_, _), do: {:error, :lost_lease}

  defp permission(organization) do
    case Repo.one(
           from i in GitHubAppInstallation,
             where:
               i.github_installation_id == ^organization.github_installation_id and
                 i.github_account_id == ^organization.github_account_id,
             lock: "FOR UPDATE"
         ) do
      %{state: :active, permissions: permissions} ->
        if permissions["contents"] == "write" and
             permissions["pull_requests"] in ["read", "write"] and
             permissions["issues"] in ["read", "write"],
           do: :ok,
           else: {:error, :permission_missing}

      _ ->
        {:error, :credential_revoked}
    end
  end

  defp validate_expected(scope, expected) when is_map(expected) do
    with true <- Enum.sort(Map.keys(expected)) == Enum.sort(@expected_keys),
         true <- positive?(expected.pull_id) and positive?(expected.issue_id),
         true <-
           scope.operation.cursor == %{
             "issue_id" => expected.issue_id,
             "pull_id" => expected.pull_id
           },
         %MirrorResourceState{} = mapping <-
           Repo.one(
             from m in MirrorResourceState,
               where:
                 m.repository_mirror_id == ^scope.repository_mirror_id and
                   m.resource_kind == :pull and
                   m.local_resource_id == ^expected.pull_id and
                   m.local_resource_type == "ForgePulls.PullRequest",
               lock: "FOR UPDATE"
           ),
         true <-
           mapping.state == :confirmed and mapping.provider_identity == expected.provider_identity,
         true <- expected.fields["state"] == "open" and expected.fields["draft"] == false,
         true <-
           Repo.exists?(
             from p in "pull_requests",
               where:
                 p.id == ^expected.pull_id and
                   p.repository_id == ^scope.repository_id and p.issue_id == ^expected.issue_id
           ),
         {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(expected.fields),
         :ok <-
           PullResourceBoundary.validate_precondition(scope, mapping, %{
             "github_object_id" => mapping.github_object_id,
             "github_node_id" => mapping.github_node_id,
             "github_number" => mapping.github_number,
             "provider_identity" => expected.provider_identity,
             "resource_state_lock_version" => expected.resource_state_lock_version,
             "pull_eligibility_proof" => expected.pull_eligibility_proof,
             "expected_local_version" => expected.local_version,
             "expected_local_fingerprint" => fingerprint,
             "expected_merge_state" => %{"merged_at" => nil, "merge_commit_sha" => nil}
           }) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_baseline}
    end
  end

  defp no_ref_effect(scope, expected) do
    proof = expected.pull_eligibility_proof

    pairs = [
      {scope.repository_mirror_id, expected.fields["base_ref"]},
      {proof["head"]["repository_mirror_id"], expected.fields["head_ref"]}
    ]

    if Enum.any?(pairs, fn {binding, ref} ->
         Repo.exists?(
           from op in MirrorOperation,
             where:
               op.repository_mirror_id == ^binding and op.kind == "sync.git_ref" and
                 op.state == :effect_pending and fragment("?->>'ref_name' = ?", op.cursor, ^ref)
         )
       end), do: {:error, :ref_effect_pending}, else: :ok
  end

  defp save_preparation(operation, expected, intent_id) do
    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: operation.repository_mirror_id,
        resource_kind: :pull,
        local_resource_id: expected.pull_id
      )

    preparation =
      Map.merge(compact(expected), %{
        "merge_operation_id" => intent_id,
        "provider_pull_identity" => provider_pull_identity(mapping)
      })

    existing = operation.checkpoint["merge_preparation"]

    cond do
      existing == preparation ->
        :ok

      not is_nil(existing) ->
        {:error, :merge_intent_conflict}

      byte_size(JSON.encode!(preparation)) > 16_384 ->
        {:error, :invalid_merge_intent}

      true ->
        # Write-once subordinate proof under the live lease/row lock. It does not
        # transition the operation or invalidate the caller's current capability.
        case Repo.update_all(capability_query(operation),
               set: [checkpoint: Map.put(operation.checkpoint, "merge_preparation", preparation)]
             ) do
          {1, _} -> :ok
          {0, _} -> {:error, :lost_lease}
        end
    end
  end

  defp compact(expected), do: expected |> Map.delete(:fields) |> json()

  defp load_context(operation, now) do
    with {:ok, scope} <- lock_scope(operation, now),
         preparation when is_map(preparation) <- scope.operation.checkpoint["merge_preparation"],
         intent when is_map(intent) <- load_intent(operation.id),
         true <- intent.id == preparation["merge_operation_id"],
         expected =
           Map.new(@expected_keys, fn key ->
             {key,
              if(key == :fields,
                do: intent.commit_intent["resource"]["expected_fields"],
                else: preparation[Atom.to_string(key)]
              )}
           end),
         :ok <- lock_reservations(scope.repository_id, expected),
         :ok <- validate_expected(scope, expected),
         %MirrorResourceState{} = mapping <-
           Repo.get_by(MirrorResourceState,
             repository_mirror_id: scope.repository_mirror_id,
             resource_kind: :pull,
             local_resource_id: expected.pull_id
           ),
         true <- preparation["provider_pull_identity"] == provider_pull_identity(mapping),
         true <- valid_intent?(intent, scope, expected),
         :ok <- authorize_requester(intent, scope),
         :ok <-
           check_unreserved(
             scope.repository_id,
             intent.base_ref,
             intent.pull_request_id,
             operation.id,
             expected.pull_eligibility_proof["head"]["repository_id"],
             intent.head_ref
           ),
         :ok <- no_ref_effect(scope, expected),
         :ok <- live_capability(scope.operation) do
      {:ok,
       Map.merge(scope, %{
         intent: intent,
         expected: expected,
         provider_pull_identity: preparation["provider_pull_identity"]
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp live_capability(operation) do
    if Repo.exists?(capability_query(operation)), do: :ok, else: {:error, :lost_lease}
  end

  defp capability_query(operation) do
    from op in MirrorOperation,
      where:
        op.id == ^operation.id and op.kind == "merge.pull" and
          op.organization_mirror_id == ^operation.organization_mirror_id and
          op.repository_mirror_id == ^operation.repository_mirror_id and
          op.state == ^operation.state and op.lease_owner == ^operation.lease_owner and
          op.lease_expires_at == ^operation.lease_expires_at and
          op.lock_version == ^operation.lock_version and
          op.lease_expires_at > fragment("timezone('UTC', clock_timestamp())")
  end

  defp load_intent(coordinator_id) do
    Repo.one(
      from i in "pull_merge_operations",
        where: i.coordinator_operation_id == ^coordinator_id,
        select: %{
          id: i.id,
          repository_id: i.repository_id,
          pull_request_id: i.pull_request_id,
          actor_user_id: i.actor_user_id,
          coordinator_operation_id: i.coordinator_operation_id,
          commit_intent: i.commit_intent,
          base_ref: i.base_ref,
          head_ref: i.head_ref,
          expected_base_oid: i.expected_base_oid,
          expected_head_oid: i.expected_head_oid,
          merge_tree_oid: i.merge_tree_oid,
          merge_oid: i.merge_oid,
          state: i.state,
          coordination_mode: i.coordination_mode
        }
    )
  end

  defp authorize_requester(intent, scope) do
    with true <- positive?(intent.actor_user_id),
         %ForgeAccounts.User{state: :active, kind: :user} = actor <-
           Repo.get(ForgeAccounts.User, intent.actor_user_id),
         %ForgeRepos.Repository{} = repository <-
           Repo.get(ForgeRepos.Repository, scope.repository_id),
         true <- Fornacast.Access.allowed?(actor, :repository_write, repository) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp valid_intent?(intent, scope, expected) do
    resource = intent.commit_intent["resource"]

    intent.coordinator_operation_id == scope.operation.id and
      intent.repository_id == scope.repository_id and
      intent.pull_request_id == expected.pull_id and
      to_string(intent.coordination_mode) == "mirror" and
      to_string(intent.state) in ["prepared", "merge_written"] and
      resource["issue_id"] == expected.issue_id and
      resource["expected_local_version"] == expected.local_version and
      resource["expected_fields"] == expected.fields and
      resource["head_repository_id"] == expected.pull_eligibility_proof["head"]["repository_id"] and
      resource["repository_generation"] ==
        expected.pull_eligibility_proof["base"]["repository_generation"] and
      resource["head_repository_generation"] ==
        expected.pull_eligibility_proof["head"]["repository_generation"] and
      intent.base_ref == expected.fields["base_ref"] and
      intent.head_ref == expected.fields["head_ref"] and
      intent.expected_base_oid == expected.fields["base_sha"] and
      intent.expected_head_oid == expected.fields["head_sha"]
  end

  defp valid_marker?(marker, intent) when is_map(marker) do
    marker == %{
      "phase" => "remote_cas_pending",
      "merge_operation_id" => intent.id,
      "merge_tree_oid" => intent.merge_tree_oid,
      "merge_oid" => intent.merge_oid
    } and
      to_string(intent.state) == "merge_written" and oid?(intent.merge_tree_oid) and
      oid?(intent.merge_oid)
  end

  defp valid_marker?(_, _), do: false

  defp recovery_marker(
         operation,
         binding,
         expected,
         intent,
         provider_identity,
         marker,
         sequence_mode
       ) do
    common = %{
      "preparation" => compact(expected),
      "provider_pull_identity" => provider_identity,
      "expected_base_oid" => intent.expected_base_oid,
      "expected_head_oid" => intent.expected_head_oid,
      "base_ref" => intent.base_ref,
      "head_ref" => intent.head_ref
    }

    core = %{
      "phase" => marker["phase"],
      "merge_operation_id" => intent.id,
      "merge_tree_oid" => intent.merge_tree_oid,
      "merge_oid" => intent.merge_oid
    }

    case marker["phase"] do
      "remote_cas_pending" ->
        if valid_marker?(core, intent) and marker == Map.merge(core, common),
          do: {:ok, nil},
          else: {:error, :stale_merge_identity}

      "metadata_issue_pending" ->
        metadata = %{
          "action" => marker["action"],
          "metadata_intent_id" => marker["metadata_intent_id"],
          "metadata_intent_hash" => marker["metadata_intent_hash"],
          "expected_remote_updated_at" => marker["expected_remote_updated_at"],
          "expected_remote_issue_updated_at" => marker["expected_remote_issue_updated_at"]
        }

        with true <- marker == core |> Map.merge(common) |> Map.merge(metadata),
             true <- metadata["action"] == "update_remote_pull_issue",
             true <-
               to_string(intent.state) == "merge_written" and oid?(intent.merge_tree_oid) and
                 oid?(intent.merge_oid),
             true <- utc_iso8601?(metadata["expected_remote_updated_at"]),
             true <- utc_iso8601?(metadata["expected_remote_issue_updated_at"]),
             metadata_intent_id when is_integer(metadata_intent_id) and metadata_intent_id > 0 <-
               metadata["metadata_intent_id"],
             %PullMetadataIntent{} = row <-
               Repo.one(
                 from i in PullMetadataIntent,
                   where: i.id == ^metadata_intent_id,
                   lock: "FOR SHARE"
               ),
             true <-
               row.operation_id == operation.id and row.repository_mirror_id == binding.id and
                 row.pull_id == expected.pull_id and row.issue_id == expected.issue_id and
                 row.local_version >= expected.local_version and
                 valid_metadata_sequence?(row, sequence_mode),
             true <- observation_versions?(binding.id, expected, metadata),
             {:ok, hash} <- ForgeMirrors.resource_fingerprint(row.payload),
             true <-
               row.payload_fingerprint == hash and metadata["metadata_intent_hash"] == hash and
                 ForgeMirrors.PullMergeMetadataEffects.valid_payload?(row.payload) do
          {:ok, row}
        else
          _ -> {:error, :stale_merge_identity}
        end

      _ ->
        {:error, :stale_merge_identity}
    end
  end

  defp utc_iso8601?(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> DateTime.to_iso8601(time) == value
      _ -> false
    end
  end

  defp utc_iso8601?(_), do: false

  defp observation_versions?(binding_id, expected, metadata) do
    rows =
      Repo.all(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^binding_id and
              ((m.resource_kind == :pull and m.local_resource_id == ^expected.pull_id) or
                 (m.resource_kind == :issue and m.local_resource_id == ^expected.issue_id)),
          lock: "FOR SHARE"
      )

    Enum.all?(
      [
        {:pull, "expected_remote_updated_at"},
        {:issue, "expected_remote_issue_updated_at"}
      ],
      fn {kind, key} ->
        mapping = Enum.find(rows, &(&1.resource_kind == kind))
        {:ok, observed, 0} = DateTime.from_iso8601(metadata[key])

        match?(%MirrorResourceState{}, mapping) and
          (is_nil(mapping.confirmed_remote_updated_at) or
             DateTime.compare(observed, mapping.confirmed_remote_updated_at) != :lt)
      end
    )
  end

  defp valid_metadata_sequence?(row, mode) do
    sequences =
      Repo.all(
        from i in PullMetadataIntent,
          where: i.operation_id == ^row.operation_id,
          order_by: i.sequence,
          select: i.sequence,
          lock: "FOR SHARE"
      )

    latest = List.last(sequences)

    expected_position? =
      case mode do
        :current -> latest == row.sequence
        :current_or_previous -> latest in [row.sequence, row.sequence + 1]
        _ -> false
      end

    row.sequence > 0 and expected_position? and
      Enum.all?(Enum.with_index(sequences, 1), fn {sequence, index} -> sequence == index end)
  end

  defp reservation_lock(id),
    do:
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "fornacast:merge-reservation:#{id}"
      ])

  defp lock_reservations(repository_id, %{
         pull_eligibility_proof: %{"head" => %{"repository_id" => head_id}}
       }) do
    if positive?(head_id) do
      [repository_id, head_id] |> Enum.uniq() |> Enum.sort() |> Enum.each(&reservation_lock/1)
      :ok
    else
      {:error, :ineligible_pull}
    end
  end

  defp lock_reservations(_, _), do: {:error, :ineligible_pull}

  defp transaction(fun),
    do:
      Repo.transaction(fn ->
        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

  defp positive?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  defp provider_pull_identity(mapping),
    do: %{"id" => mapping.github_object_id, "node_id" => mapping.github_node_id}

  defp valid_provider_pull_identity?(%{"id" => id, "node_id" => node} = identity),
    do:
      map_size(identity) == 2 and positive?(id) and is_binary(node) and byte_size(node) in 1..512

  defp valid_provider_pull_identity?(_), do: false
  defp oid?(oid), do: is_binary(oid) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, oid)
  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
