defmodule ForgeAccounts.OrganizationGitHubCredential do
  @moduledoc "Organization-owned GitHub App user grant; the authorizer is audit provenance."
  use Ecto.Schema

  @derive {Inspect, only: [:id, :organization_id, :status, :verification_version]}
  schema "organization_github_credentials" do
    field :organization_id, :integer
    field :authorized_by_user_id, :integer
    field :github_user_id, :integer
    field :github_user_login, :string
    field :github_app_id, :integer
    field :client_id, :string
    field :ciphertext, :binary, redact: true
    field :nonce, :binary, redact: true
    field :tag, :binary, redact: true
    field :key_id, :string
    field :refresh_ciphertext, :binary, redact: true
    field :refresh_nonce, :binary, redact: true
    field :refresh_tag, :binary, redact: true
    field :refresh_key_id, :string
    field :expires_at, :utc_datetime
    field :refresh_expires_at, :utc_datetime
    field :status, Ecto.Enum, values: [:valid, :invalid], default: :valid
    field :verification_version, :integer, default: 1
    field :token_generation, :integer, default: 1
    field :refresh_claim_id, :string, redact: true
    field :refresh_claimed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
