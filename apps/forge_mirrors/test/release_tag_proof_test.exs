defmodule ForgeMirrors.ReleaseTagProofTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Multi
  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState
  }

  @oid String.duplicate("a", 40)
  @other_oid String.duplicate("b", 40)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{capabilities: %{"releases" => "enabled"}})

    binding = repository_mirror_fixture(organization)
    now = DateTime.utc_now(:second)

    %{organization: organization, binding: binding, now: now}
  end

  test "an owned release atomically yields to a tag child before its continuation", c do
    parent = release_operation(c, "previous-name") |> claim!(c.now)

    assert {:error, :invalid_transition} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_observation(
               parent,
               %{
                 github_object_id: 77_001,
                 tag_name: "v1.0.0",
                 remote_updated_at: c.now
               },
               c.now
             )

    parent = claim_specific!(yielded, c.now, "canonical-release")

    assert {:ok, %{operation: completed, tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    assert completed.id == parent.id
    assert completed.state == :completed
    assert tag.id < continuation.id
    assert tag.kind == "sync.git_ref"
    assert tag.cursor["ref_name"] == "refs/tags/v1.0.0"
    assert tag.cursor["release_parent_operation_id"] == parent.id
    assert continuation.kind == "sync.release"
    assert continuation.cursor["tag_proof_operation_id"] == tag.id
    assert continuation.cursor["tag_proof_parent_operation_id"] == parent.id

    tag =
      tag
      |> Ecto.Changeset.change(checkpoint: %{"lfs_scan" => "complete"})
      |> Repo.update!()

    assert {:ok, [claimed_tag]} =
             ForgeMirrors.claim_operations("release-tag", c.now, 60, 1, [
               "sync.git_ref",
               "sync.release"
             ])

    assert claimed_tag.id == tag.id
    assert {:ok, []} = ForgeMirrors.claim_operations("blocked-continuation", c.now, 60, 1)

    assert {:ok, %{operation: completed_tag}} =
             ForgeMirrors.confirm_git_ref(
               claimed_tag,
               "refs/tags/v1.0.0",
               @oid,
               @oid,
               c.now
             )

    assert completed_tag.checkpoint["release_tag_proof"] == %{
             "release_parent_operation_id" => parent.id,
             "ref_name" => "refs/tags/v1.0.0",
             "ref_state_lock_version" => 1,
             "state" => "confirmed",
             "confirmed_oid" => @oid,
             "local_oid" => @oid,
             "remote_oid" => @oid,
             "confirmed_at" => DateTime.to_iso8601(c.now)
           }

    assert completed_tag.checkpoint["lfs_scan"] == "complete"

    assert {:ok, [claimed_continuation]} =
             ForgeMirrors.claim_operations("release-continuation", c.now, 60, 1, [
               "sync.release"
             ])

    assert claimed_continuation.id == continuation.id

    assert {:ok, context} = ForgeMirrors.release_operation_context(claimed_continuation)

    assert context.tag_proof == %{
             tag_name: "v1.0.0",
             ref_name: "refs/tags/v1.0.0",
             confirmed_oid: @oid,
             local_oid: @oid,
             remote_oid: @oid,
             confirmed_at: c.now,
             ref_state_lock_version: context.tag_proof.ref_state_lock_version,
             repository_id: c.binding.repository_id
           }

    assert context.tag_proof.ref_state_lock_version > 0
  end

  test "the atomic split is recoverably idempotent and rejects a forged tag", c do
    parent = release_operation(c, "v1.0.0") |> claim!(c.now)

    assert {:ok, first} = ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)
    assert {:ok, replay} = ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    assert replay.operation.id == first.operation.id
    assert replay.tag_operation.id == first.tag_operation.id
    assert replay.continuation.id == first.continuation.id

    assert Repo.aggregate(
             from(operation in MirrorOperation,
               where:
                 operation.cursor["tag_proof_parent_operation_id"] == ^parent.id or
                   operation.cursor["release_parent_operation_id"] == ^parent.id
             ),
             :count
           ) == 2

    assert {:error, :invalid_transition} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v2.0.0", c.now)
  end

  test "historical, missing, and retargeted tag state cannot satisfy release proof", c do
    historical = ref_state(c, "v1.0.0", @oid, DateTime.add(c.now, -60))
    parent = release_operation(c, "v1.0.0") |> claim!(c.now)

    assert {:ok, %{tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    tag = claim_specific!(tag, c.now, "historical-tag")

    assert {:ok, %{operation: _}} =
             ForgeMirrors.confirm_git_ref(
               tag,
               "refs/tags/v1.0.0",
               @oid,
               @oid,
               c.now
             )

    continuation = claim_specific!(continuation, c.now, "historical-continuation")
    assert {:ok, %{tag_proof: proof}} = ForgeMirrors.release_operation_context(continuation)
    assert proof.ref_state_lock_version > historical.lock_version

    Repo.get!(MirrorRefState, historical.id)
    |> MirrorRefState.persistence_changeset(%{
      confirmed_oid: @other_oid,
      last_local_oid: @other_oid,
      last_remote_oid: @other_oid,
      last_confirmed_at: c.now,
      lock_version: proof.ref_state_lock_version + 1
    })
    |> Repo.update!()

    assert {:error, :tag_retarget} = ForgeMirrors.release_operation_context(continuation)

    Repo.get!(MirrorRefState, historical.id)
    |> MirrorRefState.persistence_changeset(%{
      state: :deleted,
      confirmed_oid: nil,
      last_local_oid: nil,
      last_remote_oid: nil,
      last_confirmed_at: DateTime.add(c.now, 2),
      lock_version: proof.ref_state_lock_version + 2
    })
    |> Repo.update!()

    assert {:error, :release_tag_missing} = ForgeMirrors.release_operation_context(continuation)
  end

  test "a tag that changed from the pre-proof confirmed OID is a retarget conflict", c do
    ref_state(c, "v1.0.0", @oid, DateTime.add(c.now, -60))
    parent = release_operation(c, "v1.0.0") |> claim!(c.now)

    assert {:ok, %{tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    tag = claim_specific!(tag, c.now, "retarget-tag")

    assert {:ok, %{operation: _}} =
             ForgeMirrors.confirm_git_ref(
               tag,
               "refs/tags/v1.0.0",
               @other_oid,
               @other_oid,
               c.now
             )

    continuation = claim_specific!(continuation, c.now, "retarget-release")
    assert {:error, :tag_retarget} = ForgeMirrors.release_operation_context(continuation)
  end

  test "a completed proof child with an absent tag reports release_tag_missing", c do
    parent = release_operation(c, "v1.0.0") |> claim!(c.now)

    assert {:ok, %{tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    tag = claim_specific!(tag, c.now, "missing-tag")

    assert {:ok, %{operation: _}} =
             ForgeMirrors.confirm_git_ref(tag, "refs/tags/v1.0.0", nil, nil, c.now)

    continuation = claim_specific!(continuation, c.now, "missing-release")
    assert {:error, :release_tag_missing} = ForgeMirrors.release_operation_context(continuation)
  end

  test "a normally failed proof child reports release_tag_missing", c do
    parent = release_operation(c, "v1.0.0") |> claim!(c.now)

    assert {:ok, %{tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    tag = claim_specific!(tag, c.now, "failed-tag")

    assert {:ok, failed} =
             ForgeMirrors.fail_operation(tag, c.now, "provider_validation", "tag missing")

    assert failed.state == :failed
    continuation = claim_specific!(continuation, c.now, "failed-release")
    assert {:error, :release_tag_missing} = ForgeMirrors.release_operation_context(continuation)
  end

  test "release confirmation persists its mapping and domain transition atomically", c do
    local_id = System.unique_integer([:positive, :monotonic])
    parent = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)

    assert {:ok, %{tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    tag = claim_specific!(tag, c.now, "confirm-tag")

    assert {:ok, %{operation: _}} =
             ForgeMirrors.confirm_git_ref(tag, "refs/tags/v1.0.0", @oid, @oid, c.now)

    continuation = claim_specific!(continuation, c.now, "confirm-release")
    assert {:ok, expected} = ForgeMirrors.release_operation_context(continuation)

    fields = fields("v1.0.0")

    confirmation = %{
      github_object_id: 77_001,
      github_node_id: "RE_77001",
      confirmed_local_version: 1,
      remote_updated_at: c.now,
      state: :confirmed,
      confirmed_snapshot: fields,
      tag_proof: expected.tag_proof
    }

    projection = %{
      repository_id: c.binding.repository_id,
      resource_kind: :release,
      local_resource_type: "ForgeReleases.Release",
      local_resource_id: local_id,
      local_version: 1,
      deleted: false,
      fields: fields
    }

    callback = fn multi -> Multi.run(multi, :resource, fn _repo, _ -> {:ok, projection} end) end

    assert {:ok, %{operation: completed, resource_state: mapping}} =
             ForgeMirrors.confirm_release_operation(
               continuation,
               c.now,
               expected,
               confirmation,
               callback
             )

    assert completed.state == :completed
    assert mapping.resource_kind == :release
    assert mapping.local_resource_type == "ForgeReleases.Release"
    assert mapping.local_resource_id == local_id
    assert mapping.github_object_id == 77_001
    assert mapping.github_number == nil
    assert mapping.provider_identity == nil

    assert mapping.confirmed_snapshot ==
             %{fields | "published_at" => DateTime.to_iso8601(fields["published_at"])}

    assert Repo.aggregate(
             from(state in MirrorResourceState, where: state.resource_kind == :release),
             :count
           ) == 1
  end

  test "effect recovery confirms the applied baseline while preserving a newer local release",
       c do
    fields = fields("v1.0.0")
    newer_fields = Map.put(fields, "name", "Newer local release")
    local_id = release_row(c, newer_fields, 2)
    parent = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)

    assert {:ok, %{tag_operation: tag, continuation: continuation}} =
             ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

    tag = claim_specific!(tag, c.now, "recover-newer-tag")

    assert {:ok, %{operation: _}} =
             ForgeMirrors.confirm_git_ref(tag, "refs/tags/v1.0.0", @oid, @oid, c.now)

    continuation = claim_specific!(continuation, c.now, "recover-newer-release")
    assert {:ok, expected} = ForgeMirrors.release_operation_context(continuation)
    assert expected.local_version == 2

    confirmation = %{
      github_object_id: 77_001,
      github_node_id: "RE_77001",
      confirmed_local_version: 1,
      remote_updated_at: c.now,
      state: :confirmed,
      confirmed_snapshot: fields,
      tag_proof: expected.tag_proof
    }

    projection = %{
      repository_id: c.binding.repository_id,
      resource_kind: :release,
      local_resource_type: "ForgeReleases.Release",
      local_resource_id: local_id,
      local_version: 2,
      deleted: false,
      fields: newer_fields
    }

    callback = fn multi -> Multi.run(multi, :resource, fn _repo, _ -> {:ok, projection} end) end

    assert {:ok, %{resource: ^projection, resource_state: mapping}} =
             ForgeMirrors.confirm_release_operation(
               continuation,
               c.now,
               expected,
               confirmation,
               callback
             )

    assert mapping.confirmed_local_version == 1
    assert mapping.confirmed_snapshot["name"] == fields["name"]

    assert %{rows: [["Newer local release", 2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "select name, sync_version from releases where id = $1",
               [local_id]
             )
  end

  test "pause, revocation, inactive installation, and inactive binding fence proof effects", c do
    for fence <- [:paused, :revoked, :installation, :repository] do
      organization =
        active_organization_mirror_fixture(%{capabilities: %{"releases" => "enabled"}})

      binding = repository_mirror_fixture(organization)
      context = %{c | organization: organization, binding: binding}
      parent = release_operation(context, "v1.0.0") |> claim_specific!(c.now, "fence-#{fence}")

      case fence do
        :paused ->
          actor = organization_owner_fixture(organization)
          assert {:ok, _paused} = ForgeMirrors.pause(actor, organization)

        :revoked ->
          organization |> Ecto.Changeset.change(state: :revoked) |> Repo.update!()

        :installation ->
          Repo.get_by!(GitHubAppInstallation,
            github_installation_id: organization.github_installation_id
          )
          |> Ecto.Changeset.change(state: :suspended)
          |> Repo.update!()

        :repository ->
          binding |> Ecto.Changeset.change(state: :revoked) |> Repo.update!()
      end

      expected_error = if fence == :paused, do: :paused, else: :invalid_transition

      assert {:error, ^expected_error} =
               ForgeMirrors.prepare_release_tag_proof(parent, "v1.0.0", c.now)

      assert Repo.get!(MirrorOperation, parent.id).state == :processing
    end
  end

  test "tag proof cannot split an ambiguous external effect or erase its marker", c do
    parent = release_operation(c, "v1.0.0") |> claim!(c.now)
    marker = %{"action" => "update_remote_release", "github_object_id" => 77_001}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(parent, c.now, marker)

    assert {:error, :invalid_transition} =
             ForgeMirrors.prepare_release_tag_proof(marked, "v1.0.0", c.now)

    persisted = Repo.get!(MirrorOperation, parent.id)
    assert persisted.state == :effect_pending
    assert persisted.external_effect_marker == marker
    assert persisted.effect_marked_at == c.now
  end

  test "remote non-delete still requires tag proof when the local release is deleted", c do
    owner = organization_owner_fixture(c.organization)

    %{rows: [[local_id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into releases (repository_id, tag_name, name, body, draft, prerelease, target_commitish, published_at, deleted_at, author_user_id, sync_version, inserted_at, updated_at) values ($1, 'v1.0.0', 'Deleted', '', false, false, 'main', $2, $2, $3, 2, $2, $2) returning id",
        [c.binding.repository_id, c.now, owner.id]
      )

    operation = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)

    assert {:ok, context} = ForgeMirrors.release_operation_context(operation)
    assert context.local_deleted
    assert context.tag_proof == :required
  end

  test "canonical immutable-ID deletion evidence permits only a deleted confirmation", c do
    local_id = System.unique_integer([:positive, :monotonic])
    operation = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)

    assert {:error, :invalid_transition} =
             ForgeMirrors.record_release_canonical_deletion(
               operation,
               %{github_object_id: 77_002, observed_at: c.now},
               c.now
             )

    assert {:error, :invalid_transition} =
             ForgeMirrors.record_release_canonical_deletion(
               operation,
               %{github_object_id: 77_001, observed_at: c.now},
               c.now
             )

    release_mapping(c, local_id)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_deletion(
               operation,
               %{github_object_id: 77_001, observed_at: c.now},
               c.now
             )

    operation = claim_specific!(yielded, c.now, "canonical-deletion")
    assert {:ok, expected} = ForgeMirrors.release_operation_context(operation)
    assert expected.tag_proof == :not_required

    fields = fields("v1.0.0")

    confirmation = %{
      github_object_id: 77_001,
      github_node_id: "RE_77001",
      confirmed_local_version: 1,
      remote_updated_at: c.now,
      state: :confirmed,
      confirmed_snapshot: fields,
      tag_proof: :not_required
    }

    callback = fn _multi ->
      flunk("non-delete confirmation must not reach the domain callback")
    end

    assert {:error, :stale_baseline} =
             ForgeMirrors.confirm_release_operation(
               operation,
               c.now,
               expected,
               confirmation,
               callback
             )

    projection = %{
      repository_id: c.binding.repository_id,
      resource_kind: :release,
      local_resource_type: "ForgeReleases.Release",
      local_resource_id: local_id,
      local_version: 1,
      deleted: true,
      fields: fields
    }

    callback = fn multi -> Multi.run(multi, :resource, fn _repo, _ -> {:ok, projection} end) end
    confirmation = %{confirmation | state: :deleted}

    assert {:ok, %{operation: completed, resource_state: mapping}} =
             ForgeMirrors.confirm_release_operation(
               operation,
               c.now,
               expected,
               confirmation,
               callback
             )

    assert completed.state == :completed
    assert mapping.github_object_id == 77_001
    assert mapping.state == :deleted
  end

  test "release confirmation cannot replace an established immutable GitHub node ID", c do
    local_id = System.unique_integer([:positive, :monotonic])
    operation = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)
    release_mapping(c, local_id)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_deletion(
               operation,
               %{github_object_id: 77_001, observed_at: c.now},
               c.now
             )

    operation = claim_specific!(yielded, c.now, "immutable-node-id")
    assert {:ok, expected} = ForgeMirrors.release_operation_context(operation)

    confirmation = %{
      github_object_id: 77_001,
      github_node_id: "RE_REPLACEMENT",
      confirmed_local_version: 1,
      remote_updated_at: c.now,
      state: :deleted,
      confirmed_snapshot: fields("v1.0.0"),
      tag_proof: :not_required
    }

    callback = fn _multi ->
      flunk("an immutable identity conflict must not reach the domain callback")
    end

    assert {:error, :stale_baseline} =
             ForgeMirrors.confirm_release_operation(
               operation,
               c.now,
               expected,
               confirmation,
               callback
             )

    assert Repo.get_by!(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :release,
             github_object_id: 77_001
           ).github_node_id == "RE_77001"
  end

  test "a later canonical release observation clears prior deletion evidence", c do
    local_id = System.unique_integer([:positive, :monotonic])
    operation = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)
    release_mapping(c, local_id)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_deletion(
               operation,
               %{github_object_id: 77_001, observed_at: c.now},
               c.now
             )

    operation = claim_specific!(yielded, c.now, "deletion-recheck")

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_observation(
               operation,
               %{
                 github_object_id: 77_001,
                 tag_name: "v2.0.0",
                 remote_updated_at: DateTime.add(c.now, 1)
               },
               c.now
             )

    refute Map.has_key?(yielded.checkpoint, "canonical_release_deletion")
    operation = claim_specific!(yielded, c.now, "canonical-after-deletion")
    assert {:ok, context} = ForgeMirrors.release_operation_context(operation)
    assert context.tag_name == "v2.0.0"
    assert context.tag_proof == :required
  end

  test "older or equal deletion evidence cannot erase newer canonical presence", c do
    local_id = System.unique_integer([:positive, :monotonic])
    operation = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)
    release_mapping(c, local_id)
    presence_at = DateTime.add(c.now, 2)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_observation(
               operation,
               %{
                 github_object_id: 77_001,
                 tag_name: "v2.0.0",
                 remote_updated_at: presence_at
               },
               c.now
             )

    for observed_at <- [DateTime.add(presence_at, -1), presence_at] do
      operation =
        claim_specific!(yielded, c.now, "stale-deletion-#{DateTime.to_unix(observed_at)}")

      assert {:error, :stale_baseline} =
               ForgeMirrors.record_release_canonical_deletion(
                 operation,
                 %{github_object_id: 77_001, observed_at: observed_at},
                 c.now
               )

      assert Repo.get!(MirrorOperation, operation.id).checkpoint == yielded.checkpoint

      operation
      |> Ecto.Changeset.change(state: :pending, lease_owner: nil, lease_expires_at: nil)
      |> Repo.update!()
    end
  end

  test "older or equal presence evidence cannot resurrect a newer canonical deletion", c do
    local_id = System.unique_integer([:positive, :monotonic])
    operation = release_operation(c, "v1.0.0", local_id) |> claim!(c.now)
    release_mapping(c, local_id)
    deletion_at = DateTime.add(c.now, 2)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_deletion(
               operation,
               %{github_object_id: 77_001, observed_at: deletion_at},
               c.now
             )

    for remote_updated_at <- [DateTime.add(deletion_at, -1), deletion_at] do
      operation =
        claim_specific!(yielded, c.now, "stale-presence-#{DateTime.to_unix(remote_updated_at)}")

      assert {:error, :stale_baseline} =
               ForgeMirrors.record_release_canonical_observation(
                 operation,
                 %{
                   github_object_id: 77_001,
                   tag_name: "v2.0.0",
                   remote_updated_at: remote_updated_at
                 },
                 c.now
               )

      assert Repo.get!(MirrorOperation, operation.id).checkpoint == yielded.checkpoint

      operation
      |> Ecto.Changeset.change(state: :pending, lease_owner: nil, lease_expires_at: nil)
      |> Repo.update!()
    end
  end

  test "equal-time canonical presence rejects conflicting tag evidence", c do
    operation = release_operation(c, "v1.0.0") |> claim!(c.now)

    assert {:ok, yielded} =
             ForgeMirrors.record_release_canonical_observation(
               operation,
               %{
                 github_object_id: 77_001,
                 tag_name: "v1.0.0",
                 remote_updated_at: c.now
               },
               c.now
             )

    operation = claim_specific!(yielded, c.now, "equal-presence-conflict")

    assert {:error, :stale_baseline} =
             ForgeMirrors.record_release_canonical_observation(
               operation,
               %{
                 github_object_id: 77_001,
                 tag_name: "v2.0.0",
                 remote_updated_at: c.now
               },
               c.now
             )

    assert Repo.get!(MirrorOperation, operation.id).checkpoint == yielded.checkpoint
  end

  defp release_operation(c, tag_name, local_id \\ System.unique_integer([:positive])) do
    {:ok, operation} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: c.organization.id,
        repository_mirror_id: c.binding.id,
        kind: "sync.release",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "release",
          "github_object_id" => 77_001,
          "local_resource_id" => local_id,
          "tag_name" => tag_name
        },
        next_attempt_at: c.now
      })

    operation
  end

  defp ref_state(c, tag_name, oid, confirmed_at) do
    %MirrorRefState{}
    |> MirrorRefState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      ref_name: "refs/tags/#{tag_name}",
      ref_kind: :tag,
      confirmed_oid: oid,
      last_local_oid: oid,
      last_remote_oid: oid,
      state: :confirmed,
      last_confirmed_at: confirmed_at
    })
    |> Repo.insert!()
  end

  defp release_mapping(c, local_id) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :release,
      local_resource_type: "ForgeReleases.Release",
      local_resource_id: local_id,
      github_object_id: 77_001,
      github_node_id: "RE_77001",
      state: :confirmed,
      lock_version: 1
    })
    |> Repo.insert!()
  end

  defp release_row(c, release_fields, sync_version) do
    actor = organization_owner_fixture(c.organization)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into releases (repository_id, tag_name, name, body, draft, prerelease, target_commitish, published_at, author_user_id, sync_version, inserted_at, updated_at) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11) returning id",
        [
          c.binding.repository_id,
          release_fields["tag_name"],
          release_fields["name"],
          release_fields["body"],
          release_fields["draft"],
          release_fields["prerelease"],
          release_fields["target_commitish"],
          release_fields["published_at"],
          actor.id,
          sync_version,
          c.now
        ]
      )

    id
  end

  defp fields(tag_name),
    do: %{
      "tag_name" => tag_name,
      "name" => "Release",
      "body" => "Body",
      "draft" => false,
      "prerelease" => false,
      "target_commitish" => "main",
      "published_at" => ~U[2026-09-14 00:00:00Z]
    }

  defp claim!(operation, now), do: claim_specific!(operation, now, "release-proof")

  defp claim_specific!(operation, now, owner) do
    assert {:ok, [claimed]} = ForgeMirrors.claim_operations(owner, now, 60, 1)
    assert claimed.id == operation.id
    claimed
  end
end
