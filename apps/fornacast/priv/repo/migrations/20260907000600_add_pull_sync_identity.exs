defmodule Fornacast.Repo.Migrations.AddPullSyncIdentity do
  use Ecto.Migration

  def up do
    alter table(:pull_requests) do
      add(:draft, :boolean, null: false, default: false)
      add(:head_repository_id, references(:repositories, on_delete: :nothing))
    end

    flush()
    execute("UPDATE pull_requests SET head_repository_id = repository_id")
    create(index(:pull_requests, [:head_repository_id]))
  end

  def down do
    drop(index(:pull_requests, [:head_repository_id]))

    alter table(:pull_requests) do
      remove(:head_repository_id)
      remove(:draft)
    end
  end
end
