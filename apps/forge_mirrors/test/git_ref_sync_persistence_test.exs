defmodule ForgeMirrors.GitRefSyncPersistenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo

  alias ForgeMirrors.{MirrorConflict, MirrorOperation, MirrorRefState, MirrorWebhookDelivery}
  alias ForgeRepos.Repository

  @oid String.duplicate("a", 40)
  @other_oid String.duplicate("b", 40)
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)
    %{organization_mirror: organization_mirror, repository_mirror: repository_mirror}
  end

  test "authenticated webhook ref hints enqueue one idempotent repository operation", context do
    delivery = %MirrorWebhookDelivery{
      delivery_guid: Ecto.UUID.generate(),
      installation_id: context.organization_mirror.github_installation_id,
      github_repository_id: context.repository_mirror.github_repository_id
    }

    assert {:ok, {:scheduled, first}} =
             ForgeMirrors.retain_webhook_git_ref_trigger(
               delivery,
               "refs/heads/new",
               true
             )

    assert {:ok, {:scheduled, replayed}} =
             ForgeMirrors.retain_webhook_git_ref_trigger(
               delivery,
               "refs/heads/new",
               true
             )

    assert replayed.id == first.id
    assert first.kind == "sync.git_ref"
    assert first.cursor["initial_absence"]
    assert first.cursor["trigger"] == "remote"
  end

  test "baseline confirmation and operation completion commit atomically", context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    assert {:ok, %{operation: completed, ref_state: state}} =
             ForgeMirrors.confirm_git_ref(operation, "refs/heads/main", @oid, @oid, now)

    assert completed.state == :completed
    assert state.state == :confirmed
    assert state.confirmed_oid == @oid
    assert state.last_local_oid == @oid
    assert state.last_remote_oid == @oid
    assert state.last_confirmed_at == now
  end

  test "an LFS failure degrades the ref without replacing its confirmed baseline", context do
    confirmed_at = DateTime.utc_now(:second)
    failed_at = DateTime.add(confirmed_at, 60)

    first =
      operation(context, "refs/heads/main", Ecto.UUID.generate(), confirmed_at)
      |> claim!(confirmed_at)

    assert {:ok, %{ref_state: confirmed}} =
             ForgeMirrors.confirm_git_ref(
               first,
               "refs/heads/main",
               @oid,
               @oid,
               confirmed_at
             )

    second =
      operation(context, "refs/heads/main", Ecto.UUID.generate(), failed_at) |> claim!(failed_at)

    assert {:ok, %{operation: failed, ref_state: degraded}} =
             ForgeMirrors.degrade_git_ref(
               second,
               "refs/heads/main",
               @other_oid,
               @other_oid,
               failed_at,
               "lfs_integrity",
               "required LFS object failed verification"
             )

    assert failed.state == :failed
    assert failed.failure_class == "lfs_integrity"
    assert failed.failure_disposition == :degraded
    assert degraded.state == :degraded
    assert degraded.confirmed_oid == @oid
    assert degraded.last_confirmed_at == confirmed_at
    assert degraded.last_local_oid == @other_oid
    assert degraded.last_remote_oid == @other_oid
    assert Repo.get!(MirrorRefState, confirmed.id).confirmed_oid == @oid

    assert Repo.get!(ForgeMirrors.OrganizationMirror, context.organization_mirror.id).state ==
             :degraded
  end

  test "an incomplete LFS scan checkpoints and yields its lease without a fake failure",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    checkpoint = %{"lfs_scan_key" => "scan-1", "phase" => "scan"}

    assert {:ok, yielded} =
             ForgeMirrors.checkpoint_git_ref_operation(
               operation,
               "refs/heads/main",
               checkpoint,
               now
             )

    assert yielded.state == :pending
    assert yielded.checkpoint == checkpoint
    assert yielded.next_attempt_at == now
    assert is_nil(yielded.lease_owner)
    assert is_nil(yielded.lease_expires_at)
    assert is_nil(yielded.failure_class)
    assert is_nil(yielded.failure_disposition)
  end

  test "LFS recovery checkpoints preserve an ambiguous Git effect across lease release",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_local", "ref" => "refs/heads/main", "proposed_oid" => @oid}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    checkpoint = %{"scan_key" => "recovery", "phase" => "scan"}

    assert {:ok, yielded} =
             ForgeMirrors.checkpoint_git_ref_operation(marked, "refs/heads/main", checkpoint, now)

    assert yielded.state == :effect_pending
    assert yielded.external_effect_marker == marker
    assert is_nil(yielded.lease_owner)
    reclaimed = claim!(yielded, now)
    assert reclaimed.state == :effect_pending
    assert reclaimed.checkpoint == checkpoint
    assert reclaimed.external_effect_marker == marker
  end

  test "post-marker pause denies an external effect without changing its durable marker",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    authorize_ready!(context, marked, marker)

    organization = Repo.get!(ForgeMirrors.OrganizationMirror, context.organization_mirror.id)

    assert {:ok, _paused} =
             ForgeMirrors.pause(
               organization_owner_fixture(organization),
               organization
             )

    assert {:error, :paused} = ForgeMirrors.authorize_external_effect(marked, marker)
    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
  end

  test "a long-running Git LFS effect reauthorization observes a later pause", context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    marker = %{
      "action" => "apply_remote",
      "ref" => "refs/heads/main",
      "expected_oid" => nil,
      "proposed_oid" => @oid,
      "lfs_required" => true
    }

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    prepare_git_ref_authorization!(context, %{"git" => "enabled", "lfs" => "enabled"})

    assert {:ok, authorized} = ForgeMirrors.authorize_git_lfs_effect(marked, marker)
    assert authorized.id == marked.id

    organization = Repo.get!(ForgeMirrors.OrganizationMirror, context.organization_mirror.id)

    organization
    |> Ecto.Changeset.change(capabilities: %{"git" => "enabled", "lfs" => "disabled"})
    |> Repo.update!()

    assert {:error, :permission_missing} =
             ForgeMirrors.authorize_git_lfs_effect(marked, marker)

    organization =
      organization
      |> Ecto.Changeset.change(capabilities: %{"git" => "enabled", "lfs" => "enabled"})
      |> Repo.update!()

    assert {:ok, _paused} =
             ForgeMirrors.pause(
               organization_owner_fixture(organization),
               organization
             )

    assert {:error, :paused} = ForgeMirrors.authorize_git_lfs_effect(marked, marker)
  end

  test "Git LFS authorization rejects an ordinary exact Git effect marker", context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    prepare_git_ref_authorization!(context, %{"git" => "enabled", "lfs" => "enabled"})

    assert {:error, :invalid_transition} =
             ForgeMirrors.authorize_git_lfs_effect(marked, marker)
  end

  test "Git LFS authorization rejects a marker for a different ref", context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    marker = %{
      "action" => "apply_remote",
      "ref" => "refs/heads/other",
      "expected_oid" => nil,
      "proposed_oid" => @oid,
      "lfs_required" => true
    }

    operation_marker = %{marker | "ref" => "refs/heads/main"}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, operation_marker)
    prepare_git_ref_authorization!(context, %{"git" => "enabled", "lfs" => "enabled"})

    assert {:error, :invalid_transition} =
             ForgeMirrors.authorize_git_lfs_effect(marked, marker)
  end

  test "post-marker revocation denies an external effect without changing its durable marker",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    authorize_ready!(context, marked, marker)

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: context.organization_mirror.github_installation_id
      )

    installation
    |> Ecto.Changeset.change(state: :revoked)
    |> Repo.update!()

    assert {:error, :revoked} = ForgeMirrors.authorize_external_effect(marked, marker)
    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
  end

  test "post-marker permission downgrade denies an external effect without changing its marker",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    authorize_ready!(context, marked, marker)

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: context.organization_mirror.github_installation_id
      )

    installation
    |> Ecto.Changeset.change(permissions: %{"metadata" => "read"})
    |> Repo.update!()

    assert {:error, :permission_missing} = ForgeMirrors.authorize_external_effect(marked, marker)
    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
  end

  test "post-marker Git capability downgrade denies an external effect without changing its marker",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    authorize_ready!(context, marked, marker)

    Repo.get!(ForgeMirrors.OrganizationMirror, context.organization_mirror.id)
    |> Ecto.Changeset.change(capabilities: %{"git" => "disabled"})
    |> Repo.update!()

    assert {:error, :permission_missing} = ForgeMirrors.authorize_external_effect(marked, marker)
    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
  end

  test "external effect authorization rejects a mismatched marker without changing the marker",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    authorize_ready!(context, marked, marker)

    assert {:error, :invalid_transition} =
             ForgeMirrors.authorize_external_effect(
               marked,
               Map.put(marker, "proposed_oid", @other_oid)
             )

    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
  end

  test "external effect authorization rejects a stale lease without changing the marker",
       context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)
    marker = %{"action" => "apply_remote", "ref" => "refs/heads/main", "proposed_oid" => @oid}

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)
    authorize_ready!(context, marked, marker)

    Repo.update_all(
      from(operation in MirrorOperation, where: operation.id == ^marked.id),
      set: [lease_expires_at: DateTime.add(now, -1)]
    )

    assert {:error, :lost_lease} = ForgeMirrors.authorize_external_effect(marked, marker)
    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
  end

  test "effect marker replacement compares and swaps the recorded recovery intent", context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    marker = %{
      "action" => "apply_remote",
      "expected_oid" => @oid,
      "proposed_oid" => @other_oid,
      "ref" => "refs/heads/main"
    }

    replacement = %{
      "action" => "apply_local",
      "expected_oid" => @oid,
      "proposed_oid" => @other_oid,
      "ref" => "refs/heads/main"
    }

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)

    assert {:ok, replaced} =
             ForgeMirrors.replace_external_effect(marked, now, marker, replacement)

    assert replaced.state == :effect_pending
    assert replaced.external_effect_marker == replacement

    assert {:error, :invalid_transition} =
             ForgeMirrors.replace_external_effect(replaced, now, marker, %{
               replacement
               | "proposed_oid" => String.duplicate("c", 40)
             })

    assert Repo.get!(MirrorOperation, replaced.id).external_effect_marker == replacement
  end

  test "conflict persistence marks the ref and operation in one transaction and deduplicates",
       context do
    now = DateTime.utc_now(:second)
    first = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    assert {:ok, %{operation: failed, conflict: conflict, ref_state: state}} =
             ForgeMirrors.conflict_git_ref(
               first,
               "refs/heads/main",
               :git_divergence,
               @oid,
               @oid,
               @other_oid,
               now
             )

    assert failed.state == :failed
    assert failed.failure_disposition == :conflict
    assert state.state == :conflicted
    assert conflict.state == :open
    assert conflict.conflict_kind == "git_divergence"

    later = DateTime.add(now, 1)
    second = operation(context, "refs/heads/main", Ecto.UUID.generate(), later) |> claim!(later)

    assert {:ok, %{conflict: replayed}} =
             ForgeMirrors.conflict_git_ref(
               second,
               "refs/heads/main",
               :git_divergence,
               @oid,
               @oid,
               @other_oid,
               later
             )

    assert replayed.id == conflict.id

    assert Repo.aggregate(
             from(candidate in MirrorConflict,
               where:
                 candidate.repository_mirror_id == ^context.repository_mirror.id and
                   candidate.resource_identity == "refs/heads/main" and
                   candidate.state == :open
             ),
             :count
           ) == 1
  end

  test "repository reconciliation fans out bounded per-ref work before a finalizer", context do
    now = DateTime.utc_now(:second)

    {:ok, parent} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "reconcile.repository.bootstrap",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "baseline" => "seeded",
          "inventory_reconciliation_sweep" => "inventory-operation:17"
        },
        next_attempt_at: now
      })

    parent = claim!(parent, now)

    assert {:ok, %{operation: completed, ref_operations: [branch, tag], finalizer: finalizer}} =
             ForgeMirrors.fanout_git_ref_reconciliation(
               parent,
               ["refs/tags/v1.0.0", "refs/heads/main"],
               now
             )

    assert completed.state == :completed

    assert Enum.map([branch, tag], & &1.cursor["ref_name"]) == [
             "refs/heads/main",
             "refs/tags/v1.0.0"
           ]

    assert Enum.all?([branch, tag], &(&1.kind == "sync.git_ref"))

    assert Enum.all?(
             [branch, tag, finalizer],
             &(&1.cursor["inventory_reconciliation_sweep"] == "inventory-operation:17")
           )

    assert finalizer.kind == "finalize.repository.git"
    assert finalizer.id > tag.id
  end

  test "finalizer LFS checkpoints release the lease and survive reclaim", context do
    now = DateTime.utc_now(:second)

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 31}, now)
      |> claim!(now)

    checkpoint = %{"scan_key" => "lfs-reconcile:31", "after_oid" => String.duplicate("a", 64)}

    assert {:ok, yielded} = ForgeMirrors.checkpoint_git_reconciliation(finalizer, checkpoint, now)
    assert yielded.state == :pending
    assert yielded.lease_owner == nil
    assert yielded.lease_expires_at == nil
    reclaimed = claim!(yielded, now)
    assert reclaimed.kind == "finalize.repository.git"
    assert reclaimed.checkpoint == checkpoint
    assert reclaimed.cursor == finalizer.cursor
  end

  test "a finalizer yields behind later repository work and queues a replacement sweep",
       context do
    now = DateTime.utc_now(:second)
    repository_id = context.repository_mirror.repository_id

    Repo.get!(Repository, repository_id)
    |> Ecto.Changeset.change(lifecycle: :synchronizing)
    |> Repo.update!()

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 37}, now)

    {:ok, later} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "sync.git_ref",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "initial_absence" => false,
          "ref_name" => "refs/heads/later",
          "trigger" => "local"
        },
        next_attempt_at: now
      })

    finalizer = claim!(finalizer, now)

    assert {:ok,
            %{
              operation: %{state: :completed},
              replacement: %{kind: "reconcile.repository.git"},
              repository_mirror: nil
            }} = ForgeMirrors.preflight_git_ref_reconciliation(finalizer, now)

    assert Repo.get!(Repository, repository_id).lifecycle == :synchronizing

    assert {:ok, [claimed_later]} =
             ForgeMirrors.claim_operations("git-ref-test", now, 30, 1)

    assert claimed_later.id == later.id
    assert {:ok, %{state: :completed}} = ForgeMirrors.complete_operation(claimed_later, now)

    assert {:ok, [replacement]} =
             ForgeMirrors.claim_operations("git-ref-test", now, 30, 1)

    assert replacement.kind == "reconcile.repository.git"
  end

  test "an inventory Git proof does not borrow an unmarked later reconciliation", context do
    now = DateTime.utc_now(:second)
    marker = "inventory-operation:901"

    finalizer =
      finalizer_operation(
        context,
        %{
          "reconciliation_operation_id" => 901,
          "inventory_reconciliation_sweep" => marker
        },
        now
      )

    {:ok, later} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "reconcile.repository.git",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{"trigger" => "remote"},
        next_attempt_at: now
      })

    finalizer = claim!(finalizer, now)

    assert {:ok,
            %{
              operation: %{state: :completed},
              replacement: replacement,
              repository_mirror: nil
            }} = ForgeMirrors.preflight_git_ref_reconciliation(finalizer, now)

    assert replacement.id > later.id
    assert replacement.id != later.id
    assert replacement.kind == "reconcile.repository.git"
    assert replacement.cursor["inventory_reconciliation_sweep"] == marker
  end

  test "finalization rechecks for repository work queued after preflight", context do
    now = DateTime.utc_now(:second)
    repository_id = context.repository_mirror.repository_id

    Repo.get!(Repository, repository_id)
    |> Ecto.Changeset.change(lifecycle: :synchronizing)
    |> Repo.update!()

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 38}, now)
      |> claim!(now)

    assert {:ok, :continue} = ForgeMirrors.preflight_git_ref_reconciliation(finalizer, now)

    {:ok, _later} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "sync.git_ref",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "initial_absence" => false,
          "ref_name" => "refs/heads/raced",
          "trigger" => "local"
        },
        next_attempt_at: now
      })

    assert {:ok,
            %{
              operation: %{state: :completed},
              replacement: %{kind: "reconcile.repository.git"},
              repository_mirror: nil
            }} = ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert Repo.get!(Repository, repository_id).lifecycle == :synchronizing
  end

  test "repository reconciliation finalizer records a successful Git sweep", context do
    now = DateTime.utc_now(:second)

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 41}, now)
      |> claim!(now)

    assert {:ok, %{operation: completed, repository_mirror: repository_mirror}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert completed.state == :completed
    assert repository_mirror.last_synced_at == now
  end

  test "the last bootstrap Git finalizer activates permanent repository and organization bindings" do
    now = DateTime.utc_now(:second)
    organization_mirror = ready_organization_mirror_fixture()
    actor = organization_owner_fixture(organization_mirror)

    assert {:ok, bootstrapping} =
             ForgeMirrors.transition_organization_mirror(
               actor,
               organization_mirror,
               :bootstrapping
             )

    assert {:ok, catching_up} =
             ForgeMirrors.transition_organization_mirror(actor, bootstrapping, :catching_up)

    repository_id = repository_fixture(catching_up.organization_id)

    Repo.get!(Repository, repository_id)
    |> Ecto.Changeset.change(lifecycle: :synchronizing)
    |> Repo.update!()

    assert {:ok, discovered} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: catching_up.id,
               repository_id: repository_id,
               github_repository_id: System.unique_integer([:positive, :monotonic]),
               github_node_id: "R_#{System.unique_integer([:positive, :monotonic])}",
               github_full_name: "example/bootstrap-finalizer"
             })

    finalizer =
      operation(
        %{organization_mirror: catching_up, repository_mirror: discovered},
        "finalize.repository.git",
        %{"reconciliation_operation_id" => System.unique_integer([:positive])},
        Ecto.UUID.generate(),
        now
      )
      |> claim!(now)

    assert {:ok, %{operation: completed, repository_mirror: active_repository}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert completed.state == :completed
    assert active_repository.state == :active
    assert Repo.get!(Repository, repository_id).lifecycle == :ready
    assert Repo.get!(ForgeMirrors.OrganizationMirror, catching_up.id).state == :active
  end

  test "repository reconciliation finalizer fails while a Git ref conflict is open", context do
    now = DateTime.utc_now(:second)

    assert {:ok, _conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: context.organization_mirror.id,
               repository_mirror_id: context.repository_mirror.id,
               resource_kind: "git_ref",
               resource_identity: "refs/heads/main",
               conflict_kind: "git_divergence",
               baseline_snapshot: %{"oid" => @oid},
               local_snapshot: %{"oid" => @oid},
               remote_snapshot: %{"oid" => @other_oid}
             })

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 42}, now)
      |> claim!(now)

    assert {:ok, %{operation: failed, repository_mirror: nil}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert failed.state == :failed
    assert failed.failure_class == "git_divergence"
    assert failed.failure_disposition == :conflict
  end

  test "bootstrap publication remains hidden until seeded refs are confirmed", context do
    now = DateTime.utc_now(:second)
    repository_id = context.repository_mirror.repository_id

    Repo.get!(Repository, repository_id)
    |> Ecto.Changeset.change(lifecycle: :synchronizing)
    |> Repo.update!()

    ref =
      %MirrorRefState{}
      |> MirrorRefState.persistence_changeset(%{
        repository_mirror_id: context.repository_mirror.id,
        ref_name: "refs/heads/main",
        ref_kind: :branch,
        state: :pending
      })
      |> Repo.insert!()

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 123_456}, now)
      |> claim!(now)

    assert {:error, :bootstrap_refs_unconfirmed} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert Repo.get!(Repository, repository_id).lifecycle == :synchronizing

    ref
    |> MirrorRefState.persistence_changeset(%{
      state: :confirmed,
      confirmed_oid: @oid,
      last_confirmed_at: now
    })
    |> Repo.update!()

    assert {:ok, %{operation: %{state: :completed}}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert Repo.get!(Repository, repository_id).lifecycle == :ready
  end

  test "repository reconciliation finalizer preserves last sync after a degraded LFS child",
       context do
    now = DateTime.utc_now(:second)
    reconciliation_id = System.unique_integer([:positive])

    {:ok, child} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "sync.git_ref",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "initial_absence" => false,
          "reconciliation_operation_id" => reconciliation_id,
          "ref_name" => "refs/heads/main"
        },
        next_attempt_at: now
      })

    child = claim!(child, now)

    assert {:ok, %{operation: _failed_child}} =
             ForgeMirrors.degrade_git_ref(
               child,
               "refs/heads/main",
               @oid,
               @oid,
               now,
               "lfs_missing",
               "required LFS object is missing"
             )

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => reconciliation_id}, now)
      |> claim!(now)

    assert {:ok, %{operation: failed, repository_mirror: nil}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert failed.failure_class == "lfs_missing"
    assert failed.failure_disposition == :degraded

    assert Repo.get!(ForgeMirrors.RepositoryMirror, context.repository_mirror.id).last_synced_at ==
             context.repository_mirror.last_synced_at
  end

  test "finalizer preserves a non-LFS terminal child failure", context do
    now = DateTime.utc_now(:second)
    reconciliation_id = System.unique_integer([:positive])

    %MirrorRefState{}
    |> MirrorRefState.persistence_changeset(%{
      repository_mirror_id: context.repository_mirror.id,
      ref_name: "refs/heads/main",
      ref_kind: :branch,
      state: :pending
    })
    |> Repo.insert!()

    {:ok, child} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "sync.git_ref",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{
          "initial_absence" => false,
          "reconciliation_operation_id" => reconciliation_id,
          "ref_name" => "refs/heads/main"
        },
        next_attempt_at: now
      })

    child = claim!(child, now)

    assert {:ok, %{state: :failed, failure_class: "credential_revoked"}} =
             ForgeMirrors.fail_operation(
               child,
               now,
               "credential_revoked",
               "installation credential was revoked"
             )

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => reconciliation_id}, now)
      |> claim!(now)

    assert {:ok, %{operation: failed, repository_mirror: nil}} =
             ForgeMirrors.preflight_git_ref_reconciliation(finalizer, now)

    assert failed.state == :failed
    assert failed.failure_class == "credential_revoked"
    assert failed.failure_disposition == :terminal
    assert {:ok, []} = ForgeMirrors.claim_operations("git-ref-test", now, 30, 1)
  end

  test "claimed ref context resolves the immutable repository binding and confirmed absence",
       context do
    now = DateTime.utc_now(:second)
    relative_path = "git-ref-sync/#{Ecto.UUID.generate()}.git"
    repository_path = Fornacast.Storage.repository_path!(relative_path)
    File.mkdir_p!(Path.dirname(repository_path))
    assert {:ok, _path} = GitCore.init_bare(repository_path)
    on_exit(fn -> File.rm_rf!(repository_path) end)

    context.repository_mirror.repository_id
    |> then(&Repo.get!(Repository, &1))
    |> Ecto.Changeset.change(storage_path: relative_path)
    |> Repo.update!()

    {:ok, installation} =
      ForgeMirrors.get_github_app_installation(context.organization_mirror.github_installation_id)

    assert {:ok, _updated} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation.github_installation_id,
               github_account_id: installation.github_account_id,
               github_account_login: installation.github_account_login,
               account_type: installation.account_type,
               repository_selection: installation.repository_selection,
               permissions: %{"contents" => "write", "metadata" => "read"},
               state: :active,
               last_verified_at: DateTime.add(installation.last_verified_at, 1)
             })

    operation =
      operation(context, "refs/heads/new", Ecto.UUID.generate(), now)
      |> then(fn operation ->
        operation
        |> Ecto.Changeset.change(cursor: Map.put(operation.cursor, "initial_absence", true))
        |> Repo.update!()
      end)
      |> claim!(now)

    assert {:ok, sync} = ForgeMirrors.git_ref_operation_context(operation)
    assert sync.baseline == nil
    assert sync.repository_path == repository_path
    assert sync.ref_name == "refs/heads/new"
    assert sync.ref_kind == :branch
    assert sync.remote_repository != ""
    assert sync.github_installation_id == installation.github_installation_id
  end

  defp authorize_ready!(context, operation, marker) do
    prepare_git_ref_authorization!(context)

    assert {:ok, authorized} = ForgeMirrors.authorize_external_effect(operation, marker)
    assert authorized.external_effect_marker == marker
  end

  defp prepare_git_ref_authorization!(context, capabilities \\ %{"git" => "enabled"}) do
    prepare_git_ref_repository!(context)

    Repo.get!(ForgeMirrors.OrganizationMirror, context.organization_mirror.id)
    |> Ecto.Changeset.change(capabilities: capabilities)
    |> Repo.update!()

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: context.organization_mirror.github_installation_id
    )
    |> Ecto.Changeset.change(permissions: %{"contents" => "write", "metadata" => "read"})
    |> Repo.update!()
  end

  defp prepare_git_ref_repository!(context) do
    relative_path = "git-ref-external-effect/#{Ecto.UUID.generate()}.git"
    repository_path = Fornacast.Storage.repository_path!(relative_path)
    File.mkdir_p!(Path.dirname(repository_path))
    assert {:ok, _path} = GitCore.init_bare(repository_path)
    on_exit(fn -> File.rm_rf!(repository_path) end)

    context.repository_mirror.repository_id
    |> then(&Repo.get!(Repository, &1))
    |> Ecto.Changeset.change(storage_path: relative_path)
    |> Repo.update!()
  end

  defp operation(context, ref_name, dedupe_key, now) do
    operation(
      context,
      "sync.git_ref",
      %{"initial_absence" => false, "ref_name" => ref_name, "trigger" => "reconcile"},
      dedupe_key,
      now
    )
  end

  defp finalizer_operation(context, cursor, now) do
    operation(context, "finalize.repository.git", cursor, Ecto.UUID.generate(), now)
  end

  defp operation(context, kind, cursor, dedupe_key, now) do
    {:ok, operation} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: kind,
        dedupe_key: dedupe_key,
        cursor: cursor,
        next_attempt_at: now
      })

    operation
  end

  defp claim!(%MirrorOperation{id: id}, now) do
    assert {:ok, [claimed]} = ForgeMirrors.claim_operations("git-ref-test", now, 30, 1)
    assert claimed.id == id
    claimed
  end
end
