defmodule ForgeMirrors.PullMergeBoundary do
  @moduledoc """
  Trusted leased preparation and pre-push fencing for coordinated pull merges.

  The caller supplies a domain Multi with key `:intent`; this module does not
  depend on ForgePulls or mutate its tables. No Git or provider effects occur
  here. Only the pre-push phase is supported; remote success is NOT inferred.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
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
    preparation = Map.put(compact(expected), "merge_operation_id", intent_id)
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
      {:ok, Map.merge(scope, %{intent: intent, expected: expected})}
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
  defp oid?(oid), do: is_binary(oid) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, oid)
  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
