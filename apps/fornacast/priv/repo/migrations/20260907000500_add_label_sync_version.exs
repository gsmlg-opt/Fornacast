defmodule Fornacast.Repo.Migrations.AddLabelSyncVersion do
  use Ecto.Migration

  def up do
    alter table(:repository_labels) do
      add(:sync_version, :bigint, null: false, default: 1)
    end

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(:repository_labels, :repository_labels_sync_version_positive,
          check: "sync_version > 0"
        )
      )
    end
  end

  def down do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(constraint(:repository_labels, :repository_labels_sync_version_positive))
    end

    alter table(:repository_labels) do
      remove(:sync_version)
    end
  end
end
