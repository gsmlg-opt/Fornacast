defmodule ForgeMirrors.PatSettings do
  @moduledoc "Organization-owner PAT configuration, separate from active App mirrors."
  import Ecto.Query
  import Ecto.Changeset
  alias ForgeMirrors.PatConfiguration
  alias Fornacast.{Repo, Audit}

  def view(actor, organization_id) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         {:ok, owners} <- ForgeAccounts.organization_github_owners(actor, organization_id) do
      config =
        Repo.get_by(PatConfiguration, organization_id: organization_id) ||
          %PatConfiguration{
            organization_id: organization_id,
            github_organization: organization.username
          }

      {:ok, %{config: config, owners: owners, credential: credential(config, owners)}}
    end
  end

  def activate_organization_connection(actor, organization_id, scope, version, metadata) do
    mutate(actor, organization_id, to_string(version), metadata, fn config, _owners ->
      with true <- scope.organization_id == organization_id,
           false <- active_work?(config),
           {:ok, current} <- ForgeMirrors.OrganizationGitHubConnections.scope(scope.connection_id),
           true <- same_organization_scope?(scope, current),
           :ok <- adopt_organization_mirror(config, current) do
        {:ok,
         change(
           config,
           Map.merge(organization_snapshots(current), %{
             credential_source: :organization_device,
             github_organization_id: nil,
             configured_by_user_id: actor.id,
             owner_user_id: nil,
             github_identity_id: nil,
             github_organization: current.github_organization,
             enabled: true,
             paused: false,
             inventory: current.inventory,
             inventory_refreshed_at: DateTime.utc_now(:second),
             repository_selection: "all",
             selected_repository_ids: [],
             last_sync_at: nil,
             last_sync_status: nil,
             last_sync_summary: %{}
           })
         )}
      else
        true -> {:error, :busy}
        false -> {:error, :credential_unavailable}
        {:error, _} = error -> error
      end
    end)
  end

  def activate_public_source(actor, organization_id, source, version, metadata) do
    expected = if to_string(version) == "0", do: "1", else: to_string(version)

    mutate(
      actor,
      organization_id,
      expected,
      metadata,
      fn config, _owners ->
        cond do
          to_string(version) == "0" and not is_nil(config.id) ->
            {:error, :stale}

          active_work?(config) or active_import?(organization_id) ->
            {:error, :busy}

          Repo.exists?(
            from m in ForgeMirrors.OrganizationMirror,
              where: m.organization_id == ^organization_id and m.state != :revoked
          ) ->
            {:error, :busy}

          true ->
            {:ok,
             change(config, %{
               credential_source: :public,
               configured_by_user_id: actor.id,
               owner_user_id: nil,
               github_identity_id: nil,
               organization_connection_id: nil,
               organization_connection_version: nil,
               organization_credential_id: nil,
               organization_credential_version: nil,
               github_installation_id: nil,
               github_organization: source.github_organization,
               github_organization_id: source.github_organization_id,
               enabled: true,
               paused: false,
               trigger_mode: "manual",
               inventory: source.inventory,
               inventory_refreshed_at: DateTime.utc_now(:second),
               repository_selection: "all",
               selected_repository_ids: [],
               last_sync_at: nil,
               last_sync_status: nil,
               last_sync_summary: %{}
             })}
        end
      end,
      public: true
    )
  end

  def save(actor, organization_id, attrs, metadata) when is_map(attrs) do
    mutate(actor, organization_id, attrs["lock_version"], metadata, fn config, owners ->
      if Map.has_key?(attrs, "lock_version") and
           Enum.all?(
             Map.keys(attrs),
             &(&1 in ~w(owner_user_id github_identity_id github_organization enabled paused trigger_mode interval_minutes lock_version))
           ) do
        changeset = PatConfiguration.changeset(config, attrs)
        candidate = apply_changes(changeset)

        cond do
          config.credential_source in [:organization_device, :public] and
              Enum.any?(
                ~w(owner_user_id github_identity_id github_organization),
                &Map.has_key?(attrs, &1)
              ) ->
            {:error, :invalid_request}

          not changeset.valid? ->
            {:error, :invalid_request}

          candidate.owner_user_id != nil and candidate.owner_user_id != config.owner_user_id and
              not Enum.any?(owners, &(&1.id == candidate.owner_user_id)) ->
            {:error, :credential_unavailable}

          candidate.enabled and not valid_credential?(credential(candidate, owners)) ->
            {:error, :credential_unavailable}

          candidate.github_identity_id != nil and credential(candidate, owners) == nil and
              (candidate.github_identity_id != config.github_identity_id or
                 candidate.owner_user_id != config.owner_user_id) ->
            {:error, :credential_unavailable}

          true ->
            changed_source =
              Enum.any?(
                [:owner_user_id, :github_identity_id, :github_organization],
                &(Map.get(candidate, &1) != Map.get(config, &1))
              )

            changeset =
              if changed_source do
                change(changeset,
                  inventory: %{},
                  inventory_refreshed_at: nil,
                  selected_repository_ids: [],
                  repository_selection: "all",
                  last_sync_at: nil,
                  last_sync_status: nil,
                  last_sync_summary: %{}
                )
              else
                changeset
              end

            {:ok, changeset}
        end
      else
        {:error, :invalid_request}
      end
    end)
  end

  def mark_sync(actor, organization_id, status, metadata)
      when status in ["running", "succeeded", "failed"] do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, %{config: config}} <- view(actor, organization_id) do
      changes =
        change(config,
          last_sync_at: DateTime.utc_now(:second),
          last_sync_status: status,
          last_sync_summary: if(status == "running", do: %{}, else: config.last_sync_summary)
        )

      with {:ok, saved} <- Repo.update(changes),
           {:ok, _audit} <-
             Audit.record(
               actor,
               "organization.github_pat.sync",
               "organization",
               organization_id,
               %{"status" => status},
               request_metadata: safe_metadata
             ) do
        {:ok, saved}
      end
    end
  end

  @doc false
  def record_sync_summary(job_id, summary) when is_integer(job_id) and is_map(summary) do
    # Settling an admitted job must remain possible after its owner loses access.
    # Use the persisted source snapshot, never a caller-supplied configuration.
    job =
      Repo.one(
        from j in "organization_pat_sync_runs",
          where: j.id == ^job_id,
          select:
            map(j, [
              :id,
              :configuration_id,
              :organization_id,
              :owner_user_id,
              :github_identity_id,
              :github_organization,
              :credential_source,
              :organization_connection_id,
              :organization_connection_version,
              :organization_credential_id,
              :organization_credential_version,
              :github_installation_id,
              :github_organization_id,
              :public_configuration_version,
              :state
            ])
      )

    case job do
      nil ->
        {:error, :not_found}

      job ->
        {count, _} =
          Repo.update_all(
            from(c in PatConfiguration,
              as: :configuration,
              where:
                c.id == ^job.configuration_id and c.organization_id == ^job.organization_id and
                  fragment("? IS NOT DISTINCT FROM ?", c.owner_user_id, ^job.owner_user_id) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    c.github_identity_id,
                    ^job.github_identity_id
                  ) and
                  c.github_organization == ^job.github_organization and
                  fragment(
                    "(? <> 'public' OR (? = ? AND ? = ?))",
                    c.credential_source,
                    c.lock_version,
                    ^job.public_configuration_version,
                    c.github_organization_id,
                    ^job.github_organization_id
                  ) and
                  fragment("? = ?", c.credential_source, ^job.credential_source) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    c.organization_connection_id,
                    ^job.organization_connection_id
                  ) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    c.organization_connection_version,
                    ^job.organization_connection_version
                  ) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    c.organization_credential_id,
                    ^job.organization_credential_id
                  ) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    c.organization_credential_version,
                    ^job.organization_credential_version
                  ) and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    c.github_installation_id,
                    ^job.github_installation_id
                  ) and
                  not exists(
                    from newer in "organization_pat_sync_runs",
                      where:
                        newer.configuration_id == parent_as(:configuration).id and
                          newer.id > ^job.id,
                      select: newer.id
                  )
            ),
            set: [last_sync_summary: summary, last_sync_status: job.state]
          )

        if count == 1, do: :ok, else: {:error, :configuration_changed}
    end
  end

  def set_paused(actor, organization_id, paused, metadata) when is_boolean(paused) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, %{config: config}} <- view(actor, organization_id),
         {:ok, saved} <- Repo.update(change(config, paused: paused)),
         {:ok, _audit} <-
           Audit.record(
             actor,
             "organization.github_pat.pause",
             "organization",
             organization_id,
             %{"paused" => paused},
             request_metadata: safe_metadata
           ) do
      {:ok, saved}
    end
  end

  def select_repositories(actor, organization_id, attrs, metadata) when is_map(attrs) do
    mutate(actor, organization_id, attrs["lock_version"], metadata, fn config, _owners ->
      with true <-
             Enum.sort(Map.keys(attrs)) ==
               Enum.sort(~w(lock_version repository_selection selected_repository_ids)),
           mode when mode in ["all", "selected"] <- attrs["repository_selection"],
           values when is_list(values) and length(values) <= 10_001 <-
             attrs["selected_repository_ids"],
           {:ok, ids} <- ids(Enum.reject(values, &(&1 == ""))),
           true <- mode == "all" or ids != [],
           available = config.inventory |> Map.get("repositories", []) |> Enum.map(& &1["id"]),
           true <- Enum.all?(ids, &(&1 in available)) do
        {:ok, change(config, repository_selection: mode, selected_repository_ids: ids)}
      else
        _ -> {:error, :invalid_request}
      end
    end)
  end

  @doc false
  def store_inventory(actor, organization_id, version, inventory, metadata) do
    mutate(actor, organization_id, version, metadata, fn config, owners ->
      if valid_credential?(credential(config, owners)) do
        {:ok,
         change(config, inventory: inventory, inventory_refreshed_at: DateTime.utc_now(:second))}
      else
        {:error, :credential_unavailable}
      end
    end)
  end

  defp mutate(actor, organization_id, version, metadata, fun, opts \\ []) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata) do
      Repo.transact(fn ->
        with {:ok, _organization} <-
               ForgeAccounts.fetch_manageable_organization(actor, organization_id),
             # Serialize creation as well as later configuration changes.
             _ <-
               Repo.one(
                 from o in ForgeAccounts.Organization,
                   where: o.id == ^organization_id,
                   lock: "FOR UPDATE"
               ),
             {:ok, %{config: config, owners: owners}} <-
               mutation_view(actor, organization_id, opts),
             true <- to_string(config.lock_version) == version,
             {:ok, changeset} <- fun.(config, owners),
             {:ok, saved} <-
               Repo.insert_or_update(change(changeset, lock_version: config.lock_version + 1)),
             {:ok, _audit} <-
               Audit.record(
                 actor,
                 "organization.github_pat.configure",
                 "organization",
                 organization_id,
                 %{},
                 request_metadata: safe_metadata
               ) do
          {:ok, saved}
        else
          false -> {:error, :stale}
          {:error, %Ecto.Changeset{}} -> {:error, :invalid_request}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defp mutation_view(actor, organization_id, opts) do
    if Keyword.get(opts, :public, false) do
      with {:ok, org} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
        config =
          Repo.get_by(PatConfiguration, organization_id: organization_id) ||
            %PatConfiguration{organization_id: organization_id, github_organization: org.username}

        {:ok, %{config: config, owners: []}}
      end
    else
      view(actor, organization_id)
    end
  end

  defp credential(%PatConfiguration{credential_source: :public}, _owners),
    do: %{credential_present: true, credential_status: :valid, credential_kind: :public}

  defp credential(%PatConfiguration{credential_source: :organization_device} = config, _owners) do
    scope = Map.merge(organization_scope(config), %{organization_id: config.organization_id})

    if valid_organization_connection?(scope),
      do: %{
        credential_present: true,
        credential_status: :valid,
        credential_kind: :github_app_user
      },
      else: nil
  end

  defp credential(config, owners) do
    with %{accounts: accounts} <- Enum.find(owners, &(&1.id == config.owner_user_id)) do
      Enum.find(accounts, &(&1.identity_id == config.github_identity_id))
    end
  end

  defp organization_snapshots(scope) do
    %{
      organization_connection_id: scope.connection_id,
      organization_connection_version: scope.connection_version,
      organization_credential_id: scope.credential_id,
      organization_credential_version: scope.verification_version,
      github_installation_id: scope.installation_id
    }
  end

  defp organization_scope(config) do
    %{
      connection_id: config.organization_connection_id,
      connection_version: config.organization_connection_version,
      credential_id: config.organization_credential_id,
      verification_version: config.organization_credential_version,
      installation_id: config.github_installation_id
    }
  end

  defp valid_organization_connection?(scope) do
    case ForgeMirrors.OrganizationGitHubConnections.scope(scope.connection_id) do
      {:ok, current} -> same_organization_scope?(scope, current)
      _ -> false
    end
  end

  defp same_organization_scope?(scope, current),
    do:
      Enum.all?(
        [
          :organization_id,
          :connection_id,
          :connection_version,
          :credential_id,
          :verification_version,
          :installation_id
        ],
        &(Map.get(current, &1) == Map.get(scope, &1))
      )

  defp adopt_organization_mirror(config, scope) do
    case Repo.one(
           from mirror in ForgeMirrors.OrganizationMirror,
             where:
               mirror.organization_id == ^config.organization_id and mirror.provider == "github" and
                 mirror.state != :revoked,
             lock: "FOR UPDATE"
         ) do
      nil ->
        :ok

      %{credential_source: source} = mirror when source in [:pat, :organization_device] ->
        with true <- mirror.github_account_id == scope.github_organization_id,
             true <- mirror.capabilities == %{"git" => true, "lfs" => true},
             true <- mirror.policy["auto_import_new_repositories"] == false,
             true <- accessible_bindings?(mirror, scope),
             :ok <-
               ForgeMirrors.OrganizationGitHubConnections.claim_identity(
                 config.organization_id,
                 scope.github_organization_id,
                 scope.installation_id
               ) do
          changes =
            Map.merge(organization_snapshots(scope), %{
              credential_source: :organization_device,
              pat_configuration_id: config.id,
              pat_configuration_version: config.lock_version + 1,
              credential_owner_user_id: nil,
              github_identity_id: nil,
              github_credential_id: nil,
              github_credential_version: nil,
              github_account_login: scope.github_organization
            })

          case Repo.update(change(mirror, changes) |> optimistic_lock(:lock_version)) do
            {:ok, _} -> :ok
            {:error, _} -> {:error, :stale}
          end
        else
          {:error, _} = error -> error
          _ -> {:error, :already_bound}
        end

      _ ->
        {:error, :already_bound}
    end
  end

  defp accessible_bindings?(mirror, scope) do
    available = MapSet.new(scope.inventory["repositories"] || [], & &1["id"])

    Repo.all(
      from binding in ForgeMirrors.RepositoryMirror,
        where:
          binding.organization_mirror_id == ^mirror.id and binding.state in [:active, :discovered],
        select: binding.github_repository_id
    )
    |> Enum.all?(&MapSet.member?(available, &1))
  end

  defp active_import?(organization_id) do
    Repo.exists?(
      from run in "github_import_runs",
        where:
          run.destination_organization_id == ^organization_id and
            run.state not in ["completed", "completed_with_warnings", "failed", "canceled"],
        select: run.id
    )
  end

  defp active_work?(%{id: nil}), do: false

  defp active_work?(config) do
    Repo.exists?(
      from run in "organization_pat_sync_runs",
        where: run.configuration_id == ^config.id and run.state in ["queued", "running"],
        select: run.id
    ) or
      Repo.exists?(
        from operation in ForgeMirrors.MirrorOperation,
          join: mirror in ForgeMirrors.OrganizationMirror,
          on: mirror.id == operation.organization_mirror_id,
          where:
            mirror.organization_id == ^config.organization_id and mirror.state != :revoked and
              (operation.state == :effect_pending or
                 (operation.state == :processing and
                    (operation.lease_expires_at > fragment("timezone('UTC', clock_timestamp())") or
                       fragment(
                         "COALESCE(?, '{}'::jsonb) <> '{}'::jsonb",
                         operation.external_effect_marker
                       ))))
      )
  end

  defp valid_credential?(%{credential_present: true, credential_status: :valid}), do: true
  defp valid_credential?(_), do: false

  defp ids(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case is_binary(value) && Integer.parse(value) do
        {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 ->
          if Integer.to_string(id) == value and id not in acc,
            do: {:cont, {:ok, [id | acc]}},
            else: {:halt, {:error, :invalid_request}}

        _ ->
          {:halt, {:error, :invalid_request}}
      end
    end)
  end
end
