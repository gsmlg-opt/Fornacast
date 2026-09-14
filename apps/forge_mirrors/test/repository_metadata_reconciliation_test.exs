defmodule ForgeMirrors.RepositoryMetadataReconciliationTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeMirrors.{MirrorConflict, MirrorOperation, MirrorResourceState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    binding = repository_mirror_fixture(organization)
    now = DateTime.utc_now(:second)
    %{organization: organization, binding: binding, now: now}
  end

  test "canonical matching repository observation confirms a durable metadata baseline", c do
    assert {:ok, operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata:one",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "repository-metadata-test",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert claimed.id == operation.id
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote = %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: sync.local_snapshot["name"],
      description: sync.local_snapshot["description"],
      visibility: String.to_atom(sync.local_snapshot["visibility"]),
      default_branch: sync.local_snapshot["default_branch"],
      archived: sync.local_snapshot["archived"],
      updated_at: c.now
    }

    assert {:ok, %{operation: %MirrorOperation{state: :completed}, baseline: baseline}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert baseline.state == :confirmed
    assert baseline.confirmed_snapshot == sync.local_snapshot

    assert %MirrorResourceState{id: baseline_id, resource_kind: :repository, state: :confirmed} =
             Repo.get!(MirrorResourceState, baseline.id)

    assert baseline_id == baseline.id
  end

  test "a canonical metadata difference is retained as a conflict instead of overwriting local state",
       c do
    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata:conflict",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "repository-metadata-conflict",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote = %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: "remote-renamed",
      description: sync.local_snapshot["description"],
      visibility: String.to_atom(sync.local_snapshot["visibility"]),
      default_branch: sync.local_snapshot["default_branch"],
      archived: sync.local_snapshot["archived"],
      updated_at: c.now
    }

    assert {:ok, %{operation: %MirrorOperation{state: :failed}, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert conflict.conflict_kind == "repository_metadata_diverged"
    assert conflict.remote_snapshot["name"] == "remote-renamed"
    assert %MirrorConflict{state: :open} = Repo.get!(MirrorConflict, conflict.id)
  end

  test "changed evidence refreshes an open conflict and terminally completes the new operation",
       c do
    first = claim_metadata_operation(c, "metadata:refresh:first", "repository-metadata-first")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(first)

    assert {:ok, %{conflict: first_conflict, operation: %MirrorOperation{state: :failed}}} =
             ForgeMirrors.record_repository_metadata_observation(
               first,
               remote(sync, "remote-first", c.now),
               c.now
             )

    second = claim_metadata_operation(c, "metadata:refresh:second", "repository-metadata-second")

    assert {:ok, %{conflict: refreshed, operation: %MirrorOperation{state: :failed}}} =
             ForgeMirrors.record_repository_metadata_observation(
               second,
               remote(sync, "remote-second", DateTime.add(c.now, 1)),
               DateTime.add(c.now, 1)
             )

    assert refreshed.id == first_conflict.id
    assert refreshed.lock_version > first_conflict.lock_version
    assert refreshed.remote_snapshot["name"] == "remote-second"
    assert Repo.get!(MirrorOperation, second.id).state == :failed
  end

  defp claim_metadata_operation(c, sweep_key, owner) do
    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(c.binding, sweep_key, c.now)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(owner, c.now, 60, 1, ["reconcile.repository.metadata"])

    claimed
  end

  defp remote(sync, name, updated_at) do
    %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: name,
      description: sync.local_snapshot["description"],
      visibility: String.to_atom(sync.local_snapshot["visibility"]),
      default_branch: sync.local_snapshot["default_branch"],
      archived: sync.local_snapshot["archived"],
      updated_at: updated_at
    }
  end
end
