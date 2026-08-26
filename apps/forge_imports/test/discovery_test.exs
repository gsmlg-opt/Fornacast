defmodule ForgeImports.DiscoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity}
  alias ForgeImports.{ImportRun, ReportEntry, RunView}
  alias ForgeImports.GitHub.{Error, Organization, Repository, User}
  alias ForgeRepos.Repository, as: LocalRepository
  alias Fornacast.{AuditEvent, Repo}

  @pat "github_pat_discovery_secret"
  @now ~U[2026-08-26 08:00:00Z]

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture("discoverer")
    %{actor: actor}
  end

  test "one-time repository discovery verifies only the user before the durable run and returns a safe plan",
       %{actor: actor} do
    repository =
      repository_fixture(
        id: 91_001,
        owner_id: 81_001,
        owner_login: "octocat",
        name: "hello-world",
        visibility: :internal,
        fork: true,
        archived: true
      )

    before_repositories = Repo.aggregate(LocalRepository, :count)
    before_users = Repo.aggregate(ForgeAccounts.User, :count)
    before_storage = storage_snapshot()

    assert {:ok,
            %RunView{
              state: :awaiting_resolution,
              source: %{owner_github_id: 81_001, repository_github_id: 91_001},
              repositories: [item]
            } = view} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "https://github.com/octocat/hello-world.git",
                 credential_source: :one_time,
                 pat: @pat
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [test_pid: self(), repository: repository]
             )

    assert_receive {:authenticated_user, {:import_setup, actor_id}}, 1_000
    assert actor_id == actor.id
    assert_receive {:repository, {:one_time_run, run_id}}, 1_000
    assert run_id == view.id

    assert item.selected
    assert item.destination_owner_id == actor.id
    assert item.destination_slug == "hello-world"
    assert item.destination_visibility == :private

    classifications = Enum.map(view.reports, & &1.classification)
    assert "visibility_downgraded" in classifications
    assert "unsupported_fork_relationship" in classifications
    assert "unsupported_archived_state" in classifications
    assert "unsupported_releases" in classifications

    assert %{source_count: 0} =
             Enum.find(view.reports, &(&1.classification == "unsupported_releases"))

    refute_receive :release_enumeration_called, 50

    assert %GitHubIdentity{local_user_id: nil} =
             identity = Repo.get_by!(GitHubIdentity, github_user_id: 71_001)

    refute Repo.exists?(
             from credential in GitHubCredential,
               where: credential.github_identity_id == ^identity.id
           )

    raw = Repo.get!(ImportRun, view.id)
    assert raw.github_identity_id == identity.id
    assert raw.source_owner_github_id == 81_001
    assert raw.source_repository_github_id == 91_001
    assert is_binary(raw.credential_ciphertext)
    refute inspect(view) =~ @pat
    refute inspect(view) =~ "credential_ciphertext"

    assert Repo.aggregate(LocalRepository, :count) == before_repositories
    assert Repo.aggregate(ForgeAccounts.User, :count) == before_users
    assert storage_snapshot() == before_storage
  end

  test "saved discovery uses the exact saved credential and strict repository references", %{
    actor: actor
  } do
    account = saved_account_fixture(actor)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: account.identity_id)

    assert {:error, :invalid_source} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "https://github.com/octocat/hello-world/tree/main",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [test_pid: self(), repository: repository_fixture()]
             )

    refute_receive {:repository, _gate_key}, 50

    assert {:ok, %RunView{repositories: [item]} = view} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/hello-world",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [test_pid: self(), repository: repository_fixture()]
             )

    assert_receive {:repository, {:saved_credential, credential_id}}, 1_000
    assert credential_id == credential.id
    assert item.github_repository_id == 91_000
    assert Repo.aggregate(ForgeImports.RepositoryItem, :count) == 1

    raw = Repo.get!(ImportRun, view.id)
    assert raw.github_credential_id == credential.id
    assert raw.credential_ciphertext == nil
  end

  test "saved bootstrap rejects metadata overlapping any saved PAT before creating a run", %{
    actor: actor
  } do
    secret = "arbitrary-unprefixed-saved-secret"
    account = saved_account_fixture(actor, secret)
    before_runs = Repo.aggregate(ImportRun, :count)
    before_audits = Repo.aggregate(AuditEvent, :count)

    metadata = Map.put(request_metadata(), "request_id", secret)

    assert {:error, :invalid_request_metadata} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/hello-world",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               metadata,
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [test_pid: self(), repository: repository_fixture()]
             )

    assert Repo.aggregate(ImportRun, :count) == before_runs
    assert Repo.aggregate(AuditEvent, :count) == before_audits
    refute_receive {:repository, _gate}, 50

    assert {:error, :invalid_response} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/#{secret}",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [test_pid: self(), repository: repository_fixture()]
             )

    assert Repo.aggregate(ImportRun, :count) == before_runs
    assert Repo.aggregate(AuditEvent, :count) == before_audits
    refute_receive {:repository, _gate}, 50
  end

  test "bootstrap checks vault readiness before saved or one-time provider calls", %{actor: actor} do
    account = saved_account_fixture(actor)
    original = Application.get_env(:fornacast, :github_credential_keyring)
    on_exit(fn -> Application.put_env(:fornacast, :github_credential_keyring, original) end)

    before_runs = Repo.aggregate(ImportRun, :count)

    for unavailable <- [
          :unavailable,
          %{active: "broken", keys: %{"broken" => <<1>>}}
        ] do
      Application.put_env(:fornacast, :github_credential_keyring, unavailable)

      assert {:error, :credential_service_unavailable} =
               ForgeImports.create_repository_discovery(
                 actor,
                 %{
                   source: "octocat/hello-world",
                   credential_source: :saved,
                   github_identity_id: account.identity_id
                 },
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.RepositoryClient,
                 client_options: [test_pid: self(), repository: repository_fixture()]
               )

      assert {:error, :credential_service_unavailable} =
               ForgeImports.create_repository_discovery(
                 actor,
                 %{source: "octocat/hello-world", credential_source: :one_time, pat: @pat},
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.RepositoryClient,
                 client_options: [test_pid: self(), repository: repository_fixture()]
               )
    end

    assert Repo.aggregate(ImportRun, :count) == before_runs
    refute_receive {:authenticated_user, _gate}, 50
    refute_receive {:repository, _gate}, 50
  end

  test "credential inputs require exactly one saved identity or one-time PAT", %{actor: actor} do
    account = saved_account_fixture(actor)
    before_runs = Repo.aggregate(ImportRun, :count)

    invalid = [
      %{
        source: "octocat/hello-world",
        credential_source: :saved,
        github_identity_id: account.identity_id,
        pat: "unexpected-pat"
      },
      %{
        source: "octocat/hello-world",
        credential_source: :one_time,
        github_identity_id: account.identity_id,
        pat: @pat
      },
      %{source: "octocat/hello-world", credential_source: :saved},
      %{source: "octocat/hello-world", credential_source: :one_time},
      %{
        "source" => "octocat/hello-world",
        "credential_source" => "one_time",
        "pat" => @pat,
        "access_token" => "extra-secret"
      }
    ]

    for attrs <- invalid do
      assert {:error, :invalid_request} =
               ForgeImports.create_repository_discovery(
                 actor,
                 attrs,
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.RepositoryClient,
                 client_options: [test_pid: self(), repository: repository_fixture()]
               )
    end

    assert Repo.aggregate(ImportRun, :count) == before_runs
    refute_receive {:authenticated_user, _gate}, 50
    refute_receive {:repository, _gate}, 50
  end

  test "initial organization destination is screened against current and other PATs", %{
    actor: actor
  } do
    selected = saved_account_fixture(actor, "selected_destination_secret")
    _other = saved_account_fixture(actor, "other_destination_secret")
    before_runs = Repo.aggregate(ImportRun, :count)

    for slug <- [
          "selected_destination_secret",
          "other_destination_secret",
          "destination_fragment",
          "https://github.com/acme?value=other_destination_secret"
        ] do
      pat =
        if slug == "destination_fragment",
          do: "prefix_destination_fragment_suffix",
          else: "one_time_destination_secret"

      attrs = %{
        organization: "github",
        credential_source: :one_time,
        pat: pat,
        destination_organization: %{action: :new, slug: slug}
      }

      assert {:error, :invalid_destination} =
               ForgeImports.create_organization_discovery(
                 actor,
                 attrs,
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.OrganizationClient,
                 client_options: [repositories: []]
               )
    end

    assert {:error, :invalid_destination} =
             ForgeImports.create_organization_discovery(
               actor,
               %{
                 organization: "github",
                 credential_source: :saved,
                 github_identity_id: selected.identity_id,
                 destination_organization: %{action: :new, slug: "other_destination_secret"}
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [repositories: []]
             )

    assert Repo.aggregate(ImportRun, :count) == before_runs
  end

  test "initial organization destination preserves credential service failures before side effects",
       %{
         actor: actor
       } do
    original = Application.get_env(:fornacast, :github_credential_keyring)
    on_exit(fn -> Application.put_env(:fornacast, :github_credential_keyring, original) end)

    before_runs = Repo.aggregate(ImportRun, :count)
    before_audits = Repo.aggregate(AuditEvent, :count)

    for unavailable <- [
          :unavailable,
          %{active: "broken", keys: %{"broken" => <<1>>}}
        ] do
      Application.put_env(:fornacast, :github_credential_keyring, unavailable)

      assert {:error, :credential_service_unavailable} =
               ForgeImports.create_organization_discovery(
                 actor,
                 %{
                   organization: "github",
                   credential_source: :one_time,
                   pat: @pat,
                   destination_organization: %{action: :new, slug: "safe-destination"}
                 },
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.OrganizationClient,
                 client_options: [test_pid: self(), repositories: []]
               )
    end

    assert Repo.aggregate(ImportRun, :count) == before_runs
    assert Repo.aggregate(AuditEvent, :count) == before_audits
    refute_receive {:authenticated_user, _gate}, 50
    refute_receive {:organization, _gate}, 50
    refute_receive {:organization_repositories, _gate}, 50
  end

  test "organization destination updates screen one-time and actor-wide saved PATs", %{
    actor: actor
  } do
    pat = "one_time_destination_secret"
    _other = saved_account_fixture(actor, "other_destination_secret")

    assert {:ok, %RunView{id: run_id, destination: original}} =
             ForgeImports.create_organization_discovery(
               actor,
               %{
                 organization: "github",
                 credential_source: :one_time,
                 pat: pat,
                 destination_organization: %{action: :new, slug: "safe-destination"}
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [repositories: []]
             )

    before_audits = Repo.aggregate(AuditEvent, :count)

    for slug <- [
          pat,
          "destination_secret",
          "other_destination_secret",
          "https://github.com/acme?value=#{pat}"
        ] do
      assert {:error, :invalid_destination} =
               ForgeImports.update_organization_destination(actor, run_id, %{
                 action: :new,
                 slug: slug
               })

      assert {:ok, %RunView{destination: ^original}} = ForgeImports.get_run(actor, run_id)
    end

    assert Repo.aggregate(AuditEvent, :count) == before_audits
  end

  test "organization destination updates preserve actor-wide credential service failures", %{
    actor: actor
  } do
    _saved = saved_account_fixture(actor, "actor-wide-vault-secret")
    original_keyring = Application.get_env(:fornacast, :github_credential_keyring)

    on_exit(fn ->
      Application.put_env(:fornacast, :github_credential_keyring, original_keyring)
    end)

    assert {:ok, %RunView{id: run_id, destination: original_destination}} =
             ForgeImports.create_organization_discovery(
               actor,
               %{
                 organization: "github",
                 credential_source: :one_time,
                 pat: @pat,
                 destination_organization: %{action: :new, slug: "safe-destination"}
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [test_pid: self(), repositories: []]
             )

    assert_receive {:authenticated_user, _gate}, 1_000
    assert_receive {:organization, _gate}, 1_000
    assert_receive {:organization_repositories, _gate}, 1_000

    before_runs = Repo.aggregate(ImportRun, :count)
    before_audits = Repo.aggregate(AuditEvent, :count)

    for unavailable <- [
          :unavailable,
          %{active: "broken", keys: %{"broken" => <<1>>}}
        ] do
      Application.put_env(:fornacast, :github_credential_keyring, unavailable)

      assert {:error, :credential_service_unavailable} =
               ForgeImports.update_organization_destination(actor, run_id, %{
                 action: :new,
                 slug: "updated-safe-destination"
               })

      assert {:ok, %RunView{destination: ^original_destination}} =
               ForgeImports.get_run(actor, run_id)
    end

    assert Repo.aggregate(ImportRun, :count) == before_runs
    assert Repo.aggregate(AuditEvent, :count) == before_audits
    refute_receive {:authenticated_user, _gate}, 50
    refute_receive {:organization, _gate}, 50
    refute_receive {:organization_repositories, _gate}, 50
  end

  test "organization destination updates preserve missing and corrupt one-time envelope failures",
       %{
         actor: actor
       } do
    for corruption <- [:missing, :corrupt] do
      assert {:ok, %RunView{id: run_id, destination: original_destination}} =
               ForgeImports.create_organization_discovery(
                 actor,
                 %{
                   organization: "github",
                   credential_source: :one_time,
                   pat: @pat,
                   destination_organization: %{action: :new, slug: "safe-#{corruption}"}
                 },
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.OrganizationClient,
                 client_options: [test_pid: self(), repositories: []]
               )

      assert_receive {:authenticated_user, _gate}, 1_000
      assert_receive {:organization, _gate}, 1_000
      assert_receive {:organization_repositories, _gate}, 1_000

      corrupt_one_time_envelope(run_id, corruption)
      before_runs = Repo.aggregate(ImportRun, :count)
      before_audits = Repo.aggregate(AuditEvent, :count)

      assert {:error, :credential_service_unavailable} =
               ForgeImports.update_organization_destination(actor, run_id, %{
                 action: :new,
                 slug: "updated-safe-#{corruption}"
               })

      assert {:ok, %RunView{destination: ^original_destination}} =
               ForgeImports.get_run(actor, run_id)

      assert Repo.aggregate(ImportRun, :count) == before_runs
      assert Repo.aggregate(AuditEvent, :count) == before_audits
      refute_receive {:authenticated_user, _gate}, 50
      refute_receive {:organization, _gate}, 50
      refute_receive {:organization_repositories, _gate}, 50
    end
  end

  test "saved bootstrap revalidates the exact generation before insert", %{actor: actor} do
    account = saved_account_fixture(actor, "old-bootstrap-secret")
    {:ok, reference} = ForgeAccounts.github_account_reference(actor, account.identity_id)
    identity = Repo.get!(GitHubIdentity, account.identity_id)
    parent = self()
    metadata = Map.put(request_metadata(), "request_id", "replacement-bootstrap-secret")

    task =
      Task.async(fn ->
        ForgeImports.create_repository_discovery(
          actor,
          %{
            source: "octocat/hello-world",
            credential_source: :saved,
            github_identity_id: account.identity_id
          },
          metadata,
          dispatch: :inline,
          client: __MODULE__.RepositoryClient,
          client_options: [repository: repository_fixture()],
          before_run: fn ->
            send(parent, {:before_run, self()})
            receive do: (:continue_run -> :ok)
          end
        )
      end)

    assert_receive {:before_run, worker}, 2_000

    assert {:ok, replacement} =
             ForgeAccounts.replace_github_credential_if_current(
               actor,
               identity.id,
               reference.credential,
               %{
                 github_user_id: identity.github_user_id,
                 login: identity.login,
                 avatar_url: identity.avatar_url,
                 profile_url: identity.profile_url
               },
               "replacement-bootstrap-secret",
               request_metadata()
             )

    assert replacement.credential_status == :valid
    send(worker, :continue_run)

    assert {:error, reason} = Task.await(task, 5_000)
    assert reason in [:stale, :credential_changed]
    assert Repo.aggregate(ImportRun, :count) == 0

    refute Repo.exists?(
             from audit in AuditEvent,
               where:
                 audit.action in ["github_import.discovered", "github_import.discovery_failed"]
           )
  end

  test "one-time worker uses the test-only injected keyring for checkout", %{actor: actor} do
    injected = %{active: "injected", keys: %{"injected" => :binary.copy(<<99>>, 32)}}

    assert {:ok, %RunView{state: :awaiting_resolution}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{source: "octocat/hello-world", credential_source: :one_time, pat: @pat},
               request_metadata(),
               dispatch: :inline,
               keyring: injected,
               client: __MODULE__.RepositoryClient,
               client_options: [repository: repository_fixture()]
             )
  end

  test "organization discovery consumes every client page, selects all repositories, and records normalized collisions",
       %{actor: actor} do
    repositories = [
      repository_fixture(id: 92_001, owner_id: 82_001, owner_login: "github", name: "Demo"),
      repository_fixture(id: 92_002, owner_id: 82_001, owner_login: "github", name: "demo")
    ]

    before_organizations = organization_count()
    before_repositories = Repo.aggregate(LocalRepository, :count)

    assert {:ok, %RunView{state: :awaiting_resolution, repositories: items} = view} =
             ForgeImports.create_organization_discovery(
               actor,
               %{
                 organization: "github",
                 credential_source: :one_time,
                 pat: @pat,
                 destination_organization: %{action: :new, slug: "github-imported"}
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [test_pid: self(), repositories: repositories]
             )

    assert_receive {:organization, {:one_time_run, run_id}}, 1_000
    assert run_id == view.id
    assert_receive {:organization_repositories, {:one_time_run, ^run_id}}, 1_000

    assert [first, second] = items
    assert Enum.all?(items, & &1.selected)
    assert Enum.all?(items, &(&1.state == :awaiting_resolution))
    assert first.destination_slug == "demo"
    assert second.destination_slug == "demo"
    assert view.counts.selected == 2
    assert Enum.all?(items, &(&1.wait_reason == "normalized_slug_collision"))

    assert {:ok, _datetime, 0} =
             DateTime.from_iso8601(view.source.provenance["observed_at"])

    assert {:ok, reloaded} = ForgeImports.get_run(actor, view.id)
    assert reloaded.source.provenance["observed_at"] == view.source.provenance["observed_at"]
    assert organization_count() == before_organizations
    assert Repo.aggregate(LocalRepository, :count) == before_repositories
  end

  test "organization destination defaults to the GitHub login only when no choice is supplied", %{
    actor: actor
  } do
    account = saved_account_fixture(actor)

    assert {:ok, %RunView{destination: destination, repositories: [item]}} =
             ForgeImports.create_organization_discovery(
               actor,
               %{
                 organization: "github",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [
                 repositories: [
                   repository_fixture(
                     owner_id: 82_001,
                     owner_login: "github",
                     full_name: "github/hello-world"
                   )
                 ]
               ]
             )

    assert destination.organization_slug == "github"
    assert item.destination_slug == "hello-world"
    assert item.state == :queued
  end

  test "destination planning masks unowned organizations and persists reserved and local conflicts",
       %{actor: actor} do
    account = saved_account_fixture(actor)
    other = user_fixture("other-owner")
    {:ok, foreign_org} = organization_fixture(other, "foreign-org")

    attrs = %{
      organization: "github",
      credential_source: :saved,
      github_identity_id: account.identity_id,
      destination_organization: %{action: :existing, id: foreign_org.id}
    }

    assert {:error, :not_found} =
             ForgeImports.create_organization_discovery(
               actor,
               attrs,
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [
                 repositories: [
                   repository_fixture(
                     owner_id: 82_001,
                     owner_login: "github",
                     full_name: "github/hello-world"
                   )
                 ]
               ]
             )

    assert {:ok, %RunView{} = reserved} =
             ForgeImports.create_organization_discovery(
               actor,
               put_in(attrs, [:destination_organization], %{action: :new, slug: "imports"}),
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [
                 repositories: [
                   repository_fixture(
                     owner_id: 82_001,
                     owner_login: "github",
                     full_name: "github/hello-world"
                   )
                 ]
               ]
             )

    assert Enum.all?(reserved.repositories, fn item ->
             item.wait_reason == "reserved_namespace" and is_nil(item.destination_slug)
           end)

    assert {:ok, %RunView{repositories: [restored]}} =
             ForgeImports.update_organization_destination(actor, reserved.id, %{
               action: :new,
               slug: "valid-destination"
             })

    assert restored.destination_slug == "hello-world"
    assert restored.state == :queued
    assert restored.wait_reason == nil

    {:ok, _existing} =
      ForgeRepos.create_repository(actor, %{
        slug: "hello-world",
        name: "Existing",
        visibility: :private
      })

    assert {:ok, %RunView{repositories: [item]}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/hello-world",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [repository: repository_fixture()]
             )

    assert item.state == :awaiting_resolution
    assert item.wait_reason == "repository_conflict"

    assert {:ok, %RunView{repositories: [normalized]}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/CamelCase",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [
                 repository:
                   repository_fixture(
                     name: "CamelCase",
                     full_name: "octocat/CamelCase",
                     html_url: "https://github.com/octocat/CamelCase",
                     id: 91_009
                   )
               ]
             )

    assert normalized.destination_slug == "camelcase"
    assert normalized.state == :awaiting_resolution
    assert normalized.wait_reason == "repository_slug_normalized"
  end

  test "actor-scoped reads and plan updates mask foreign and disabled users", %{actor: actor} do
    account = saved_account_fixture(actor)

    assert {:ok, %RunView{id: run_id, repositories: [item]}} =
             ForgeImports.create_organization_discovery(
               actor,
               %{
                 organization: "github",
                 credential_source: :saved,
                 github_identity_id: account.identity_id,
                 destination_organization: %{action: :new, slug: "new-destination"}
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.OrganizationClient,
               client_options: [
                 repositories: [
                   repository_fixture(
                     owner_id: 82_001,
                     owner_login: "github",
                     full_name: "github/hello-world"
                   )
                 ]
               ]
             )

    other = user_fixture("foreign-viewer")
    assert {:error, :not_found} = ForgeImports.get_run(other, run_id)
    assert {:error, :not_found} = ForgeImports.update_repository_selection(other, run_id, [])

    assert {:error, :not_found} =
             ForgeImports.update_organization_destination(other, run_id, %{
               action: :new,
               slug: "masked"
             })

    assert {:ok, %RunView{counts: %{selected: 0}, repositories: [unselected]}} =
             ForgeImports.update_repository_selection(actor, run_id, [])

    refute unselected.selected
    assert unselected.id == item.id

    actor
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:error, :not_found} = ForgeImports.get_run(actor, run_id)
  end

  test "expected discovery failure terminalizes the run, clears the one-time envelope, and stores only safe evidence",
       %{actor: actor} do
    assert {:ok, %RunView{state: :failed, reports: [report]} = view} =
             ForgeImports.create_repository_discovery(
               actor,
               %{source: "octocat/missing", credential_source: :one_time, pat: @pat},
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.FailingClient,
               client_options: [test_pid: self()]
             )

    raw = Repo.get!(ImportRun, view.id)
    assert raw.credential_ciphertext == nil
    assert raw.credential_nonce == nil
    assert raw.credential_tag == nil
    assert raw.credential_key_id == nil
    assert raw.report_finalized_at
    assert report.classification == "github_forbidden"

    inspected = inspect(Repo.all(ReportEntry)) <> inspect(Repo.all(AuditEvent)) <> inspect(view)
    refute inspected =~ @pat
    refute inspected =~ "Bearer"
    refute inspected =~ Fornacast.Config.repo_storage_root()
  end

  test "source metadata is screened against every actor-owned saved PAT before persistence", %{
    actor: actor
  } do
    selected = saved_account_fixture(actor, "selected-credential-secret-value")
    _other = saved_account_fixture(actor, "actor-wide-credential-secret-value")

    poisoned = repository_fixture(description: "actor-wide-credential-secret-value")

    assert {:ok, %RunView{state: :failed, reports: [report]} = view} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/hello-world",
                 credential_source: :saved,
                 github_identity_id: selected.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.RepositoryClient,
               client_options: [repository: poisoned]
             )

    assert report.classification == "github_invalid_response"
    assert Repo.aggregate(ForgeImports.RepositoryItem, :count) == 0

    persisted =
      inspect(Repo.get!(ImportRun, view.id)) <> inspect(view) <> inspect(Repo.all(AuditEvent))

    refute persisted =~ "actor-wide-credential-secret-value"
    refute persisted =~ "selected-credential-secret-value"
  end

  test "saved 401 invalidates only the exact checked-out credential generation", %{actor: actor} do
    account = saved_account_fixture(actor)

    assert {:ok, %RunView{state: :failed}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{
                 source: "octocat/hello-world",
                 credential_source: :saved,
                 github_identity_id: account.identity_id
               },
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.UnauthorizedClient,
               client_options: []
             )

    assert {:ok, accounts} = ForgeAccounts.list_github_accounts(actor)

    assert %{credential_status: :invalid} =
             Enum.find(accounts, &(&1.identity_id == account.identity_id))

    assert Repo.exists?(
             from audit in AuditEvent,
               where: audit.action == "github.credential.invalidated"
           )
  end

  test "saved forbidden rate-limit and transport failures keep the credential valid", %{
    actor: actor
  } do
    account = saved_account_fixture(actor)

    for kind <- [:forbidden, :primary_rate_limit, :transport] do
      assert {:ok, %RunView{state: :failed}} =
               ForgeImports.create_repository_discovery(
                 actor,
                 %{
                   source: "octocat/hello-world",
                   credential_source: :saved,
                   github_identity_id: account.identity_id
                 },
                 request_metadata(),
                 dispatch: :inline,
                 client: __MODULE__.ClassifiedFailureClient,
                 client_options: [kind: kind]
               )

      assert {:ok, accounts} = ForgeAccounts.list_github_accounts(actor)

      assert %{credential_status: :valid} =
               Enum.find(accounts, &(&1.identity_id == account.identity_id))
    end
  end

  test "one-time 401 never invalidates an unrelated saved credential", %{actor: actor} do
    account = saved_account_fixture(actor)

    assert {:ok, %RunView{state: :failed}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{source: "octocat/hello-world", credential_source: :one_time, pat: @pat},
               request_metadata(),
               dispatch: :inline,
               client: __MODULE__.UnauthorizedClient,
               client_options: []
             )

    assert {:ok, accounts} = ForgeAccounts.list_github_accounts(actor)

    assert %{credential_status: :valid} =
             Enum.find(accounts, &(&1.identity_id == account.identity_id))

    refute Repo.exists?(
             from audit in AuditEvent,
               where: audit.action == "github.credential.invalidated"
           )
  end

  test "concurrent saved replacement wins over a stale 401 invalidation", %{actor: actor} do
    account = saved_account_fixture(actor)
    {:ok, reference} = ForgeAccounts.github_account_reference(actor, account.identity_id)
    parent = self()

    task =
      Task.async(fn ->
        ForgeImports.create_repository_discovery(
          actor,
          %{
            source: "octocat/hello-world",
            credential_source: :saved,
            github_identity_id: account.identity_id
          },
          request_metadata(),
          dispatch: :inline,
          client: __MODULE__.ConcurrentUnauthorizedClient,
          client_options: [test_pid: parent]
        )
      end)

    assert_receive {:unauthorized_started, worker}, 2_000
    identity = Repo.get!(GitHubIdentity, account.identity_id)

    assert {:ok, replacement} =
             ForgeAccounts.replace_github_credential_if_current(
               actor,
               identity.id,
               reference.credential,
               %{
                 github_user_id: identity.github_user_id,
                 login: identity.login,
                 avatar_url: identity.avatar_url,
                 profile_url: identity.profile_url
               },
               "replacement-credential-secret",
               request_metadata()
             )

    assert replacement.credential_status == :valid
    send(worker, :return_unauthorized)

    assert {:ok, %RunView{state: :failed, reports: [report]}} = Task.await(task, 5_000)
    assert report.classification == "github_credential_changed"

    assert {:ok, accounts} = ForgeAccounts.list_github_accounts(actor)

    assert %{credential_status: :valid} =
             Enum.find(accounts, &(&1.identity_id == account.identity_id))
  end

  defmodule RepositoryClient do
    def authenticated_user(_pat, opts) do
      notify(opts, {:authenticated_user, Keyword.fetch!(opts, :gate_key)})

      {:ok,
       %User{
         id: 71_001,
         login: "discovery-user",
         name: "Discovery User",
         avatar_url: nil,
         html_url: "https://github.com/discovery-user"
       }}
    end

    def repository(_pat, _owner, _repository, opts) do
      notify(opts, {:repository, Keyword.fetch!(opts, :gate_key)})
      {:ok, Keyword.fetch!(opts, :repository)}
    end

    defp notify(opts, message) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule OrganizationClient do
    def authenticated_user(_pat, opts) do
      notify(opts, {:authenticated_user, Keyword.fetch!(opts, :gate_key)})

      {:ok,
       %User{
         id: 71_001,
         login: "discovery-user",
         name: nil,
         avatar_url: nil,
         html_url: "https://github.com/discovery-user"
       }}
    end

    def organization(_pat, _login, opts) do
      notify(opts, {:organization, Keyword.fetch!(opts, :gate_key)})

      {:ok,
       %Organization{
         id: 82_001,
         login: "github",
         name: "GitHub",
         description: nil,
         avatar_url: nil,
         html_url: "https://github.com/github"
       }}
    end

    def organization_repositories(_pat, _login, opts) do
      notify(opts, {:organization_repositories, Keyword.fetch!(opts, :gate_key)})
      {:ok, Keyword.fetch!(opts, :repositories)}
    end

    defp notify(opts, message) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule FailingClient do
    defdelegate authenticated_user(pat, opts),
      to: ForgeImports.DiscoveryTest.RepositoryClient

    def repository(_pat, _owner, _repository, opts) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, {:repository, Keyword.fetch!(opts, :gate_key)})
        _ -> :ok
      end

      {:error, Error.new(:forbidden)}
    end

    def releases(_pat, _owner, _repository, opts) do
      send(Keyword.fetch!(opts, :test_pid), :release_enumeration_called)
      {:ok, []}
    end
  end

  defmodule UnauthorizedClient do
    defdelegate authenticated_user(pat, opts),
      to: ForgeImports.DiscoveryTest.RepositoryClient

    def repository(_pat, _owner, _repository, _opts),
      do: {:error, Error.new(:invalid_credential)}
  end

  defmodule ConcurrentUnauthorizedClient do
    defdelegate authenticated_user(pat, opts),
      to: ForgeImports.DiscoveryTest.RepositoryClient

    def repository(_pat, _owner, _repository, opts) do
      parent = Keyword.fetch!(opts, :test_pid)
      send(parent, {:unauthorized_started, self()})

      receive do
        :return_unauthorized -> {:error, Error.new(:invalid_credential)}
      end
    end
  end

  defmodule ClassifiedFailureClient do
    defdelegate authenticated_user(pat, opts),
      to: ForgeImports.DiscoveryTest.RepositoryClient

    def repository(_pat, _owner, _repository, opts),
      do: {:error, Error.new(Keyword.fetch!(opts, :kind))}
  end

  defp repository_fixture(overrides \\ []) do
    defaults = [
      id: 91_000,
      owner_id: 81_000,
      name: "hello-world",
      full_name: "octocat/hello-world",
      owner_login: "octocat",
      description: "A repository",
      visibility: :public,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true,
      fork: false,
      archived: false,
      html_url: "https://github.com/octocat/hello-world",
      updated_at: @now,
      pushed_at: @now
    ]

    values = Keyword.merge(defaults, overrides)

    values =
      if Keyword.has_key?(overrides, :full_name) do
        values
      else
        Keyword.put(values, :full_name, "#{values[:owner_login]}/#{values[:name]}")
      end

    values =
      if Keyword.has_key?(overrides, :html_url) do
        values
      else
        Keyword.put(values, :html_url, "https://github.com/#{values[:full_name]}")
      end

    struct!(Repository, values)
  end

  defp saved_account_fixture(actor, pat \\ "saved-discovery-pat") do
    github_id = 72_000 + System.unique_integer([:positive])

    assert {:ok, account} =
             ForgeAccounts.save_github_account(
               actor,
               %{
                 github_user_id: github_id,
                 login: "saved-#{github_id}",
                 avatar_url: nil,
                 profile_url: "https://github.com/saved-#{github_id}"
               },
               pat,
               request_metadata()
             )

    account
  end

  defp organization_fixture(actor, slug) do
    ForgeAccounts.create_organization(actor, %{username: slug, display_name: slug})
  end

  defp user_fixture(prefix) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "#{prefix}-#{suffix}",
        email: "#{prefix}-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp request_metadata do
    suffix = System.unique_integer([:positive])

    %{
      "request_id" => "request-#{suffix}",
      "operation_id" => "operation-#{suffix}",
      "ip_address" => "203.0.113.8",
      "user_agent" => String.duplicate("ua", 200)
    }
  end

  defp organization_count do
    Repo.aggregate(
      from(user in ForgeAccounts.User, where: user.kind == :organization),
      :count
    )
  end

  defp corrupt_one_time_envelope(run_id, :missing) do
    Repo.update_all(
      from(run in ImportRun, where: run.id == ^run_id),
      set: [
        credential_ciphertext: nil,
        credential_nonce: nil,
        credential_tag: nil,
        credential_key_id: nil
      ]
    )
  end

  defp corrupt_one_time_envelope(run_id, :corrupt) do
    Repo.update_all(
      from(run in ImportRun, where: run.id == ^run_id),
      set: [credential_tag: :binary.copy(<<0>>, 16)]
    )
  end

  defp storage_snapshot do
    root = Fornacast.Config.repo_storage_root()
    Path.wildcard(Path.join(root, "**"), match_dot: true) |> Enum.sort()
  end

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "api_keys",
          "ssh_keys",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
