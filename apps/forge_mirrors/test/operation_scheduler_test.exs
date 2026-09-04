defmodule ForgeMirrors.OperationSchedulerTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeMirrors.MirrorOperation

  @moduletag :persistence

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_mirror = active_organization_mirror_fixture()
    %{organization_mirror: organization_mirror, now: DateTime.utc_now(:second)}
  end

  test "enqueue is idempotent only when immutable inputs match", context do
    attrs = %{
      organization_mirror_id: context.organization_mirror.id,
      kind: "reconcile.organization_inventory",
      dedupe_key: "same-operation",
      cursor: %{"page" => 2},
      next_attempt_at: context.now
    }

    assert {:ok, first} = ForgeMirrors.enqueue_operation(attrs)
    assert {:ok, replay} = ForgeMirrors.enqueue_operation(attrs)
    assert replay.id == first.id

    assert {:error, :dedupe_conflict} =
             ForgeMirrors.enqueue_operation(%{attrs | cursor: %{"page" => 3}})

    assert Repo.aggregate(MirrorOperation, :count, :id) == 1
  end

  test "same repository serializes while different repositories progress", context do
    first_repository = repository_mirror_fixture(context.organization_mirror)
    second_repository = repository_mirror_fixture(context.organization_mirror)

    first =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: first_repository.id,
        dedupe_key: "repo-one-first",
        next_attempt_at: context.now
      })

    second =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: first_repository.id,
        dedupe_key: "repo-one-second",
        next_attempt_at: context.now
      })

    independent =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: second_repository.id,
        dedupe_key: "repo-two-first",
        next_attempt_at: context.now
      })

    assert {:ok, claimed} = ForgeMirrors.claim_operations("worker-a", context.now, 30, 10)
    assert MapSet.new(Enum.map(claimed, & &1.id)) == MapSet.new([first.id, independent.id])

    first_claim = Enum.find(claimed, &(&1.id == first.id))
    assert {:ok, _} = ForgeMirrors.complete_operation(first_claim, DateTime.add(context.now, 1))

    assert {:ok, [%MirrorOperation{id: second_id}]} =
             ForgeMirrors.claim_operations("worker-b", DateTime.add(context.now, 1), 30, 10)

    assert second_id == second.id
  end

  test "organization-scoped inventory work is head-of-line serialized", context do
    first =
      operation_fixture(context.organization_mirror, %{
        kind: "reconcile.organization_inventory",
        dedupe_key: "inventory-one",
        next_attempt_at: context.now
      })

    second =
      operation_fixture(context.organization_mirror, %{
        kind: "reconcile.organization_inventory",
        dedupe_key: "inventory-two",
        next_attempt_at: context.now
      })

    assert {:ok, [%MirrorOperation{id: first_id} = claimed]} =
             ForgeMirrors.claim_operations("inventory-a", context.now, 30, 10)

    assert first_id == first.id
    assert {:ok, []} = ForgeMirrors.claim_operations("inventory-b", context.now, 30, 10)
    assert {:ok, _} = ForgeMirrors.complete_operation(claimed, DateTime.add(context.now, 1))

    assert {:ok, [%MirrorOperation{id: second_id}]} =
             ForgeMirrors.claim_operations("inventory-b", DateTime.add(context.now, 1), 30, 10)

    assert second_id == second.id
  end

  test "expired claim is recovered and stale owner cannot complete", context do
    operation_fixture(context.organization_mirror, %{next_attempt_at: context.now})

    assert {:ok, [stale_claim]} =
             ForgeMirrors.claim_operations("crashed-worker", context.now, 5, 1)

    assert {:ok, 0} = ForgeMirrors.recover_expired_operations(DateTime.add(context.now, 4))
    assert {:ok, 1} = ForgeMirrors.recover_expired_operations(DateTime.add(context.now, 5))

    assert {:error, :lost_lease} =
             ForgeMirrors.complete_operation(stale_claim, DateTime.add(context.now, 5))

    assert {:ok, [recovered]} =
             ForgeMirrors.claim_operations("recovery-worker", DateTime.add(context.now, 5), 30, 1)

    assert recovered.id == stale_claim.id
    assert recovered.attempt_count == 2
    assert recovered.lock_version > stale_claim.lock_version
  end

  test "external-effect marker survives a crash and requires reconciliation before retry",
       context do
    operation_fixture(context.organization_mirror, %{next_attempt_at: context.now})

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("effect-worker", context.now, 5, 1)

    marked_at = DateTime.add(context.now, 1)

    assert {:ok, marked} =
             ForgeMirrors.mark_external_effect(claimed, marked_at, %{
               "request_id" => "provider-request-1"
             })

    assert marked.state == :effect_pending
    assert marked.external_effect_marker == %{"request_id" => "provider-request-1"}
    assert {:ok, 1} = ForgeMirrors.recover_expired_operations(DateTime.add(context.now, 5))

    recovered = Repo.get!(MirrorOperation, marked.id)
    assert recovered.state == :effect_pending
    assert recovered.lease_owner == nil
    assert recovered.external_effect_marker == marked.external_effect_marker

    assert {:ok, [reconciler_claim]} =
             ForgeMirrors.claim_operations(
               "effect-reconciler",
               DateTime.add(context.now, 5),
               30,
               1
             )

    assert reconciler_claim.state == :effect_pending

    assert {:error, :invalid_transition} =
             ForgeMirrors.retry_operation(
               reconciler_claim,
               DateTime.add(context.now, 6),
               DateTime.add(context.now, 20),
               "network"
             )

    assert {:ok, retried} =
             ForgeMirrors.retry_operation(
               reconciler_claim,
               DateTime.add(context.now, 6),
               DateTime.add(context.now, 20),
               "network",
               external_effect_reconciled: true
             )

    assert retried.state == :pending
    assert retried.external_effect_marker == nil
  end

  test "pause retains queued work and resume makes it claimable", context do
    repository_mirror = repository_mirror_fixture(context.organization_mirror)

    operation =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: repository_mirror.id,
        next_attempt_at: context.now
      })

    assert {:ok, paused} =
             ForgeMirrors.pause(
               organization_owner_fixture(context.organization_mirror),
               context.organization_mirror
             )

    assert {:ok, []} = ForgeMirrors.claim_operations("worker", context.now, 30, 10)
    assert Repo.get!(MirrorOperation, operation.id).state == :pending

    assert {:ok, _active} = ForgeMirrors.resume(organization_owner_fixture(paused), paused)

    assert {:ok, [%MirrorOperation{id: operation_id}]} =
             ForgeMirrors.claim_operations("worker", context.now, 30, 10)

    assert operation_id == operation.id
  end

  test "revoked organization excludes queued work", context do
    operation_fixture(context.organization_mirror, %{next_attempt_at: context.now})

    assert {:ok, revoked} =
             ForgeMirrors.transition_organization_mirror(
               organization_owner_fixture(context.organization_mirror),
               context.organization_mirror,
               :revoked
             )

    assert revoked.state == :revoked
    assert {:ok, []} = ForgeMirrors.claim_operations("worker", context.now, 30, 10)
  end

  test "revoked repository retains queued work but excludes it from claims", context do
    repository_mirror = repository_mirror_fixture(context.organization_mirror)

    operation =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: repository_mirror.id,
        next_attempt_at: context.now
      })

    assert {:ok, revoked} =
             ForgeMirrors.transition_repository_mirror(
               organization_owner_fixture(repository_mirror),
               repository_mirror,
               :revoked
             )

    assert revoked.state == :revoked
    assert {:ok, []} = ForgeMirrors.claim_operations("worker", context.now, 30, 10)
    assert Repo.get!(MirrorOperation, operation.id).state == :pending
  end

  test "reconciliation is durable, idempotent for one schedule, and reported", context do
    assert {:ok, first} =
             ForgeMirrors.schedule_reconciliation(
               organization_owner_fixture(context.organization_mirror),
               context.organization_mirror,
               context.now
             )

    assert {:ok, replay} =
             ForgeMirrors.schedule_reconciliation(
               organization_owner_fixture(context.organization_mirror),
               context.organization_mirror,
               context.now
             )

    assert replay.id == first.id

    assert {:ok, status} = ForgeMirrors.organization_status(context.organization_mirror.id)
    assert status.operation_counts == %{pending: 1}
    assert status.open_conflicts == 0
  end

  test "retry and completion reject stale versioned capabilities", context do
    operation_fixture(context.organization_mirror, %{next_attempt_at: context.now})
    assert {:ok, [claimed]} = ForgeMirrors.claim_operations("worker", context.now, 30, 1)

    assert {:ok, completed} =
             ForgeMirrors.complete_operation(claimed, DateTime.add(context.now, 1))

    assert completed.state == :completed

    assert {:error, :lost_lease} =
             ForgeMirrors.complete_operation(claimed, DateTime.add(context.now, 2))
  end

  test "an effect marker can be completed by its current owner", context do
    operation_fixture(context.organization_mirror, %{next_attempt_at: context.now})
    assert {:ok, [claimed]} = ForgeMirrors.claim_operations("worker", context.now, 30, 1)

    assert {:ok, marked} =
             ForgeMirrors.mark_external_effect(claimed, context.now, %{"id" => "one"})

    assert {:ok, completed} =
             ForgeMirrors.complete_operation(marked, DateTime.add(context.now, 1))

    assert completed.state == :completed
    assert completed.completed_at == DateTime.add(context.now, 1)
  end

  test "failure classes are explicit and bounded", context do
    operation_fixture(context.organization_mirror, %{next_attempt_at: context.now})
    assert {:ok, [claimed]} = ForgeMirrors.claim_operations("worker", context.now, 30, 1)

    assert {:error, :invalid_argument} =
             ForgeMirrors.fail_operation(claimed, context.now, "made_up_failure")

    assert {:ok, failed} =
             ForgeMirrors.fail_operation(claimed, context.now, "permission_missing")

    assert failed.state == :failed
    assert failed.failure_class == "permission_missing"
  end

  test "only the first unfinished operation is claimable", context do
    repository = repository_mirror_fixture(context.organization_mirror)

    first =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: repository.id,
        dedupe_key: "future-first",
        next_attempt_at: DateTime.add(context.now, 60)
      })

    _second =
      operation_fixture(context.organization_mirror, %{
        repository_mirror_id: repository.id,
        dedupe_key: "due-second",
        next_attempt_at: context.now
      })

    assert {:ok, []} = ForgeMirrors.claim_operations("worker", context.now, 30, 10)
    assert Repo.get!(MirrorOperation, first.id).state == :pending

    assert Repo.aggregate(
             from(operation in MirrorOperation,
               where: operation.repository_mirror_id == ^repository.id
             ),
             :count
           ) == 2
  end
end
