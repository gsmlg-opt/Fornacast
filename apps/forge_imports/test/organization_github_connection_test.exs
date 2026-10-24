defmodule ForgeImports.OrganizationGitHubConnectionTest do
  use ExUnit.Case, async: false
  alias ForgeAccounts.{OrganizationGitHubCredential, OrganizationGitHubCredentials, User}
  alias ForgeGitHub.{AppInstallation, UserInstallation}
  alias ForgeImports.OrganizationGitHubConnection, as: Connection
  alias ForgeMirrors.OrganizationGitHubConnections, as: Connections
  alias Fornacast.Repo

  defmodule Client do
    def authenticated_user(_token, _opts) do
      {:ok, Process.get(:org_profile, %ForgeGitHub.User{id: 9001, login: "org-authorizer"})}
    end

    def user_installations(token, _opts) do
      if hook = Process.delete(:org_installation_hook), do: hook.(token)

      {:ok,
       Process.get(:org_installations, [
         ForgeImports.OrganizationGitHubConnectionTest.installation()
       ])}
    end

    def user_installation_repositories(_token, _id, _opts) do
      {:ok,
       Process.get(:org_repositories, [ForgeImports.OrganizationGitHubConnectionTest.repository()])}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        username: "org-connection#{suffix}",
        email: "org#{suffix}@test.local",
        password_hash: "unused",
        kind: :user,
        state: :active
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "connection-org#{suffix}"})
    {:ok, expected} = Connection.reference(owner, org.id)
    %{owner: owner, org: org, expected: expected}
  end

  test "organization authorization creates no personal identity and requires installation", c do
    assert {:ok, saved} = connect(c)
    assert saved.state == :installation_required
    assert saved.organization_id == c.org.id
    assert Repo.aggregate(ForgeAccounts.GitHubCredential, :count) == 0
    assert Repo.aggregate(ForgeAccounts.GitHubIdentity, :count) == 0
    assert Repo.aggregate(OrganizationGitHubCredential, :count) == 1
    assert {:ok, %{state: :installation_required}} = Connection.view(c.owner, c.org.id)
    assert {:error, :credential_unavailable} = Connection.scope(saved.id)
  end

  test "binding verifies installation identity and complete effective inventory", c do
    {:ok, saved} = connect(c)
    assert {:ok, ready} = bind(c, saved)
    assert ready.state == :ready
    assert ready.github_organization_id == 91

    assert ready.inventory["repositories"] == [
             %{"id" => 501, "full_name" => "source-org/project", "visibility" => "private"}
           ]

    assert {:ok, scope} = Connection.scope(ready.id)
    assert :ok = Connection.validate_repository(scope, 501, client: Client)

    assert {:error, :repository_not_in_installation} =
             Connection.validate_repository(scope, 502, client: Client)
  end

  test "authorization with no visible installation stays unconnected", c do
    {:ok, saved} = connect(c)
    Process.put(:org_installations, [])
    assert {:ok, []} = Connection.installations(c.owner, c.org.id, client: Client)
    assert {:error, :installation_required} = bind(c, saved)
    assert Connections.get(c.org.id).state == :installation_required
  end

  test "wrong App and suspended or personal installations cannot be bound", c do
    {:ok, saved} = connect(c)
    original = installation()

    for item <- [
          %{original | app_id: 11},
          %{original | app_slug: "another-app"},
          %{original | client_id: "another-client"},
          %{original | installation: %{original.installation | state: :suspended}},
          %{original | installation: %{original.installation | account_type: :user}}
        ] do
      Process.put(:org_installations, [item])
      assert {:error, :insufficient_installation_access} = bind(c, saved)
    end

    assert Connections.get(c.org.id).state == :installation_required
  end

  test "permissions missing is distinct from installation ready", c do
    {:ok, saved} = connect(c)
    item = installation()

    Process.put(:org_installations, [
      %{item | installation: %{item.installation | permissions: %{"contents" => "read"}}}
    ])

    assert {:ok, missing} = bind(c, saved)
    assert missing.state == :permissions_missing
    assert {:error, :credential_unavailable} = Connection.scope(missing.id)
  end

  test "repositories from another immutable owner are rejected", c do
    {:ok, saved} = connect(c)
    Process.put(:org_repositories, [%{repository() | owner_id: 92}])
    assert {:error, :insufficient_installation_access} = bind(c, saved)
  end

  test "reconnect clears readiness and fences the previous grant and run scope", c do
    {:ok, saved} = connect(c)
    {:ok, ready} = bind(c, saved)
    {:ok, scope} = Connection.scope(ready.id)
    {:ok, expected} = Connection.reference(c.owner, c.org.id)

    assert {:ok, reconnected} =
             Connection.connect(c.owner, c.org.id, token("second"), expected, %{}, client: Client)

    assert reconnected.state == :installation_required
    assert reconnected.inventory == %{}
    assert reconnected.github_organization_id == 91

    assert {:error, :credential_unavailable} =
             Connection.with_credential(scope, fn _, _ -> flunk("stale grant used") end,
               client: Client
             )

    assert {:error, :stale} =
             Connection.connect(c.owner, c.org.id, token("late"), expected, %{}, client: Client)
  end

  test "a renamed login cannot substitute another pinned GitHub organization", c do
    {:ok, saved} = connect(c)
    {:ok, ready} = bind(c, saved)
    item = installation()

    Process.put(:org_installations, [
      %{item | installation: %{item.installation | account_id: 92}}
    ])

    Process.put(:org_repositories, [%{repository() | owner_id: 92}])
    assert {:error, :organization_mismatch} = bind(c, ready)
  end

  test "disconnect during provider verification fences late binding", c do
    {:ok, saved} = connect(c)

    Process.put(:org_installation_hook, fn _ ->
      assert {:ok, _} = Connection.disconnect(c.owner, c.org.id, saved.lock_version, %{})
    end)

    assert {:error, _} = bind(c, saved)
    assert {:ok, %{state: :disconnected}} = Connection.view(c.owner, c.org.id)
  end

  test "deactivating the local authorizer does not invalidate committed organization authority",
       c do
    {:ok, saved} = connect(c)
    {:ok, ready} = bind(c, saved)
    {:ok, scope} = Connection.scope(ready.id)
    Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))

    assert {:ok, :ok} =
             Connection.with_credential(
               scope,
               fn _token, current ->
                 assert current.organization_id == c.org.id
                 :ok
               end,
               client: Client
             )

    assert {:error, :forbidden} = Connection.reference(c.owner, c.org.id)
  end

  test "direct connection mutations reject nonmanagers and stale row versions", c do
    {:ok, saved} = connect(c)
    {:ok, ready} = bind(c, saved)

    assert {:error, :stale} =
             Repo.transact(fn ->
               Connections.bind(saved, installation().installation, ready.inventory, c.owner, %{})
             end)

    outsider =
      Repo.insert!(%User{
        username: "outsider#{c.org.id}",
        email: "outsider#{c.org.id}@test.local",
        password_hash: "unused"
      })

    assert {:error, :forbidden} =
             Repo.transact(fn ->
               Connections.bind(
                 ready,
                 installation().installation,
                 ready.inventory,
                 outsider,
                 %{}
               )
             end)

    assert {:error, :stale} =
             Repo.transact(fn ->
               Connections.bind(
                 %{ready | github_organization_id: nil},
                 %{installation().installation | account_id: 92, account_login: "another-org"},
                 ready.inventory,
                 c.owner,
                 %{}
               )
             end)

    assert Connections.get(c.org.id).lock_version == ready.lock_version
    assert Connections.get(c.org.id).github_organization_id == ready.github_organization_id
  end

  test "a provider reflecting checked-out access during rotation never reaches public inventory",
       c do
    {:ok, saved} = connect(c)
    old_token = token()

    Process.put(:org_installation_hook, fn _ ->
      row = Repo.get_by!(OrganizationGitHubCredential, organization_id: c.org.id)

      Repo.update!(
        Ecto.Changeset.change(row, expires_at: DateTime.add(DateTime.utc_now(:second), 10))
      )

      {:ok, scope} = OrganizationGitHubCredentials.current_reference(c.org.id)

      assert :ok =
               OrganizationGitHubCredentials.refresh_credential(scope, fn _, _ ->
                 {:ok, token("rotated")}
               end)

      Process.put(:org_repositories, [%{repository() | description: old_token.access_token}])
    end)

    assert {:error, :invalid_response} = bind(c, saved)
    refute inspect(Connections.get(c.org.id).inventory) =~ old_token.access_token
  end

  def installation do
    %UserInstallation{
      app_id: 5_412_311,
      app_slug: "fornacast",
      installation: %AppInstallation{
        id: 44,
        account_id: 91,
        account_login: "source-org",
        account_type: :organization,
        repository_selection: :selected,
        permissions: %{"contents" => "read", "issues" => "read", "pull_requests" => "read"},
        state: :active
      }
    }
  end

  def repository do
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
  end

  defp token(suffix \\ "initial"),
    do: %ForgeGitHub.DeviceFlow.Token{
      client_id: "Iv23lizCVE3E24s7fCA0",
      access_token: "organization-access-#{suffix}-secret",
      refresh_token: "organization-refresh-#{suffix}-secret",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }

  defp connect(c),
    do: Connection.connect(c.owner, c.org.id, token(), c.expected, %{}, client: Client)

  defp bind(c, saved),
    do: Connection.bind(c.owner, c.org.id, 44, saved.lock_version, %{}, client: Client)
end
