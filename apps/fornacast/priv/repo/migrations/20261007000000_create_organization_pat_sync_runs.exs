defmodule Fornacast.Repo.Migrations.CreateOrganizationPatSyncRuns do
  use Ecto.Migration

  def change do
    create table(:organization_pat_sync_runs) do
      add(:configuration_id, references(:organization_pat_configurations, on_delete: :delete_all),
        null: false
      )

      add(:organization_id, references(:users, on_delete: :delete_all), null: false)
      add(:owner_user_id, references(:users, on_delete: :restrict), null: false)
      add(:github_identity_id, references(:github_identities, on_delete: :restrict), null: false)
      add(:github_organization, :string, null: false)
      add(:import_run_id, references(:github_import_runs, on_delete: :restrict))
      add(:state, :string, null: false, default: "queued")
      add(:progress, :map, null: false, default: %{})
      add(:request_metadata, :map, null: false, default: %{})
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:finished_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:organization_pat_sync_runs, [:configuration_id],
        where: "state IN ('queued', 'running')",
        name: :organization_pat_sync_runs_active_configuration
      )
    )

    create(
      constraint(:organization_pat_sync_runs, :organization_pat_sync_runs_state,
        check: "state IN ('queued', 'running', 'succeeded', 'failed')"
      )
    )
  end
end
