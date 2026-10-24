defmodule ForgeImports.OrganizationPatSettings do
  @moduledoc "GitHub organization inventory and PAT-backed synchronization entrypoints."
  import Ecto.Query

  alias ForgeImports.{ImportRun, PatSyncRun, RepositoryItem}
  alias ForgeMirrors.PatSettings

  def refresh(actor, organization_id, version, metadata, opts \\ []) do
    with {:ok, %{config: config}} <- PatSettings.view(actor, organization_id) do
      case config.credential_source do
        :organization_device ->
          refresh_organization(actor, config, version, metadata, opts)

        :public ->
          ForgeImports.OrganizationPublicSync.refresh(
            actor,
            organization_id,
            version,
            metadata,
            opts
          )

        _ ->
          refresh_personal(actor, organization_id, version, metadata, opts)
      end
    end
  end

  defp refresh_organization(actor, config, version, metadata, opts) do
    with true <- to_string(config.lock_version) == version,
         {:ok, scope} <-
           ForgeImports.OrganizationGitHubConnection.scope(config.organization_connection_id),
         true <- ForgeImports.OrganizationExecution.scope_matches?(config, scope) do
      ForgeImports.OrganizationGitHubConnection.with_credential(
        scope,
        fn _token, current ->
          case PatSettings.store_inventory(
                 actor,
                 config.organization_id,
                 version,
                 current.inventory,
                 metadata
               ) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end,
        opts
      )
      |> organization_result()
    else
      false -> {:error, :stale}
      {:error, _} = error -> error
    end
  end

  defp refresh_personal(actor, organization_id, version, metadata, opts) do
    client = Keyword.get(opts, :client, ForgeGitHub.Client)

    with {:ok, %{config: config}} <- PatSettings.view(actor, organization_id),
         true <- config.id != nil and to_string(config.lock_version) == version,
         {:ok, owner} <-
           ForgeAccounts.organization_github_owner(actor, organization_id, config.owner_user_id) do
      credential_call(
        owner,
        config.github_identity_id,
        fn token ->
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
        end,
        opts
      )
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Immediately queues a durable synchronization of every PAT-visible organization repository."
  def restart_sync(actor, organization_id, version, metadata, opts \\ []),
    do: sync(actor, organization_id, version, metadata, Keyword.put(opts, :restart, true))

  def sync(actor, organization_id, version, metadata, opts \\ []) do
    with {:ok, %{config: config}} <-
           ForgeImports.OrganizationPublicSync.view(actor, organization_id) do
      cond do
        Keyword.has_key?(opts, :required_source) and
            config.credential_source != opts[:required_source] ->
          {:error, :source_changed}

        config.credential_source in [:organization_device, :public] ->
          sync_organization(actor, config, version, metadata, opts)

        true ->
          sync_personal(actor, organization_id, version, metadata, opts)
      end
    end
  end

  @doc false
  def sync_organization_configuration(config, metadata) do
    if config.credential_source in [:organization_device, :public],
      do: sync_organization(nil, config, to_string(config.lock_version), metadata, []),
      else: {:error, :invalid_context}
  end

  defp sync_organization(actor, expected, version, metadata, opts) do
    alias ForgeImports.OrganizationExecution
    alias Fornacast.Repo

    with {:ok, metadata} <- ForgeAccounts.validate_github_request_metadata(metadata) do
      Repo.transact(fn ->
        Repo.one(
          from org in ForgeAccounts.Organization,
            where: org.id == ^expected.organization_id,
            lock: "FOR UPDATE"
        )

        with :ok <- authorize_source_request(actor, expected),
             %ForgeMirrors.PatConfiguration{} = config <-
               Repo.one(
                 from c in ForgeMirrors.PatConfiguration,
                   where: c.id == ^expected.id,
                   lock: "FOR UPDATE"
               ),
             :ok <- required_source(config, opts),
             :ok <- sync_enabled(config, version),
             {:ok, scope} <-
               configuration_scope(config),
             true <- OrganizationExecution.scope_matches?(config, scope) do
          active =
            Repo.one(
              from job in PatSyncRun,
                where: job.configuration_id == ^config.id and job.state in ["queued", "running"],
                lock: "FOR UPDATE"
            )

          cond do
            active && active.credential_source == config.credential_source &&
                OrganizationExecution.scope_matches?(active, scope) ->
              if Keyword.get(opts, :restart, false),
                do: restart_organization_job(active, actor, config, scope, metadata),
                else: queue_job(active)

            active ->
              {:error, :busy}

            true ->
              with {:ok, job} <- insert_organization_job(actor, config, scope, metadata),
                   {:ok, recovered} <- recover_organization_import(job, scope),
                   do: queue_job(recovered)
          end
        else
          false -> {:error, :configuration_changed}
          {:error, _} = error -> error
          _ -> {:error, :configuration_changed}
        end
      end)
    end
  end

  defp required_source(config, opts) do
    if Keyword.has_key?(opts, :required_source) and
         config.credential_source != opts[:required_source],
       do: {:error, :source_changed},
       else: :ok
  end

  defp configuration_scope(%{credential_source: :public} = config),
    do: {:ok, ForgeImports.OrganizationExecution.public_scope(config)}

  defp configuration_scope(config),
    do: ForgeImports.OrganizationGitHubConnection.scope(config.organization_connection_id)

  defp insert_organization_job(actor, config, scope, metadata) do
    attrs =
      Map.merge(ForgeImports.OrganizationExecution.snapshots(scope), %{
        configuration_id: config.id,
        organization_id: config.organization_id,
        credential_source: config.credential_source,
        requested_by_user_id: if(actor, do: actor.id, else: config.configured_by_user_id),
        github_organization: scope.github_organization,
        github_organization_id: scope.github_organization_id,
        request_metadata: metadata
      })

    with {:ok, job} <- Fornacast.Repo.insert(struct(PatSyncRun, attrs)),
         {:ok, _} <-
           Fornacast.Repo.update(
             Ecto.Changeset.change(config,
               last_sync_at: DateTime.utc_now(:second),
               last_sync_status: "running",
               last_sync_summary: %{}
             )
           ),
         do: {:ok, job}
  end

  defp restart_organization_job(previous, actor, config, scope, metadata) do
    with :ok <- fence_organization_job(previous, metadata),
         {:ok, _} <-
           previous
           |> Ecto.Changeset.change(
             state: "failed",
             error: "sync_restarted",
             finished_at: DateTime.utc_now(:second),
             lease_owner: nil,
             lease_expires_at: nil
           )
           |> Fornacast.Repo.update(),
         {:ok, job} <- insert_organization_job(actor, config, scope, metadata),
         {:ok, job} <- recover_organization_import(job, scope),
         do: queue_job(job)
  end

  defp fence_organization_job(%{import_run_id: nil}, _metadata), do: :ok

  defp fence_organization_job(previous, metadata) do
    with %ImportRun{} = run <- Fornacast.Repo.get(ImportRun, previous.import_run_id) do
      if run.state in ImportRun.terminal_states() do
        :ok
      else
        with {:ok, execution} <- ForgeImports.OrganizationExecution.for_run(run),
             {:ok, _} <- ForgeImports.Retry.fence_organization_restart(execution, run, metadata),
             do: :ok
      end
    else
      _ -> {:error, :import_unavailable}
    end
  end

  defp recover_organization_import(job, scope) do
    candidates =
      Fornacast.Repo.all(
        from previous in PatSyncRun,
          join: run in ImportRun,
          on: run.id == previous.import_run_id,
          left_join: successor in ImportRun,
          on: successor.predecessor_run_id == run.id,
          where:
            previous.configuration_id == ^job.configuration_id and previous.state == "failed" and
              previous.credential_source == ^job.credential_source and is_nil(successor.id) and
              run.credential_source == ^job.credential_source and
              run.state in [:failed, :canceled, :completed_with_warnings],
          order_by: [desc: previous.id]
      )

    previous =
      Enum.find(candidates, fn candidate ->
        ForgeImports.OrganizationExecution.scope_matches?(candidate, scope) and
          Fornacast.Repo.exists?(
            from item in RepositoryItem,
              where:
                item.import_run_id == ^candidate.import_run_id and
                  item.selected == true and item.state in [:failed, :canceled] and
                  is_nil(item.cleanup_state) and item.publication_evidence == ^%{}
          )
      end)

    if previous do
      metadata = Map.put(job.request_metadata, "operation_id", "organization-pat-sync-#{job.id}")

      with {:ok, execution} <- ForgeImports.OrganizationExecution.for_sync(job),
           {:ok, successor} <-
             ForgeImports.Retry.organization_successor(
               execution,
               Fornacast.Repo.get!(ImportRun, previous.import_run_id),
               metadata
             ),
           do: attach_successor(job, previous, successor, metadata)
    else
      {:ok, job}
    end
  end

  defp authorize_source_request(nil, config) do
    case Fornacast.Repo.get(ForgeAccounts.Organization, config.organization_id) do
      %{state: :active} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_source_request(actor, config) do
    case ForgeAccounts.fetch_manageable_organization(actor, config.organization_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp sync_personal(actor, organization_id, version, metadata, opts) do
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
                   else: queue_job(active)
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
                   queue_job(job)
                 end
               end
             else
               {:error, reason} -> {:error, reason}
               _ -> {:error, :credential_unavailable}
             end
           end) do
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
      queue_job(job)
    end
  end

  defp recover_import(job, owner, config) do
    previous =
      Fornacast.Repo.one(
        from j in PatSyncRun,
          join: r in ImportRun,
          on: r.id == j.import_run_id,
          left_join: successor in ImportRun,
          on: successor.predecessor_run_id == r.id,
          join: i in RepositoryItem,
          on: i.import_run_id == r.id,
          where:
            j.configuration_id == ^config.id and j.state == "failed" and
              j.owner_user_id == ^owner.id and j.github_identity_id == ^config.github_identity_id and
              j.github_organization == ^config.github_organization and
              is_nil(successor.id) and
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

  defp queue_job(job) do
    with {:ok, _} <- ForgeImports.SyncJobs.enqueue_pat_sync(job.id), do: {:ok, job}
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
    with {:ok, %{config: config}} <- PatSettings.view(actor, organization_id) do
      case config.credential_source do
        :organization_device ->
          check_organization(config, opts)

        :public ->
          with {:ok, _} <-
                 ForgeImports.OrganizationPublicSync.refresh(
                   actor,
                   organization_id,
                   to_string(config.lock_version),
                   %{},
                   opts
                 ),
               do: {:ok, length(config.inventory["repositories"] || [])}

        _ ->
          check_personal(actor, organization_id, opts)
      end
    end
  end

  defp check_organization(config, opts) do
    ref = make_ref()

    with {:ok, scope} <-
           ForgeImports.OrganizationGitHubConnection.scope(config.organization_connection_id),
         true <- ForgeImports.OrganizationExecution.scope_matches?(config, scope),
         :ok <-
           organization_result(
             ForgeImports.OrganizationGitHubConnection.with_credential(
               scope,
               fn _token, current ->
                 send(self(), {ref, length(current.inventory["repositories"] || [])})
                 :ok
               end,
               opts
             )
           ) do
      receive do
        {^ref, count} ->
          {:ok,
           %{
             owner: nil,
             github_organization: scope.github_organization,
             credential_status: :valid,
             repository_count: count,
             checked_at: DateTime.utc_now(:second)
           }}
      after
        0 -> {:error, :unavailable}
      end
    else
      false -> {:error, :configuration_changed}
      {:error, _} = error -> error
    end
  end

  defp organization_result({:ok, :ok}), do: :ok
  defp organization_result({:ok, {:error, reason}}), do: {:error, reason}
  defp organization_result({:error, _} = error), do: error
  defp organization_result(_), do: {:error, :unavailable}

  defp check_personal(actor, organization_id, opts) do
    client = Keyword.get(opts, :client, ForgeGitHub.Client)

    with {:ok, %{config: config, credential: credential}} <-
           PatSettings.view(actor, organization_id),
         true <- config.id != nil,
         true <- credential != nil,
         {:ok, owner} <-
           ForgeAccounts.organization_github_owner(actor, organization_id, config.owner_user_id),
         {:ok, repositories} <-
           credential_call(
             owner,
             config.github_identity_id,
             fn token ->
               client.organization_repositories(token, config.github_organization,
                 gate_key: {:saved_credential, config.github_identity_id}
               )
             end,
             opts
           ) do
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

  defp credential_call(owner, identity_id, callback, opts) do
    ref = make_ref()
    caller = self()

    result =
      ForgeGitHub.SavedCredential.with_credential(
        owner,
        identity_id,
        fn token ->
          send(caller, {:organization_pat_credential_result, ref, callback.(token)})
          :ok
        end,
        opts
      )

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
