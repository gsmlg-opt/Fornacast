defmodule ForgeImports.OrganizationExecution do
  @moduledoc false

  import Ecto.Query
  alias ForgeImports.{ImportRun, PatSyncRun, RepositoryItem}
  alias ForgeMirrors.PatConfiguration
  alias Fornacast.Repo

  # id is immutable audit provenance. This is never a User or a replacement owner.
  @enforce_keys [:id, :organization_id, :pat_sync_run_id]
  defstruct [:id, :username, :organization_id, :pat_sync_run_id, :run_id]

  @fields [
    {:organization_connection_id, :connection_id},
    {:organization_connection_version, :connection_version},
    {:organization_credential_id, :credential_id},
    {:organization_credential_version, :verification_version},
    {:github_installation_id, :installation_id}
  ]

  def for_sync(%PatSyncRun{credential_source: source} = job)
      when source in [:organization_device, :public] do
    with {:ok, _scope, _config} <- sync_context(job) do
      {:ok,
       %__MODULE__{
         id: job.requested_by_user_id,
         username: organization_login(job.organization_id),
         organization_id: job.organization_id,
         pat_sync_run_id: job.id,
         run_id: job.import_run_id
       }}
    end
  end

  def audit_principal(%ImportRun{credential_source: source, organization_sync_run_id: id} = run)
      when source in [:organization_device, :public] and not is_nil(id) do
    %__MODULE__{
      id: run.actor_user_id,
      username: organization_login(run.destination_organization_id),
      organization_id: run.destination_organization_id,
      pat_sync_run_id: run.organization_sync_run_id,
      run_id: run.id
    }
  end

  def for_run(%ImportRun{credential_source: source, organization_sync_run_id: id} = run)
      when source in [:organization_device, :public] and not is_nil(id) do
    with %PatSyncRun{} = job <- Repo.get(PatSyncRun, run.organization_sync_run_id),
         {:ok, execution} <- for_sync(job),
         :ok <- run_binding(run, job) do
      {:ok, %{execution | run_id: run.id}}
    else
      {:error, _} = error -> error
      _ -> {:error, :configuration_changed}
    end
  end

  def authorize(%__MODULE__{} = execution, opts \\ []) do
    with %PatSyncRun{} = observed <- Repo.get(PatSyncRun, execution.pat_sync_run_id),
         true <-
           observed.organization_id == execution.organization_id and
             observed.requested_by_user_id == execution.id,
         {:ok, scope, _config} <- sync_context(observed, opts),
         %PatSyncRun{} = job <- locked(PatSyncRun, observed.id, opts),
         true <- job.state in ["queued", "running"] and scope_matches?(job, scope),
         :ok <- authorize_run(execution, job, opts) do
      {:ok, scope}
    else
      {:error, _} = error -> error
      _ -> {:error, :configuration_changed}
    end
  end

  def authorize_item(%ImportRun{} = run, %RepositoryItem{} = item, opts \\ []) do
    with {:ok, execution} <- for_run(run),
         true <-
           item.import_run_id == run.id and item.destination_owner_id == execution.organization_id,
         {:ok, scope} <- authorize(execution, opts) do
      {:ok, execution, scope}
    else
      {:error, _} = error -> error
      _ -> {:error, :configuration_changed}
    end
  end

  def snapshots(%{credential_source: :public} = scope),
    do: %{public_configuration_version: scope.configuration_version}

  def snapshots(scope) do
    Map.new(@fields, fn {field, key} -> {field, Map.fetch!(scope, key)} end)
  end

  def scope_matches?(record, %{credential_source: :public} = scope) do
    record.credential_source == :public and
      if is_struct(record, PatConfiguration),
        do:
          record.id == scope.configuration_id and
            record.lock_version == scope.configuration_version,
        else: record.public_configuration_version == scope.configuration_version
  end

  def scope_matches?(record, scope) do
    Enum.all?(@fields, fn {field, key} -> Map.get(record, field) == Map.get(scope, key) end)
  end

  def sync_context(job, opts \\ [])

  def sync_context(%PatSyncRun{credential_source: :public} = job, opts) do
    with %ForgeAccounts.Organization{state: :active} <-
           locked(ForgeAccounts.Organization, job.organization_id, opts),
         %PatConfiguration{credential_source: :public} = config <-
           locked(PatConfiguration, job.configuration_id, opts),
         true <-
           job.state in ["queued", "running"] and config.organization_id == job.organization_id and
             config.github_organization == job.github_organization and
             config.github_organization_id == job.github_organization_id and
             config.lock_version == job.public_configuration_version do
      cond do
        config.paused -> {:error, :paused}
        not config.enabled -> {:error, :configuration_changed}
        true -> {:ok, public_scope(config), config}
      end
    else
      _ -> {:error, :configuration_changed}
    end
  end

  def sync_context(job, opts) do
    with %ForgeAccounts.Organization{state: :active} <-
           locked(ForgeAccounts.Organization, job.organization_id, opts),
         %ForgeMirrors.OrganizationGitHubConnection{} <-
           locked(ForgeMirrors.OrganizationGitHubConnection, job.organization_connection_id, opts),
         %ForgeAccounts.OrganizationGitHubCredential{} <-
           locked(
             ForgeAccounts.OrganizationGitHubCredential,
             job.organization_credential_id,
             opts
           ),
         %PatConfiguration{credential_source: :organization_device} = config <-
           locked(PatConfiguration, job.configuration_id, opts),
         true <-
           job.state in ["queued", "running"] and config.organization_id == job.organization_id,
         true <- config.enabled,
         false <- config.paused,
         {:ok, scope} <-
           ForgeImports.OrganizationGitHubConnection.scope(job.organization_connection_id),
         true <-
           scope.organization_id == job.organization_id and
             scope.github_organization_id == job.github_organization_id,
         true <-
           config.github_organization == job.github_organization and
             scope.github_organization == job.github_organization,
         true <- scope_matches?(job, scope) and scope_matches?(config, scope) do
      {:ok, scope, config}
    else
      false -> {:error, :configuration_changed}
      true -> {:error, :paused}
      {:error, _} = error -> error
      _ -> {:error, :configuration_changed}
    end
  end

  def public_scope(config) do
    %{
      credential_source: :public,
      organization_id: config.organization_id,
      configuration_id: config.id,
      configuration_version: config.lock_version,
      github_organization: config.github_organization,
      github_organization_id: config.github_organization_id
    }
  end

  defp authorize_run(%{run_id: nil}, %{import_run_id: nil}, _opts), do: :ok
  defp authorize_run(%{run_id: nil}, _job, _opts), do: {:error, :configuration_changed}

  defp authorize_run(execution, job, opts) do
    with %ImportRun{} = run <-
           locked(ImportRun, execution.run_id, opts),
         :ok <- run_binding(run, job),
         true <-
           Keyword.get(opts, :allow_terminal, false) or
             run.state not in ImportRun.terminal_states() do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :configuration_changed}
    end
  end

  defp run_binding(run, job) do
    if run.credential_source == job.credential_source and
         run.public_configuration_version == job.public_configuration_version and
         job.import_run_id == run.id and
         run.organization_sync_run_id == job.id and
         run.destination_organization_id == job.organization_id and
         run.source_owner_github_id == job.github_organization_id and
         Enum.all?(@fields, fn {field, _} -> Map.get(run, field) == Map.get(job, field) end),
       do: :ok,
       else: {:error, :configuration_changed}
  end

  defp organization_login(id) do
    case Repo.get(ForgeAccounts.Organization, id) do
      %{username: username} -> username
      _ -> nil
    end
  end

  defp locked(schema, id, opts) do
    query = from row in schema, where: row.id == ^id

    query =
      if Repo.in_transaction?() and Keyword.get(opts, :lock, false) do
        if schema == ImportRun and Keyword.get(opts, :run_lock) == :update,
          do: lock(query, "FOR UPDATE"),
          else: lock(query, "FOR SHARE")
      else
        query
      end

    Repo.one(query)
  end
end
