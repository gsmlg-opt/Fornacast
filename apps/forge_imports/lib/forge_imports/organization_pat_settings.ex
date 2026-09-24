defmodule ForgeImports.OrganizationPatSettings do
  @moduledoc "Read-only GitHub inventory discovery for future PAT synchronization."
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
