defmodule Fornacast.Repo.Migrations.CreateOrganizationGithubConnections do
  use Ecto.Migration

  def change do
    create table(:organization_github_connections) do
      add(:organization_id, references(:users, on_delete: :delete_all), null: false)
      add(:credential_id, references(:organization_github_credentials), null: false)
      add(:credential_version, :bigint, null: false)
      add(:github_app_id, :bigint, null: false)
      add(:client_id, :string, null: false)
      add(:github_organization_id, :bigint)
      add(:github_organization, :string)
      add(:installation_id, :bigint)
      add(:inventory, :map, null: false, default: %{})
      add(:permissions, :map, null: false, default: %{})
      add(:repository_selection, :string)
      add(:state, :string, null: false, default: "installation_required")
      add(:observed_at, :utc_datetime)
      add(:lock_version, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organization_github_connections, [:organization_id]))

    create(
      unique_index(:organization_github_connections, [:installation_id], where: "state = 'ready'")
    )

    create(
      constraint(:organization_github_connections, :organization_github_connection_shape,
        check: """
        credential_version > 0 AND lock_version > 0 AND github_app_id > 0 AND
        state IN ('installation_required','ready','permissions_missing','disconnected') AND
        (state <> 'ready' OR (installation_id > 0 AND github_organization_id > 0 AND
         github_organization IS NOT NULL AND observed_at IS NOT NULL AND
         repository_selection IN ('all','selected'))) AND
        ((github_organization_id IS NULL AND github_organization IS NULL) OR
         (github_organization_id > 0 AND github_organization IS NOT NULL))
        """
      )
    )
  end
end
