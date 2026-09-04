defmodule ForgeMirrors.InventoryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, RepositoryMirror}

  @inventory_kind "reconcile.organization_inventory"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    now = DateTime.utc_now(:second)
    organization_mirror = active_inventory_mirror(now)

    %{organization_mirror: organization_mirror, now: now}
  end

  test "claims only inventory work and requires an active installation", context do
    inventory = inventory_operation(context.organization_mirror, context.now, "kind-filtered")

    assert {:ok, [%MirrorOperation{id: id}]} =
             ForgeMirrors.claim_operations(
               "inventory-worker",
               context.now,
               30,
               10,
               [@inventory_kind]
             )

    assert id == inventory.id

    assert {:ok, completed} =
             ForgeMirrors.complete_operation(Repo.get!(MirrorOperation, id), context.now)

    assert completed.state == :completed

    ordinary =
      operation_fixture(context.organization_mirror, %{
        kind: "repository.metadata",
        dedupe_key: "ordinary-not-inventory",
        next_attempt_at: context.now
      })

    assert {:ok, []} =
             ForgeMirrors.claim_operations(
               "inventory-worker",
               context.now,
               30,
               10,
               [@inventory_kind]
             )

    assert Repo.get!(MirrorOperation, ordinary.id).state == :pending
    Repo.delete!(ordinary)

    assert {:ok, _suspended} =
             ForgeMirrors.suspend_github_app_installation(
               context.organization_mirror.github_installation_id,
               DateTime.add(context.now, 1)
             )

    blocked = inventory_operation(context.organization_mirror, context.now, "suspended")

    assert {:ok, []} =
             ForgeMirrors.claim_operations(
               "inventory-worker",
               context.now,
               30,
               10,
               [@inventory_kind]
             )

    assert Repo.get!(MirrorOperation, blocked.id).state == :pending
  end

  test "page commit upserts immutable identities and checkpoints without changing enqueue cursor",
       context do
    operation = inventory_operation(context.organization_mirror, context.now, "checkpoint")
    claimed = claim_inventory!(operation, context.now)

    assert {:ok, inventory_context} = ForgeMirrors.inventory_operation_context(claimed)
    assert inventory_context.cursor == 1
    assert inventory_context.sweep_marker == "inventory-operation:#{operation.id}"

    assert inventory_context.github_installation_id ==
             context.organization_mirror.github_installation_id

    repository = inventory_repository(101, "R_inventory_101", "github/one")

    assert {:ok,
            %{
              operation: %MirrorOperation{state: :pending, checkpoint: %{"next_cursor" => 2}},
              classifications: %{added: [repository_mirror_id]}
            }} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [repository],
               2,
               context.now
             )

    persisted_operation = Repo.get!(MirrorOperation, operation.id)
    assert persisted_operation.cursor == %{"source" => "checkpoint"}
    assert persisted_operation.checkpoint == %{"next_cursor" => 2}

    repository_mirror = Repo.get!(RepositoryMirror, repository_mirror_id)
    assert repository_mirror.organization_mirror_id == context.organization_mirror.id
    assert repository_mirror.repository_id == nil
    assert repository_mirror.github_repository_id == 101
    assert repository_mirror.github_node_id == "R_inventory_101"
    assert repository_mirror.github_full_name == "github/one"
    refute repository_mirror.github_archived
    assert repository_mirror.inventory_included
    assert repository_mirror.inventory_selection == :all
    assert repository_mirror.last_inventory_sweep == "inventory-operation:#{operation.id}"

    assert {:ok, next_claim} =
             ForgeMirrors.claim_operations(
               "inventory-worker-next",
               context.now,
               30,
               1,
               [@inventory_kind]
             )

    assert [%MirrorOperation{id: operation_id}] = next_claim
    assert operation_id == operation.id
    assert {:ok, %{cursor: 2}} = ForgeMirrors.inventory_operation_context(hd(next_claim))

    assert {:error, :lost_lease} =
             ForgeMirrors.record_inventory_page(claimed, [repository], 2, context.now)
  end

  test "final sweep classifies rename and archive changes then revokes only unseen remote mirrors",
       context do
    seen = remote_repository_mirror(context.organization_mirror, 201, "R_seen", "github/old")
    unseen = remote_repository_mirror(context.organization_mirror, 202, "R_unseen", "github/gone")
    operation = inventory_operation(context.organization_mirror, context.now, "final-sweep")
    claimed = claim_inventory!(operation, context.now)

    assert {:ok,
            %{
              operation: %MirrorOperation{state: :completed},
              classifications: %{
                renamed: [seen_id],
                archive_changed: [seen_id],
                access_revoked: [unseen_id]
              }
            }} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [inventory_repository(201, "R_seen", "github/renamed", true)],
               nil,
               context.now
             )

    assert seen_id == seen.id
    assert unseen_id == unseen.id

    assert %RepositoryMirror{github_full_name: "github/renamed", github_archived: true} =
             Repo.get!(RepositoryMirror, seen.id)

    assert Repo.get!(RepositoryMirror, unseen.id).state == :revoked
    assert Repo.get!(MirrorOperation, operation.id).cursor == %{"source" => "final-sweep"}
  end

  test "an intermediate page never revokes unseen repositories", context do
    unseen =
      remote_repository_mirror(context.organization_mirror, 301, "R_unseen", "github/unseen")

    operation = inventory_operation(context.organization_mirror, context.now, "intermediate")
    claimed = claim_inventory!(operation, context.now)

    assert {:ok, %{operation: %MirrorOperation{state: :pending}}} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [inventory_repository(302, "R_seen", "github/seen")],
               2,
               context.now
             )

    assert Repo.get!(RepositoryMirror, unseen.id).state == :discovered
  end

  test "a visible remote-only revoked mirror recovers to discovered", context do
    mirror =
      remote_repository_mirror(context.organization_mirror, 401, "R_recovered", "github/repo")

    actor = organization_owner_fixture(context.organization_mirror)
    assert {:ok, revoked} = ForgeMirrors.transition_repository_mirror(actor, mirror, :revoked)
    assert revoked.repository_id == nil

    operation = inventory_operation(context.organization_mirror, context.now, "recover")
    claimed = claim_inventory!(operation, context.now)

    assert {:ok, %{operation: %MirrorOperation{state: :completed}}} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [inventory_repository(401, "R_recovered", "github/repo")],
               nil,
               context.now
             )

    assert Repo.get!(RepositoryMirror, mirror.id).state == :discovered
  end

  test "auto-import policy creates one durable bootstrap intent only for newly visible included repositories",
       context do
    auto_mirror =
      active_inventory_mirror(context.now,
        policy: %{
          "repository_selection" => "selected",
          "selected_repository_ids" => [501, 503],
          "auto_import_new_repositories" => true
        }
      )

    operation = inventory_operation(auto_mirror, context.now, "auto-import")
    claimed = claim_inventory!(operation, context.now)

    assert {:ok, %{operation: %MirrorOperation{state: :completed}}} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [
                 inventory_repository(501, "R_included", "github/included"),
                 inventory_repository(502, "R_excluded", "github/excluded"),
                 inventory_repository(503, "R_archived", "github/archived", true)
               ],
               nil,
               context.now
             )

    mirrors =
      RepositoryMirror
      |> where([mirror], mirror.organization_mirror_id == ^auto_mirror.id)
      |> order_by([mirror], asc: mirror.github_repository_id)
      |> Repo.all()

    assert Enum.map(mirrors, &{&1.github_repository_id, &1.inventory_included}) == [
             {501, true},
             {502, false},
             {503, true}
           ]

    assert [%MirrorOperation{} = bootstrap] =
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^auto_mirror.id and
                     operation.kind == "bootstrap.repository_import"
             )

    assert bootstrap.repository_mirror_id == hd(mirrors).id
    assert bootstrap.cursor == %{"github_repository_id" => 501, "source" => "inventory"}

    # A new sweep observing the same repository cannot duplicate the bootstrap intent.
    replay = inventory_operation(auto_mirror, context.now, "auto-import-replay")
    replay_claim = claim_inventory!(replay, context.now)

    assert {:ok, _result} =
             ForgeMirrors.record_inventory_page(
               replay_claim,
               [inventory_repository(501, "R_included", "github/included")],
               nil,
               context.now
             )

    assert Repo.aggregate(
             from(operation in MirrorOperation,
               where:
                 operation.organization_mirror_id == ^auto_mirror.id and
                   operation.kind == "bootstrap.repository_import"
             ),
             :count
           ) == 1
  end

  test "invalid inventory policy fails explicitly without partially persisting a page", context do
    invalid_policy_mirror =
      active_inventory_mirror(context.now, policy: %{"auto_import_new_repositories" => "yes"})

    operation = inventory_operation(invalid_policy_mirror, context.now, "invalid-policy")
    claimed = claim_inventory!(operation, context.now)

    assert {:error, :invalid_policy} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [inventory_repository(601, "R_invalid", "github/invalid")],
               nil,
               context.now
             )

    refute Repo.exists?(
             from mirror in RepositoryMirror,
               where: mirror.organization_mirror_id == ^invalid_policy_mirror.id
           )
  end

  test "checkpoint progression cannot skip or move backwards", context do
    operation = inventory_operation(context.organization_mirror, context.now, "unsafe-checkpoint")
    claimed = claim_inventory!(operation, context.now)

    assert {:error, :invalid_argument} =
             ForgeMirrors.record_inventory_page(
               claimed,
               [inventory_repository(701, "R_unsafe", "github/unsafe")],
               3,
               context.now
             )

    refute Repo.exists?(
             from mirror in RepositoryMirror,
               where: mirror.organization_mirror_id == ^context.organization_mirror.id
           )
  end

  test "an expired inventory capability cannot persist observations", context do
    operation = inventory_operation(context.organization_mirror, context.now, "expired-lease")
    claimed = claim_inventory!(operation, context.now)
    expired_at = DateTime.add(DateTime.utc_now(:second), -1)

    Repo.update_all(from(candidate in MirrorOperation, where: candidate.id == ^claimed.id),
      set: [lease_expires_at: expired_at]
    )

    assert {:error, :lost_lease} =
             ForgeMirrors.record_inventory_page(
               %{claimed | lease_expires_at: expired_at},
               [inventory_repository(750, "R_expired", "github/expired")],
               nil,
               context.now
             )

    refute Repo.exists?(
             from mirror in RepositoryMirror,
               where: mirror.organization_mirror_id == ^context.organization_mirror.id
           )
  end

  test "database rejects an invalid inventory selection", context do
    mirror =
      remote_repository_mirror(
        context.organization_mirror,
        801,
        "R_selection",
        "github/selection"
      )

    assert_raise Postgrex.Error, ~r/repository_mirrors_inventory_selection_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "update repository_mirrors set inventory_selection = 'unsafe' where id = $1",
        [mirror.id]
      )
    end
  end

  test "database requires operation checkpoints to remain bounded JSON objects", context do
    operation =
      inventory_operation(context.organization_mirror, context.now, "checkpoint-constraint")

    assert_raise Postgrex.Error, ~r/mirror_operations_checkpoint_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "update mirror_operations set checkpoint = '[]'::jsonb where id = $1",
        [operation.id]
      )
    end
  end

  test "inventory completion preserves unavailable LFS and release capabilities", context do
    actor = organization_owner_fixture(context.organization_mirror)

    capabilities = %{
      "git" => "active",
      "issues" => "active",
      "lfs" => "unavailable",
      "releases" => "unavailable"
    }

    assert {:ok, mirror} =
             ForgeMirrors.update_organization_mirror(
               actor,
               context.organization_mirror,
               %{capabilities: capabilities}
             )

    operation = inventory_operation(mirror, context.now, "capabilities")
    claimed = claim_inventory!(operation, context.now)

    assert {:ok, %{operation: %MirrorOperation{state: :completed}}} =
             ForgeMirrors.record_inventory_page(claimed, [], nil, context.now)

    assert {:ok, status} = ForgeMirrors.organization_status(mirror.id)
    assert status.mirror.capabilities == capabilities
  end

  defp active_inventory_mirror(now, options \\ []) do
    policy = Keyword.get(options, :policy, %{})

    mirror = active_organization_mirror_fixture(%{policy: policy})

    assert {:ok, _installation} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: mirror.github_installation_id,
               github_account_id: mirror.github_account_id,
               github_account_login: mirror.github_account_login,
               account_type: :organization,
               repository_selection: :all,
               permissions: %{"metadata" => "read"},
               state: :active,
               last_verified_at: DateTime.to_iso8601(now)
             })

    mirror
  end

  defp inventory_operation(organization_mirror, now, suffix) do
    operation_fixture(organization_mirror, %{
      kind: @inventory_kind,
      dedupe_key: "inventory-test:#{suffix}:#{organization_mirror.id}",
      cursor: %{"source" => suffix},
      next_attempt_at: now
    })
  end

  defp claim_inventory!(operation, now) do
    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "inventory-worker-#{operation.id}",
               now,
               30,
               1,
               [@inventory_kind]
             )

    assert claimed.id == operation.id
    claimed
  end

  defp remote_repository_mirror(organization_mirror, github_id, node_id, full_name) do
    actor = organization_owner_fixture(organization_mirror)

    assert {:ok, mirror} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: organization_mirror.id,
               github_repository_id: github_id,
               github_node_id: node_id,
               github_full_name: full_name
             })

    mirror
  end

  defp inventory_repository(github_id, node_id, full_name, archived \\ false) do
    %{
      github_repository_id: github_id,
      github_node_id: node_id,
      github_full_name: full_name,
      github_archived: archived
    }
  end
end
