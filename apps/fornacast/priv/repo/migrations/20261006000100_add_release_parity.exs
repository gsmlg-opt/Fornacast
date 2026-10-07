defmodule Fornacast.Repo.Migrations.AddReleaseParity do
  use Ecto.Migration

  def change do
    alter table(:releases) do
      add(:immutable, :boolean, null: false, default: false)
      add(:source_metadata, :map, null: false, default: %{})
      add(:make_latest, :string, null: false, default: "legacy")
    end

    create table(:release_assets) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:release_id, references(:releases, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:label, :string)
      add(:content_type, :string, null: false)
      add(:size, :bigint)
      add(:sha256_digest, :string)
      add(:storage_key, :string)
      add(:state, :string, null: false, default: "pending")
      add(:download_count, :bigint, null: false, default: 0)
      add(:source_download_count, :bigint, null: false, default: 0)
      add(:source_asset_id, :bigint)
      add(:uploader_user_id, references(:users, on_delete: :restrict))
      add(:uploader_github_identity_id, references(:github_identities, on_delete: :restrict))
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:release_assets, [:release_id, :name],
        where: "state <> 'deleted'",
        name: :release_assets_active_name_index
      )
    )

    create(index(:release_assets, [:storage_key, :state]))

    create(
      constraint(:release_assets, :release_assets_uploader_check,
        check: "(uploader_user_id is not null) <> (uploader_github_identity_id is not null)"
      )
    )

    create(
      constraint(:release_assets, :release_assets_ready_check,
        check:
          "state <> 'uploaded' or (size >= 0 and sha256_digest is not null and storage_key = sha256_digest)"
      )
    )

    create table(:release_asset_operations) do
      add(:asset_id, references(:release_assets, on_delete: :delete_all), null: false)
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:repository_generation, :integer, null: false)
      add(:source_key, :string, null: false)
      add(:kind, :string, null: false)
      add(:state, :string, null: false, default: "staging")
      add(:staging_key, :string)
      add(:storage_key, :string)
      add(:size, :bigint)
      add(:failure, :string)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:release_asset_operations, [:source_key]))
    create(index(:release_asset_operations, [:state, :lease_expires_at]))
    create(index(:release_asset_operations, [:storage_key, :state]))

    create table(:release_asset_blobs, primary_key: false) do
      add(:storage_key, :string, primary_key: true)
      add(:size, :bigint, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:gc_after, :utc_datetime)
      add(:version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(index(:release_asset_blobs, [:state, :gc_after]))
  end
end
