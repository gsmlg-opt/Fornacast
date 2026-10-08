defmodule ForgeImports.OrganizationPatSettings do
  @moduledoc "GitHub organization inventory and PAT-backed synchronization entrypoints."
  import Ecto.Query
  @allow_test_options Mix.env() == :test

  alias ForgeImports.{ImportRun, PatSyncRun, RepositoryItem}
  alias ForgeMirrors.PatSettings

  def refresh(actor, organization_id, version, metadata, opts \\ []) do
    client = Keyword.get(opts, :client, ForgeGitHub.Client)

    with {:ok, %{config: config}} <- PatSettings.view(actor, organization_id),
         true <- config.id != nil and to_string(config.lock_version) == version,
         {:ok, owner} <-
           ForgeAccounts.organization_github_owner(actor, organization_id, config.owner_user_id) do
      credential_call(owner, config.github_identity_id, fn token ->
        with {:ok, repositories} <-
               client.organization_repositories(token, config.github_organization,
                 gate_key: {:saved_credential, config.github_identity_id}
               ),
             true <- is_list(repositories) and length(repositories) <= 10_000,
             true <-
               Enum.all?(
                 repositories,
                 &(String.downcase(&1.owner_login) == config.github_organization)
               ),
             :ok <- ForgeAccounts.validate_github_external_profiles(owner, repositories),
             inventory = %{
               "repositories" =>
                 Enum.map(repositories, fn repo ->
                   %{
                     "id" => repo.id,
                     "full_name" => repo.full_name,
                     "visibility" => to_string(repo.visibility)
                   }
                 end)
             },
             {:ok, _saved} <-
               PatSettings.store_inventory(actor, organization_id, version, inventory, metadata) do
          :ok
        else
          false -> {:error, :invalid_inventory}
          {:error, %ForgeGitHub.Error{kind: kind}} -> {:error, kind}
          {:error, reason} when is_atom(reason) -> {:error, reason}
          _ -> {:error, :unavailable}
        end
      end)
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Immediately queues a durable synchronization of every PAT-visible organization repository."
  def restart_sync(actor, organization_id, version, metadata, opts \\ []),
    do: sync(actor, organization_id, version, metadata, Keyword.put(opts, :restart, true))

  def sync(actor, organization_id, version, metadata, opts \\ []) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, job} <-
           Fornacast.Repo.transact(fn ->
             with {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id),
                  {:ok, snapshot} <- lock_sync_owners(actor, organization_id),
                  _locked <-
                    Fornacast.Repo.one(
                      from c in ForgeMirrors.PatConfiguration,
                        where: c.organization_id == ^organization_id,
                        lock: "FOR UPDATE"
                    ),
                  {:ok, %{config: config, credential: credential}} <-
                    PatSettings.view(actor, organization_id),
                  :ok <- unchanged_sync_owner(snapshot, config),
                  :ok <- sync_enabled(config, version),
                  %{credential_present: true, credential_status: :valid} <- credential,
                  {:ok, owner} <-
                    ForgeAccounts.organization_github_owner(
                      actor,
                      organization_id,
                      config.owner_user_id
                    ) do
               active =
                 Fornacast.Repo.one(
                   from j in PatSyncRun,
                     where: j.configuration_id == ^config.id and j.state in ["queued", "running"],
                     lock: "FOR UPDATE"
                 )

               same_source? =
                 not is_nil(active) and active.owner_user_id == owner.id and
                   active.github_identity_id == config.github_identity_id and
                   active.github_organization == config.github_organization

               if same_source? do
                 if Keyword.get(opts, :restart, false),
                   do: restart_job(active, owner, config, safe_metadata),
                   else: {:ok, active}
               else
                 if active do
                   Fornacast.Repo.update_all(from(j in PatSyncRun, where: j.id == ^active.id),
                     set: [
                       state: "failed",
                       error: "configuration_changed",
                       lease_owner: nil,
                       lease_expires_at: nil,
                       finished_at: DateTime.utc_now(:second)
                     ]
                   )
                 end

                 with {:ok, job} <-
                        Fornacast.Repo.insert(%PatSyncRun{
                          configuration_id: config.id,
                          organization_id: organization_id,
                          owner_user_id: owner.id,
                          github_identity_id: config.github_identity_id,
                          github_organization: config.github_organization,
                          request_metadata: safe_metadata
                        }),
                      {:ok, job} <- recover_import(job, owner, config),
                      {:ok, _} <-
                        PatSettings.mark_sync(actor, organization_id, "running", safe_metadata) do
                   {:ok, job}
                 end
               end
             else
               {:error, reason} -> {:error, reason}
               _ -> {:error, :credential_unavailable}
             end
           end) do
      dispatch(opts)

      {:ok, job}
    end
  end

  defp lock_sync_owners(actor, organization_id) do
    case Fornacast.Repo.get_by(ForgeMirrors.PatConfiguration,
           organization_id: organization_id
         ) do
      nil ->
        {:error, :stale}

      snapshot ->
        ids = Enum.reject([actor.id, snapshot.owner_user_id, organization_id], &is_nil/1)

        # Recovery and publication fences acquire lifecycle rows before run/configuration rows.
        Fornacast.Repo.all(
          from user in ForgeAccounts.User,
            where: user.id in ^ids,
            order_by: user.id,
            lock: "FOR UPDATE"
        )

        with {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
          {:ok, snapshot}
        end
    end
  end

  defp unchanged_sync_owner(snapshot, config) do
    if config.id == snapshot.id and config.owner_user_id == snapshot.owner_user_id,
      do: :ok,
      else: {:error, :stale}
  end

  defp restart_job(previous, owner, config, metadata) do
    with {:ok, _} <-
           previous
           |> Ecto.Changeset.change(
             state: "failed",
             error: "sync_restarted",
             finished_at: DateTime.utc_now(:second),
             lease_owner: nil,
             lease_expires_at: nil
           )
           |> Fornacast.Repo.update(),
         {:ok, job} <-
           Fornacast.Repo.insert(%PatSyncRun{
             configuration_id: config.id,
             organization_id: config.organization_id,
             owner_user_id: owner.id,
             github_identity_id: config.github_identity_id,
             github_organization: config.github_organization,
             request_metadata: metadata
           }),
         metadata <- Map.put(metadata, "operation_id", "organization-pat-sync-#{job.id}"),
         {:ok, successor} <-
           ForgeImports.restart_import(
             owner,
             previous.import_run_id,
             {:saved, config.github_identity_id},
             metadata
           ),
         {:ok, job} <- attach_successor(job, previous, successor, metadata),
         {:ok, _} <- PatSettings.mark_sync(owner, config.organization_id, "running", metadata) do
      {:ok, job}
    end
  end

  defp recover_import(job, owner, config) do
    previous =
      Fornacast.Repo.one(
        from j in PatSyncRun,
          join: r in ImportRun,
          on: r.id == j.import_run_id,
          join: i in RepositoryItem,
          on: i.import_run_id == r.id,
          where:
            j.configuration_id == ^config.id and j.state == "failed" and
              j.owner_user_id == ^owner.id and j.github_identity_id == ^config.github_identity_id and
              j.github_organization == ^config.github_organization and
              r.state in [:failed, :canceled, :completed_with_warnings] and
              i.selected == true and i.state in [:failed, :canceled] and
              is_nil(i.cleanup_state) and i.publication_evidence == ^%{},
          distinct: j.id,
          order_by: [desc: j.id],
          limit: 1
      )

    if previous do
      metadata = Map.put(job.request_metadata, "operation_id", "organization-pat-sync-#{job.id}")

      with {:ok, successor} <-
             ForgeImports.retry_import(
               owner,
               previous.import_run_id,
               {:saved, config.github_identity_id},
               metadata
             ) do
        attach_successor(job, previous, successor, metadata)
      end
    else
      {:ok, job}
    end
  end

  defp attach_successor(job, previous, successor, metadata) do
    current_items =
      Fornacast.Repo.all(from i in RepositoryItem, where: i.import_run_id == ^successor.id)

    with {:ok, retained} <-
           ForgeImports.PatSyncProgress.restore_ancestor_imports(
             job,
             successor,
             previous.progress,
             current_items
           ) do
      progress =
        current_items
        |> Enum.reduce(retained, fn item, rows ->
          Map.put(rows, to_string(item.id), %{
            "github_repository_id" => item.github_repository_id,
            "source_full_name" => item.source_full_name,
            "mode" => "import",
            "status" => "pending"
          })
        end)

      job
      |> Ecto.Changeset.change(
        import_run_id: successor.id,
        progress: progress,
        request_metadata: metadata
      )
      |> Fornacast.Repo.update()
    end
  end

  if @allow_test_options do
    defp dispatch(opts) do
      if Keyword.get(opts, :dispatch, :async) != :manual, do: ForgeImports.PatSyncWorker.kick()
    end
  else
    defp dispatch(_opts), do: ForgeImports.PatSyncWorker.kick()
  end

  defp sync_enabled(config, version) do
    cond do
      is_nil(config.id) or to_string(config.lock_version) != version -> {:error, :stale}
      config.paused -> {:error, :paused}
      not config.enabled -> {:error, :not_enabled}
      true -> :ok
    end
  end

  def check(actor, organization_id, opts \\ []) do
    client = Keyword.get(opts, :client, ForgeGitHub.Client)

    with {:ok, %{config: config, credential: credential}} <-
           PatSettings.view(actor, organization_id),
         true <- config.id != nil,
         true <- credential != nil,
         {:ok, owner} <-
           ForgeAccounts.organization_github_owner(actor, organization_id, config.owner_user_id),
         {:ok, repositories} <-
           credential_call(owner, config.github_identity_id, fn token ->
             client.organization_repositories(token, config.github_organization,
               gate_key: {:saved_credential, config.github_identity_id}
             )
           end) do
      {:ok,
       %{
         owner: owner.username,
         github_organization: config.github_organization,
         credential_status: credential.credential_status,
         repository_count: length(repositories),
         checked_at: DateTime.utc_now(:second)
       }}
    else
      false -> {:error, :invalid_request}
      {:error, %ForgeGitHub.Error{kind: kind}} -> {:error, kind}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_call(owner, identity_id, callback) do
    ref = make_ref()
    caller = self()

    result =
      ForgeAccounts.with_github_credential(owner, identity_id, fn token ->
        send(caller, {:organization_pat_credential_result, ref, callback.(token)})
        :ok
      end)

    case result do
      {:ok, :ok} ->
        receive do
          {:organization_pat_credential_result, ^ref, value} -> value
        after
          30_000 -> {:error, :timeout}
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
