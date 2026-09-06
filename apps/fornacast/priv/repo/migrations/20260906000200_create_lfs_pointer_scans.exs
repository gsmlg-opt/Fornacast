defmodule Fornacast.Repo.Migrations.CreateLFSPointerScans do
  use Ecto.Migration

  def change do
    create table(:lfs_pointer_scans) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:repository_generation, :integer, null: false)
      add(:scan_key, :string, null: false)
      add(:baseline_fingerprint, :string, null: false)
      add(:state, :string, null: false, default: "scanning")
      add(:batch_limit, :integer, null: false)
      add(:completed_at, :utc_datetime)
      add(:published_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lfs_pointer_scans, [:repository_id, :scan_key]))
    create(index(:lfs_pointer_scans, [:repository_id, :state, :id]))

    create table(:lfs_pointer_scan_refs) do
      add(:scan_id, references(:lfs_pointer_scans, on_delete: :delete_all), null: false)
      add(:ref_name, :string, null: false)
      add(:ref_kind, :string, null: false)
      add(:target_oid, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lfs_pointer_scan_refs, [:scan_id, :ref_name]))

    create table(:lfs_pointer_reachabilities) do
      add(
        :scan_id,
        references(:lfs_pointer_scans, on_delete: :delete_all),
        null: false
      )

      add(:ref_name, :string, null: false)
      add(:ref_kind, :string, null: false)
      add(:target_oid, :string, null: false)

      add(:oid_sha256, :string, null: false)

      add(:size, :bigint, null: false)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:lfs_pointer_reachabilities, [:scan_id, :ref_name, :oid_sha256],
        name: :lfs_pointer_reachabilities_scan_ref_oid_index
      )
    )

    create(index(:lfs_pointer_reachabilities, [:scan_id, :oid_sha256]))

    create table(:lfs_pointer_scan_work_items) do
      add(:scan_id, references(:lfs_pointer_scans, on_delete: :delete_all), null: false)
      add(:ref_name, :string, null: false)
      add(:object_oid, :string, null: false)
      add(:object_kind, :string, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:tree_offset, :bigint, null: false, default: 0)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:last_expanded_offset, :bigint)
      add(:last_result_fingerprint, :string)
      add(:last_owner, :string)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:lfs_pointer_scan_work_items, [:scan_id, :ref_name, :object_oid],
        name: :lfs_pointer_scan_work_items_scan_ref_oid_index
      )
    )

    create(
      index(
        :lfs_pointer_scan_work_items,
        [:scan_id, :state, :lease_expires_at, :id],
        name: :lfs_pointer_scan_work_items_claim_index
      )
    )

    unless turso?() do
      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_generation_check,
          check: "repository_generation > 0"
        )
      )

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_scan_key_check,
          check: "octet_length(scan_key) between 1 and 255 and scan_key = btrim(scan_key)"
        )
      )

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_fingerprint_check,
          check: "baseline_fingerprint ~ '^[0-9a-f]{64}$'"
        )
      )

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_state_check,
          check: "state in ('scanning', 'complete', 'published')"
        )
      )

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_batch_limit_check,
          check: "batch_limit between 1 and 200"
        )
      )

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_completion_check,
          check:
            "(state = 'scanning' and completed_at is null and published_at is null) or " <>
              "(state = 'complete' and completed_at is not null and published_at is null) or " <>
              "(state = 'published' and completed_at is not null and published_at is not null)"
        )
      )

      create(
        constraint(:lfs_pointer_scan_refs, :lfs_pointer_scan_refs_ref_name_check,
          check:
            "octet_length(ref_name) between 1 and 1024 and " <>
              "(ref_name like 'refs/heads/%' or ref_name like 'refs/tags/%')"
        )
      )

      create(
        constraint(:lfs_pointer_scan_refs, :lfs_pointer_scan_refs_ref_kind_check,
          check: "ref_kind in ('branch', 'tag')"
        )
      )

      create(
        constraint(:lfs_pointer_scan_refs, :lfs_pointer_scan_refs_target_oid_check,
          check: "octet_length(target_oid) in (40, 64) and target_oid !~ '[^0-9a-f]'"
        )
      )

      create(
        constraint(:lfs_pointer_reachabilities, :lfs_pointer_reachabilities_ref_name_check,
          check:
            "octet_length(ref_name) between 1 and 1024 and " <>
              "(ref_name like 'refs/heads/%' or ref_name like 'refs/tags/%')"
        )
      )

      create(
        constraint(:lfs_pointer_reachabilities, :lfs_pointer_reachabilities_ref_kind_check,
          check: "ref_kind in ('branch', 'tag')"
        )
      )

      create(
        constraint(:lfs_pointer_reachabilities, :lfs_pointer_reachabilities_target_oid_check,
          check: "octet_length(target_oid) in (40, 64) and target_oid !~ '[^0-9a-f]'"
        )
      )

      create(
        constraint(:lfs_pointer_reachabilities, :lfs_pointer_reachabilities_oid_check,
          check: "oid_sha256 ~ '^[0-9a-f]{64}$'"
        )
      )

      create(
        constraint(:lfs_pointer_reachabilities, :lfs_pointer_reachabilities_size_check,
          check: "size >= 0"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_ref_name_check,
          check: "octet_length(ref_name) between 1 and 1024"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_oid_check,
          check: "octet_length(object_oid) in (40, 64) and object_oid !~ '[^0-9a-f]'"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_kind_check,
          check: "object_kind in ('commit', 'tree', 'blob', 'tag', 'tag_or_commit')"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_state_check,
          check: "state in ('pending', 'processing', 'done')"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_offset_check,
          check:
            "tree_offset >= 0 and (last_expanded_offset is null or last_expanded_offset >= 0)"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_attempt_check,
          check: "attempt_count >= 0"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_lease_check,
          check:
            "(state = 'processing' and lease_owner is not null and lease_expires_at is not null) or " <>
              "(state <> 'processing' and lease_owner is null and lease_expires_at is null)"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_replay_check,
          check:
            "(last_expanded_offset is null and last_result_fingerprint is null and last_owner is null) or " <>
              "(last_expanded_offset is not null and last_result_fingerprint is not null and last_owner is not null)"
        )
      )

      create(
        constraint(:lfs_pointer_scan_work_items, :lfs_pointer_scan_work_items_fingerprint_check,
          check: "last_result_fingerprint is null or last_result_fingerprint ~ '^[0-9a-f]{64}$'"
        )
      )
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
