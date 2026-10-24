defmodule ForgeImports.OrganizationPublicSync do
  @moduledoc "Anonymous GitHub organization inventory and durable inbound synchronization."
  import Ecto.Query
  alias ForgeMirrors.PatSettings
  alias Fornacast.Repo

  def view(actor, organization_id) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      config =
        Repo.get_by(ForgeMirrors.PatConfiguration, organization_id: organization_id) ||
          %ForgeMirrors.PatConfiguration{
            organization_id: organization_id,
            github_organization: organization.username
          }

      history =
        Repo.all(
          from job in ForgeImports.PatSyncRun,
            where: job.organization_id == ^organization_id,
            order_by: [desc: job.id],
            limit: 20
        )

      credential =
        if config.credential_source == :public,
          do: %{credential_present: true, credential_status: :valid, credential_kind: :public},
          else: nil

      {:ok, %{config: config, credential: credential, owners: [], history: history}}
    end
  end

  def configure(actor, organization_id, attrs, metadata, opts \\ []) do
    with {:ok, _organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         true <-
           is_map(attrs) and Enum.sort(Map.keys(attrs)) == ~w(github_organization lock_version),
         login when is_binary(login) <- attrs["github_organization"],
         true <- byte_size(login) <= 128 and String.valid?(login),
         login = String.downcase(String.trim(login)),
         true <- Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/, login),
         {:ok, source} <-
           inventory(actor, login, Keyword.put(opts, :local_organization_id, organization_id)) do
      PatSettings.activate_public_source(
        actor,
        organization_id,
        source,
        attrs["lock_version"],
        metadata
      )
    else
      {:error, %{kind: kind}} -> {:error, kind}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def sync(actor, organization_id, version, metadata),
    do:
      ForgeImports.OrganizationPatSettings.sync(actor, organization_id, version, metadata,
        required_source: :public
      )

  def refresh(actor, organization_id, version, metadata, opts \\ []) do
    with {:ok, %{config: %{credential_source: :public} = config}} <-
           view(actor, organization_id),
         {:ok, source} <-
           inventory(
             actor,
             config.github_organization,
             Keyword.put(opts, :local_organization_id, organization_id)
           ),
         true <- source.github_organization_id == config.github_organization_id do
      PatSettings.store_inventory(actor, organization_id, version, source.inventory, metadata)
    else
      {:error, %{kind: kind}} -> {:error, kind}
      {:error, _} = error -> error
      _ -> {:error, :source_changed}
    end
  end

  @doc false
  def adopt_import(
        %ForgeImports.ImportRun{
          credential_source: :public,
          organization_sync_run_id: nil,
          source_kind: :organization,
          destination_organization_id: id,
          state: state
        } = run
      )
      when state in [:completed, :completed_with_warnings] and is_integer(id) do
    Repo.transact(fn ->
      Repo.one(
        from org in ForgeAccounts.Organization,
          where: org.id == ^run.destination_organization_id,
          lock: "FOR UPDATE"
      )

      config =
        Repo.get_by(ForgeMirrors.PatConfiguration,
          organization_id: run.destination_organization_id
        )

      if is_nil(config) or
           (config.credential_source == :personal and not config.enabled and
              is_nil(config.owner_user_id) and is_nil(config.github_identity_id)) do
        items =
          Repo.all(from item in ForgeImports.RepositoryItem, where: item.import_run_id == ^run.id)

        source = %{
          github_organization: String.downcase(run.source_owner_login),
          github_organization_id: run.source_owner_github_id,
          inventory: %{
            "repositories" =>
              Enum.map(
                items,
                &%{
                  "id" => &1.github_repository_id,
                  "full_name" => &1.source_full_name,
                  "visibility" => "public"
                }
              )
          }
        }

        with %ForgeAccounts.User{} = actor <- Repo.get(ForgeAccounts.User, run.actor_user_id),
             {:ok, _} <-
               PatSettings.activate_public_source(
                 actor,
                 run.destination_organization_id,
                 source,
                 if(config, do: config.lock_version, else: 1),
                 run.request_metadata
               ) do
          {:ok, :adopted}
        else
          {:error, _} = error -> error
          _ -> {:error, :forbidden}
        end
      else
        {:ok, :unchanged}
      end
    end)
  end

  def adopt_import(_), do: {:ok, :unchanged}

  defp inventory(actor, login, opts) do
    client = Keyword.get(opts, :client, ForgeGitHub.Client)
    client_opts = Keyword.put(Keyword.get(opts, :client_options, []), :gate_key, {:public, 1})

    with {:ok, %ForgeGitHub.Organization{} = org} <-
           client.organization(:public, login, client_opts),
         true <- org.id > 0 and String.downcase(org.login) == login,
         :ok <- ForgeAccounts.GitHubProfileSafety.validate(org, :public),
         {:ok, repositories} <- client.organization_repositories(:public, login, client_opts),
         true <- is_list(repositories) and length(repositories) <= 10_000,
         true <-
           Enum.all?(repositories, fn
             %ForgeGitHub.Repository{visibility: :public} = repo ->
               repo.id > 0 and repo.owner_id == org.id and
                 String.downcase(repo.owner_login) == login and
                 String.downcase(repo.full_name) == login <> "/" <> String.downcase(repo.name) and
                 ForgeAccounts.GitHubProfileSafety.validate(repo, :public) == :ok

             _ ->
               false
           end),
         true <- length(Enum.uniq_by(repositories, & &1.id)) == length(repositories),
         {:ok, _} <-
           ForgeAccounts.fetch_manageable_organization(
             actor,
             Keyword.fetch!(opts, :local_organization_id)
           ) do
      {:ok,
       %{
         github_organization: login,
         github_organization_id: org.id,
         inventory: %{
           "repositories" =>
             Enum.map(
               repositories,
               &%{"id" => &1.id, "full_name" => &1.full_name, "visibility" => "public"}
             )
         }
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_inventory}
    end
  end
end
