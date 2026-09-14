defmodule ForgeMirrors.PullHeadSweepTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    org = active_organization_mirror_fixture(%{capabilities: %{"pulls" => "enabled"}})
    binding = repository_mirror_fixture(org)
    %{org: org, binding: binding, now: DateTime.utc_now(:second)}
  end

  test "inventory-triggered head discovery is deduplicated and yields bounded pull children", c do
    for number <- 1..101 do
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.binding.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: number,
        github_object_id: 1000 + number,
        github_node_id: "PR_#{number}",
        github_number: number,
        state: :unsupported
      })
    end

    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:one",
               c.now
             )

    assert {:ok, same} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:one",
               c.now
             )

    assert same.id == sweep.id

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    assert {:ok, %{operation: remote_pending, operations: []}} =
             ForgeMirrors.record_resource_reconciliation_page(claimed, :pull, [], nil, c.now)

    assert remote_pending.state == :pending
    assert remote_pending.checkpoint == %{"phase" => "mapped", "mapping_cursor" => nil}

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    assert {:ok, %{operation: pending, operations: children}} =
             ForgeMirrors.reconcile_pull_head_page(claimed, c.now)

    assert pending.state == :pending
    assert length(children) == 100
    assert Enum.all?(children, &(&1.kind == "sync.pull" and &1.cursor["trigger"] == "reconcile"))

    assert pending.checkpoint["mapping_cursor"]["after_id"] <
             pending.checkpoint["mapping_cursor"]["through_id"]

    assert {:error, :lost_lease} = ForgeMirrors.reconcile_pull_head_page(claimed, c.now)
    assert {:ok, [next]} = ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    assert {:ok, %{operation: %{state: :completed}, operations: [_]}} =
             ForgeMirrors.reconcile_pull_head_page(next, c.now)
  end

  test "revocation after scheduling prevents discovery writes", c do
    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:revoked",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    c.org |> Ecto.Changeset.change(state: :revoked) |> Repo.update!()
    assert {:error, _} = ForgeMirrors.reconcile_pull_head_page(claimed, c.now)
    assert Repo.get!(MirrorOperation, sweep.id).state == :processing
  end

  test "a provider page discovers a pull that has no local mapping or webhook", c do
    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:omitted-webhook",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    observation = %{
      github_object_id: 8_021,
      github_number: 7,
      github_issue_id: nil,
      remote_updated_at: c.now
    }

    assert {:ok, %{operation: pending, operations: [child]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               claimed,
               :pull,
               [observation],
               nil,
               c.now
             )

    assert pending.state == :pending
    assert pending.checkpoint == %{"phase" => "mapped", "mapping_cursor" => nil}
    assert child.kind == "sync.pull"
    assert child.cursor["trigger"] == "reconcile"
    assert child.cursor["github_object_id"] == 8_021
    assert child.cursor["github_number"] == 7

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :pull,
             github_object_id: 8_021
           )
  end

  test "empty head discovery completes without adding a bootstrap requirement", c do
    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:empty",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    assert {:ok, %{phase: :remote, page: 1, mapping_cursor: nil}} =
             ForgeMirrors.pull_reconciliation_context(claimed)

    assert {:ok, %{operation: remote_pending, operations: []}} =
             ForgeMirrors.record_resource_reconciliation_page(claimed, :pull, [], nil, c.now)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    assert {:ok, %{phase: :mapped, page: 1, mapping_cursor: nil}} =
             ForgeMirrors.pull_reconciliation_context(claimed)

    assert {:ok, %{operation: %{state: :completed}, operations: []}} =
             ForgeMirrors.reconcile_pull_head_page(claimed, c.now)

    assert remote_pending.state == :pending

    assert Repo.get!(ForgeMirrors.RepositoryMirror, c.binding.id).state == :active
  end

  test "cross-repository continuation is rejected without completing the parent", c do
    other = repository_mirror_fixture(c.org)

    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:scope",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    cursor = %{
      "repository_mirror_id" => other.id,
      "resource_kind" => "pull",
      "after_id" => 1,
      "through_id" => 2
    }

    claimed =
      claimed
      |> Ecto.Changeset.change(checkpoint: %{"phase" => "mapped", "mapping_cursor" => cursor})
      |> Repo.update!()

    assert {:error, :invalid_transition} = ForgeMirrors.reconcile_pull_head_page(claimed, c.now)
    assert Repo.get!(MirrorOperation, sweep.id).state == :processing
  end

  test "expired head discovery cannot advance its checkpoint", c do
    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:expired",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("head-sweep", c.now, 60, 1, [sweep.kind])

    claimed =
      claimed
      |> Ecto.Changeset.change(lease_expires_at: DateTime.add(c.now, -1, :second))
      |> Repo.update!()

    assert {:error, :lost_lease} = ForgeMirrors.reconcile_pull_head_page(claimed, c.now)
    persisted = Repo.get!(MirrorOperation, sweep.id)
    assert persisted.state == :processing
    assert persisted.checkpoint == claimed.checkpoint
  end

  test "disabled pulls do not schedule head discovery", c do
    c.org |> Ecto.Changeset.change(capabilities: %{}) |> Repo.update!()

    assert {:ok, nil} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               c.binding,
               "inventory:disabled",
               c.now
             )

    refute Repo.get_by(MirrorOperation,
             repository_mirror_id: c.binding.id,
             kind: "reconcile.repository.pull_heads"
           )
  end
end
