defmodule ForgeMirrors.GitHubInstallationIntentTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeAccounts.{GitHubIdentity, OrganizationMember}
  alias ForgeMirrors.{GitHubAppInstallation, OrganizationMirror}
  alias Fornacast.Repo

  @now ~U[2026-09-05 02:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_id = organization_fixture()
    actor = organization_owner_fixture(organization_id)
    github_user_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, %GitHubIdentity{} = identity} =
             ForgeAccounts.observe_github_identity(
               %{id: github_user_id, login: "installer-#{github_user_id}"},
               @now
             )

    assert {:ok, %GitHubIdentity{local_user_id: actor_id}} =
             ForgeAccounts.link_github_identity(actor, identity)

    assert actor_id == actor.id

    %{actor: actor, organization_id: organization_id, github_user_id: github_user_id}
  end

  test "callback remains pending until a signed installation webhook proves the linked actor",
       context do
    digest = :crypto.hash(:sha256, "opaque-state")

    assert {:ok, %{intent: intent, mirror: %OrganizationMirror{state: :pending_installation}}} =
             ForgeMirrors.begin_github_installation(
               context.actor,
               context.organization_id,
               digest,
               @now,
               DateTime.add(@now, 600)
             )

    installation_id = 8_000_000 + System.unique_integer([:positive, :monotonic])
    observe_installation(installation_id, context.organization_id)

    assert {:ok, %{status: :pending_webhook, mirror: pending}} =
             ForgeMirrors.record_github_installation_callback(
               context.actor,
               context.organization_id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 1)
             )

    assert pending.state == :pending_installation
    assert pending.github_installation_id == nil

    assert {:ok, :unclaimed} =
             ForgeMirrors.confirm_github_installation_webhook(
               installation_id,
               context.github_user_id + 10_000,
               DateTime.add(@now, 2)
             )

    assert {:ok, %{intent: completed, mirror: ready}} =
             ForgeMirrors.confirm_github_installation_webhook(
               installation_id,
               context.github_user_id,
               DateTime.add(@now, 3)
             )

    assert completed.id == intent.id
    assert completed.state == :completed
    assert ready.state == :ready_to_bootstrap
    assert ready.github_installation_id == installation_id
    assert ready.github_account_id == context.organization_id
    assert ready.github_account_login == "github-org-#{context.organization_id}"
    assert ready.capabilities["git"] == "enabled"
    assert ready.capabilities["lfs"] == "enabled"
    assert ready.capabilities["issues"] == "enabled"
    assert ready.capabilities["pulls"] == "enabled"

    assert {:ok, settings} =
             ForgeMirrors.organization_settings(context.actor, context.organization_id)

    assert "issues:write" in settings.missing_permissions
    assert "pull_requests:write" in settings.missing_permissions
    refute settings.actions.bootstrap
  end

  test "a historical signed webhook received before callback cannot authorize the callback",
       context do
    digest = :crypto.hash(:sha256, "webhook-first-state")

    assert {:ok, %{mirror: pending}} =
             ForgeMirrors.begin_github_installation(
               context.actor,
               context.organization_id,
               digest,
               @now,
               DateTime.add(@now, 600)
             )

    installation_id = 8_000_000 + System.unique_integer([:positive, :monotonic])
    observe_installation(installation_id, context.organization_id)
    enqueue_created_delivery(installation_id, context.github_user_id)

    assert {:ok, %{status: :pending_webhook, mirror: pending_after_callback}} =
             ForgeMirrors.record_github_installation_callback(
               context.actor,
               context.organization_id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 1)
             )

    assert pending.id == pending_after_callback.id
    assert pending_after_callback.state == :pending_installation
    assert pending_after_callback.github_installation_id == nil
  end

  test "completion rechecks current local organization-management permission", context do
    digest = :crypto.hash(:sha256, "permission-recheck-state")

    assert {:ok, _result} =
             ForgeMirrors.begin_github_installation(
               context.actor,
               context.organization_id,
               digest,
               @now,
               DateTime.add(@now, 600)
             )

    installation_id = 8_000_000 + System.unique_integer([:positive, :monotonic])
    observe_installation(installation_id, context.organization_id)

    assert {:ok, %{status: :pending_webhook}} =
             ForgeMirrors.record_github_installation_callback(
               context.actor,
               context.organization_id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 1)
             )

    {1, nil} =
      Repo.update_all(
        from(member in OrganizationMember,
          where:
            member.organization_id == ^context.organization_id and
              member.user_id == ^context.actor.id
        ),
        set: [role: :member]
      )

    assert {:ok, :unclaimed} =
             ForgeMirrors.confirm_github_installation_webhook(
               installation_id,
               context.github_user_id,
               DateTime.add(@now, 2)
             )

    assert {:ok, %OrganizationMirror{state: :pending_installation}} =
             ForgeMirrors.get_organization_mirror_for_organization(
               context.organization_id,
               "github"
             )
  end

  test "state digests are actor and organization bound, one time, and expire", context do
    digest = :crypto.hash(:sha256, "single-use-state")

    assert {:ok, _result} =
             ForgeMirrors.begin_github_installation(
               context.actor,
               context.organization_id,
               digest,
               @now,
               DateTime.add(@now, 60)
             )

    installation_id = 8_000_000 + System.unique_integer([:positive, :monotonic])
    observe_installation(installation_id, context.organization_id)

    assert {:error, :expired_installation_intent} =
             ForgeMirrors.record_github_installation_callback(
               context.actor,
               context.organization_id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 61)
             )

    assert {:error, :invalid_installation_intent} =
             ForgeMirrors.record_github_installation_callback(
               context.actor,
               context.organization_id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 62)
             )
  end

  defp observe_installation(installation_id, github_account_id) do
    assert {:ok, %GitHubAppInstallation{}} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: "github-org-#{github_account_id}",
               account_type: :organization,
               repository_selection: :all,
               permissions: %{"contents" => "write", "metadata" => "read"},
               state: :active,
               last_verified_at: @now
             })
  end

  defp enqueue_created_delivery(installation_id, sender_id) do
    raw_payload =
      JSON.encode!(%{
        "action" => "created",
        "installation" => %{"id" => installation_id},
        "sender" => %{"id" => sender_id}
      })

    assert {:ok, _delivery, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(
               %{
                 delivery_guid: Ecto.UUID.generate(),
                 hook_id: 1,
                 event: "installation",
                 action: "created",
                 installation_id: installation_id,
                 github_repository_id: nil,
                 signature_version: "sha256",
                 raw_payload: raw_payload,
                 received_at: @now
               },
               :pending
             )
  end
end
