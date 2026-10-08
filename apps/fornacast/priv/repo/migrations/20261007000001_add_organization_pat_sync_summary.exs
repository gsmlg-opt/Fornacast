defmodule Fornacast.Repo.Migrations.AddOrganizationPatSyncSummary do
  use Ecto.Migration

  def change do
    alter table(:organization_pat_configurations) do
      add(:last_sync_summary, :map, null: false, default: %{})
    end

    alter table(:organization_pat_sync_runs) do
      add(:error, :string)
    end
  end
end
