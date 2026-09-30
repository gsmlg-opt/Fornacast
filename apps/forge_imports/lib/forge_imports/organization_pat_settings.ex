defmodule ForgeImports.OrganizationPatSettings do
  @moduledoc "GitHub organization inventory and PAT-backed synchronization entrypoints."
  import Ecto.Query

  alias ForgeImports.ImportRun
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

  @doc "Starts or reuses the durable organization import for the saved PAT."
  def sync(actor, organization_id, version, metadata, opts \\ []) do
    imports = Keyword.get(opts, :imports, ForgeImports)
    dispatch = Keyword.get(opts, :dispatch, :async)
    import_opts = if Mix.env() == :test, do: [dispatch: dispatch], else: []

    with {:ok, %{config: config}} <- PatSettings.view(actor, organization_id),
         true <- config.id != nil and to_string(config.lock_version) == version,
         false <- config.paused,
         true <- config.enabled,
         {:ok, owner} <-
           ForgeAccounts.organization_github_owner(actor, organization_id, config.owner_user_id),
         {:ok, run} <-
           start_or_reuse(
             actor,
             organization_id,
             config,
             owner,
             metadata,
             imports,
             import_opts
           ) do
      {:ok, run}
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

  defp start_or_reuse(actor, organization_id, config, owner, metadata, imports, import_opts) do
    case existing_run(actor, organization_id, config.github_organization) do
      {:ok, _run} = result ->
        result

      nil ->
        imports.create_organization_discovery(
          owner,
          %{
            organization: config.github_organization,
            credential_source: :saved,
            github_identity_id: config.github_identity_id,
            destination_organization: %{action: :existing, id: organization_id}
          },
          metadata,
          import_opts
        )
    end
  end

  defp existing_run(actor, organization_id, source_login) do
    actor_id = actor.id

    query =
      from run in ImportRun,
        where:
          run.actor_user_id == ^actor_id and
            run.destination_organization_id == ^organization_id and
            run.source_kind == :organization and
            run.source_owner_login == ^source_login and
            run.state not in ^ImportRun.terminal_states(),
        order_by: [desc: run.id],
        limit: 1

    case Fornacast.Repo.one(query) do
      %ImportRun{} = run -> ForgeImports.get_run(actor, run.id)
      nil -> nil
    end
  end
end
