defmodule ForgeImports.PublicOrganizationSyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias ForgeAccounts.User
  alias ForgeImports.{ImportRun, OrganizationPublicSync, PatSyncRun, PatSyncWorker, Worker}
  alias ForgeMirrors.PatConfiguration
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    n = System.unique_integer([:positive])

    actor =
      Repo.insert!(%User{
        username: "public#{n}",
        email: "public#{n}@test.local",
        password_hash: "unused"
      })

    {:ok, organization} = ForgeAccounts.create_organization(actor, %{username: "public-org#{n}"})
    %{actor: actor, organization: organization}
  end

  test "anonymous organization discovery creates no identities or encrypted credentials", c do
    assert {:ok, view} =
             ForgeImports.create_organization_discovery(
               c.actor,
               %{
                 organization: "source-org",
                 credential_source: "public",
                 destination_organization: %{action: :existing, id: c.organization.id}
               },
               %{},
               dispatch: :inline,
               client: __MODULE__.Client
             )

    assert view.state == :awaiting_resolution
    assert [%{github_repository_id: 501, selected: true}] = view.repositories

    assert %ImportRun{
             credential_source: :public,
             github_identity_id: nil,
             github_credential_id: nil,
             credential_ciphertext: nil,
             credential_nonce: nil,
             credential_tag: nil,
             credential_key_id: nil
           } = Repo.get!(ImportRun, view.id)

    refute Repo.exists?(ForgeAccounts.GitHubIdentity)
    refute Repo.exists?(ForgeAccounts.GitHubCredential)
  end

  test "public discovery rejects a private repository in an otherwise valid inventory", c do
    assert {:ok, view} =
             ForgeImports.create_organization_discovery(
               c.actor,
               %{
                 organization: "source-org",
                 credential_source: "public",
                 destination_organization: %{action: :existing, id: c.organization.id}
               },
               %{},
               dispatch: :inline,
               client: __MODULE__.Client,
               client_options: [visibility: :private]
             )

    assert view.state == :failed
    assert view.repositories == []
  end

  test "public source rejects mixed personal credentials before creating a run", c do
    assert {:error, :invalid_request} =
             ForgeImports.create_organization_discovery(
               c.actor,
               %{
                 organization: "source-org",
                 credential_source: "public",
                 pat: "not-a-real-token",
                 destination_organization: %{action: :existing, id: c.organization.id}
               },
               %{},
               dispatch: :inline,
               client: __MODULE__.Client
             )

    refute Repo.exists?(ImportRun)
  end

  test "public configuration snapshots organization authority and queues the existing sync worker",
       c do
    assert {:ok, config} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{"github_organization" => "source-org", "lock_version" => "1"},
               %{},
               client: __MODULE__.Client
             )

    assert %PatConfiguration{
             credential_source: :public,
             owner_user_id: nil,
             github_identity_id: nil,
             trigger_mode: "manual"
           } = config

    assert Map.get(config, :github_organization_id) == 1

    assert {:ok, job} =
             OrganizationPublicSync.sync(
               c.actor,
               c.organization.id,
               to_string(config.lock_version),
               %{}
             )

    assert %PatSyncRun{
             credential_source: :public,
             owner_user_id: nil,
             github_identity_id: nil,
             github_organization_id: 1
           } = job

    assert :pending = PatSyncWorker.perform(job.id)
    assert %PatSyncRun{import_run_id: run_id} = Repo.get!(PatSyncRun, job.id)

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(run_id, "public-discovery", client: __MODULE__.Client)

    assert %ImportRun{
             credential_source: :public,
             github_identity_id: nil,
             source_owner_github_id: 1
           } = Repo.get!(ImportRun, run_id)
  end

  test "public sync rejects a current personal configuration without creating jobs", c do
    config =
      Repo.insert!(%PatConfiguration{
        organization_id: c.organization.id,
        github_organization: "source-org"
      })

    assert {:error, :source_changed} =
             OrganizationPublicSync.sync(
               c.actor,
               c.organization.id,
               to_string(config.lock_version),
               %{}
             )

    refute Repo.exists?(PatSyncRun)
    refute Repo.exists?(ImportRun)
  end

  test "public source cutover refuses active work and removed owners cannot configure", c do
    assert {:ok, config} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{"github_organization" => "source-org", "lock_version" => "1"},
               %{},
               client: __MODULE__.Client
             )

    assert {:ok, _job} =
             OrganizationPublicSync.sync(
               c.actor,
               c.organization.id,
               to_string(config.lock_version),
               %{}
             )

    assert {:error, :busy} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{
                 "github_organization" => "other-org",
                 "lock_version" => to_string(config.lock_version)
               },
               %{},
               client: __MODULE__.Client
             )
  end

  test "real public view is credential-free and owner authorization remains mandatory", c do
    assert {:ok, view} = OrganizationPublicSync.view(c.actor, c.organization.id)
    assert view.owners == []
    assert view.history == []

    assert {:ok, _} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{"github_organization" => "source-org", "lock_version" => "0"},
               %{},
               client: __MODULE__.Client
             )

    assert {:ok,
            %{config: %{credential_source: :public}, credential: %{credential_kind: :public}}} =
             OrganizationPublicSync.view(c.actor, c.organization.id)

    Repo.delete_all(
      from m in ForgeAccounts.OrganizationMember,
        where: m.organization_id == ^c.organization.id and m.user_id == ^c.actor.id
    )

    assert {:error, _} = OrganizationPublicSync.view(c.actor, c.organization.id)

    assert {:error, _} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{"github_organization" => "source-org", "lock_version" => "2"},
               %{},
               client: __MODULE__.Client
             )
  end

  test "public organization pause resumes the same snapshot and changed versions fence queued work",
       c do
    assert {:ok, config} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{"github_organization" => "source-org", "lock_version" => "1"},
               %{},
               client: __MODULE__.Client
             )

    assert {:ok, job} =
             OrganizationPublicSync.sync(
               c.actor,
               c.organization.id,
               to_string(config.lock_version),
               %{}
             )

    assert {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.actor, c.organization.id, true, %{})
    assert {:error, :paused} = ForgeImports.OrganizationExecution.for_sync(job)

    assert {:ok, resumed} =
             ForgeMirrors.PatSettings.set_paused(c.actor, c.organization.id, false, %{})

    assert resumed.lock_version == config.lock_version
    assert {:ok, _} = ForgeImports.OrganizationExecution.for_sync(job)
    Repo.update!(Ecto.Changeset.change(resumed, lock_version: resumed.lock_version + 1))
    assert {:error, :configuration_changed} = ForgeImports.OrganizationExecution.for_sync(job)
  end

  test "public discovery paused during inventory waits and resumes without partial rows", c do
    assert {:ok, config} =
             OrganizationPublicSync.configure(
               c.actor,
               c.organization.id,
               %{"github_organization" => "source-org", "lock_version" => "0"},
               %{},
               client: __MODULE__.Client
             )

    assert {:ok, job} =
             OrganizationPublicSync.sync(
               c.actor,
               c.organization.id,
               to_string(config.lock_version),
               %{}
             )

    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    pause = fn ->
      assert {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.actor, c.organization.id, true, %{})
    end

    assert {:error, :paused} =
             Worker.run_discovery(job.import_run_id, "pause-discovery",
               client: __MODULE__.PausingDiscoveryClient,
               client_options: [pause: pause]
             )

    run = Repo.get!(ImportRun, job.import_run_id)
    assert run.state == :discovering
    assert run.wait_reason == "paused"
    assert run.next_attempt_at
    assert is_nil(run.lease_owner)
    refute Repo.exists?(ForgeImports.RepositoryItem)
    assert {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.actor, c.organization.id, false, %{})
    Repo.update!(Ecto.Changeset.change(run, next_attempt_at: nil))

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(run.id, "resume-discovery", client: __MODULE__.Client)

    assert Repo.get!(ImportRun, run.id).wait_reason == nil
  end

  defmodule PausingDiscoveryClient do
    def organization(token, login, opts),
      do: ForgeImports.PublicOrganizationSyncTest.Client.organization(token, login, opts)

    def organization_repositories(token, login, opts) do
      Keyword.fetch!(opts, :pause).()
      ForgeImports.PublicOrganizationSyncTest.Client.organization_repositories(token, login, opts)
    end
  end

  test "anonymous rate limit persists a recoverable deadline without finalizing an incomplete inventory",
       c do
    retry_at = DateTime.add(DateTime.utc_now(:second), 600)

    assert {:ok, view} =
             ForgeImports.create_organization_discovery(
               c.actor,
               %{
                 organization: "source-org",
                 credential_source: :public,
                 destination_organization: %{action: :existing, id: c.organization.id}
               },
               %{},
               dispatch: :async
             )

    assert {:error, :primary_rate_limit} =
             Worker.run_discovery(view.id, "public-rate",
               client: __MODULE__.RateLimitedClient,
               client_options: [retry_at: retry_at]
             )

    assert %ImportRun{
             state: :discovering,
             wait_reason: "primary_rate_limit",
             next_attempt_at: ^retry_at,
             lease_owner: nil,
             report_finalized_at: nil
           } = Repo.get!(ImportRun, view.id)

    refute Repo.exists?(ForgeImports.RepositoryItem)

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(view.id, "public-retry", client: __MODULE__.Client)

    assert %ImportRun{state: :awaiting_resolution, wait_reason: nil, next_attempt_at: nil} =
             Repo.get!(ImportRun, view.id)
  end

  test "incomplete anonymous pagination never publishes a partial inventory", c do
    assert {:ok, view} =
             ForgeImports.create_organization_discovery(
               c.actor,
               %{
                 organization: "source-org",
                 credential_source: :public,
                 destination_organization: %{action: :existing, id: c.organization.id}
               },
               %{},
               dispatch: :inline,
               client: __MODULE__.IncompleteClient
             )

    assert view.state == :failed
    assert view.repositories == []
    assert Repo.get!(ImportRun, view.id).failure_kind == "github_invalid_pagination"
  end

  defmodule RateLimitedClient do
    defdelegate authenticated_user(credential, opts),
      to: ForgeImports.PublicOrganizationSyncTest.Client

    defdelegate organization_repositories(credential, login, opts),
      to: ForgeImports.PublicOrganizationSyncTest.Client

    def organization(:public, _, opts),
      do: {:error, ForgeGitHub.Error.new(:primary_rate_limit, opts[:retry_at])}
  end

  defmodule IncompleteClient do
    defdelegate authenticated_user(credential, opts),
      to: ForgeImports.PublicOrganizationSyncTest.Client

    defdelegate organization(credential, login, opts),
      to: ForgeImports.PublicOrganizationSyncTest.Client

    def organization_repositories(:public, _, _),
      do: {:error, ForgeGitHub.Error.new(:invalid_pagination)}
  end

  defmodule Client do
    def authenticated_user(_, _), do: raise("public access must not authenticate a user")

    def organization(:public, login, _opts),
      do:
        {:ok,
         %ForgeGitHub.Organization{
           id: 1,
           login: login,
           name: login,
           html_url: "https://github.com/#{login}"
         }}

    def organization_repositories(:public, login, opts),
      do:
        {:ok,
         [
           %ForgeGitHub.Repository{
             id: 501,
             name: "project",
             full_name: "#{login}/project",
             owner_id: 1,
             owner_login: login,
             visibility: Keyword.get(opts, :visibility, :public),
             default_branch: "main",
             has_issues: true,
             allow_merge_commit: true,
             fork: false,
             archived: false,
             html_url: "https://github.com/#{login}/project"
           }
         ]}

    def repository(:public, login, _name, opts),
      do:
        organization_repositories(:public, login, opts)
        |> then(fn {:ok, [repo]} -> {:ok, repo} end)
  end
end
