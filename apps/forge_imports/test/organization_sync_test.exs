defmodule ForgeImports.OrganizationSyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{Organization, User}
  alias ForgeGitHub.AppInstallation
  alias ForgeImports.ImportRun
  alias ForgeMirrors.OrganizationMirror
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    actor = user_fixture()

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(actor, %{
               username: unique("sync-org"),
               display_name: "Sync Organization"
             })

    %{actor: actor, organization: organization}
  end

  test "settings projection is actor scoped, bounded, and marks unavailable capabilities",
       context do
    assert {:ok, disconnected} =
             ForgeImports.OrganizationSync.get_settings(context.actor, context.organization)

    assert disconnected.coverage == :none
    assert disconnected.actions.install
    assert disconnected.capabilities["lfs"] == "disabled"
    assert disconnected.capabilities["releases"] == "unavailable"

    outsider = user_fixture()

    assert {:error, :forbidden} =
             ForgeImports.OrganizationSync.get_settings(outsider, context.organization)
  end

  test "policy updates require installation permissions and reject invalid selections", context do
    installation_id = 9_000_000 + System.unique_integer([:positive, :monotonic])
    github_account_id = 9_100_000 + System.unique_integer([:positive, :monotonic])
    now = DateTime.utc_now(:second)

    assert {:ok, _installation} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: "sync-source",
               account_type: :organization,
               repository_selection: :selected,
               permissions: %{
                 "metadata" => "read",
                 "contents" => "write",
                 "issues" => "write",
                 "administration" => "write"
               },
               state: :active,
               last_verified_at: now
             })

    assert {:ok, pending} =
             ForgeMirrors.create_organization_mirror(context.actor, %{
               organization_id: context.organization.id,
               provider: "github",
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: "sync-source"
             })

    assert {:ok, %OrganizationMirror{state: :ready_to_bootstrap}} =
             ForgeMirrors.transition_organization_mirror(
               context.actor,
               pending,
               :ready_to_bootstrap
             )

    attrs = %{
      "repository_selection" => "selected",
      "selected_repository_ids" => ["", "101", "202"],
      "auto_import_new" => "true",
      "auto_create_remote" => "false",
      "repository_deletion_policy" => "retain",
      "conflict_notification_policy" => "dashboard_only",
      "capabilities" => ["git", "issues"]
    }

    assert {:error, :missing_permissions} =
             ForgeImports.OrganizationSync.update_settings(
               context.actor,
               context.organization,
               Map.put(attrs, "capabilities", ["git", "issues", "pulls"]),
               request_metadata()
             )

    assert {:ok, updated} =
             ForgeImports.OrganizationSync.update_settings(
               context.actor,
               context.organization,
               attrs,
               request_metadata()
             )

    assert updated.policy["repository_selection"] == "selected"
    assert updated.policy["selected_repository_ids"] == [101, 202]
    assert updated.policy["auto_import_new_repositories"]
    assert updated.capabilities["git"] == "enabled"
    assert updated.capabilities["lfs"] == "disabled"

    assert {:ok, view} =
             ForgeImports.OrganizationSync.get_settings(context.actor, context.organization)

    assert view.coverage == :partial
    assert view.missing_permissions == []
    refute view.actions.bootstrap
    assert view.actions.update

    assert {:error, :invalid_request} =
             ForgeImports.OrganizationSync.update_settings(
               context.actor,
               context.organization,
               Map.put(attrs, "selected_repository_ids", [""]),
               request_metadata()
             )

    assert {:error, :invalid_request} =
             ForgeImports.OrganizationSync.update_settings(
               context.actor,
               context.organization,
               Map.put(attrs, "unexpected", "value"),
               request_metadata()
             )
  end

  test "pause, resume, reconcile, and disconnect use mirror lifecycle APIs", context do
    assert {:ok, pending} =
             ForgeMirrors.create_organization_mirror(context.actor, %{
               organization_id: context.organization.id,
               provider: "github"
             })

    assert {:ok, _ready} =
             ForgeMirrors.transition_organization_mirror(
               context.actor,
               pending,
               :ready_to_bootstrap
             )

    assert {:ok, %OrganizationMirror{state: :paused}} =
             ForgeImports.OrganizationSync.pause(
               context.actor,
               context.organization,
               request_metadata()
             )

    assert {:ok, %OrganizationMirror{state: :ready_to_bootstrap}} =
             ForgeImports.OrganizationSync.resume(
               context.actor,
               context.organization,
               request_metadata()
             )

    assert {:ok, operation} =
             ForgeImports.OrganizationSync.reconcile(
               context.actor,
               context.organization,
               request_metadata()
             )

    assert operation.kind == "reconcile.organization_inventory"

    assert {:ok, %OrganizationMirror{state: :revoked}} =
             ForgeImports.OrganizationSync.disconnect(
               context.actor,
               context.organization,
               request_metadata()
             )

    assert {:error, :not_found} =
             ForgeImports.OrganizationSync.reconcile(
               context.actor,
               context.organization,
               request_metadata()
             )
  end

  test "policy updates are rejected while bootstrap state is mutable", context do
    assert {:ok, pending} =
             ForgeMirrors.create_organization_mirror(context.actor, %{
               organization_id: context.organization.id,
               provider: "github"
             })

    assert {:ok, ready} =
             ForgeMirrors.transition_organization_mirror(
               context.actor,
               pending,
               :ready_to_bootstrap
             )

    assert {:ok, bootstrapping} =
             ForgeMirrors.transition_organization_mirror(context.actor, ready, :bootstrapping)

    assert {:error, :invalid_transition} =
             ForgeImports.OrganizationSync.update_settings(
               context.actor,
               context.organization,
               settings_attrs(),
               request_metadata()
             )

    assert {:ok, _catching_up} =
             ForgeMirrors.transition_organization_mirror(
               context.actor,
               bootstrapping,
               :catching_up
             )

    assert {:error, :invalid_transition} =
             ForgeImports.OrganizationSync.update_settings(
               context.actor,
               context.organization,
               settings_attrs(),
               request_metadata()
             )
  end

  test "bootstrap atomically binds an App-backed importer run and enters bootstrapping",
       context do
    installation_id = 9_200_000 + System.unique_integer([:positive, :monotonic])
    github_account_id = 9_300_000 + System.unique_integer([:positive, :monotonic])
    now = DateTime.utc_now(:second)

    assert {:ok, _installation} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: "bootstrap-source",
               account_type: :organization,
               repository_selection: :all,
               permissions: %{
                 "metadata" => "read",
                 "contents" => "write",
                 "issues" => "write",
                 "pull_requests" => "write",
                 "administration" => "write"
               },
               state: :active,
               last_verified_at: now
             })

    assert {:ok, pending} =
             ForgeMirrors.create_organization_mirror(context.actor, %{
               organization_id: context.organization.id,
               provider: "github",
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: "bootstrap-source",
               capabilities: %{
                 "git" => "enabled",
                 "issues" => "enabled",
                 "pulls" => "enabled",
                 "lfs" => "enabled",
                 "releases" => "unavailable"
               },
               policy: %{
                 "repository_selection" => "all",
                 "selected_repository_ids" => [],
                 "auto_import_new_repositories" => false,
                 "auto_create_remote_repositories" => false,
                 "repository_deletion_policy" => "retain",
                 "conflict_notification_policy" => "dashboard_only"
               }
             })

    assert {:ok, %OrganizationMirror{state: :ready_to_bootstrap}} =
             ForgeMirrors.transition_organization_mirror(
               context.actor,
               pending,
               :ready_to_bootstrap
             )

    assert {:error, :invalid_request} =
             ForgeImports.OrganizationSync.bootstrap(
               context.actor,
               context.organization,
               %{"repository_selection" => "all"},
               request_metadata()
             )

    assert Repo.aggregate(ImportRun, :count, :id) == 0

    assert {:error, :missing_permissions} =
             ForgeImports.OrganizationSync.bootstrap(
               context.actor,
               context.organization,
               %{"repository_selection" => "current_policy"},
               request_metadata(),
               installation_fetch: fn ^installation_id ->
                 {:ok,
                  app_installation(
                    installation_id,
                    github_account_id,
                    %{"metadata" => "read"}
                  )}
               end
             )

    assert Repo.aggregate(ImportRun, :count, :id) == 0

    assert {:ok,
            %{
              run: %ImportRun{
                id: run_id,
                credential_source: :github_app,
                github_identity_id: nil,
                github_credential_id: nil,
                source_owner_github_id: ^github_account_id,
                source_owner_login: "bootstrap-source",
                destination_organization_id: destination_organization_id,
                state: :discovering
              },
              mirror: %OrganizationMirror{
                state: :bootstrapping,
                bootstrap_import_run_id: run_id
              }
            }} =
             ForgeImports.OrganizationSync.bootstrap(
               context.actor,
               context.organization,
               %{"repository_selection" => "current_policy"},
               request_metadata(),
               installation_fetch: fn ^installation_id ->
                 {:ok, app_installation(installation_id, github_account_id)}
               end
             )

    assert destination_organization_id == context.organization.id

    assert Repo.one(
             from run in ImportRun,
               where:
                 run.id == ^run_id and run.credential_source == :github_app and
                   is_nil(run.credential_ciphertext) and is_nil(run.credential_nonce) and
                   is_nil(run.credential_tag) and is_nil(run.credential_key_id),
               select: count(run.id)
           ) == 1

    bound_mirror = Repo.get_by!(OrganizationMirror, bootstrap_import_run_id: run_id)
    binding = ForgeMirrors.TestSupport.MirrorFixtures.repository_mirror_fixture(bound_mirror)

    {:ok, deferred, :enqueued} =
      ForgeMirrors.enqueue_webhook_delivery(
        %{
          organization_mirror_id: bound_mirror.id,
          delivery_guid: Ecto.UUID.generate(),
          hook_id: System.unique_integer([:positive]),
          event: "issues",
          action: "edited",
          installation_id: installation_id,
          github_repository_id: binding.github_repository_id,
          signature_version: "sha256",
          raw_payload: JSON.encode!(%{"action" => "edited"})
        },
        :pending_unsupported
      )

    completed =
      Repo.get!(ImportRun, run_id)
      |> Ecto.Changeset.change(state: :completed_with_warnings, terminal_at: now)
      |> Repo.update!()

    assert :ok = ForgeImports.OrganizationSync.Bootstrap.finish(completed, now)
    mirror = Repo.get_by!(OrganizationMirror, bootstrap_import_run_id: run_id)
    assert mirror.state == :degraded
    assert mirror.next_reconcile_at == now
    assert Repo.get!(ForgeMirrors.MirrorWebhookDelivery, deferred.id).state == :pending
  end

  defp user_fixture do
    value = unique("sync-user")

    Repo.insert!(%User{
      username: value,
      email: "#{value}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp request_metadata, do: %{"request_id" => Ecto.UUID.generate()}

  defp app_installation(installation_id, account_id, permissions \\ nil) do
    %AppInstallation{
      id: installation_id,
      account_id: account_id,
      account_login: "bootstrap-source",
      account_type: :organization,
      repository_selection: :all,
      permissions:
        permissions ||
          %{
            "metadata" => "read",
            "contents" => "write",
            "issues" => "write",
            "pull_requests" => "write",
            "administration" => "write"
          },
      state: :active
    }
  end

  defp settings_attrs do
    %{
      "repository_selection" => "all",
      "selected_repository_ids" => [""],
      "auto_import_new" => "false",
      "auto_create_remote" => "false",
      "repository_deletion_policy" => "retain",
      "conflict_notification_policy" => "dashboard_only",
      "capabilities" => []
    }
  end

  defp unique(prefix) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{prefix}-#{suffix}"
  end
end
