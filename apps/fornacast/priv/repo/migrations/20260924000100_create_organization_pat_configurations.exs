defmodule Fornacast.Repo.Migrations.CreateOrganizationPatConfigurations do
  use Ecto.Migration

  def change do
    create table(:organization_pat_configurations) do
      add(:organization_id, references(:users, on_delete: :delete_all), null: false)
      add(:owner_user_id, references(:users, on_delete: :restrict))
      add(:github_identity_id, references(:github_identities, on_delete: :nilify_all))
      add(:github_organization, :string, null: false)
      add(:enabled, :boolean, default: false, null: false)
      add(:direction, :string, default: "github_to_fornacast", null: false)
      add(:repository_selection, :string, default: "all", null: false)
      add(:selected_repository_ids, {:array, :bigint}, default: [], null: false)
      add(:inventory, :map, default: %{}, null: false)
      add(:inventory_refreshed_at, :utc_datetime)
      add(:lock_version, :integer, default: 1, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organization_pat_configurations, [:organization_id]))

    create(
      constraint(:organization_pat_configurations, :pat_configuration_direction,
        check: "direction = 'github_to_fornacast'"
      )
    )

    create(
      constraint(:organization_pat_configurations, :pat_configuration_selection,
        check: "repository_selection IN ('all', 'selected')"
      )
    )

  end
end
