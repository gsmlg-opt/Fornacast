defmodule ForgeMirrors.WebhookInboxTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, MirrorWebhookDelivery, OrganizationMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "durably enqueues byte-exact deliveries and treats only identical GUID redelivery as idempotent" do
    attrs = delivery_attrs()

    assert {:ok, %MirrorWebhookDelivery{} = inserted, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(attrs, :pending)

    assert inserted.raw_payload == attrs.raw_payload
    assert inserted.state == :pending
    assert inserted.received_at
    assert inserted.next_attempt_at

    assert {:ok, duplicate, :duplicate} =
             ForgeMirrors.enqueue_webhook_delivery(attrs, :pending)

    assert duplicate.id == inserted.id

    assert {:error, :delivery_collision} =
             ForgeMirrors.enqueue_webhook_delivery(
               %{attrs | raw_payload: attrs.raw_payload <> " "},
               :pending
             )
  end

  test "raw payload bytes are redacted from delivery and changeset inspection" do
    marker = "webhook-payload-secret-marker"
    attrs = delivery_attrs(%{raw_payload: JSON.encode!(%{"marker" => marker})})

    assert {:ok, delivery, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(attrs, :ignored)

    refute inspect(delivery) =~ marker
    refute inspect(delivery) =~ "raw_payload"

    changeset =
      MirrorWebhookDelivery.persistence_changeset(%MirrorWebhookDelivery{}, %{
        raw_payload: attrs.raw_payload
      })

    refute inspect(changeset) =~ marker
    assert inspect(changeset) =~ "**redacted**"
  end

  test "deferred supported deliveries remain non-claimable and unknown combinations are terminal" do
    assert {:ok, deferred, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(
               delivery_attrs(%{delivery_guid: Ecto.UUID.generate(), event: "repository"}),
               :pending_unsupported
             )

    assert deferred.state == :pending_unsupported
    refute deferred.processed_at

    assert {:ok, ignored, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(
               delivery_attrs(%{delivery_guid: Ecto.UUID.generate(), event: "future"}),
               :ignored
             )

    assert ignored.state == :ignored
    assert ignored.processed_at

    assert {:ok, []} = ForgeMirrors.claim_webhook_deliveries("worker-a", 30, 10)
  end

  test "claims safely backfill eligible legacy resource deliveries but not paused mirrors" do
    active =
      active_organization_mirror_fixture(%{
        capabilities: %{"pulls" => "enabled", "releases" => "enabled"}
      })

    binding = repository_mirror_fixture(active)

    legacy_pull =
      enqueue_deferred!(
        pull_delivery_attrs(active.github_installation_id, binding.github_repository_id)
      )

    legacy_release =
      enqueue_deferred!(
        pull_delivery_attrs(active.github_installation_id, binding.github_repository_id, %{
          event: "release",
          action: "published"
        })
      )

    paused_source =
      active_organization_mirror_fixture(%{
        capabilities: %{"pulls" => "enabled"}
      })

    paused_binding = repository_mirror_fixture(paused_source)
    paused_actor = organization_owner_fixture(paused_source)
    assert {:ok, paused} = ForgeMirrors.pause(paused_actor, paused_source)

    paused_pull =
      enqueue_deferred!(
        pull_delivery_attrs(paused.github_installation_id, paused_binding.github_repository_id)
      )

    assert {:ok, [claimed_pull]} =
             ForgeMirrors.claim_webhook_deliveries("backfill-worker", 30, 10)

    assert claimed_pull.id == legacy_pull.id
    assert claimed_pull.organization_mirror_id == active.id

    assert {:ok, %{state: :completed}} =
             ForgeMirrors.complete_webhook_delivery(claimed_pull, "backfill-worker")

    assert {:ok, [claimed_release]} =
             ForgeMirrors.claim_webhook_deliveries("backfill-worker", 30, 10)

    assert claimed_release.id == legacy_release.id
    assert claimed_release.organization_mirror_id == active.id

    assert {:ok, %{state: :completed}} =
             ForgeMirrors.complete_webhook_delivery(claimed_release, "backfill-worker")

    assert {:ok, []} = ForgeMirrors.claim_webhook_deliveries("backfill-worker", 30, 10)

    assert Repo.get!(MirrorWebhookDelivery, paused_pull.id).state == :pending_unsupported

    processable_paused_pull =
      enqueue!(
        pull_delivery_attrs(paused.github_installation_id, paused_binding.github_repository_id)
      )

    assert {:ok, {:scheduled, paused_operation}} =
             ForgeMirrors.retain_webhook_resource_trigger(processable_paused_pull, %{
               "resource_kind" => "pull",
               "github_object_id" => pull_object_id(processable_paused_pull),
               "github_number" => pull_object_id(processable_paused_pull),
               "issue_kind" => "pull_request"
             })

    assert paused_operation.state == :pending
    assert paused_operation.organization_mirror_id == paused.id

    assert {:ok, []} =
             ForgeMirrors.claim_operations(
               "paused-pull-effects",
               DateTime.utc_now(:second),
               30,
               1,
               ["sync.pull"]
             )
  end

  test "claims one due head per installation and enforces lease-owned transitions" do
    first = enqueue!(delivery_attrs(%{delivery_guid: Ecto.UUID.generate(), installation_id: 10}))
    second = enqueue!(delivery_attrs(%{delivery_guid: Ecto.UUID.generate(), installation_id: 10}))
    other = enqueue!(delivery_attrs(%{delivery_guid: Ecto.UUID.generate(), installation_id: 11}))

    assert {:ok, claimed} = ForgeMirrors.claim_webhook_deliveries("worker-a", 30, 10, 2)
    assert Enum.map(claimed, & &1.id) |> Enum.sort() == Enum.sort([first.id, other.id])
    refute Enum.any?(claimed, &(&1.id == second.id))
    assert Enum.all?(claimed, &(&1.state == :processing and &1.attempt_count == 1))

    claimed_first = Enum.find(claimed, &(&1.id == first.id))
    assert {:error, :lost_lease} = ForgeMirrors.complete_webhook_delivery(claimed_first, "other")

    assert {:ok, completed} =
             ForgeMirrors.complete_webhook_delivery(claimed_first, "worker-a")

    assert completed.state == :completed
    assert completed.processed_at

    assert {:ok, [claimed_second]} =
             ForgeMirrors.claim_webhook_deliveries("worker-a", 30, 10)

    assert claimed_second.id == second.id

    assert {:ok, retried} =
             ForgeMirrors.retry_webhook_delivery(
               claimed_second,
               "worker-a",
               "network",
               60
             )

    assert retried.state == :pending
    assert retried.failure_class == "network"
    refute retried.lease_owner
  end

  test "concurrent claims never duplicate work and expired leases recover" do
    delivery = enqueue!(delivery_attrs(%{delivery_guid: Ecto.UUID.generate()}))
    parent = self()

    tasks =
      for owner <- ["worker-a", "worker-b"] do
        Task.async(fn ->
          receive do: (:run -> :ok)
          ForgeMirrors.claim_webhook_deliveries(owner, 30, 1)
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
      send(task.pid, :run)
    end)

    results = Enum.map(tasks, &Task.await/1)
    claimed = for {:ok, rows} <- results, row <- rows, do: row
    assert Enum.map(claimed, & &1.id) == [delivery.id]

    past = DateTime.add(DateTime.utc_now(:second), -60)

    {1, _} =
      MirrorWebhookDelivery
      |> where([row], row.id == ^delivery.id)
      |> Repo.update_all(set: [lease_expires_at: past])

    assert {:ok, 1} = ForgeMirrors.recover_expired_webhook_deliveries()
    recovered = Repo.get!(MirrorWebhookDelivery, delivery.id)
    assert recovered.state == :pending
    refute recovered.lease_owner
    assert recovered.internal_failure_count == 1

    assert {:ok, [reclaimed]} = ForgeMirrors.claim_webhook_deliveries("worker-c", 30, 1)
    assert reclaimed.id == delivery.id
    assert reclaimed.attempt_count == 2
  end

  test "expired worker leases use the separate internal-failure budget" do
    previous = Application.get_env(:forge_mirrors, :webhook_worker_max_internal_attempts, 10)
    Application.put_env(:forge_mirrors, :webhook_worker_max_internal_attempts, 1)

    on_exit(fn ->
      Application.put_env(:forge_mirrors, :webhook_worker_max_internal_attempts, previous)
    end)

    delivery = enqueue!(delivery_attrs(%{delivery_guid: Ecto.UUID.generate()}))
    assert {:ok, [claimed]} = ForgeMirrors.claim_webhook_deliveries("worker-a", 30, 1)
    assert claimed.id == delivery.id

    past = DateTime.add(DateTime.utc_now(:second), -60)

    {1, _} =
      MirrorWebhookDelivery
      |> where([row], row.id == ^delivery.id)
      |> Repo.update_all(set: [lease_expires_at: past])

    assert {:ok, 1} = ForgeMirrors.recover_expired_webhook_deliveries()
    failed = Repo.get!(MirrorWebhookDelivery, delivery.id)
    assert failed.state == :failed
    assert failed.failure_class == "worker_crash"
    assert failed.internal_failure_count == 1
    assert failed.processed_at
  end

  test "retains inventory webhook triggers only after the installation is bound" do
    guid = Ecto.UUID.generate()
    installation_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, :deferred} =
             ForgeMirrors.retain_webhook_inventory_trigger(installation_id, guid)

    mirror = organization_mirror_fixture(%{github_installation_id: installation_id})

    assert {:ok, {:scheduled, operation}} =
             ForgeMirrors.retain_webhook_inventory_trigger(installation_id, guid)

    assert operation.organization_mirror_id == mirror.id
    assert operation.kind == "reconcile.organization_inventory"
    assert operation.cursor == %{"delivery_guid" => guid}

    assert {:ok, {:scheduled, replay}} =
             ForgeMirrors.retain_webhook_inventory_trigger(installation_id, guid)

    assert replay.id == operation.id
    assert Repo.get!(ForgeMirrors.OrganizationMirror, mirror.id).last_webhook_at
  end

  test "installation revocation durably revokes a bound organization idempotently" do
    installation_id = System.unique_integer([:positive, :monotonic])
    mirror = active_organization_mirror_fixture(%{github_installation_id: installation_id})

    assert {:ok, revoked} =
             ForgeMirrors.revoke_bound_organization_from_webhook(installation_id)

    assert revoked.id == mirror.id
    assert revoked.state == :revoked
    assert revoked.last_webhook_at

    assert {:ok, replay} =
             ForgeMirrors.revoke_bound_organization_from_webhook(installation_id)

    assert replay.id == revoked.id
    assert replay.lock_version == revoked.lock_version

    assert {:ok, :unbound} =
             ForgeMirrors.revoke_bound_organization_from_webhook(installation_id + 1)
  end

  test "organization webhook health is bounded and exposes delivery gaps without payloads" do
    mirror =
      active_organization_mirror_fixture()
      |> Ecto.Changeset.change(last_reconciled_at: DateTime.add(DateTime.utc_now(:second), -120))
      |> Repo.update!()

    owner = organization_owner_fixture(mirror)

    github_repository_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, binding} =
             ForgeMirrors.bind_repository(owner, %{
               organization_mirror_id: mirror.id,
               github_repository_id: github_repository_id,
               github_node_id: "R_health_#{github_repository_id}",
               github_full_name: "health/repository-#{github_repository_id}"
             })

    pending =
      enqueue!(
        delivery_attrs(%{
          organization_mirror_id: mirror.id,
          installation_id: mirror.github_installation_id,
          received_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
        })
      )

    failed =
      enqueue!(
        delivery_attrs(%{
          delivery_guid: Ecto.UUID.generate(),
          organization_mirror_id: mirror.id,
          installation_id: mirror.github_installation_id
        })
      )

    assert {:ok, [claimed]} = ForgeMirrors.claim_webhook_deliveries("health-worker", 30, 10)
    assert claimed.id == pending.id or claimed.id == failed.id

    assert {:ok, _failed} =
             ForgeMirrors.fail_webhook_delivery(
               claimed,
               "health-worker",
               "invalid_webhook_payload"
             )

    assert {:ok, health} = ForgeMirrors.webhook_health(owner, mirror.organization_id)
    assert health.state_counts.pending + health.state_counts.failed == 2
    assert health.gap?
    assert health.unreconciled_failed_count == 1
    assert health.oldest_unprocessed_at
    assert health.latest_failure.failure_class == "invalid_webhook_payload"
    refute Map.has_key?(health, :raw_payload)

    reconciled_at = DateTime.add(DateTime.utc_now(:second), 5)

    inventory =
      operation_fixture(mirror, %{
        kind: "reconcile.organization_inventory",
        dedupe_key: Ecto.UUID.generate(),
        next_attempt_at: reconciled_at
      })

    marker = "inventory-operation:#{inventory.id}"

    inventory
    |> Ecto.Changeset.change(
      state: :completed,
      checkpoint: %{"completed_sweep" => marker},
      completed_at: reconciled_at
    )
    |> Repo.update!()

    child =
      operation_fixture(mirror, %{
        repository_mirror_id: binding.id,
        kind: "reconcile.repository.metadata",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{"inventory_reconciliation_sweep" => marker},
        next_attempt_at: reconciled_at
      })

    finalizer =
      operation_fixture(mirror, %{
        kind: "finalize.organization.reconciliation",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "version" => 1,
          "inventory_operation_id" => inventory.id,
          "inventory_reconciliation_sweep" => marker,
          "observed_at" => DateTime.to_iso8601(reconciled_at)
        },
        next_attempt_at: reconciled_at
      })

    assert {:ok, [claimed_finalizer]} =
             ForgeMirrors.claim_operations(
               "webhook-gap-finalizer",
               reconciled_at,
               30,
               1,
               ["finalize.organization.reconciliation"]
             )

    assert claimed_finalizer.id == finalizer.id

    assert {:ok, %{status: :waiting}} =
             ForgeMirrors.finalize_organization_reconciliation(
               claimed_finalizer,
               reconciled_at
             )

    assert {:ok, still_unrepaired} = ForgeMirrors.webhook_health(owner, mirror.organization_id)
    assert still_unrepaired.gap?

    child
    |> Ecto.Changeset.change(state: :completed, completed_at: reconciled_at)
    |> Repo.update!()

    retry_at = DateTime.add(reconciled_at, 5)

    assert {:ok, [reclaimed_finalizer]} =
             ForgeMirrors.claim_operations(
               "webhook-gap-finalizer-retry",
               retry_at,
               30,
               1,
               ["finalize.organization.reconciliation"]
             )

    assert {:ok,
            %{
              status: :completed,
              organization_mirror: %OrganizationMirror{last_reconciled_at: ^reconciled_at},
              operation: %MirrorOperation{state: :completed}
            }} =
             ForgeMirrors.finalize_organization_reconciliation(reclaimed_finalizer, retry_at)

    assert {:ok, repaired} = ForgeMirrors.webhook_health(owner, mirror.organization_id)
    refute repaired.gap?
    assert repaired.state_counts.failed == 1
    assert repaired.unreconciled_failed_count == 0
  end

  defp enqueue!(attrs) do
    assert {:ok, delivery, :enqueued} = ForgeMirrors.enqueue_webhook_delivery(attrs, :pending)
    delivery
  end

  defp enqueue_deferred!(attrs) do
    assert {:ok, delivery, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(attrs, :pending_unsupported)

    delivery
  end

  defp pull_delivery_attrs(installation_id, repository_id, overrides \\ %{}) do
    pull_id = System.unique_integer([:positive, :monotonic])

    delivery_attrs(
      Map.merge(
        %{
          delivery_guid: Ecto.UUID.generate(),
          event: "pull_request",
          action: "synchronize",
          installation_id: installation_id,
          github_repository_id: repository_id,
          raw_payload:
            JSON.encode!(%{
              "action" => "synchronize",
              "installation" => %{"id" => installation_id},
              "repository" => %{"id" => repository_id},
              "pull_request" => %{"id" => pull_id, "number" => pull_id}
            })
        },
        overrides
      )
    )
  end

  defp pull_object_id(delivery) do
    delivery.raw_payload
    |> JSON.decode!()
    |> get_in(["pull_request", "id"])
  end

  defp delivery_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        delivery_guid: Ecto.UUID.generate(),
        hook_id: 9001,
        event: "installation",
        action: "created",
        installation_id: 44,
        github_repository_id: nil,
        signature_version: "sha256",
        raw_payload: ~s({"action":"created","installation":{"id":44}})
      },
      overrides
    )
  end
end
