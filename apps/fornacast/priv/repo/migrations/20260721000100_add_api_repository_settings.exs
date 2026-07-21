defmodule Fornacast.Repo.Migrations.AddAPIRepositorySettings do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add(:has_issues, :boolean, null: false, default: true)
      add(:allow_merge_commit, :boolean, null: false, default: true)
    end
  end
end
