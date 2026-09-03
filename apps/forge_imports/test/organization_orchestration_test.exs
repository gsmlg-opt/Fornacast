defmodule ForgeImports.OrganizationOrchestrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{Organization, OrganizationMember, User}
  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, RepositoryItem, RunView}
  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-25 12:00:00Z]

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture("importer")
    identity = identity_fixture(actor)
    %{actor: actor, identity: identity}
  end

  test "start_import creates a new organization with the importer as sole owner", %{
    actor: actor,
    identity: identity
  } do
    other_github_member = user_fixture("gh-member")

    run =
      organization_run_fixture(actor, identity,
        source_owner_login: "acme",
        destination_organization_slug: "acme",
        source_metadata: %{
          "name" => "Acme Engineering",
          "description" => "Widgets and sprockets",
          "observed_at" => DateTime.to_iso8601(@now)
        }
      )

    item =
      repository_item_fixture(run,
        github_repository_id: 9_710_000_001,
        destination_slug: "widgets"
      )

    assert {:ok, %RunView{state: :running} = activated} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-new-org"),
               dispatch: :manual
             )

    assert %Organization{} = activated.destination_organization
    assert activated.destination_organization.username == "acme"
    assert activated.destination_organization.display_name == "Acme Engineering"
    assert activated.destination_organization.description == "Widgets and sprockets"
    assert activated.destination.organization_id == activated.destination_organization.id
    assert ForgeAccounts.organization_role(actor, activated.destination_organization) == :owner
    assert ForgeAccounts.list_user_organizations(other_github_member) == []

    assert [
             %OrganizationMember{
               organization_id: organization_id,
               user_id: actor_id,
               role: :owner
             }
           ] = Repo.all(OrganizationMember)

    assert {organization_id, actor_id} ==
             {activated.destination_organization.id, actor.id}

    assert %RepositoryItem{
             destination_owner_id: ^organization_id,
             state: :queued,
             attempt_count: 1
           } = Repo.get!(RepositoryItem, item.id)

    assert Repo.aggregate(ImportAttempt, :count, :id) == 1

    assert Repo.exists?(
             from audit in AuditEvent,
               where: audit.action == "organization.created"
           )

    assert Repo.exists?(
             from audit in AuditEvent,
               where: audit.action == "github_import.organization_activated"
           )

    assert Repo.exists?(
             from audit in AuditEvent,
               where: audit.action == "github_import.started"
           )
  end

  test "missing GitHub display name falls back to the chosen local slug", %{
    actor: actor,
    identity: identity
  } do
    run =
      organization_run_fixture(actor, identity,
        destination_organization_slug: "fallback-org",
        source_metadata: %{
          "description" => "Only a description",
          "observed_at" => DateTime.to_iso8601(@now)
        }
      )

    _item =
      repository_item_fixture(run,
        github_repository_id: 9_710_000_002,
        destination_slug: "tools"
      )

    assert {:ok, %RunView{destination_organization: organization}} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-fallback-name"),
               dispatch: :manual
             )

    assert organization.username == "fallback-org"
    assert organization.display_name == "fallback-org"
    assert organization.description == "Only a description"
  end

  test "existing organization activation preserves profile and memberships", %{
    actor: actor,
    identity: identity
  } do
    other_member = user_fixture("co-owner")

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(actor, %{
               username: "kept-org",
               display_name: "Local Kept Org",
               description: "Do not overwrite"
             })

    assert {:ok, _} =
             %OrganizationMember{}
             |> OrganizationMember.changeset(%{
               organization_id: organization.id,
               user_id: other_member.id,
               role: :owner
             })
             |> Repo.insert()

    run =
      organization_run_fixture(actor, identity,
        destination_organization_action: :existing,
        destination_organization_slug: organization.username,
        destination_organization_id: organization.id,
        source_metadata: %{
          "name" => "GitHub Name Should Not Win",
          "description" => "GitHub description should not win",
          "observed_at" => DateTime.to_iso8601(@now)
        }
      )

    item =
      repository_item_fixture(run,
        github_repository_id: 9_710_000_003,
        destination_owner_id: organization.id,
        destination_slug: "service"
      )

    assert {:ok, %RunView{state: :running} = activated} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-existing-org"),
               dispatch: :manual
             )

    assert activated.destination_organization.id == organization.id
    assert activated.destination_organization.display_name == "Local Kept Org"
    assert activated.destination_organization.description == "Do not overwrite"

    refreshed = Repo.get!(Organization, organization.id)
    assert refreshed.display_name == "Local Kept Org"
    assert refreshed.description == "Do not overwrite"

    assert MapSet.new([
             {actor.id, :owner},
             {other_member.id, :owner}
           ]) ==
             OrganizationMember
             |> where([member], member.organization_id == ^organization.id)
             |> select([member], {member.user_id, member.role})
             |> Repo.all()
             |> MapSet.new()

    assert Repo.get!(RepositoryItem, item.id).destination_owner_id == organization.id

    refute Repo.exists?(
             from audit in AuditEvent,
               where: audit.action == "organization.created"
           )
  end

  test "does not import GitHub members or teams when activating a new organization", %{
    actor: actor,
    identity: identity
  } do
    _outsider = user_fixture("outsider")

    run =
      organization_run_fixture(actor, identity,
        destination_organization_slug: "no-members",
        source_metadata: %{
          "name" => "No Members",
          "observed_at" => DateTime.to_iso8601(@now)
        }
      )

    _item =
      repository_item_fixture(run,
        github_repository_id: 9_710_000_004,
        destination_slug: "core"
      )

    assert {:ok, %RunView{destination_organization: organization}} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-no-members"),
               dispatch: :manual
             )

    assert [%OrganizationMember{user_id: actor_id, role: :owner}] =
             Repo.all(
               from member in OrganizationMember,
                 where: member.organization_id == ^organization.id
             )

    assert actor_id == actor.id
  end

  test "rejects reserved namespace drift and ownership drift before activation", %{
    actor: actor,
    identity: identity
  } do
    reserved_run =
      organization_run_fixture(actor, identity,
        destination_organization_slug: "settings",
        source_metadata: %{"observed_at" => DateTime.to_iso8601(@now)}
      )

    _reserved_item =
      repository_item_fixture(reserved_run,
        github_repository_id: 9_710_000_005,
        destination_slug: "app"
      )

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               reserved_run.id,
               request_metadata("start-reserved"),
               dispatch: :manual
             )

    refute ForgeAccounts.get_organization_by_slug("settings")
    assert Repo.get!(ImportRun, reserved_run.id).state == :awaiting_resolution

    assert {:ok, %Organization{} = foreign_org} =
             ForgeAccounts.create_organization(user_fixture("foreign-owner"), %{
               username: "foreign-owned",
               display_name: "Foreign Owned"
             })

    site_admin =
      user_fixture("site-admin", role: :admin)

    drift_run =
      organization_run_fixture(site_admin, identity_fixture(site_admin),
        destination_organization_action: :existing,
        destination_organization_slug: foreign_org.username,
        destination_organization_id: foreign_org.id,
        source_metadata: %{"observed_at" => DateTime.to_iso8601(@now)}
      )

    _drift_item =
      repository_item_fixture(drift_run,
        github_repository_id: 9_710_000_006,
        destination_owner_id: foreign_org.id,
        destination_slug: "leak"
      )

    assert {:error, :stale} =
             ForgeImports.start_import(
               site_admin,
               drift_run.id,
               request_metadata("start-admin-override"),
               dispatch: :manual
             )

    assert Repo.get!(ImportRun, drift_run.id).state == :awaiting_resolution
    assert Repo.aggregate(ImportAttempt, :count, :id) == 0
  end

  test "requires at least one selected repository and leaves not-selected items untouched", %{
    actor: actor,
    identity: identity
  } do
    empty_run =
      organization_run_fixture(actor, identity,
        destination_organization_slug: "needs-selection",
        selected_count: 0,
        source_metadata: %{"observed_at" => DateTime.to_iso8601(@now)}
      )

    _unselected =
      repository_item_fixture(empty_run,
        github_repository_id: 9_710_000_007,
        destination_slug: "skipped-source",
        selected: false
      )

    assert {:error, :invalid_selection} =
             ForgeImports.start_import(
               actor,
               empty_run.id,
               request_metadata("start-empty"),
               dispatch: :manual
             )

    refute ForgeAccounts.get_organization_by_slug("needs-selection")

    mixed_run =
      organization_run_fixture(actor, identity,
        destination_organization_slug: "mixed-selection",
        selected_count: 1,
        source_metadata: %{
          "name" => "Mixed",
          "observed_at" => DateTime.to_iso8601(@now)
        }
      )

    selected =
      repository_item_fixture(mixed_run,
        github_repository_id: 9_710_000_008,
        destination_slug: "chosen"
      )

    not_selected =
      repository_item_fixture(mixed_run,
        github_repository_id: 9_710_000_009,
        destination_slug: "left-out",
        selected: false
      )

    assert {:ok, %RunView{state: :running, destination_organization: organization}} =
             ForgeImports.start_import(
               actor,
               mixed_run.id,
               request_metadata("start-mixed"),
               dispatch: :manual
             )

    assert %RepositoryItem{attempt_count: 1, destination_owner_id: owner_id, state: :queued} =
             Repo.get!(RepositoryItem, selected.id)

    assert owner_id == organization.id

    assert %RepositoryItem{attempt_count: 0, destination_owner_id: nil, state: :queued} =
             Repo.get!(RepositoryItem, not_selected.id)

    assert Repo.aggregate(ImportAttempt, :count, :id) == 1
  end

  test "organization survives when every selected repository later fails", %{
    actor: actor,
    identity: identity
  } do
    run =
      organization_run_fixture(actor, identity,
        destination_organization_slug: "survives-failure",
        selected_count: 2,
        source_metadata: %{
          "name" => "Survives",
          "description" => "Keep me",
          "observed_at" => DateTime.to_iso8601(@now)
        }
      )

    first =
      repository_item_fixture(run,
        github_repository_id: 9_710_000_010,
        destination_slug: "one"
      )

    second =
      repository_item_fixture(run,
        github_repository_id: 9_710_000_011,
        destination_slug: "two"
      )

    assert {:ok, %RunView{destination_organization: organization}} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-survive"),
               dispatch: :manual
             )

    organization_id = organization.id

    now = DateTime.utc_now(:second)

    for item <- [first, second] do
      current = Repo.get!(RepositoryItem, item.id)

      {:ok, failed} =
        Persistence.update_without_lease(
          current,
          [:queued],
          RepositoryItem.transition_changeset(current, :failed, %{
            failure_kind: "staging_unavailable"
          }),
          now
        )

      assert failed.state == :failed
    end

    surviving = Repo.get!(Organization, organization_id)
    assert surviving.username == "survives-failure"
    assert surviving.display_name == "Survives"
    assert surviving.description == "Keep me"
    assert ForgeAccounts.organization_role(actor, surviving) == :owner
    assert Repo.get!(ImportRun, run.id).destination_organization_id == organization_id
  end

  test "ForgeAccounts.create_import_organization creates the sole owner and audited organization",
       %{actor: actor} do
    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_import_organization(
               actor,
               %{
                 username: "import-created",
                 display_name: "Import Created",
                 description: "From GitHub import",
                 state: :active
               },
               request_metadata("create-import-org")
             )

    assert organization.username == "import-created"
    assert ForgeAccounts.organization_role(actor, organization) == :owner

    assert %AuditEvent{
             action: "organization.created",
             actor_user_id: actor_id,
             target_id: target_id
           } =
             Repo.get_by!(AuditEvent,
               action: "organization.created",
               target_type: "organization"
             )

    assert actor_id == actor.id
    assert target_id == Integer.to_string(organization.id)
  end

  defp organization_run_fixture(actor, identity, overrides) do
    defaults = %{
      actor_user_id: actor.id,
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: 8_710_000_001,
      source_owner_login: "acme",
      source_repository_github_id: nil,
      source_repository_full_name: nil,
      destination_organization_action: :new,
      destination_organization_slug: "acme",
      destination_organization_id: nil,
      destination_organization_status: :clean,
      state: :awaiting_resolution,
      selected_count: 1,
      source_metadata: %{"observed_at" => DateTime.to_iso8601(@now)},
      request_metadata: %{}
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp repository_item_fixture(run, overrides) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: 9_710_000_001,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: nil,
      destination_slug: "demo",
      destination_visibility: :private,
      state: :queued
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_610_000_000 + suffix,
          login: "org-importer-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)
    identity
  end

  defp user_fixture(prefix, opts \\ []) do
    suffix = System.unique_integer([:positive])
    role = Keyword.get(opts, :role, :user)

    Repo.insert!(%User{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: role,
      state: :active
    })
  end

  defp request_metadata(operation) do
    %{
      "request_id" => "#{operation}-request",
      "operation_id" => "#{operation}-operation",
      "ip_address" => "203.0.113.90",
      "user_agent" => "forge-import-organization-orchestration-test"
    }
  end

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, %Ecto.Changeset{} = changeset}) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

  defp reset_database! do
    for table <- [
          "github_import_repository_cleanups",
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
