defmodule Fornacast.Repo.Migrations.CreateGitLFSObjects do
  use Ecto.Migration

  def change do
    create table(:lfs_objects, primary_key: false) do
      add(:oid_sha256, :string, primary_key: true)
      add(:size, :bigint, null: false)
      add(:storage_key, :string, null: false)
      add(:verified_at, :utc_datetime, null: false)
      add(:state, :string, null: false, default: "ready")

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lfs_objects, [:storage_key]))

    create table(:lfs_repository_objects) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)

      add(
        :oid_sha256,
        references(:lfs_objects,
          column: :oid_sha256,
          type: :string,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:first_seen_ref, :string)
      add(:reachable, :boolean, null: false, default: true)
      add(:last_reconciled_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:lfs_repository_objects, [:repository_id, :oid_sha256]))
    create(index(:lfs_repository_objects, [:oid_sha256]))

    unless turso?() do
      create(
        constraint(:lfs_objects, :lfs_objects_oid_sha256_check,
          check: "oid_sha256 ~ '^[0-9a-f]{64}$'"
        )
      )

      create(
        constraint(:lfs_objects, :lfs_objects_storage_key_check,
          check: "storage_key ~ '^[0-9a-f]{64}$'"
        )
      )

      create(constraint(:lfs_objects, :lfs_objects_size_check, check: "size >= 0"))

      create(constraint(:lfs_objects, :lfs_objects_state_check, check: "state in ('ready')"))

      create(
        constraint(:lfs_repository_objects, :lfs_repository_objects_oid_sha256_check,
          check: "oid_sha256 ~ '^[0-9a-f]{64}$'"
        )
      )
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
