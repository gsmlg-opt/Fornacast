defmodule ForgeMirrors.PatGitMirror do
  @moduledoc "Explicit Git/LFS handoff for repositories published by saved-PAT imports."
  import Ecto.Query
  alias Fornacast.{Audit, Repo}
  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}

  alias ForgeMirrors.{
    MirrorConflict,
    MirrorOperation,
    OrganizationMirror,
    PatConfiguration,
    RepositoryMirror
  }

  @authority_fields [
    :credential_source,
    :organization_id,
    :organization_connection_id,
    :organization_connection_version,
    :organization_credential_id,
    :organization_credential_version,
    :github_installation_id,
    :pat_configuration_id,
    :pat_configuration_version,
    :credential_owner_user_id,
    :github_identity_id,
    :github_credential_id,
    :github_credential_version,
    :github_account_id
  ]

  def enroll(actor, organization_id, version, repository_ids, metadata)
      when is_list(repository_ids) and length(repository_ids) in 1..100 do
    with true <-
           Enum.all?(repository_ids, &(is_integer(&1) and &1 > 0)) and
             length(repository_ids) == length(Enum.uniq(repository_ids)),
         {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata) do
      Repo.transaction(fn ->
        config = lock_config_by_organization(organization_id)
        require!(config != nil, :not_found)

        case ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        require!(config.lock_version == version, :stale)
        require!(not legacy_active?(config.id), :legacy_sync_active)
        credential = credential!(config)
        proofs = Enum.map(repository_ids, &proof!(config, &1))
        require!(length(Enum.uniq(Enum.map(proofs, & &1.account_id))) == 1, :unverified_import)

        reauthorizing? =
          Repo.exists?(
            from m in OrganizationMirror,
              where: m.pat_configuration_id == ^config.id and m.state != :revoked
          )

        proof = hd(proofs)

        check!(
          ForgeMirrors.OrganizationGitHubConnections.claim_identity(
            config.organization_id,
            proof.account_id,
            config.github_installation_id
          )
        )

        mirror = mirror!(config, credential, proof)
        bindings = Enum.map(proofs, &binding!(mirror, &1))

        operations =
          Enum.map(bindings, fn binding ->
            enqueue!(
              mirror,
              binding,
              "enrollment:#{binding.id}:#{mirror.pat_configuration_version}:#{mirror.github_credential_id}:#{mirror.github_credential_version}",
              DateTime.utc_now(:second)
            )
          end)

        case Audit.record(
               actor,
               if(reauthorizing?,
                 do: "organization.github_pat.git_reauthorize",
                 else: "organization.github_pat.git_enroll"
               ),
               "organization",
               organization_id,
               %{"repository_ids" => repository_ids},
               request_metadata: safe_metadata
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        %{organization_mirror: mirror, repository_mirrors: bindings, operations: operations}
      end)
    else
      false -> {:error, :invalid_argument}
      error -> error
    end
  end

  def enroll(_, _, _, _, _), do: {:error, :invalid_argument}

  def view(actor, organization_id) do
    with {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      config = Repo.get_by(PatConfiguration, organization_id: organization_id)

      mirror =
        config &&
          Repo.one(
            from m in OrganizationMirror,
              where: m.pat_configuration_id == ^config.id and m.state != :revoked
          )

      repositories =
        Repo.all(
          from r in ForgeRepos.Repository,
            where: r.owner_user_id == ^organization_id
        )

      candidates =
        if config do
          Enum.flat_map(repositories, fn repository ->
            case proof(config, repository.id) do
              {:ok, p} ->
                binding = Repo.get_by(RepositoryMirror, repository_id: repository.id)

                [
                  %{
                    repository_id: repository.id,
                    id: repository.id,
                    slug: repository.slug,
                    source_full_name: p.full_name,
                    full_name: p.full_name,
                    github_repository_id: p.github_id,
                    import_item_id: p.item_id,
                    enrolled:
                      binding != nil and binding.organization_mirror_id == (mirror && mirror.id)
                  }
                ]

              _ ->
                []
            end
          end)
        else
          []
        end

      {:ok, %{config: config, organization_mirror: mirror, candidates: candidates}}
    end
  end

  def handoff(config_id, repository_id) do
    Repo.transaction(fn ->
      config = lock_config(config_id)
      require!(config != nil, :not_found)

      case enrolled_binding(config_id, repository_id) do
        nil -> :legacy
        {_mirror, binding} -> {:mirror, binding}
      end
    end)
  end

  def schedule(actor, config_id, repository_id, request_key)
      when is_binary(request_key) and byte_size(request_key) in 1..255 do
    Repo.transaction(fn ->
      config = lock_config(config_id)
      require!(config != nil, :not_found)

      case ForgeAccounts.fetch_manageable_organization(actor, config.organization_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      {mirror, binding} = enrolled_binding(config_id, repository_id) || Repo.rollback(:not_found)
      check!(authorize(scope(mirror, binding)))
      enqueue!(mirror, binding, "request:#{request_key}", DateTime.utc_now(:second))
    end)
  end

  def schedule(_, _, _, _), do: {:error, :invalid_argument}

  def status(actor, config_id, repository_id, operation_id) do
    with %PatConfiguration{} = config <- Repo.get(PatConfiguration, config_id),
         {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, config.organization_id),
         {mirror, binding} <- enrolled_binding(config_id, repository_id),
         :ok <- authorize(scope(mirror, binding)),
         %MirrorOperation{
           organization_mirror_id: mirror_id,
           repository_mirror_id: binding_id,
           kind: "reconcile.repository.git"
         } = parent <- Repo.get(MirrorOperation, operation_id),
         true <- mirror_id == mirror.id and binding_id == binding.id do
      reconciliation_status(binding, parent, MapSet.new())
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def schedule_committed(config_id, repository_id, request_key, authorize)
      when is_function(authorize, 0) and is_binary(request_key) and
             byte_size(request_key) in 1..255 do
    Repo.transaction(fn ->
      config = lock_config(config_id)
      require!(config != nil and config.credential_source == :organization_device, :not_found)
      check!(authorize.())
      {mirror, binding} = enrolled_binding(config_id, repository_id) || Repo.rollback(:not_found)
      check!(authorize(scope(mirror, binding)))
      enqueue!(mirror, binding, "request:#{request_key}", DateTime.utc_now(:second))
    end)
  end

  @doc false
  def status_committed(config_id, repository_id, operation_id, authorize)
      when is_function(authorize, 0) do
    with :ok <- authorize.(),
         %PatConfiguration{credential_source: :organization_device} <-
           Repo.get(PatConfiguration, config_id),
         {mirror, binding} <- enrolled_binding(config_id, repository_id),
         :ok <- authorize(scope(mirror, binding)),
         %MirrorOperation{
           organization_mirror_id: mid,
           repository_mirror_id: bid,
           kind: "reconcile.repository.git"
         } = operation <- Repo.get(MirrorOperation, operation_id),
         true <- mid == mirror.id and bid == binding.id do
      reconciliation_status(binding, operation, MapSet.new())
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp reconciliation_status(binding, parent, visited) do
    if MapSet.member?(visited, parent.id) or MapSet.size(visited) >= 1_000 do
      {:ok, :pending}
    else
      operations =
        Repo.all(
          from o in MirrorOperation,
            where:
              o.repository_mirror_id == ^binding.id and
                (o.id == ^parent.id or
                   fragment(
                     "?->>'reconciliation_operation_id' = ?",
                     o.cursor,
                     ^Integer.to_string(parent.id)
                   ))
        )

      finalizer = Enum.find(operations, &(&1.kind == "finalize.repository.git"))

      conflict =
        Repo.exists?(
          from c in MirrorConflict,
            where:
              c.repository_mirror_id == ^binding.id and c.state == :open and
                c.resource_kind == "git_ref"
        )

      cond do
        conflict ->
          {:error, :git_divergence}

        failed = Enum.find(operations, &(&1.state == :failed)) ->
          {:error, failure_reason(failed)}

        finalizer == nil or not Enum.all?(operations, &(&1.state == :completed)) ->
          {:ok, :pending}

        finalizer.checkpoint["successful_bootstrap_item_id"] ==
            binding.bootstrap_repository_item_id ->
          {:ok, :complete}

        true ->
          replacement_status(binding, finalizer, MapSet.put(visited, parent.id))
      end
    end
  end

  defp replacement_status(binding, finalizer, visited) do
    case finalizer.checkpoint["replacement_git_operation_id"] do
      id when is_integer(id) and id > finalizer.id ->
        case Repo.get(MirrorOperation, id) do
          %MirrorOperation{repository_mirror_id: binding_id, kind: "reconcile.repository.git"} =
              parent
          when binding_id == binding.id ->
            reconciliation_status(binding, parent, visited)

          %MirrorOperation{
            repository_mirror_id: binding_id,
            kind: "finalize.repository.git",
            cursor: cursor
          }
          when binding_id == binding.id ->
            case Repo.get(MirrorOperation, cursor["reconciliation_operation_id"]) do
              %MirrorOperation{
                repository_mirror_id: ^binding_id,
                kind: "reconcile.repository.git"
              } = parent ->
                reconciliation_status(binding, parent, visited)

              _ ->
                {:ok, :pending}
            end

          _ ->
            {:ok, :pending}
        end

      _ ->
        {:ok, :pending}
    end
  end

  def schedule_all(%OrganizationMirror{credential_source: source} = mirror, key, now)
      when source in [:pat, :organization_device] do
    with :ok <- authorize(scope(mirror)) do
      bindings =
        Repo.all(
          from r in RepositoryMirror,
            where: r.organization_mirror_id == ^mirror.id and r.state in [:active, :discovered],
            order_by: r.id
        )

      Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, operations} ->
        case ForgeMirrors.enqueue_operation(operation_attrs(mirror, binding, key, now)) do
          {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def scope(mirror, binding \\ nil, operation \\ nil) do
    authority =
      Map.take(mirror, @authority_fields)
      |> Map.merge(%{
        credential_source: mirror.credential_source,
        github_installation_id: mirror.github_installation_id,
        organization_mirror_id: mirror.id,
        remote_owner: mirror.github_account_login
      })

    authority =
      if binding do
        [_owner, name] = String.split(binding.github_full_name, "/")

        Map.merge(authority, %{
          repository_mirror_id: binding.id,
          repository_id: binding.repository_id,
          repository_generation: binding.pat_repository_generation,
          github_repository_id: binding.github_repository_id,
          github_node_id: binding.github_node_id,
          remote_repository: name
        })
      else
        authority
      end

    if operation do
      Map.merge(authority, %{
        operation_id: operation.id,
        operation_lock_version: operation.lock_version,
        lease_owner: operation.lease_owner,
        lease_expires_at: operation.lease_expires_at
      })
    else
      authority
    end
  end

  def authorize(%{credential_source: source, organization_mirror_id: id} = supplied)
      when source in [:pat, :organization_device] do
    mirror = Repo.get(OrganizationMirror, id)

    with %OrganizationMirror{credential_source: ^source, state: state} <- mirror,
         :ok <- mirror_state(state),
         true <- Enum.all?(@authority_fields, &(Map.get(mirror, &1) == Map.get(supplied, &1))),
         :ok <- capabilities(mirror),
         %PatConfiguration{} = config <- Repo.get(PatConfiguration, mirror.pat_configuration_id),
         :ok <- configuration_state(config),
         true <- valid_config?(config, mirror),
         credential when not is_nil(credential) <- current_credential(config),
         true <- credential_matches?(credential, mirror),
         :ok <- authorize_repository(supplied, mirror),
         :ok <- authorize_operation(supplied, mirror) do
      :ok
    else
      %OrganizationMirror{state: :paused} ->
        {:error, :paused}

      %OrganizationMirror{state: :revoked} ->
        {:error, :revoked}

      {:error, reason} = error
      when reason in [:lost_lease, :paused, :revoked, :permission_missing, :ref_deletion_disabled] ->
        error

      _ ->
        {:error, :credential_unavailable}
    end
  end

  def authorize(_), do: {:error, :credential_unavailable}

  def authorize_operation_if_pat(operation) do
    case Repo.get(OrganizationMirror, operation.organization_mirror_id) do
      %OrganizationMirror{credential_source: source} = mirror
      when source in [:pat, :organization_device] ->
        case Repo.get(RepositoryMirror, operation.repository_mirror_id) do
          %RepositoryMirror{} = binding -> authorize(scope(mirror, binding, operation))
          _ -> {:error, :credential_unavailable}
        end

      _ ->
        :ok
    end
  end

  defp mirror_state(:paused), do: {:error, :paused}
  defp mirror_state(:revoked), do: {:error, :revoked}
  defp mirror_state(_), do: :ok

  defp authorize_repository(%{repository_mirror_id: id} = supplied, mirror) do
    with %RepositoryMirror{
           organization_mirror_id: mirror_id,
           repository_id: repository_id,
           pat_repository_generation: generation,
           state: state
         } = binding <- Repo.get(RepositoryMirror, id),
         true <- mirror_id == mirror.id and state in [:active, :discovered],
         true <-
           repository_id == supplied.repository_id and
             generation == supplied.repository_generation,
         true <- binding.github_repository_id == supplied.github_repository_id,
         true <-
           supplied.remote_owner == mirror.github_account_login and
             binding.github_full_name ==
               supplied.remote_owner <> "/" <> supplied.remote_repository and
             binding.github_node_id == supplied.github_node_id,
         {:ok, repository} <- ForgeRepos.fetch_live_repository(repository_id),
         true <-
           repository.owner_user_id == mirror.organization_id and
             repository.generation == generation do
      :ok
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  defp authorize_repository(_, _), do: :ok

  defp authorize_operation(%{operation_id: id} = supplied, mirror) do
    case Repo.get(MirrorOperation, id) do
      %MirrorOperation{external_effect_marker: %{"action" => action}}
      when action in ["delete_local", "delete_remote"] ->
        {:error, :ref_deletion_disabled}

      %MirrorOperation{} = operation ->
        if operation.organization_mirror_id == mirror.id and
             operation.repository_mirror_id == Map.get(supplied, :repository_mirror_id) and
             operation.state in [:processing, :effect_pending] and
             operation.lock_version >= supplied.operation_lock_version and
             operation.lease_owner == supplied.lease_owner and
             operation.lease_expires_at == supplied.lease_expires_at and
             is_struct(operation.lease_expires_at, DateTime) and
             DateTime.compare(operation.lease_expires_at, DateTime.utc_now()) == :gt,
           do: :ok,
           else: {:error, :lost_lease}

      _ ->
        {:error, :lost_lease}
    end
  end

  defp authorize_operation(_, _), do: :ok

  defp valid_config?(config, mirror) do
    config.enabled and not config.paused and
      config.lock_version == mirror.pat_configuration_version and
      config.organization_id == mirror.organization_id and
      source_config_matches?(config, mirror) and
      config.owner_user_id == mirror.credential_owner_user_id and
      config.github_identity_id == mirror.github_identity_id and
      String.downcase(config.github_organization) == String.downcase(mirror.github_account_login)
  end

  defp capabilities(mirror) do
    if mirror.capabilities["git"] == true and mirror.capabilities["lfs"] == true,
      do: :ok,
      else: {:error, :permission_missing}
  end

  defp configuration_state(%PatConfiguration{paused: true}), do: {:error, :paused}
  defp configuration_state(_), do: :ok

  defp source_config_matches?(
         %{credential_source: :organization_device} = config,
         %{credential_source: :organization_device} = mirror
       ) do
    Enum.all?(
      [
        :organization_connection_id,
        :organization_connection_version,
        :organization_credential_id,
        :organization_credential_version,
        :github_installation_id
      ],
      &(Map.get(config, &1) == Map.get(mirror, &1))
    )
  end

  defp source_config_matches?(%{credential_source: :personal}, %{credential_source: :pat}),
    do: true

  defp source_config_matches?(_, _), do: false

  defp credential_matches?(credential, %{credential_source: :organization_device} = mirror),
    do:
      credential.id == mirror.organization_credential_id and
        credential.verification_version == mirror.organization_credential_version

  defp credential_matches?(credential, mirror),
    do:
      credential.id == mirror.github_credential_id and
        credential.verification_version == mirror.github_credential_version

  defp current_credential(%{credential_source: :organization_device} = config) do
    with true <- config.enabled and not config.paused,
         %ForgeAccounts.Organization{state: :active} <-
           Repo.get(ForgeAccounts.Organization, config.organization_id),
         {:ok, scope} <-
           ForgeMirrors.OrganizationGitHubConnections.scope(config.organization_connection_id),
         true <- scope.organization_id == config.organization_id,
         true <-
           Enum.all?(organization_snapshots(scope), fn {key, value} ->
             Map.get(config, key) == value
           end) do
      %{id: scope.credential_id, verification_version: scope.verification_version}
    else
      _ -> nil
    end
  end

  defp current_credential(config) do
    with true <- config.enabled and not config.paused,
         %User{} = owner <- Repo.get(User, config.owner_user_id),
         {:ok, _} <-
           ForgeAccounts.organization_github_owner(owner, config.organization_id, owner.id),
         %GitHubIdentity{kind: :user, local_user_id: owner_id} = identity <-
           Repo.get(GitHubIdentity, config.github_identity_id),
         true <- owner_id == owner.id do
      Repo.get_by(GitHubCredential,
        github_identity_id: identity.id,
        local_user_id: owner.id,
        status: :valid
      )
    else
      _ -> nil
    end
  end

  defp credential!(config),
    do: current_credential(config) || Repo.rollback(:credential_unavailable)

  defp lock_config(id),
    do: Repo.one(from c in PatConfiguration, where: c.id == ^id, lock: "FOR UPDATE")

  defp lock_config_by_organization(id),
    do: Repo.one(from c in PatConfiguration, where: c.organization_id == ^id, lock: "FOR UPDATE")

  defp legacy_active?(id),
    do:
      Repo.exists?(
        from j in "organization_pat_sync_runs",
          where: j.configuration_id == ^id and j.state in ["queued", "running"],
          select: j.id
      )

  defp enrolled_binding(config_id, repository_id) do
    Repo.one(
      from r in RepositoryMirror,
        join: m in OrganizationMirror,
        on: m.id == r.organization_mirror_id,
        where:
          m.pat_configuration_id == ^config_id and
            m.credential_source in [:pat, :organization_device] and
            m.state != :revoked and r.repository_id == ^repository_id and
            r.state not in [:revoked, :tombstoned],
        select: {m, r}
    )
  end

  defp proof!(config, id) do
    case proof(config, id) do
      {:ok, proof} -> proof
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp proof(config, id) do
    with {:ok, repository} <- ForgeRepos.fetch_live_repository(id),
         true <- repository.owner_user_id == config.organization_id do
      rows =
        Repo.all(
          from i in "github_import_repository_items",
            join: r in "github_import_runs",
            on: r.id == i.import_run_id,
            where:
              i.hidden_repository_id == ^id and i.state in ["published", "completed"] and
                r.state in ["completed", "completed_with_warnings"] and
                r.destination_organization_id == ^config.organization_id,
            where: ^proof_source(config),
            order_by: [desc: i.id],
            select: %{
              item_id: i.id,
              run_id: r.id,
              github_id: i.github_repository_id,
              full_name: i.source_full_name,
              evidence: i.publication_evidence,
              account_id: r.source_owner_github_id,
              login: r.source_owner_login,
              source_metadata: i.source_metadata
            }
        )

      valid =
        Enum.filter(rows, fn row ->
          e = row.evidence || %{}

          e["state"] == "committed" and e["repository_id"] == id and
            e["owner_user_id"] == config.organization_id and
            e["generation"] == repository.generation and
            e["run_id"] == row.run_id and is_integer(row.account_id) and row.account_id > 0 and
            is_integer(row.github_id) and row.github_id > 0 and
            is_binary(row.login) and
            String.downcase(row.login) == String.downcase(config.github_organization) and
            is_binary(row.full_name) and
            String.starts_with?(String.downcase(row.full_name), String.downcase(row.login) <> "/")
        end)

      case valid do
        [p | _] ->
          if length(Enum.uniq(Enum.map(valid, &{&1.account_id, &1.github_id}))) == 1,
            do:
              {:ok,
               Map.merge(p, %{
                 repository_id: id,
                 generation: repository.generation,
                 node_id: (p.source_metadata || %{})["node_id"]
               })},
            else: {:error, :unverified_import}

        [] ->
          {:error, :unverified_import}
      end
    else
      _ -> {:error, :unverified_import}
    end
  end

  defp proof_source(%{credential_source: :organization_device} = config) do
    dynamic(
      [i, r],
      r.credential_source == "organization_device" and
        r.organization_connection_id == ^config.organization_connection_id and
        r.organization_connection_version == ^config.organization_connection_version and
        r.organization_credential_id == ^config.organization_credential_id and
        r.organization_credential_version == ^config.organization_credential_version and
        r.github_installation_id == ^config.github_installation_id
    )
  end

  defp proof_source(%{
         credential_source: :personal,
         github_identity_id: identity_id,
         owner_user_id: owner_id
       })
       when is_integer(identity_id) and identity_id > 0 and is_integer(owner_id) and owner_id > 0 do
    dynamic(
      [i, r],
      r.credential_source == "saved" and r.github_identity_id == ^identity_id and
        r.actor_user_id == ^owner_id
    )
  end

  defp proof_source(_), do: dynamic(false)

  defp organization_snapshots(scope) do
    %{
      organization_connection_id: scope.connection_id,
      organization_connection_version: scope.connection_version,
      organization_credential_id: scope.credential_id,
      organization_credential_version: scope.verification_version,
      github_installation_id: scope.installation_id
    }
  end

  defp mirror_authority(config, credential) do
    common = %{pat_configuration_version: config.lock_version}

    if config.credential_source == :organization_device do
      Map.merge(
        common,
        Map.take(config, [
          :organization_connection_id,
          :organization_connection_version,
          :organization_credential_id,
          :organization_credential_version,
          :github_installation_id
        ])
      )
    else
      Map.merge(common, %{
        github_credential_id: credential.id,
        github_credential_version: credential.verification_version
      })
    end
  end

  defp mirror!(config, credential, proof) do
    existing =
      Repo.one(
        from m in OrganizationMirror,
          where:
            m.organization_id == ^config.organization_id and m.provider == "github" and
              m.state != :revoked,
          lock: "FOR UPDATE"
      )

    if existing do
      require!(
        existing.credential_source ==
          if(config.credential_source == :organization_device,
            do: :organization_device,
            else: :pat
          ) and existing.pat_configuration_id == config.id and
          existing.github_account_id == proof.account_id and
          existing.credential_owner_user_id == config.owner_user_id and
          existing.github_identity_id == config.github_identity_id and
          String.downcase(existing.github_account_login) == String.downcase(proof.login),
        :already_bound
      )

      changes = mirror_authority(config, credential)

      if Enum.all?(changes, fn {key, value} -> Map.get(existing, key) == value end) do
        existing
      else
        case existing
             |> Ecto.Changeset.change(changes)
             |> Ecto.Changeset.optimistic_lock(:lock_version)
             |> Repo.update() do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    else
      attrs =
        Map.merge(mirror_authority(config, credential), %{
          organization_id: config.organization_id,
          provider: "github",
          github_account_id: proof.account_id,
          github_account_login: proof.login,
          pat_configuration_id: config.id,
          credential_owner_user_id: config.owner_user_id,
          github_identity_id: config.github_identity_id,
          bootstrap_import_run_id: proof.run_id
        })

      changeset =
        if config.credential_source == :organization_device,
          do: OrganizationMirror.organization_enrollment_changeset(%OrganizationMirror{}, attrs),
          else: OrganizationMirror.pat_enrollment_changeset(%OrganizationMirror{}, attrs)

      changeset
      |> insert!()
    end
  end

  defp binding!(mirror, p) do
    existing = Repo.get_by(RepositoryMirror, repository_id: p.repository_id)

    if existing do
      require!(
        existing.organization_mirror_id == mirror.id and
          existing.github_repository_id == p.github_id and
          existing.pat_repository_generation == p.generation and
          existing.state in [:active, :discovered],
        :already_bound
      )

      existing
    else
      %RepositoryMirror{}
      |> RepositoryMirror.create_changeset(%{
        organization_mirror_id: mirror.id,
        repository_id: p.repository_id,
        pat_repository_generation: p.generation,
        github_repository_id: p.github_id,
        github_node_id: p.node_id,
        github_full_name: p.full_name,
        bootstrap_repository_item_id: p.item_id
      })
      |> insert!()
    end
  end

  defp operation_attrs(mirror, binding, key, now),
    do: %{
      organization_mirror_id: mirror.id,
      repository_mirror_id: binding.id,
      kind: "reconcile.repository.git",
      dedupe_key: "pat-git:#{mirror.id}:#{binding.id}:#{key}",
      cursor: %{},
      next_attempt_at: now
    }

  defp enqueue!(mirror, binding, key, now) do
    case ForgeMirrors.enqueue_operation(operation_attrs(mirror, binding, key, now)) do
      {:ok, operation} -> operation
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
  defp require!(true, _), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)

  defp failure_reason(%{failure_class: reason})
       when reason in ["git_divergence", "stale_baseline"], do: :git_divergence

  defp failure_reason(%{failure_class: "lfs_missing"}), do: :lfs_missing
  defp failure_reason(%{failure_class: "lfs_integrity"}), do: :lfs_integrity
  defp failure_reason(_), do: :reconciliation_failed
end
