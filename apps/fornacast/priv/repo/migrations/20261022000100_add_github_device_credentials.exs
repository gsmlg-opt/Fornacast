defmodule Fornacast.Repo.Migrations.AddGithubDeviceCredentials do
  use Ecto.Migration

  def change do
    alter table(:github_credentials) do
      add(:credential_kind, :string, null: false, default: "pat")
      add(:client_id, :string)
      add(:expires_at, :utc_datetime)
      add(:refresh_expires_at, :utc_datetime)
      add(:refresh_ciphertext, :binary)
      add(:refresh_nonce, :binary)
      add(:refresh_tag, :binary)
      add(:refresh_key_id, :string)
      add(:token_generation, :bigint, null: false, default: 1)
      add(:refresh_claim_id, :string)
      add(:refresh_claimed_at, :utc_datetime)
    end

    create(
      constraint(:github_credentials, :github_credentials_device_lifecycle_check,
        check: """
        token_generation > 0 AND
        ((refresh_claim_id IS NULL AND refresh_claimed_at IS NULL) OR
         (refresh_claim_id IS NOT NULL AND refresh_claimed_at IS NOT NULL)) AND
        ((credential_kind = 'pat' AND client_id IS NULL AND expires_at IS NULL AND
          refresh_expires_at IS NULL AND refresh_ciphertext IS NULL AND
          refresh_nonce IS NULL AND refresh_tag IS NULL AND refresh_key_id IS NULL AND
          refresh_claim_id IS NULL) OR
         (credential_kind = 'github_app_user' AND client_id IS NOT NULL AND
          expires_at IS NOT NULL AND refresh_expires_at IS NOT NULL AND
          refresh_ciphertext IS NOT NULL AND refresh_nonce IS NOT NULL AND
          refresh_tag IS NOT NULL AND refresh_key_id IS NOT NULL))
        """
      )
    )
  end
end
