defmodule Fornacast.Repo.Migrations.AddPatSyncRepositoryResults do
  use Ecto.Migration

  def change do
    alter table(:organization_pat_sync_runs) do
      add(:started_at, :utc_datetime)
      add(:heartbeat_at, :utc_datetime)
      add(:last_progress_at, :utc_datetime)
    end

    create table(:organization_pat_sync_repository_results) do
      add(:pat_sync_run_id, references(:organization_pat_sync_runs, on_delete: :delete_all),
        null: false
      )

      add(
        :repository_item_id,
        references(:github_import_repository_items, on_delete: :nilify_all)
      )

      add(:item_key, :string, null: false)
      add(:data, :map, null: false, default: %{})
      add(:state, :string, null: false, default: "pending")
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:finished_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organization_pat_sync_repository_results, [:pat_sync_run_id, :item_key]))
    create(index(:organization_pat_sync_repository_results, [:state, :lease_expires_at]))
  end
end
