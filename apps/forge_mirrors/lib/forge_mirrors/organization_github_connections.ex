defmodule ForgeMirrors.OrganizationGitHubConnections do
  @moduledoc "Persistence and lifecycle fences for organization App user connections."
  import Ecto.Query
  alias ForgeAccounts.{OrganizationMember, User}
  alias ForgeMirrors.{OrganizationGitHubConnection, OrganizationMirror}
  alias Fornacast.{Audit, Repo}

  def get(organization_id),
    do: Repo.get_by(OrganizationGitHubConnection, organization_id: organization_id)

  def get_by_id(id) when is_integer(id), do: Repo.get(OrganizationGitHubConnection, id)
  def get_by_id(_), do: nil

  def scope(id) do
    with %OrganizationGitHubConnection{state: :ready} = connection <- get_by_id(id),
         {:ok, credential} <-
           ForgeAccounts.OrganizationGitHubCredentials.current_reference(
             connection.organization_id
           ),
         true <-
           credential.status == :valid and credential.credential_id == connection.credential_id and
             credential.verification_version == connection.credential_version and
             credential.client_id == connection.client_id and
             credential.github_app_id == connection.github_app_id do
      {:ok,
       %{
         organization_id: connection.organization_id,
         connection_id: connection.id,
         connection_version: connection.lock_version,
         credential_id: connection.credential_id,
         verification_version: connection.credential_version,
         installation_id: connection.installation_id,
         github_organization_id: connection.github_organization_id,
         github_organization: connection.github_organization,
         inventory: connection.inventory,
         permissions: connection.permissions,
         repository_selection: connection.repository_selection,
         github_app_id: connection.github_app_id,
         client_id: connection.client_id,
         state: :ready
       }}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def transaction(actor, organization_id, expected_version, callback) do
    Repo.transact(fn ->
      with :ok <- lock_management(actor, organization_id),
           connection <-
             Repo.one(
               from c in OrganizationGitHubConnection,
                 where: c.organization_id == ^organization_id,
                 lock: "FOR UPDATE"
             ),
           true <-
             to_string(if(connection, do: connection.lock_version, else: 0)) ==
               to_string(expected_version) do
        callback.(connection || %OrganizationGitHubConnection{organization_id: organization_id})
      else
        false -> {:error, :stale}
        {:error, _} = error -> error
      end
    end)
  end

  def store_grant(connection, reference, actor, metadata) do
    persist(
      connection,
      %{
        credential_id: reference.credential_id,
        credential_version: reference.verification_version,
        github_app_id: reference.github_app_id,
        client_id: reference.client_id,
        inventory: %{},
        permissions: %{},
        state: :installation_required,
        lock_version: next_version(connection)
      },
      actor,
      "organization.github.connect",
      metadata
    )
  end

  def bind(connection, installation, inventory, actor, metadata, ready? \\ true) do
    with :ok <- authorize_mutation(connection, actor),
         true <- installation.account_type == :organization and installation.state == :active,
         true <-
           not ready? or
             Enum.all?(
               ~w(contents issues pull_requests),
               &(installation.permissions[&1] in ["read", "write"])
             ),
         :ok <-
           claim_identity(connection.organization_id, installation.account_id, installation.id) do
      cond do
        connection.github_organization_id != nil and
            connection.github_organization_id != installation.account_id ->
          {:error, :organization_mismatch}

        Repo.exists?(
          from m in OrganizationMirror,
            where:
              m.provider == "github" and m.state != :revoked and
                  ((m.github_account_id == ^installation.account_id and
                      m.organization_id != ^connection.organization_id) or
                     (m.organization_id == ^connection.organization_id and
                        m.github_account_id != ^installation.account_id))
        ) ->
          {:error, :identity_conflict}

        true ->
          persist(
            connection,
            %{
              github_organization_id: installation.account_id,
              github_organization: String.downcase(installation.account_login),
              installation_id: installation.id,
              inventory: inventory,
              permissions: installation.permissions,
              repository_selection: to_string(installation.repository_selection),
              state: if(ready?, do: :ready, else: :permissions_missing),
              observed_at: DateTime.utc_now(:second),
              lock_version: next_version(connection)
            },
            actor,
            "organization.github.bind",
            metadata
          )
      end
    else
      false -> {:error, :insufficient_installation_access}
      error -> error
    end
  end

  @doc false
  def claim_identity(organization_id, github_account_id, installation_id \\ nil) do
    if Repo.in_transaction?() do
      installation_id = installation_id || 0

      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "fornacast-github-organization:#{github_account_id}"
      ])

      connection_conflict =
        Repo.exists?(
          from c in OrganizationGitHubConnection,
            where:
              c.state != :disconnected and c.organization_id != ^organization_id and
                (c.github_organization_id == ^github_account_id or
                   c.installation_id == ^installation_id)
        )

      mirror_conflict =
        Repo.exists?(
          from m in OrganizationMirror,
            where:
              m.provider == "github" and m.state != :revoked and
                m.github_account_id == ^github_account_id and
                m.organization_id != ^organization_id
        )

      if connection_conflict or mirror_conflict, do: {:error, :identity_conflict}, else: :ok
    else
      {:error, :transaction_required}
    end
  end

  def disconnect(connection, reference, actor, metadata) do
    persist(
      connection,
      %{
        credential_version: reference.verification_version,
        state: :disconnected,
        inventory: %{},
        permissions: %{},
        lock_version: next_version(connection)
      },
      actor,
      "organization.github.disconnect",
      metadata
    )
  end

  defp persist(connection, attrs, actor, action, metadata) do
    with :ok <- authorize_mutation(connection, actor),
         {:ok, credential} <-
           ForgeAccounts.OrganizationGitHubCredentials.current_reference(
             connection.organization_id
           ),
         true <-
           Map.get(attrs, :credential_id, connection.credential_id) == credential.credential_id and
             Map.get(attrs, :credential_version, connection.credential_version) ==
               credential.verification_version and
             Map.get(attrs, :client_id, connection.client_id) == credential.client_id and
             Map.get(attrs, :github_app_id, connection.github_app_id) == credential.github_app_id,
         true <- attrs[:state] == :disconnected or credential.status == :valid,
         {:ok, metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, saved} <-
           Repo.insert_or_update(OrganizationGitHubConnection.changeset(connection, attrs)),
         {:ok, _} <-
           Audit.record(
             actor,
             action,
             "organization",
             connection.organization_id,
             %{"connection_id" => saved.id, "state" => to_string(saved.state)},
             request_metadata: metadata
           ) do
      {:ok, saved}
    else
      false -> {:error, :stale}
      {:error, %Ecto.Changeset{}} -> {:error, :identity_conflict}
      error -> error
    end
  end

  defp authorize_mutation(connection, actor) do
    with true <- Repo.in_transaction?(),
         :ok <- lock_management(actor, connection.organization_id),
         current <-
           Repo.one(
             from c in OrganizationGitHubConnection,
               where: c.organization_id == ^connection.organization_id,
               lock: "FOR UPDATE"
           ),
         true <- current_row?(connection, current) do
      :ok
    else
      false -> {:error, :stale}
      error -> error
    end
  end

  defp current_row?(
         %OrganizationGitHubConnection{organization_id: organization_id} = supplied,
         nil
       ),
       do: supplied == %OrganizationGitHubConnection{organization_id: organization_id}

  defp current_row?(
         %OrganizationGitHubConnection{} = supplied,
         %OrganizationGitHubConnection{} = current
       ) do
    fields = OrganizationGitHubConnection.__schema__(:fields)
    Map.take(supplied, fields) == Map.take(current, fields)
  end

  defp current_row?(_, _), do: false

  defp next_version(%{id: nil}), do: 1
  defp next_version(connection), do: connection.lock_version + 1

  defp lock_management(%User{id: actor_id} = actor, organization_id) do
    Repo.all(
      from u in User,
        where: u.id in ^Enum.sort(Enum.uniq([actor_id, organization_id])),
        order_by: u.id,
        lock: "FOR UPDATE"
    )

    Repo.all(
      from m in OrganizationMember,
        where: m.organization_id == ^organization_id and m.user_id == ^actor_id,
        lock: "FOR UPDATE"
    )

    case ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp lock_management(_, _), do: {:error, :forbidden}
end
