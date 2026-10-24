defmodule ForgeImports.OrganizationDeviceCredentialProviderTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias ForgeAccounts.{OrganizationGitHubCredentials, OrganizationMember, User}

  alias ForgeImports.{
    CredentialProvider,
    Discovery,
    ImportAttempt,
    OrganizationExecution,
    OrganizationPatSettings,
    RepositoryItem
  }

  alias ForgeMirrors.{OrganizationGitHubConnections, PatSettings}
  alias Fornacast.Repo

  @access "provider-checkout-access-secret"

  defmodule Client do
    def user_installations(_token, _opts) do
      {:ok,
       [
         %ForgeGitHub.UserInstallation{
           app_id: 5_412_311,
           app_slug: "fornacast",
           client_id: "Iv23lizCVE3E24s7fCA0",
           installation: %ForgeGitHub.AppInstallation{
             id: 44,
             account_id: 1,
             account_login: "source-org",
             account_type: :organization,
             repository_selection: :selected,
             state: :active,
             permissions: %{"contents" => "read", "issues" => "read", "pull_requests" => "read"}
           }
         }
       ]}
    end

    def user_installation_repositories(_token, 44, _opts) do
      {:ok,
       Enum.map(Process.get(:provider_inventory, [501, 502]), fn id ->
         name = if id == 501, do: "project", else: "other"

         {:ok, repository} =
           ForgeGitHub.Repository.from_json(
             ForgeImports.TestSupport.FakeGitHub.repository_json(%{
               id: id,
               name: name,
               owner: "source-org"
             })
           )

         repository
       end)}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        username: "provider#{n}",
        email: "provider#{n}@test.local",
        password_hash: "unused"
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "provider-org#{n}"})
    {:ok, expected} = OrganizationGitHubCredentials.reference(owner, org.id)

    token = %ForgeGitHub.DeviceFlow.Token{
      client_id: "Iv23lizCVE3E24s7fCA0",
      access_token: @access,
      refresh_token: "provider-checkout-refresh-secret",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }

    {:ok, credential} =
      OrganizationGitHubCredentials.save_device_grant_if_current(
        owner,
        org.id,
        %{github_user_id: 91, login: "external-authorizer"},
        token,
        expected,
        %{}
      )

    {:ok, connection} =
      OrganizationGitHubConnections.transaction(owner, org.id, 0, fn connection ->
        OrganizationGitHubConnections.store_grant(connection, credential, owner, %{})
      end)

    {:ok, [installation]} = Client.user_installations(@access, [])

    inventory = %{
      "repositories" => [
        %{"id" => 501, "full_name" => "source-org/project", "visibility" => "private"},
        %{"id" => 502, "full_name" => "source-org/other", "visibility" => "private"}
      ]
    }

    {:ok, connection} =
      OrganizationGitHubConnections.transaction(
        owner,
        org.id,
        connection.lock_version,
        fn current ->
          OrganizationGitHubConnections.bind(
            current,
            installation.installation,
            inventory,
            owner,
            %{}
          )
        end
      )

    {:ok, scope} = OrganizationGitHubConnections.scope(connection.id)
    {:ok, config} = PatSettings.activate_organization_connection(owner, org.id, scope, "1", %{})
    {:ok, job} = OrganizationPatSettings.sync(owner, org.id, to_string(config.lock_version), %{})
    {:ok, execution} = OrganizationExecution.for_sync(job)
    {:ok, run} = Discovery.create_organization(execution, %{}, %{}, [])
    run = Repo.update!(Ecto.Changeset.change(run, state: :running))
    now = DateTime.utc_now(:second)

    item =
      Repo.insert!(%RepositoryItem{
        import_run_id: run.id,
        github_repository_id: 501,
        source_full_name: "source-org/project",
        source_name: "project",
        source_observed_at: now,
        destination_owner_id: org.id,
        destination_slug: "project",
        destination_visibility: :private,
        state: :staging_git,
        attempt_count: 1,
        lease_owner: "provider-test-lease",
        lease_expires_at: DateTime.add(now, 900)
      })

    attempt =
      Repo.insert!(%ImportAttempt{
        repository_item_id: item.id,
        attempt_number: 1,
        state: :running,
        decision: %{},
        started_at: now
      })

    {:ok, execution} = OrganizationExecution.for_run(run)

    %{
      owner: owner,
      org: org,
      connection: connection,
      config: config,
      run: run,
      item: item,
      execution: execution,
      attempt: attempt
    }
  end

  test "valid leased organization capability checks out without a personal account or active authorizer",
       c do
    Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))

    Repo.delete_all(
      from member in OrganizationMember,
        where: member.organization_id == ^c.org.id and member.user_id == ^c.owner.id
    )

    assert checkout(c, c.run, c.item) == {:ok, :acknowledged}
    assert Process.get(:provider_callback) == true
    refute Repo.exists?(ForgeAccounts.GitHubCredential)
  end

  test "forged repository identity with unchanged id lease and version never admits callback",
       c do
    forged = %{c.item | github_repository_id: 502}
    assert forged.id == c.item.id
    assert forged.lock_version == c.item.lock_version
    assert forged.lease_owner == c.item.lease_owner
    assert_rejected(c, c.run, forged)
  end

  test "a removed repository cannot regain access through a forged allowed repository id", c do
    Process.put(:provider_inventory, [502])

    Repo.update!(
      Ecto.Changeset.change(c.connection,
        inventory: %{
          "repositories" => [
            %{"id" => 502, "full_name" => "source-org/other", "visibility" => "private"}
          ]
        }
      )
    )

    assert_rejected(c, c.run, c.item)
    assert_rejected(c, c.run, %{c.item | github_repository_id: 502})
  end

  test "source destination run and credential snapshot substitutions cannot borrow a live lease",
       c do
    for forged <- [
          %{c.item | source_full_name: "source-org/other", source_name: "other"},
          %{c.item | destination_owner_id: c.owner.id},
          %{c.item | import_run_id: c.run.id + 1},
          %{c.item | attempt_count: 2}
        ] do
      assert_rejected(c, c.run, forged)
    end

    for forged <- [
          %{c.run | source_owner_github_id: 2},
          %{c.run | source_owner_login: "other-org"},
          %{c.run | destination_organization_id: c.owner.id},
          %{c.run | organization_connection_version: c.run.organization_connection_version + 1},
          %{c.run | organization_credential_id: c.run.organization_credential_id + 1},
          %{c.run | credential_source: :saved}
        ] do
      assert_rejected(c, forged, c.item)
    end
  end

  test "pause disconnect expired lease and terminal attempt fence checkout", c do
    {:ok, paused} = PatSettings.set_paused(c.owner, c.org.id, true, %{})
    assert_rejected(c, c.run, c.item)
    Repo.update!(Ecto.Changeset.change(paused, paused: false))

    Repo.update!(
      Ecto.Changeset.change(c.item, lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1))
    )

    assert_rejected(c, c.run, c.item)

    Repo.update!(
      Ecto.Changeset.change(c.item,
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), 900)
      )
    )

    Repo.update!(
      Ecto.Changeset.change(c.attempt, state: :failed, terminal_at: DateTime.utc_now(:second))
    )

    assert_rejected(c, c.run, c.item)
    Repo.update!(Ecto.Changeset.change(c.attempt, state: :running, terminal_at: nil))

    assert {:ok, _} =
             ForgeImports.OrganizationGitHubConnection.disconnect(
               c.owner,
               c.org.id,
               c.connection.lock_version,
               %{}
             )

    assert_rejected(c, c.run, c.item)
  end

  defp checkout(c, run, item) do
    CredentialProvider.checkout(
      %{actor: c.execution, run: run, capability: item},
      fn token, metadata ->
        assert token == @access
        assert metadata.git_login == "x-access-token"
        Process.put(:provider_callback, true)
        :ok
      end,
      client: Client
    )
  end

  defp assert_rejected(c, run, item) do
    Process.delete(:provider_callback)
    assert {:error, _} = checkout(c, run, item)
    refute Process.get(:provider_callback)
  end
end
