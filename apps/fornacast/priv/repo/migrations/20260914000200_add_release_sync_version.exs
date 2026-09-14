defmodule Fornacast.Repo.Migrations.AddReleaseSyncVersion do
  use Ecto.Migration

  def up do
    alter table(:releases) do
      add(:sync_version, :bigint, null: false, default: 1)
    end

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(constraint(:releases, :releases_sync_version_positive, check: "sync_version > 0"))
    end
  end

  def down do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(constraint(:releases, :releases_sync_version_positive))
    end

    alter table(:releases) do
      remove(:sync_version)
    end
  end
end
