defmodule ForgeGitHub.WebhookProcessorTest do
  use ExUnit.Case, async: false

  alias Fornacast.Repo
  alias ForgeGitHub.{AppInstallation, Error}
  alias ForgeMirrors.{GitHubAppInstallation, MirrorWebhookDelivery}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "mutable installation notifications refetch canonical state before persisting and invalidating",
       %{
         test: test
       } do
    parent = self()
    now = ~U[2026-09-05 01:02:03.123456Z]

    canonical = %AppInstallation{
      id: 44,
      account_id: 900,
      account_login: "acme",
      account_type: :organization,
      repository_selection: :selected,
      permissions: %{"contents" => "write", "metadata" => "read"},
      state: :suspended
    }

    delivery =
      delivery("installation", "suspend", %{
        "action" => "suspend",
        "installation" => %{"id" => 44}
      })

    assert :ok =
             ForgeGitHub.WebhookProcessor.process(delivery,
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 ->
                 send(parent, {:canonical_fetch, test})
                 {:ok, canonical}
               end,
               now: fn -> now end,
               inventory_schedule: fn 44, _delivery_guid -> {:ok, :scheduled} end,
               token_invalidate: fn 44 ->
                 persisted = Repo.get_by!(GitHubAppInstallation, github_installation_id: 44)
                 send(parent, {:invalidated_after_commit, test, persisted.state})
                 :ok
               end
             )

    assert_received {:canonical_fetch, ^test}
    assert_received {:invalidated_after_commit, ^test, :suspended}

    persisted = Repo.get_by!(GitHubAppInstallation, github_installation_id: 44)
    assert persisted.github_account_id == 900
    assert persisted.github_account_login == "acme"
    assert persisted.repository_selection == :selected
    assert persisted.permissions == canonical.permissions
    assert persisted.last_verified_at == now
  end

  test "repository-selection notifications also refetch instead of trusting payload fields" do
    canonical = installation()

    payload = %{
      "action" => "added",
      "installation" => %{"id" => 44},
      "repositories_added" => [%{"id" => 999, "name" => "untrusted"}]
    }

    parent = self()

    assert :ok =
             delivery("installation_repositories", "added", payload)
             |> ForgeGitHub.WebhookProcessor.process(
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 -> {:ok, canonical} end,
               now: fn -> ~U[2026-09-05 01:02:03.123456Z] end,
               inventory_schedule: fn 44, delivery_guid ->
                 send(parent, {:inventory_retained, delivery_guid})
                 {:ok, :scheduled}
               end,
               token_invalidate: fn 44 -> :ok end
             )

    assert_received {:inventory_retained, _delivery_guid}
    persisted = Repo.get_by!(GitHubAppInstallation, github_installation_id: 44)
    assert persisted.repository_selection == :all
    assert persisted.github_account_login == "canonical"
  end

  test "installation creation confirms the durable actor-bound intent from signed sender evidence" do
    parent = self()
    now = ~U[2026-09-05 01:02:03Z]

    payload = %{
      "action" => "created",
      "installation" => %{"id" => 44},
      "sender" => %{"id" => 777}
    }

    assert :defer =
             delivery("installation", "created", payload)
             |> ForgeGitHub.WebhookProcessor.process(
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 -> {:ok, installation()} end,
               now: fn -> now end,
               installation_confirm: fn 44, 777, ^now ->
                 send(parent, :installation_intent_confirmed)
                 {:ok, :unclaimed}
               end,
               inventory_schedule: fn 44, _delivery_guid -> {:ok, :deferred} end,
               token_invalidate: fn 44 -> :ok end
             )

    assert_receive :installation_intent_confirmed
  end

  test "installation creation requires a signed sender identity" do
    payload = %{"action" => "created", "installation" => %{"id" => 44}}

    assert {:fail, "invalid_webhook_payload"} =
             delivery("installation", "created", payload)
             |> ForgeGitHub.WebhookProcessor.process(
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 -> {:ok, installation()} end,
               installation_confirm: fn _installation_id, _sender_id, _now ->
                 flunk("missing sender evidence must not confirm an intent")
               end,
               inventory_schedule: fn _installation_id, _delivery_guid ->
                 flunk("invalid installation creation must not schedule inventory")
               end,
               token_invalidate: fn _installation_id ->
                 flunk("invalid installation creation must not invalidate tokens")
               end
             )
  end

  test "processable inventory delivery remains deferred until an installation is bound" do
    canonical = installation()

    assert :defer =
             delivery("installation_repositories", "removed", %{
               "action" => "removed",
               "installation" => %{"id" => 44}
             })
             |> ForgeGitHub.WebhookProcessor.process(
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 -> {:ok, canonical} end,
               token_invalidate: fn 44 -> :ok end
             )
  end

  test "repository notifications retain a canonical inventory trigger instead of applying payload" do
    parent = self()

    payload = %{
      "action" => "renamed",
      "installation" => %{"id" => 44},
      "repository" => %{"id" => 99, "name" => "untrusted-name"}
    }

    delivery =
      delivery("repository", "renamed", payload)
      |> Map.put(:github_repository_id, 99)

    assert :ok =
             ForgeGitHub.WebhookProcessor.process(delivery,
               inventory_schedule: fn 44, delivery_guid ->
                 send(parent, {:repository_inventory_retained, delivery_guid})
                 {:ok, :scheduled}
               end
             )

    assert_received {:repository_inventory_retained, _delivery_guid}
  end

  test "immutable installation deletion persists full identity evidence before revoking tokens",
       %{
         test: test
       } do
    parent = self()

    payload = %{
      "action" => "deleted",
      "installation" => %{
        "id" => 44,
        "account" => %{"id" => 900, "login" => "acme", "type" => "Organization"},
        "repository_selection" => "all",
        "permissions" => %{"contents" => "write"},
        "suspended_at" => nil
      }
    }

    assert :ok =
             delivery("installation", "deleted", payload)
             |> ForgeGitHub.WebhookProcessor.process(
               installation_fetch: fn _config, _id -> flunk("deletion must not refetch") end,
               organization_revoke: fn 44 ->
                 persisted = Repo.get_by!(GitHubAppInstallation, github_installation_id: 44)
                 send(parent, {:organization_revoked_after_installation, test, persisted.state})
                 {:ok, :unbound}
               end,
               token_revoke: fn 44 ->
                 persisted = Repo.get_by!(GitHubAppInstallation, github_installation_id: 44)
                 send(parent, {:revoked_after_commit, test, persisted.state})
                 :ok
               end
             )

    assert_received {:organization_revoked_after_installation, ^test, :revoked}
    assert_received {:revoked_after_commit, ^test, :revoked}
  end

  test "classifies canonical fetch failures and rejects insufficient immutable evidence" do
    retry_at = DateTime.add(DateTime.utc_now(:second), 30)

    delivery =
      delivery("installation", "created", %{
        "action" => "created",
        "installation" => %{"id" => 44}
      })

    assert {:retry, "github_primary_rate_limit", delay} =
             ForgeGitHub.WebhookProcessor.process(delivery,
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 ->
                 {:error, Error.new(:primary_rate_limit, retry_at)}
               end,
               now: fn -> DateTime.add(retry_at, -30) end
             )

    assert delay in 29..31

    assert {:fail, "invalid_webhook_payload"} =
             delivery("installation", "deleted", %{
               "action" => "deleted",
               "installation" => %{"id" => 44}
             })
             |> ForgeGitHub.WebhookProcessor.process(
               token_revoke: fn _id -> flunk("invalid deletion must not revoke") end
             )
  end

  test "rejects persisted routing metadata that does not match the authenticated payload" do
    delivery =
      delivery("installation", "created", %{
        "action" => "suspend",
        "installation" => %{"id" => 44}
      })

    assert {:fail, "webhook_routing_mismatch"} =
             ForgeGitHub.WebhookProcessor.process(delivery,
               installation_fetch: fn _config, _id -> flunk("mismatch must not refetch") end
             )
  end

  test "immutable deletion evidence must match an existing installation identity" do
    observed_at = ~U[2026-09-05 00:59:00.000000Z]

    assert {:ok, _installation} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: 44,
               github_account_id: 900,
               github_account_login: "acme",
               account_type: :organization,
               repository_selection: :all,
               permissions: %{"contents" => "write"},
               state: :active,
               last_verified_at: observed_at
             })

    payload = %{
      "action" => "deleted",
      "installation" => %{
        "id" => 44,
        "account" => %{"id" => 901, "login" => "other", "type" => "Organization"},
        "repository_selection" => "all",
        "permissions" => %{"contents" => "write"},
        "suspended_at" => nil
      }
    }

    assert {:fail, "installation_state_conflict"} =
             delivery("installation", "deleted", payload)
             |> ForgeGitHub.WebhookProcessor.process(
               token_revoke: fn _id -> flunk("mismatched deletion must not revoke") end
             )

    assert Repo.get_by!(GitHubAppInstallation, github_installation_id: 44).state == :active
  end

  test "an out-of-order mutable delivery cannot regress a canonically deleted installation" do
    observed_at = ~U[2026-09-05 00:59:00Z]

    assert {:ok, _installation} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: 44,
               github_account_id: 900,
               github_account_login: "acme",
               account_type: :organization,
               repository_selection: :all,
               permissions: %{"contents" => "write"},
               state: :active,
               last_verified_at: observed_at
             })

    deletion = %{
      "action" => "deleted",
      "installation" => %{
        "id" => 44,
        "account" => %{"id" => 900, "login" => "acme", "type" => "Organization"},
        "repository_selection" => "all",
        "permissions" => %{"contents" => "write"},
        "suspended_at" => nil
      }
    }

    assert :ok =
             delivery("installation", "deleted", deletion)
             |> ForgeGitHub.WebhookProcessor.process(
               now: fn -> ~U[2026-09-05 01:00:00Z] end,
               organization_revoke: fn 44 -> {:ok, :unbound} end,
               token_revoke: fn 44 -> :ok end
             )

    stale = %{"action" => "suspend", "installation" => %{"id" => 44}}

    assert :ignore =
             delivery("installation", "suspend", stale)
             |> ForgeGitHub.WebhookProcessor.process(
               config_fetch: fn -> {:ok, :config} end,
               installation_fetch: fn :config, 44 -> {:error, Error.new(:not_found)} end,
               token_invalidate: fn _id ->
                 flunk("a missing canonical installation is not usable")
               end
             )

    assert Repo.get_by!(GitHubAppInstallation, github_installation_id: 44).state == :revoked
  end

  defp delivery(event, action, payload) do
    %MirrorWebhookDelivery{
      id: 1,
      delivery_guid: Ecto.UUID.generate(),
      hook_id: 9_001,
      event: event,
      action: action,
      installation_id: 44,
      signature_version: "sha256",
      raw_payload: JSON.encode!(payload),
      state: :processing,
      attempt_count: 1,
      received_at: ~U[2026-09-05 01:00:00Z]
    }
  end

  defp installation do
    %AppInstallation{
      id: 44,
      account_id: 900,
      account_login: "canonical",
      account_type: :organization,
      repository_selection: :all,
      permissions: %{"contents" => "write"},
      state: :active
    }
  end
end
