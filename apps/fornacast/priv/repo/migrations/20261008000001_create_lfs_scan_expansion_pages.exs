defmodule Fornacast.Repo.Migrations.CreateLfsScanExpansionPages do
  use Ecto.Migration

  def change do
    create table(:lfs_pointer_scan_expansion_pages) do
      add(:scan_id, references(:lfs_pointer_scans, on_delete: :delete_all), null: false)
      add(:object_oid, :string, null: false)
      add(:tree_offset, :bigint, null: false)
      add(:batch_limit, :integer, null: false)
      add(:format_version, :integer, null: false)
      add(:object_kind, :string, null: false)
      add(:children, {:array, :map}, null: false, default: [])
      add(:candidate_data, :binary)
      add(:candidate_size, :integer)
      add(:next_offset, :bigint)
      add(:result_fingerprint, :string, null: false)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(
        :lfs_pointer_scan_expansion_pages,
        [:scan_id, :object_oid, :tree_offset, :batch_limit, :format_version],
        name: :lfs_pointer_scan_expansion_pages_key_index
      )
    )

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(:lfs_pointer_scan_expansion_pages, :lfs_scan_expansion_page_bounds,
          check:
            "tree_offset >= 0 and batch_limit between 1 and 200 and format_version > 0 and " <>
              "cardinality(children) <= batch_limit and (next_offset is null or next_offset > tree_offset)"
        )
      )

      create(
        constraint(:lfs_pointer_scan_expansion_pages, :lfs_scan_expansion_page_oid,
          check:
            "octet_length(object_oid) in (40,64) and object_oid !~ '[^0-9a-f]' and result_fingerprint ~ '^[0-9a-f]{64}$'"
        )
      )

      create(
        constraint(:lfs_pointer_scan_expansion_pages, :lfs_scan_expansion_page_candidate,
          check:
            "object_kind in ('commit','tree','blob','tag') and " <>
              "((candidate_data is null and candidate_size is null) or " <>
              "(object_kind = 'blob' and candidate_data is not null and candidate_size is not null and " <>
              "candidate_size between 0 and 1024 and octet_length(candidate_data) = candidate_size))"
        )
      )
    end
  end
end
