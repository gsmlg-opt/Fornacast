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
    field :status, Ecto.Enum, values: @statuses, default: :valid
    field :last_verified_at, :utc_datetime

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
      :last_verified_at
    ])
    |> validate_required([
      :local_user_id,
      :github_identity_id,
      :ciphertext,
      :nonce,
      :tag,
      :key_id,
      :status
    ])
    |> validate_number(:local_user_id, greater_than: 0)
    |> validate_number(:github_identity_id, greater_than: 0)
    |> validate_length(:ciphertext, min: 1, max: 4_096, count: :bytes)
    |> validate_length(:nonce, is: 12, count: :bytes)
    |> validate_length(:tag, is: 16, count: :bytes)
    |> validate_key_id_byte_size()
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:github_identity_id,
      name: ~r/github_credentials_github_identity_id/
    )
  end

  defp validate_key_id_byte_size(changeset) do
    validate_change(changeset, :key_id, fn :key_id, key_id ->
      if is_binary(key_id) and byte_size(key_id) in 1..255,
        do: [],
        else: [key_id: "should be between 1 and 255 byte(s)"]
    end)
  end
end
