defmodule ForgeGitHub.OrganizationMirrorCredentialTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{OrganizationGitHubCredentials, User}
  alias ForgeGitHub.{AppInstallation, MirrorCredential, UserInstallation}
  alias ForgeMirrors.OrganizationGitHubConnections, as: Connections
  alias Fornacast.Repo

  defmodule Client do
    def user_installations(_token, _opts) do
      permissions = Process.get(:mirror_permissions, %{"contents" => "read"})

      {:ok,
       [
         %UserInstallation{
           app_id: 5_412_311,
           app_slug: "fornacast",
           client_id: "Iv23lizCVE3E24s7fCA0",
           installation: %AppInstallation{
             id: 44,
             account_id: 91,
             account_login: "source-org",
             account_type: :organization,
             state: :active,
             repository_selection: :selected,
             permissions: permissions
           }
         }
       ]}
    end

    def user_installation_repositories(_token, 44, _opts) do
      if hook = Process.delete(:mirror_inventory_hook), do: hook.()

      {:ok,
       Process.get(:mirror_inventory, [
         %ForgeGitHub.Repository{
           id: 501,
           owner_id: 91,
           owner_login: "source-org",
           name: "project",
           full_name: "source-org/project",
           visibility: :private,
           default_branch: "main",
           has_issues: true,
           allow_merge_commit: true,
           fork: false,
           archived: false
         }
       ])}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        username: "mirror-grant#{n}",
        email: "mirror-grant#{n}@test.local",
        password_hash: "unused"
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "mirror-org#{n}"})
    {:ok, original} = OrganizationGitHubCredentials.reference(owner, org.id)

    token = %ForgeGitHub.DeviceFlow.Token{
      client_id: "Iv23lizCVE3E24s7fCA0",
      access_token: "organization-mirror-access-secret",
      refresh_token: "organization-mirror-refresh-secret",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }

    {:ok, credential} =
      OrganizationGitHubCredentials.save_device_grant_if_current(
        owner,
        org.id,
        %{github_user_id: 90, login: "authorizer"},
        token,
        original,
        %{}
      )

    {:ok, connection} =
      Connections.transaction(owner, org.id, 0, fn connection ->
        Connections.store_grant(connection, credential, owner, %{})
      end)

    {:ok, [installation]} = Client.user_installations(token.access_token, [])
    permissions = %{"contents" => "read", "issues" => "read", "pull_requests" => "read"}
    installation = %{installation.installation | permissions: permissions}

    {:ok, connection} =
      Connections.transaction(owner, org.id, connection.lock_version, fn current ->
        Connections.bind(
          current,
          installation,
          %{
            "repositories" => [
              %{"id" => 501, "full_name" => "source-org/project", "visibility" => "private"}
            ]
          },
          owner,
          %{}
        )
      end)

    scope = %{
      credential_source: :organization_device,
      organization_id: org.id,
      organization_connection_id: connection.id,
      organization_connection_version: connection.lock_version,
      organization_credential_id: credential.credential_id,
      organization_credential_version: credential.verification_version,
      github_installation_id: 44,
      github_account_id: 91,
      github_repository_id: 501
    }

    %{owner: owner, org: org, connection: connection, scope: scope}
  end

  test "organization checkout needs no personal credential or active local authorizer", c do
    Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))
    assert :ok = checkout(c.scope, "read")
    assert Process.get(:mirror_callback)
    refute Repo.exists?(ForgeAccounts.GitHubCredential)

    assert MirrorCredential.gate_key(c.scope) ==
             {:organization_credential, c.scope.organization_credential_id}
  end

  test "disconnect during installation verification fences the effect callback", c do
    Process.put(:mirror_inventory_hook, fn ->
      assert {:ok, _} =
               Connections.transaction(c.owner, c.org.id, c.connection.lock_version, fn current ->
                 with {:ok, ref} <- OrganizationGitHubCredentials.current_reference(c.org.id),
                      {:ok, invalid} <-
                        OrganizationGitHubCredentials.disconnect_if_current(
                          c.owner,
                          c.org.id,
                          ref,
                          %{}
                        ),
                      do: Connections.disconnect(current, invalid, c.owner, %{})
               end)
    end)

    assert {:error, _} = checkout(c.scope, "read")
    refute Process.get(:mirror_callback)
  end

  test "rechecking a binding during verification fences the prior scope", c do
    Process.put(:mirror_inventory_hook, fn ->
      Repo.update!(
        Ecto.Changeset.change(c.connection, lock_version: c.connection.lock_version + 1)
      )
    end)

    assert {:error, _} = checkout(c.scope, "read")
    refute Process.get(:mirror_callback)
  end

  test "missing write permission or removed repository prevents an effect", c do
    assert {:error, :insufficient_installation_access} = checkout(c.scope, "write")
    refute Process.get(:mirror_callback)

    Process.put(:mirror_inventory, [])
    assert {:error, :insufficient_installation_access} = checkout(c.scope, "read")
    refute Process.get(:mirror_callback)
  end

  defp checkout(scope, permission) do
    MirrorCredential.with_token(
      scope,
      %{permissions: %{"contents" => permission}},
      [client: Client, pat_authorize: fn _ -> :ok end],
      fn token ->
        assert token == "organization-mirror-access-secret"
        Process.put(:mirror_callback, true)
        :ok
      end
    )
  end
end
