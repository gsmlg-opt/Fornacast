defmodule Fornacast.Repo.Migrations.CreateGitHubCredentials do
  use Ecto.Migration

  def change do
    if turso?(), do: create_turso_table(), else: create_postgres_table()

    create(index(:github_credentials, [:local_user_id]))

    create(
      unique_index(:github_credentials, [:github_identity_id],
        name: :github_credentials_github_identity_id_index
      )
    )
  end

  defp create_turso_table do
    create table(:github_credentials) do
      add(:local_user_id, references(:users, on_delete: :delete_all), null: false)

      add(:github_identity_id, references(:github_identities, on_delete: :restrict), null: false)

      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:key_id, :string, null: false)

      add(:status, :string,
        null: false,
        default: "valid",
        check: [
          name: "github_credentials_status_check",
          expr: "status in ('valid', 'invalid')"
        ]
      )

      add(:last_verified_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end
  end

  defp create_postgres_table do
    create table(:github_credentials) do
      add(:local_user_id, references(:users, on_delete: :delete_all), null: false)

      add(:github_identity_id, references(:github_identities, on_delete: :restrict), null: false)

      add(:ciphertext, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:tag, :binary, null: false)
      add(:key_id, :string, null: false)
      add(:status, :string, null: false, default: "valid")
      add(:last_verified_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(
      constraint(:github_credentials, :github_credentials_status_check,
        check: "status in ('valid', 'invalid')"
      )
    )
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
