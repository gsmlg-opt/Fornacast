defmodule Fornacast.Repo.Migrations.AddIssueSyncVersions do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add(:sync_version, :bigint, null: false, default: 1)
    end

    alter table(:issue_comments) do
      add(:sync_version, :bigint, null: false, default: 1)
    end
  end
end
