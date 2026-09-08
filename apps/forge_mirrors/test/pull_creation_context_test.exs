defmodule ForgeMirrors.PullCreationContextTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, OrganizationMirror, RepositoryMirror}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    binding = repository_mirror_fixture(organization)
    now = DateTime.utc_now(:second)

    operation =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "sync.pull",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "pull",
          "github_object_id" => 1700,
          "github_number" => 7,
          "delivery_guid" => "discovery-delivery"
        },
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("pull-create-context", now, 120, 100, ["sync.pull"])

    %{
      organization: organization,
      binding: binding,
      operation: Enum.find(claimed, &(&1.id == operation.id)),
      now: now
    }
  end

  test "missing remote identity gets leased provider routing without inventing local identity",
       c do
    assert {:ok, context} = ForgeMirrors.remote_pull_creation_context(c.operation)
    assert context.mode == :inbound_create
    assert context.repository_id == c.binding.repository_id
    assert context.repository_mirror_id == c.binding.id
    assert context.github_repository_id == c.binding.github_repository_id
    assert context.github_repository_node_id == c.binding.github_node_id
    assert context.github_object_id == 1700
    assert context.github_number == 7
    assert context.provenance.delivery_guid == "discovery-delivery"
    assert context.metadata_permissions == %{"metadata" => "read", "pull_requests" => "write"}
    refute Map.has_key?(context, :local_resource_id)

    assert Enum.join([context.remote_owner, context.remote_repository], "/") ==
             c.binding.github_full_name

    assert Repo.get!(MirrorOperation, c.operation.id) == c.operation
  end

  test "partial canonical issue mapping and corrupt pull identity are never treated as missing",
       c do
    for attrs <- [
          %{resource_kind: :issue, github_number: 7, github_object_id: 700},
          %{resource_kind: :pull, github_number: 8, github_object_id: 1700}
        ] do
      mapping =
        Repo.insert!(
          struct!(
            MirrorResourceState,
            Map.merge(attrs, %{repository_mirror_id: c.binding.id, state: :pending})
          )
        )

      assert {:error, :identity_conflict} = ForgeMirrors.remote_pull_creation_context(c.operation)
      Repo.delete!(mapping)
    end
  end

  test "expired lease and forged scope cannot obtain routing", c do
    assert {:error, _} =
             ForgeMirrors.remote_pull_creation_context(%{
               c.operation
               | organization_mirror_id: c.organization.id + 1
             })

    assert {:error, _} =
             ForgeMirrors.remote_pull_creation_context(%{
               c.operation
               | cursor: Map.put(c.operation.cursor, "github_object_id", 1701)
             })

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} = ForgeMirrors.remote_pull_creation_context(c.operation)
  end

  test "local cursor or existing external effect cannot enter inbound discovery", c do
    for attrs <- [
          %{cursor: Map.put(c.operation.cursor, "issue_id", 10)},
          %{cursor: Map.put(c.operation.cursor, "trigger", "local")},
          %{
            state: :effect_pending,
            external_effect_marker: %{"action" => "create_remote_pull"},
            effect_marked_at: c.now
          }
        ] do
      Repo.get!(MirrorOperation, c.operation.id) |> Ecto.Changeset.change(attrs) |> Repo.update!()
      operation = Repo.get!(MirrorOperation, c.operation.id)
      assert {:error, :invalid_transition} = ForgeMirrors.remote_pull_creation_context(operation)

      Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
        set: [
          cursor: c.operation.cursor,
          state: :processing,
          external_effect_marker: nil,
          effect_marked_at: nil
        ]
      )
    end
  end

  test "paused or revoked organizations and unavailable base identity fail closed", c do
    for state <- [:paused, :revoked] do
      Repo.update_all(from(o in OrganizationMirror, where: o.id == ^c.organization.id),
        set: [state: state]
      )

      assert {:error, _} = ForgeMirrors.remote_pull_creation_context(c.operation)
    end

    Repo.update_all(from(o in OrganizationMirror, where: o.id == ^c.organization.id),
      set: [state: :active]
    )

    for attrs <- [[state: :discovered], [github_node_id: nil]] do
      Repo.update_all(from(b in RepositoryMirror, where: b.id == ^c.binding.id), set: attrs)
      assert {:error, :ineligible_pull} = ForgeMirrors.remote_pull_creation_context(c.operation)

      Repo.update_all(from(b in RepositoryMirror, where: b.id == ^c.binding.id),
        set: [state: :active, github_node_id: c.binding.github_node_id]
      )
    end
  end
end
