defmodule ForgeMirrors.ResourceSyncPersistenceTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture(%{capabilities: %{"issues" => "enabled"}})
    binding = repository_mirror_fixture(organization)
    %{organization: organization, binding: binding, now: DateTime.utc_now(:second)}
  end

  test "remote identities resolve a confirmed mapping under a current lease", c do
    mapping = mapping(c)
    operation = claimed(c)
    assert {:ok, context} = ForgeMirrors.resource_operation_context(operation)
    assert context.resource_kind == :issue
    assert context.local_resource_id == mapping.local_resource_id
    assert context.github_object_id == 456
    assert context.baseline == %{"title" => "base"}
    assert context.resource_state_lock_version == mapping.lock_version
    assert context.repository_id == c.binding.repository_id
    assert context.provenance.delivery_guid == "delivery-1"
  end

  test "fingerprints sort nested object keys and reject non-JSON or oversized snapshots" do
    assert {:ok, full_body_digest} =
             ForgeMirrors.resource_fingerprint(%{"body" => String.duplicate("界", 65_536)})

    assert byte_size(full_body_digest) == 64

    assert {:ok, digest} =
             ForgeMirrors.resource_fingerprint(%{"b" => [%{"z" => 2, "a" => 1}], "a" => nil})

    assert digest ==
             Base.encode16(:crypto.hash(:sha256, ~s({"a":null,"b":[{"a":1,"z":2}]})),
               case: :lower
             )

    assert {:error, :invalid_snapshot} = ForgeMirrors.resource_fingerprint(%{atom_key: 1})

    assert {:error, :invalid_snapshot} =
             ForgeMirrors.resource_fingerprint(%{"body" => String.duplicate("x", 2_000_001)})
  end

  test "forged cursors and expired capability cannot borrow operation identity", c do
    operation = claimed(c)

    assert {:error, :lost_lease} =
             ForgeMirrors.resource_operation_context(%{operation | lock_version: 999})

    assert {:error, :invalid_transition} =
             ForgeMirrors.resource_operation_context(%{
               operation
               | cursor: %{operation.cursor | "github_object_id" => 999}
             })
  end

  test "sync operations require a bounded immutable resource identity", c do
    operation = claimed(c, %{cursor: %{"trigger" => "remote", "resource_kind" => "issue"}})
    assert {:error, :invalid_transition} = ForgeMirrors.resource_operation_context(operation)
  end

  test "conflicted mappings cannot be replayed as a confirmed common base", c do
    mapping(c) |> Ecto.Changeset.change(state: :conflicted) |> Repo.update!()
    operation = claimed(c)
    assert {:error, :resource_conflicted} = ForgeMirrors.resource_operation_context(operation)
  end

  test "disabled policy and unpublished repositories reject execution", c do
    operation = claimed(c)

    c.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "disabled"})
    |> Repo.update!()

    assert {:error, :invalid_transition} = ForgeMirrors.resource_operation_context(operation)

    c.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "enabled"})
    |> Repo.update!()

    Repo.get!(ForgeRepos.Repository, c.binding.repository_id)
    |> Ecto.Changeset.change(lifecycle: :importing)
    |> Repo.update!()

    assert {:error, :invalid_transition} = ForgeMirrors.resource_operation_context(operation)
  end

  test "remote comments require an immutable issue parent and reject pull parents", c do
    operation =
      claimed(c, %{
        kind: "sync.issue_comment",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "issue_comment",
          "github_object_id" => 789,
          "github_issue_id" => 456,
          "github_number" => 7
        }
      })

    assert {:error, :parent_mapping_missing} = ForgeMirrors.resource_operation_context(operation)
    parent = mapping(c)
    assert {:ok, %{parent_issue_id: 123}} = ForgeMirrors.resource_operation_context(operation)
    parent |> Ecto.Changeset.change(resource_kind: :pull) |> Repo.update!()
    assert {:error, :unsupported_resource} = ForgeMirrors.resource_operation_context(operation)
  end

  test "local comment tombstones expose deletion and their mapped parent number", c do
    mapping(c)

    operation =
      claimed(c, %{
        kind: "sync.issue_comment",
        cursor: %{
          "trigger" => "local",
          "issue_id" => 123,
          "comment_id" => 999,
          "sync_version" => 2,
          "event_type" => "issue_comment.deleted",
          "deleted" => true,
          "issue_kind" => "issue"
        }
      })

    assert {:ok, %{local_deleted: true, local_version: 2, parent_issue_id: 123, github_number: 7}} =
             ForgeMirrors.resource_operation_context(operation)
  end

  test "checkpoint releases a lease without changing immutable intent", c do
    operation = claimed(c)
    checkpoint = %{"recovery" => %{"page" => 2, "match" => nil}}

    assert {:ok, updated} =
             ForgeMirrors.checkpoint_resource_operation(operation, checkpoint, c.now)

    assert updated.state == :pending
    assert updated.lease_owner == nil
    assert updated.cursor == operation.cursor
    assert updated.checkpoint == checkpoint

    assert {:error, :lost_lease} =
             ForgeMirrors.checkpoint_resource_operation(operation, checkpoint, c.now)
  end

  test "effect recovery respects backoff while preserving its marker", c do
    operation = claimed(c)
    marker = %{"action" => "create_remote_issue", "correlation_id" => Ecto.UUID.generate()}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, c.now, marker)
    later = DateTime.add(c.now, 60)

    assert {:ok, yielded} =
             ForgeMirrors.checkpoint_resource_operation(
               marked,
               %{"recovery" => %{"page" => 2}},
               later,
               "network",
               c.now
             )

    assert yielded.external_effect_marker == marker
    assert yielded.state == :effect_pending
    assert {:ok, []} = ForgeMirrors.claim_operations("early", c.now, 60, 100, ["sync.issue"])

    assert {:ok, [reclaimed]} =
             ForgeMirrors.claim_operations("later", later, 60, 100, ["sync.issue"])

    assert reclaimed.id == operation.id
    assert reclaimed.external_effect_marker == marker
  end

  test "reconciliation page schedules identity hints and persists its advancing cursor", c do
    operation =
      claimed(c, %{
        kind: "reconcile.repository.issues",
        cursor: %{
          "trigger" => "reconcile",
          "resource_kind" => "issue",
          "since" => "1970-01-01T00:00:00Z",
          "page" => 1,
          "sweep_id" => Ecto.UUID.generate()
        }
      })

    assert {:ok, sync} = ForgeMirrors.resource_operation_context(operation)
    assert sync.since == ~U[1970-01-01 00:00:00Z]
    assert sync.page == 1

    observations = [
      %{github_object_id: 456, github_number: 7, github_issue_id: nil, remote_updated_at: c.now}
    ]

    assert {:ok, %{operation: yielded, operations: [child]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               operation,
               :issue,
               observations,
               2,
               c.now
             )

    assert yielded.state == :pending
    assert yielded.checkpoint["page"] == 2
    assert child.kind == "sync.issue"
    assert child.cursor["github_object_id"] == 456
    refute Map.has_key?(child.cursor, "body")

    assert {:error, :lost_lease} =
             ForgeMirrors.record_resource_reconciliation_page(
               operation,
               :issue,
               observations,
               2,
               c.now
             )

    assert {:ok, [reclaimed]} =
             ForgeMirrors.claim_operations("resume-sweep", c.now, 60, 100, [operation.kind])

    assert {:ok, %{page: 2}} = ForgeMirrors.resource_operation_context(reclaimed)

    assert {:error, :invalid_transition} =
             ForgeMirrors.record_resource_reconciliation_page(
               reclaimed,
               :issue,
               [],
               2,
               c.now
             )

    assert {:ok, %{operation: completed}} =
             ForgeMirrors.record_resource_reconciliation_page(
               reclaimed,
               :issue,
               [],
               nil,
               c.now
             )

    assert completed.state == :completed
  end

  test "a later full sweep revisits unchanged remote identities", c do
    observations = [
      %{github_object_id: 456, github_number: 7, github_issue_id: nil, remote_updated_at: c.now}
    ]

    children =
      for _ <- 1..2 do
        operation =
          claimed(c, %{
            kind: "reconcile.repository.issues",
            cursor: %{
              "trigger" => "reconcile",
              "resource_kind" => "issue",
              "since" => "1970-01-01T00:00:00Z",
              "page" => 1,
              "sweep_id" => Ecto.UUID.generate()
            }
          })

        assert {:ok, %{operations: [child]}} =
                 ForgeMirrors.record_resource_reconciliation_page(
                   operation,
                   :issue,
                   observations,
                   nil,
                   c.now
                 )

        assert {:ok, [claimed_child]} =
                 ForgeMirrors.claim_operations("child", c.now, 60, 100, ["sync.issue"])

        assert {:ok, _} = ForgeMirrors.complete_operation(claimed_child, c.now)
        child
      end

    assert Enum.map(children, & &1.id) |> Enum.uniq() |> length() == 2
  end

  test "confirmation commits domain projection and mapping baseline with operation", c do
    operation = claimed(c)
    projection = projection(c)
    callback = &Ecto.Multi.run(&1, :resource, fn _, _ -> {:ok, projection} end)

    assert {:ok, %{operation: completed, resource_state: mapping}} =
             ForgeMirrors.confirm_resource_operation(
               operation,
               c.now,
               expected(),
               confirmation(c),
               callback
             )

    assert completed.state == :completed
    assert mapping.local_resource_id == projection.local_resource_id
    assert mapping.confirmed_snapshot == %{"title" => "confirmed"}
    assert mapping.confirmed_local_version == 1
    assert mapping.github_object_id == 456
  end

  test "bad callback scope rolls back both its writes and confirmation", c do
    operation = claimed(c)

    callback = fn multi ->
      Ecto.Multi.run(multi, :resource, fn _, _ ->
        c.binding |> Ecto.Changeset.change(github_full_name: "changed/path") |> Repo.update!()
        {:ok, %{projection(c) | repository_id: c.binding.repository_id + 1}}
      end)
    end

    assert {:error, :invalid_projection} =
             ForgeMirrors.confirm_resource_operation(
               operation,
               c.now,
               expected(),
               confirmation(c),
               callback
             )

    assert Repo.get!(ForgeMirrors.RepositoryMirror, c.binding.id).github_full_name ==
             c.binding.github_full_name

    assert Repo.get!(MirrorOperation, operation.id).state == :processing
  end

  test "stale mapping versions do not run the domain callback", c do
    mapping(c)
    operation = claimed(c)
    callback = fn _ -> flunk("stale confirmation must not apply domain changes") end

    assert {:error, :stale_baseline} =
             ForgeMirrors.confirm_resource_operation(
               operation,
               c.now,
               expected(),
               confirmation(c),
               callback
             )
  end

  test "conflicts preserve complete snapshots and fail the operation atomically", c do
    mapping = mapping(c)
    operation = claimed(c)
    local = %{"body" => String.duplicate("界", 65_536)}

    assert {:ok, %{operation: failed, conflict: conflict}} =
             ForgeMirrors.conflict_resource_operation(
               operation,
               c.now,
               "concurrent_edit",
               %{"title" => "base"},
               local,
               %{"title" => "remote"}
             )

    assert failed.state == :failed
    assert conflict.local_snapshot == local
    assert Repo.get!(MirrorResourceState, mapping.id).state == :conflicted
  end

  test "conflicted external effects retain correlation evidence for explicit recovery", c do
    operation = claimed(c)
    marker = %{"action" => "create_remote_issue", "correlation_id" => Ecto.UUID.generate()}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, c.now, marker)

    assert {:ok, %{operation: failed}} =
             ForgeMirrors.conflict_resource_operation(
               marked,
               c.now,
               "ambiguous_create",
               %{},
               %{},
               %{}
             )

    assert failed.checkpoint["conflicted_effect_marker"] == marker
    assert failed.external_effect_marker == nil
  end

  test "a local-only conflict preserves its typed identity for later operations", c do
    operation =
      claimed(c, %{
        cursor: %{
          "trigger" => "local",
          "issue_id" => 123,
          "issue_kind" => "issue",
          "sync_version" => 1
        }
      })

    assert {:ok, _} =
             ForgeMirrors.conflict_resource_operation(
               operation,
               c.now,
               "missing_baseline",
               %{},
               %{},
               %{}
             )

    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: c.binding.id,
        local_resource_id: 123
      )

    assert mapping.local_resource_type == "ForgeIssues.Issue"
  end

  defp projection(c),
    do: %{
      resource_kind: :issue,
      repository_id: c.binding.repository_id,
      local_resource_id: 123,
      local_resource_type: "ForgeIssues.Issue",
      local_version: 1,
      fields: %{"title" => "confirmed"},
      label_ids: [],
      assignee_refs: []
    }

  defp expected,
    do: %{
      resource_state_lock_version: :missing,
      local_resource_id: nil,
      expected_local_version: :missing,
      github_object_id: 456,
      expected_remote_updated_at: :missing,
      effect_marker: nil
    }

  defp confirmation(c),
    do: %{
      github_object_id: 456,
      github_node_id: "I_456",
      github_number: 7,
      remote_updated_at: c.now,
      confirmed_local_version: 1,
      confirmed_snapshot: %{"title" => "confirmed"},
      state: :confirmed
    }

  defp claimed(c, attrs \\ %{}) do
    operation =
      operation_fixture(
        c.organization,
        Map.merge(
          %{
            repository_mirror_id: c.binding.id,
            kind: "sync.issue",
            cursor: %{
              "trigger" => "remote",
              "resource_kind" => "issue",
              "issue_kind" => "issue",
              "github_object_id" => 456,
              "github_number" => 7,
              "delivery_guid" => "delivery-1"
            },
            next_attempt_at: c.now
          },
          attrs
        )
      )

    {:ok, operations} =
      ForgeMirrors.claim_operations("resource-test", c.now, 60, 100, [operation.kind])

    Enum.find(operations, &(&1.id == operation.id))
  end

  defp mapping(c) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :issue,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: 123,
      github_object_id: 456,
      github_node_id: "I_456",
      github_number: 7,
      confirmed_local_version: 1,
      confirmed_remote_updated_at: c.now,
      confirmed_snapshot: %{"title" => "base"},
      state: :confirmed
    })
    |> Repo.insert!()
  end
end
