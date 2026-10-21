defmodule ForgeAccounts.GitHubCredential do
  use Ecto.Schema

  import Ecto.Changeset

  @statuses [:valid, :invalid]

  @type t :: %__MODULE__{}

  schema "github_credentials" do
    field :local_user_id, :integer
    field :github_identity_id, :integer
    field :ciphertext, :binary, redact: true
    field :nonce, :binary, redact: true
    field :tag, :binary, redact: true
    field :key_id, :string
    field :credential_kind, Ecto.Enum, values: [:pat, :github_app_user], default: :pat
    field :client_id, :string
    field :expires_at, :utc_datetime
    field :refresh_expires_at, :utc_datetime
    field :refresh_ciphertext, :binary, redact: true
    field :refresh_nonce, :binary, redact: true
    field :refresh_tag, :binary, redact: true
    field :refresh_key_id, :string
    field :token_generation, :integer, default: 1
    field :refresh_claim_id, :string, redact: true
    field :refresh_claimed_at, :utc_datetime
    field :status, Ecto.Enum, values: @statuses, default: :valid
    field :last_verified_at, :utc_datetime
    field :verification_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  def changeset(%__MODULE__{} = credential, attrs) do
    credential
    |> cast(attrs, [
      :local_user_id,
      :github_identity_id,
      :ciphertext,
      :nonce,
      :tag,
      :key_id,
      :status,
      :last_verified_at,
      :credential_kind,
      :client_id,
      :expires_at,
      :refresh_expires_at,
      :refresh_ciphertext,
      :refresh_nonce,
      :refresh_tag,
      :refresh_key_id
    ])
    |> validate_required([
      :local_user_id,
      :github_identity_id,
      :ciphertext,
      :nonce,
      :tag,
      :key_id,
      :status,
      :verification_version
    ])
    |> validate_number(:local_user_id, greater_than: 0)
    |> validate_number(:github_identity_id, greater_than: 0)
    |> validate_length(:ciphertext, min: 1, max: 4_096, count: :bytes)
    |> validate_length(:nonce, is: 12, count: :bytes)
    |> validate_length(:tag, is: 16, count: :bytes)
    |> validate_key_id_byte_size()
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:verification_version, greater_than: 0)
    |> validate_number(:token_generation, greater_than: 0)
    |> validate_device_fields()
    |> check_constraint(:credential_kind, name: :github_credentials_device_lifecycle_check)
    |> unique_constraint(:github_identity_id,
      name: ~r/github_credentials_github_identity_id/
    )
  end

  defp validate_device_fields(changeset) do
    if get_field(changeset, :credential_kind) == :github_app_user do
      changeset
      |> validate_required([
        :client_id,
        :expires_at,
        :refresh_expires_at,
        :refresh_ciphertext,
        :refresh_nonce,
        :refresh_tag,
        :refresh_key_id
      ])
      |> validate_length(:client_id, min: 1, max: 255, count: :bytes)
      |> validate_length(:refresh_ciphertext, min: 1, max: 4_096, count: :bytes)
      |> validate_length(:refresh_nonce, is: 12, count: :bytes)
      |> validate_length(:refresh_tag, is: 16, count: :bytes)
      |> validate_length(:refresh_key_id, min: 1, max: 255, count: :bytes)
    else
      changeset
    end
  end

  defp validate_key_id_byte_size(changeset) do
    validate_change(changeset, :key_id, fn :key_id, key_id ->
      if is_binary(key_id) and byte_size(key_id) in 1..255,
        do: [],
        else: [key_id: "should be between 1 and 255 byte(s)"]
    end)
  end
end
