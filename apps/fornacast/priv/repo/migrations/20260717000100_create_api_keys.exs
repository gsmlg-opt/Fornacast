defmodule Fornacast.Repo.Migrations.CreateAPIKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:token_prefix, :string, null: false)
      add(:token_hash, :string, null: false)
      add(:scopes, :map, null: false)
      add(:expires_at, :utc_datetime)
      add(:last_used_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:api_keys, [:user_id]))
    create(unique_index(:api_keys, [:token_hash]))
    create(index(:api_keys, [:token_prefix]))
  end
end
