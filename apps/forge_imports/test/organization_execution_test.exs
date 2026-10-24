defmodule ForgeImports.OrganizationExecutionTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias ForgeAccounts.{OrganizationGitHubCredentials, OrganizationMember, User}
  alias ForgeImports.{ImportRun, OrganizationExecution, OrganizationPatSettings, PatSyncRun}
  alias ForgeMirrors.{OrganizationGitHubConnections, PatSettings}
  alias Fornacast.Repo

  setup context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: context[:committed] != true)
    suffix = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        username: "execution#{suffix}",
        email: "execution#{suffix}@test.local",
        password_hash: "unused"
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "execution-org#{suffix}"})
    {:ok, original} = OrganizationGitHubCredentials.reference(owner, org.id)

    token = %ForgeGitHub.DeviceFlow.Token{
      client_id: "Iv23lizCVE3E24s7fCA0",
      access_token: "execution-access-secret",
      refresh_token: "execution-refresh-secret",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }

    {:ok, credential} =
      OrganizationGitHubCredentials.save_device_grant_if_current(
        owner,
        org.id,
        %{github_user_id: 91, login: "execution-authorizer"},
        token,
        original,
        %{}
      )

    {:ok, connection} =
      OrganizationGitHubConnections.transaction(owner, org.id, 0, fn connection ->
        OrganizationGitHubConnections.store_grant(connection, credential, owner, %{})
      end)

    installation = %{
      id: 44,
      account_id: 92,
      account_login: "source-org",
      account_type: :organization,
      repository_selection: :selected,
      state: :active,
      permissions: %{"contents" => "read", "issues" => "read", "pull_requests" => "read"}
    }

    inventory = %{
      "repositories" => [
        %{"id" => 501, "full_name" => "source-org/project", "visibility" => "private"}
      ]
    }

    {:ok, ready} =
      OrganizationGitHubConnections.transaction(
        owner,
        org.id,
        connection.lock_version,
        fn connection ->
          OrganizationGitHubConnections.bind(connection, installation, inventory, owner, %{})
        end
      )

    {:ok, scope} = OrganizationGitHubConnections.scope(ready.id)

    if context[:committed] do
      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.update_all(from(j in PatSyncRun, where: j.organization_id == ^org.id),
            set: [import_run_id: nil]
          )

          Repo.delete_all(from(r in ImportRun, where: r.destination_organization_id == ^org.id))
          Repo.delete_all(from(j in PatSyncRun, where: j.organization_id == ^org.id))

          Repo.delete_all(
            from(c in ForgeMirrors.PatConfiguration, where: c.organization_id == ^org.id)
          )

          Repo.delete_all(
            from(c in ForgeMirrors.OrganizationGitHubConnection,
              where: c.organization_id == ^org.id
            )
          )

          Repo.delete_all(
            from(c in ForgeAccounts.OrganizationGitHubCredential,
              where: c.organization_id == ^org.id
            )
          )

          Repo.delete_all(from(m in OrganizationMember, where: m.organization_id == ^org.id))
          Repo.delete_all(from(a in Fornacast.AuditEvent, where: a.actor_user_id == ^owner.id))
          Repo.delete_all(from(u in User, where: u.id in ^[org.id, owner.id]))
        end)
      end)
    end

    %{owner: owner, org: org, connection: ready, scope: scope}
  end

  test "source activation uses organization authority without a personal saved account", c do
    assert {:ok, config} = activate(c)
    assert config.credential_source == :organization_device
    assert config.owner_user_id == nil
    assert config.github_identity_id == nil
    assert config.organization_credential_id == c.scope.credential_id

    assert {:ok, %{credential: %{credential_status: :valid}}} =
             PatSettings.view(c.owner, c.org.id)

    assert {:ok, job} =
             OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    assert job.credential_source == :organization_device
    assert job.owner_user_id == nil
    assert job.requested_by_user_id == c.owner.id
    assert {:ok, %OrganizationExecution{}} = OrganizationExecution.for_sync(job)
  end

  test "public admission refuses a current App configuration without queuing work", c do
    {:ok, config} = activate(c)

    assert {:error, :source_changed} =
             ForgeImports.OrganizationPublicSync.sync(
               c.owner,
               c.org.id,
               to_string(config.lock_version),
               %{}
             )

    refute Repo.exists?(PatSyncRun)
    refute Repo.exists?(ImportRun)
  end

  test "removing the local authorizer preserves admitted work and system scheduling", c do
    {:ok, config} = activate(c)

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    {:ok, execution} = OrganizationExecution.for_sync(job)
    Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))

    Repo.delete_all(
      from m in OrganizationMember,
        where: m.organization_id == ^c.org.id and m.user_id == ^c.owner.id
    )

    assert {:ok, _} = OrganizationExecution.authorize(execution)
    assert {:ok, same} = OrganizationPatSettings.sync_organization_configuration(config, %{})
    assert same.id == job.id
  end

  test "pause and disconnected credential authority fence an admitted run", c do
    {:ok, config} = activate(c)

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    {:ok, execution} = OrganizationExecution.for_sync(job)
    assert {:ok, paused} = PatSettings.set_paused(c.owner, c.org.id, true, %{})
    assert {:error, :paused} = OrganizationExecution.authorize(execution)
    Repo.update!(Ecto.Changeset.change(paused, paused: false))

    assert {:ok, _} =
             ForgeImports.OrganizationGitHubConnection.disconnect(
               c.owner,
               c.org.id,
               c.connection.lock_version,
               %{}
             )

    assert {:error, _} = OrganizationExecution.authorize(execution)
  end

  test "an active job prevents changing the source snapshot", c do
    {:ok, config} = activate(c)

    {:ok, _job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    assert {:error, :busy} =
             PatSettings.activate_organization_connection(
               c.owner,
               c.org.id,
               c.scope,
               to_string(config.lock_version),
               %{}
             )
  end

  test "caller-supplied scope cannot substitute another credential or organization", c do
    assert {:error, :credential_unavailable} =
             PatSettings.activate_organization_connection(
               c.owner,
               c.org.id,
               %{c.scope | credential_id: c.scope.credential_id + 1},
               "1",
               %{}
             )

    assert {:error, :credential_unavailable} =
             PatSettings.activate_organization_connection(
               c.owner,
               c.org.id,
               %{c.scope | organization_id: c.org.id + 1},
               "1",
               %{}
             )
  end

  test "import children retain exact durable job and organization source binding", c do
    {:ok, config} = activate(c)

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    attrs =
      Map.merge(OrganizationExecution.snapshots(c.scope), %{
        actor_user_id: c.owner.id,
        organization_sync_run_id: job.id,
        source_kind: :organization,
        credential_source: :organization_device,
        source_owner_github_id: c.scope.github_organization_id,
        source_owner_login: "source-org",
        destination_organization_action: :existing,
        destination_organization_id: c.org.id,
        destination_organization_slug: c.org.username,
        destination_organization_status: :clean,
        state: :discovering,
        request_metadata: %{}
      })

    run = Repo.insert!(struct(ImportRun, attrs))
    Repo.update!(Ecto.Changeset.change(job, import_run_id: run.id))
    assert {:ok, execution} = OrganizationExecution.for_run(run)
    assert {:ok, _} = OrganizationExecution.authorize(execution)
    forged = %{run | organization_credential_version: run.organization_credential_version + 1}
    assert {:error, :configuration_changed} = OrganizationExecution.for_run(forged)

    Repo.update!(Ecto.Changeset.change(job, state: "failed"))

    wrong_parent =
      Repo.insert!(
        struct(
          PatSyncRun,
          Map.merge(OrganizationExecution.snapshots(c.scope), %{
            configuration_id: config.id,
            organization_id: c.org.id,
            credential_source: :organization_device,
            requested_by_user_id: c.owner.id,
            github_organization: "source-org",
            github_organization_id: c.scope.github_organization_id
          })
        )
      )

    assert {:error, :configuration_changed} =
             OrganizationExecution.for_run(%{run | organization_sync_run_id: wrong_parent.id})
  end

  @tag :committed
  test "concurrent organization claims acquire the final run lock without shared upgrades", c do
    {:ok, config} = activate(c)

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    run =
      Repo.insert!(
        struct(
          ImportRun,
          Map.merge(OrganizationExecution.snapshots(c.scope), %{
            actor_user_id: c.owner.id,
            organization_sync_run_id: job.id,
            source_kind: :organization,
            credential_source: :organization_device,
            source_owner_github_id: c.scope.github_organization_id,
            source_owner_login: "source-org",
            destination_organization_action: :existing,
            destination_organization_id: c.org.id,
            destination_organization_slug: c.org.username,
            destination_organization_status: :clean,
            state: :discovering,
            request_metadata: %{}
          })
        )
      )

    Repo.update!(Ecto.Changeset.change(job, import_run_id: run.id))
    {:ok, execution} = OrganizationExecution.for_run(run)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            try do
              Repo.transaction(fn ->
                assert {:ok, _} =
                         OrganizationExecution.authorize(execution, lock: true, run_lock: :update)

                send(parent, {:authorized, self()})
                receive do: (:upgrade -> :ok)
                Repo.one!(from r in ImportRun, where: r.id == ^run.id, lock: "FOR UPDATE")
                :ok
              end)
            rescue
              error in Postgrex.Error -> {:error, error.postgres.code}
            end
          end)
        end)
      end

    assert_receive {:authorized, first}, 2_000

    receive do
      {:authorized, second} ->
        send(first, :upgrade)
        send(second, :upgrade)
    after
      200 ->
        send(first, :upgrade)
        assert_receive {:authorized, second}, 2_000
        send(second, :upgrade)
    end

    assert Enum.map(tasks, &Task.await(&1, 5_000)) == [{:ok, :ok}, {:ok, :ok}]
  end

  defp activate(c),
    do: PatSettings.activate_organization_connection(c.owner, c.org.id, c.scope, "1", %{})
end
