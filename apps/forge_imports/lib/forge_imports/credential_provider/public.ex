defmodule ForgeImports.CredentialProvider.Public do
  @moduledoc false
  @behaviour ForgeImports.CredentialProvider
  alias ForgeAccounts.User
  alias ForgeImports.{ImportRun, RepositoryItem, OrganizationExecution}
  alias Fornacast.Repo

  def checkout(
        %{run: %ImportRun{credential_source: :public} = expected, capability: capability},
        callback,
        opts
      )
      when is_function(callback, 2) do
    with %ImportRun{credential_source: :public} = run <- Repo.get(ImportRun, expected.id),
         true <- same_run_snapshot?(run, expected),
         :ok <- authorize(run),
         {:ok, current} <- current_capability(run, capability),
         :ok <- validate_source(run, current, opts),
         :ok <- authorize(run),
         {:ok, _} <- current_capability(run, capability) do
      case callback.(:public, %{
             git_login: nil,
             authentication: :anonymous,
             gate_key: {:public, 1}
           }) do
        :ok -> {:ok, :acknowledged}
        {:error, reason} when is_atom(reason) -> {:ok, :acknowledged}
        _ -> {:error, :unsafe_credential_result}
      end
    else
      {:error, %ForgeGitHub.Error{} = error} -> {:error, error}
      {:error, _} = error -> error
      _ -> {:error, :invalid_context}
    end
  end

  def checkout(_, _, _), do: {:error, :invalid_context}

  def authorize(%ImportRun{organization_sync_run_id: id} = run) when not is_nil(id) do
    with {:ok, execution} <- OrganizationExecution.for_run(run),
         {:ok, _} <- OrganizationExecution.authorize(execution),
         do: :ok
  end

  def authorize(run) do
    with %User{kind: :user, state: :active} = actor <- Repo.get(User, run.actor_user_id),
         :ok <- destination(actor, run),
         :ok <- ForgeImports.PatSyncWorker.import_authorized?(run.id),
         do: :ok
  end

  defp destination(actor, %{destination_organization_id: id}) when not is_nil(id) do
    case ForgeAccounts.fetch_manageable_organization(actor, id) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp destination(_, _), do: :ok

  def validate_source(_run, %ImportRun{}, _opts), do: :ok

  def validate_source(run, %RepositoryItem{} = item, opts) do
    client = Keyword.get(opts, :client, ForgeGitHub.Client)
    client_opts = Keyword.put(Keyword.delete(opts, :client), :gate_key, {:public, 1})
    [owner, repository] = String.split(item.source_full_name, "/", parts: 2)

    with {:ok, %ForgeGitHub.Repository{visibility: :public} = source} <-
           client.repository(:public, owner, repository, client_opts),
         true <-
           source.id == item.github_repository_id and
             source.owner_id == run.source_owner_github_id and
             String.downcase(source.owner_login) == String.downcase(run.source_owner_login) and
             String.downcase(source.full_name) == String.downcase(item.source_full_name),
         :ok <- ForgeAccounts.GitHubProfileSafety.validate(source, :public) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :source_changed}
    end
  end

  defp current_capability(run, %ImportRun{} = expected) do
    current = Repo.get(ImportRun, expected.id)

    if current && current.id == run.id && current.lock_version == expected.lock_version &&
         current.lease_owner == expected.lease_owner && live?(current.lease_expires_at) &&
         current.state == :discovering && same_run_snapshot?(current, expected),
       do: {:ok, current},
       else: {:error, :invalid_context}
  end

  defp current_capability(run, %RepositoryItem{} = expected) do
    current = Repo.get(RepositoryItem, expected.id)

    if current && current.import_run_id == run.id && current.lock_version == expected.lock_version &&
         current.lease_owner == expected.lease_owner && live?(current.lease_expires_at) &&
         current.selected &&
         current.state in [:staging_git, :git_staged, :staging_metadata] &&
         is_nil(current.cleanup_state) &&
         Repo.get!(ImportRun, run.id).state == :running &&
         same_snapshot?(current, expected, [
           :import_run_id,
           :github_repository_id,
           :source_full_name,
           :destination_owner_id,
           :destination_slug,
           :destination_visibility,
           :source_name,
           :attempt_count
         ]) &&
         match?(
           %ForgeImports.ImportAttempt{state: :running},
           Repo.get_by(ForgeImports.ImportAttempt,
             repository_item_id: current.id,
             attempt_number: current.attempt_count
           )
         ), do: {:ok, current}, else: {:error, :invalid_context}
  end

  defp current_capability(_, _), do: {:error, :invalid_context}

  defp same_run_snapshot?(current, expected) do
    same_snapshot?(current, expected, [
      :credential_source,
      :actor_user_id,
      :organization_sync_run_id,
      :public_configuration_version,
      :organization_connection_id,
      :organization_connection_version,
      :organization_credential_id,
      :organization_credential_version,
      :github_installation_id,
      :source_kind,
      :source_owner_github_id,
      :source_owner_login,
      :destination_organization_id,
      :destination_organization_action
    ])
  end

  defp same_snapshot?(current, expected, fields),
    do: Enum.all?(fields, &(Map.get(current, &1) == Map.get(expected, &1)))

  defp live?(%DateTime{} = time), do: DateTime.compare(time, DateTime.utc_now(:second)) == :gt
  defp live?(_), do: false
end
