defmodule Fornacast.Repo.Migrations.AddPatSyncControls do
  use Ecto.Migration

  def change do
    alter table(:organization_pat_configurations) do
      add :paused, :boolean, default: false, null: false
      add :trigger_mode, :string, default: "manual", null: false
      add :interval_minutes, :integer, default: 360, null: false
      add :last_sync_at, :utc_datetime
      add :last_sync_status, :string
    end

    create constraint(:organization_pat_configurations, :pat_configuration_trigger_mode,
      check: "trigger_mode IN ('manual', 'interval')"
    )

    create constraint(:organization_pat_configurations, :pat_configuration_interval,
      check: "interval_minutes BETWEEN 5 AND 10080"
    )
  end
end
