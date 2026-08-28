defmodule ForgeImports.CleanupOperationTest do
  use ExUnit.Case, async: true

  alias ForgeImports.CleanupOperation

  @now ~U[2026-08-28 12:00:00Z]

  test "exposes the durable cleanup journal contract" do
    assert CleanupOperation.__schema__(:source) == "github_import_repository_cleanups"
    assert CleanupOperation.states() == [:cleanup_pending, :cleanup_blocked, :cleanup_complete]
    assert CleanupOperation.terminal_states() == [:cleanup_blocked, :cleanup_complete]

    assert CleanupOperation.kinds() == [
             :remote_quarantine,
             :unpublished_shadow,
             :replacement_tombstone
           ]

    assert CleanupOperation.deterministic_operation_id(:remote_quarantine, 11, 22, 3) ==
             "github-import-cleanup:remote_quarantine:11:22:3"
  end

  test "creation persists only a pending immutable intent" do
    attrs = remote_attrs()
    changeset = CleanupOperation.create_changeset(%CleanupOperation{}, attrs)

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :state) == :cleanup_pending
    assert Ecto.Changeset.get_field(changeset, :attempt_count) == 0
    assert Ecto.Changeset.get_field(changeset, :lock_version) == 0

    for {field, value} <- [
          state: :cleanup_complete,
          operation_id: "forged",
          evidence: Map.put(attrs.evidence, "device", 7),
          next_attempt_at: nil
        ] do
      refute CleanupOperation.create_changeset(
               %CleanupOperation{},
               Map.put(attrs, field, value)
             ).valid?
    end
  end

  test "all three cleanup kinds require exact versioned base evidence" do
    for attrs <- [remote_attrs(), unpublished_attrs(), replacement_attrs()] do
      assert CleanupOperation.create_changeset(%CleanupOperation{}, attrs).valid?,
             "expected #{attrs.kind} evidence to be valid"

      for evidence <- [
            Map.delete(attrs.evidence, "repository_id"),
            Map.put(attrs.evidence, "unknown", true),
            Map.put(attrs.evidence, "item_lock_version", attrs.source_lock_version + 1),
            Map.put(attrs.evidence, "version", "1")
          ] do
        refute CleanupOperation.create_changeset(
                 %CleanupOperation{},
                 %{attrs | evidence: evidence}
               ).valid?
      end
    end
  end

  test "attempt fingerprints use the exact canonical external term" do
    decision = %{"action" => "create", "slug" => "demo"}

    expected =
      :crypto.hash(:sha256, :erlang.term_to_binary({22, 4, decision}))
      |> Base.encode16(case: :lower)

    assert CleanupOperation.attempt_fingerprint(22, 4, decision) == expected

    refute CleanupOperation.attempt_fingerprint(22, 4, Map.put(decision, "slug", "other")) ==
             expected
  end

  test "anchored enrichment chooses one complete immutable outcome" do
    operation =
      %CleanupOperation{}
      |> CleanupOperation.create_changeset(remote_attrs())
      |> Ecto.Changeset.apply_changes()

    started = @now

    present =
      operation.evidence
      |> Map.put("root_identity", identity(16))
      |> Map.put("anchored_identity", identity(32))

    assert CleanupOperation.lease_update_changeset(operation,
             evidence: present,
             effect_started_at: started
           ).valid?

    for evidence <- [
          Map.put(operation.evidence, "root_identity", identity(16)),
          Map.put(operation.evidence, "anchored_identity", identity(32)),
          present |> Map.put("anchored_absence", absence_marker()),
          operation.evidence
        ] do
      refute CleanupOperation.lease_update_changeset(operation,
               evidence: evidence,
               effect_started_at: started
             ).valid?
    end

    absence = Map.put(operation.evidence, "anchored_absence", absence_marker())

    refute CleanupOperation.lease_update_changeset(operation,
             evidence: absence,
             effect_started_at: started
           ).valid?

    forged = put_in(absence, ["anchored_absence", "relative_path"], "forged.git")

    refute CleanupOperation.lease_update_changeset(operation,
             evidence: forged,
             effect_started_at: started,
             effect_finished_at: DateTime.add(started, 1, :second)
           ).valid?

    enriched =
      operation
      |> CleanupOperation.lease_update_changeset(
        evidence: present,
        effect_started_at: started
      )
      |> Ecto.Changeset.apply_changes()

    refute CleanupOperation.lease_update_changeset(enriched,
             evidence: put_in(present, ["anchored_identity", "inode"], 33),
             effect_finished_at: DateTime.add(started, 1, :second)
           ).valid?
  end

  test "complete and blocked lifecycle shapes are exact" do
    operation =
      %CleanupOperation{}
      |> CleanupOperation.create_changeset(remote_attrs())
      |> Ecto.Changeset.apply_changes()

    started = @now
    finished = DateTime.add(started, 1, :second)
    completed = DateTime.add(finished, 1, :second)
    evidence = Map.merge(operation.evidence, %{"anchored_absence" => absence_marker()})

    assert CleanupOperation.lease_update_changeset(operation,
             state: :cleanup_complete,
             evidence: evidence,
             next_attempt_at: nil,
             effect_started_at: started,
             effect_finished_at: finished,
             completed_at: completed
           ).valid?

    assert CleanupOperation.lease_update_changeset(operation,
             state: :cleanup_blocked,
             next_attempt_at: nil,
             last_error: "identity_mismatch"
           ).valid?

    for last_error <- ["cleanup_timeout", "storage_unavailable"] do
      assert CleanupOperation.lease_update_changeset(operation,
               state: :cleanup_blocked,
               next_attempt_at: nil,
               last_error: last_error
             ).valid?
    end

    refute CleanupOperation.lease_update_changeset(operation,
             state: :cleanup_complete,
             next_attempt_at: nil,
             completed_at: completed
           ).valid?

    refute CleanupOperation.lease_update_changeset(operation,
             state: :cleanup_blocked,
             next_attempt_at: nil,
             last_error: "/srv/private.git token=secret"
           ).valid?

    for last_error <- [
          "cleanup failed: /srv/private.git",
          "cleanup failed (/srv/private.git)",
          "cleanup failed: \\\\private\\repo.git",
          "cleanup failed: C:\\secret"
        ] do
      refute CleanupOperation.lease_update_changeset(operation,
               state: :cleanup_blocked,
               next_attempt_at: nil,
               last_error: last_error
             ).valid?
    end

    lease_expires_at = DateTime.add(@now, 30, :second)

    assert CleanupOperation.lease_update_changeset(
             %{operation | lease_owner: "worker", lease_expires_at: lease_expires_at},
             attempt_count: 1,
             next_attempt_at: DateTime.add(@now, 5, :second)
           ).valid?

    for invalid <- [
          %{operation | lease_owner: "worker"},
          %{operation | lease_expires_at: lease_expires_at},
          %{
            operation
            | state: :cleanup_blocked,
              lease_owner: "worker",
              lease_expires_at: lease_expires_at
          },
          %{operation | effect_finished_at: @now}
        ] do
      refute CleanupOperation.lease_update_changeset(invalid, attempt_count: 1).valid?
    end
  end

  test "inspect redacts cleanup evidence and errors" do
    inspected =
      inspect(%CleanupOperation{
        evidence: %{"quarantine_path" => "secret-path"},
        last_error: "secret-error"
      })

    refute inspected =~ "secret-path"
    refute inspected =~ "secret-error"
  end

  test "creation binds the live root and exact remote absolute joins" do
    attrs = remote_attrs()
    evidence = attrs.evidence

    assert evidence["requested_path"] ==
             Path.join(evidence["storage_root"], evidence["repository_storage_path"])

    assert evidence["quarantine_path"] ==
             Path.join(evidence["storage_root"], evidence["relative_path"])

    assert evidence["quarantine_path"] ==
             GitCore.Remote.cleanup_slot_path(evidence["requested_path"])

    basename_digest =
      :sha256
      |> :crypto.hash(
        "fornacast.git-core.remote.cleanup-slot.v1\0" <>
          Path.basename(evidence["requested_path"])
      )
      |> Base.url_encode64(padding: false)

    basename_slot =
      Path.join(
        Path.dirname(evidence["requested_path"]),
        ".fornacast-cleanup-v1-" <> basename_digest
      )

    for forged <- [
          Map.put(evidence, "storage_root", "/different/live/root"),
          Map.put(evidence, "requested_path", evidence["repository_storage_path"]),
          Map.put(evidence, "quarantine_path", basename_slot),
          Map.put(evidence, "relative_path", evidence["quarantine_path"]),
          Map.put(evidence, "repository_storage_path", "/absolute/repository.git")
        ] do
      refute CleanupOperation.create_changeset(
               %CleanupOperation{},
               %{attrs | evidence: forged}
             ).valid?
    end
  end

  test "replacement cleanup reuses the exact committed publication authority" do
    attrs = replacement_attrs()
    marker = attrs.evidence["publication_marker"]
    item = %{item_id: 22, hidden_repository_id: 66}

    assert ForgeImports.RepositoryPublisher.valid_committed_evidence?(marker, item)

    corruptions = [
      put_in(marker, ["action"], "create"),
      put_in(marker, ["repository_id"], 67),
      put_in(marker, ["hidden_repository_id"], 67),
      put_in(marker, ["replaced_repository_id"], 12),
      put_in(marker, ["attempt_number"], 5),
      put_in(marker, ["operation_id"], "github-import-publication-22-5"),
      put_in(marker, ["run_id"], 0),
      put_in(marker, ["request_metadata"], %{"request_id" => "/secret/path"})
    ]

    for corrupted_marker <- corruptions do
      evidence = %{attrs.evidence | "publication_marker" => corrupted_marker}

      refute CleanupOperation.create_changeset(
               %CleanupOperation{},
               %{attrs | evidence: evidence}
             ).valid?
    end
  end

  defp remote_attrs do
    storage_root = storage_root()
    repository_storage_path = "11/repository.git"
    requested_path = Path.join(storage_root, repository_storage_path)
    quarantine_path = GitCore.Remote.cleanup_slot_path(requested_path)

    %{
      repository_id: 11,
      repository_item_id: 22,
      source_lock_version: 3,
      kind: :remote_quarantine,
      operation_id: "github-import-cleanup:remote_quarantine:11:22:3",
      evidence: %{
        "version" => 1,
        "kind" => "remote_quarantine",
        "storage_root" => storage_root,
        "relative_path" => Path.relative_to(quarantine_path, storage_root),
        "repository_id" => 11,
        "repository_generation" => 2,
        "repository_storage_path" => repository_storage_path,
        "item_id" => 22,
        "item_lock_version" => 3,
        "requested_path" => requested_path,
        "quarantine_path" => quarantine_path,
        "mode" => 0o700,
        "major_device" => 8,
        "minor_device" => 1,
        "inode" => 99,
        "remote_failure_kind" => "remote_clone_failed"
      },
      eligible_at: @now,
      next_attempt_at: @now
    }
  end

  defp unpublished_attrs do
    decision = %{"action" => "rename", "slug" => "demo"}
    storage_root = storage_root()
    repository_storage_path = "11/repository.git"

    %{
      repository_id: 11,
      repository_item_id: 22,
      source_lock_version: 3,
      kind: :unpublished_shadow,
      operation_id: "github-import-cleanup:unpublished_shadow:11:22:3",
      evidence: %{
        "version" => 1,
        "kind" => "unpublished_shadow",
        "storage_root" => storage_root,
        "relative_path" => repository_storage_path,
        "repository_id" => 11,
        "repository_generation" => 2,
        "repository_write_version" => 0,
        "repository_storage_path" => repository_storage_path,
        "repository_updated_at" => DateTime.to_iso8601(@now),
        "item_id" => 22,
        "item_lock_version" => 3,
        "item_state" => "failed",
        "run_id" => 44,
        "run_state" => "failed",
        "attempt_number" => 4,
        "attempt_state" => "failed",
        "attempt_decision" => decision,
        "attempt_fingerprint" => CleanupOperation.attempt_fingerprint(22, 4, decision),
        "publication_evidence" => %{},
        "predecessor_item_id" => nil,
        "successor_item_id" => nil,
        "adopter_item_id" => nil
      },
      eligible_at: @now,
      next_attempt_at: @now
    }
  end

  defp replacement_attrs do
    storage_root = storage_root()
    repository_storage_path = "11/repository.git"

    decision = %{
      "action" => "replace",
      "slug" => "demo",
      "replacement_repository_id" => 11,
      "replacement_owner_id" => 77,
      "replacement_storage_path" => repository_storage_path,
      "replacement_generation" => 2,
      "replacement_write_version" => 7,
      "replacement_updated_at" => DateTime.to_iso8601(@now),
      "replacement_last_pushed_at" => nil
    }

    marker = %{
      "version" => 1,
      "state" => "committed",
      "attempt_number" => 4,
      "action" => "replace",
      "hidden_repository_id" => 66,
      "operation_id" => "github-import-publication-22-4",
      "request_metadata" => %{},
      "repository_id" => 66,
      "owner_user_id" => 77,
      "slug" => "demo",
      "generation" => 3,
      "replaced_repository_id" => 11,
      "run_id" => 44,
      "published_count_after" => 1,
      "run_lock_version_after" => 5
    }

    %{
      repository_id: 11,
      repository_item_id: 22,
      source_lock_version: 3,
      kind: :replacement_tombstone,
      operation_id: "github-import-cleanup:replacement_tombstone:11:22:3",
      evidence: %{
        "version" => 1,
        "kind" => "replacement_tombstone",
        "storage_root" => storage_root,
        "relative_path" => repository_storage_path,
        "repository_id" => 11,
        "repository_generation" => 2,
        "repository_write_version" => 7,
        "repository_storage_path" => repository_storage_path,
        "repository_deleted_at" => DateTime.to_iso8601(@now),
        "repository_updated_at" => DateTime.to_iso8601(@now),
        "item_id" => 22,
        "item_lock_version" => 3,
        "attempt_number" => 4,
        "attempt_decision" => decision,
        "attempt_fingerprint" => CleanupOperation.attempt_fingerprint(22, 4, decision),
        "publication_operation_id" => marker["operation_id"],
        "publication_marker" => marker,
        "new_repository_id" => marker["repository_id"],
        "new_repository_generation" => marker["generation"],
        "publication_audit_id" => 88
      },
      eligible_at: @now,
      next_attempt_at: @now
    }
  end

  defp identity(inode) do
    %{"mode" => 16_384, "major_device" => 8, "minor_device" => 1, "inode" => inode}
  end

  defp absence_marker do
    %{
      "version" => 1,
      "observed_at" => DateTime.to_iso8601(@now),
      "root_identity" => identity(16)
    }
  end

  defp storage_root, do: Fornacast.Config.repo_storage_root() |> Path.expand()
end
