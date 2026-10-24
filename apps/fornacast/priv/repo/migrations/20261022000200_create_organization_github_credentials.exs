defmodule Fornacast.Repo.Migrations.CreateOrganizationGithubCredentials do
  use Ecto.Migration

  def change do
    create table(:organization_github_credentials) do
      add(:organization_id, references(:users, on_delete: :delete_all), null: false)
      add(:authorized_by_user_id, references(:users, on_delete: :nilify_all))
      add(:github_user_id, :bigint, null: false)
      add(:github_user_login, :string, null: false)
      add(:github_app_id, :bigint, null: false)
      add(:client_id, :string, null: false)

      for field <- [:ciphertext, :nonce, :tag, :refresh_ciphertext, :refresh_nonce, :refresh_tag] do
        add(field, :binary, null: false)
      end

      add(:key_id, :string, null: false)
      add(:refresh_key_id, :string, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:refresh_expires_at, :utc_datetime, null: false)
      add(:status, :string, null: false, default: "valid")
      add(:verification_version, :bigint, null: false, default: 1)
      add(:token_generation, :bigint, null: false, default: 1)
      add(:refresh_claim_id, :string)
      add(:refresh_claimed_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organization_github_credentials, [:organization_id]))

    create(
      constraint(:organization_github_credentials, :organization_github_credentials_lifecycle,
        check:
          "status IN ('valid', 'invalid') AND verification_version > 0 AND token_generation > 0 AND github_user_id > 0 AND github_app_id = 5412311 AND client_id = 'Iv23lizCVE3E24s7fCA0' AND ((refresh_claim_id IS NULL AND refresh_claimed_at IS NULL) OR (refresh_claim_id IS NOT NULL AND refresh_claimed_at IS NOT NULL))"
      )
    )
  end
end
