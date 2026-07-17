defmodule ForgeAccounts.SSHKey do
  use Ecto.Schema

  import Ecto.Changeset

  @accepted_algorithms ~w(ssh-ed25519 ssh-rsa)
  @minimum_rsa_modulus Integer.pow(2, 2047)

  schema "ssh_keys" do
    field :title, :string
    field :public_key, :string
    field :fingerprint_sha256, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, ForgeAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:title, :public_key])
    |> normalize_public_key()
    |> validate_required([:user_id, :title, :public_key])
    |> validate_length(:title, min: 1, max: 120)
    |> validate_public_key()
    |> unique_constraint(:fingerprint_sha256)
  end

  def fingerprint(public_key) when is_binary(public_key) do
    with {:ok, algorithm, key_blob} <- parse_public_key(public_key) do
      _ = algorithm

      fingerprint =
        :crypto.hash(:sha256, key_blob)
        |> Base.encode64(padding: false)

      {:ok, "SHA256:" <> fingerprint}
    end
  end

  def fingerprint(_), do: {:error, :invalid_public_key}

  def decode_public_key(public_key) when is_binary(public_key) do
    with {:ok, _algorithm, _key_blob} <- parse_public_key(public_key),
         {:ok, decoded_key} <- decode_openssh_key(public_key) do
      {:ok, decoded_key}
    end
  end

  def decode_public_key(_), do: {:error, :invalid_public_key}

  defp normalize_public_key(changeset) do
    update_change(changeset, :public_key, fn public_key ->
      public_key
      |> String.trim()
      |> String.replace(~r/\s+/, " ")
    end)
  end

  defp validate_public_key(changeset) do
    public_key = get_field(changeset, :public_key)

    case parse_public_key(public_key) do
      {:ok, _algorithm, _key_blob} ->
        {:ok, fingerprint} = fingerprint(public_key)
        put_change(changeset, :fingerprint_sha256, fingerprint)

      {:error, reason} ->
        add_error(changeset, :public_key, public_key_error(reason))
    end
  end

  defp parse_public_key(public_key) when is_binary(public_key) do
    with [algorithm, blob | _rest] <- String.split(public_key, " "),
         true <- algorithm in @accepted_algorithms,
         {:ok, key_blob} <- Base.decode64(blob, padding: false),
         {:ok, decoded_key} <- decode_openssh_key(public_key),
         :ok <- validate_decoded_algorithm(algorithm, decoded_key) do
      {:ok, algorithm, key_blob}
    else
      false -> {:error, :unsupported_algorithm}
      :error -> {:error, :invalid_base64}
      _ -> {:error, :invalid_public_key}
    end
  end

  defp parse_public_key(_), do: {:error, :invalid_public_key}

  defp validate_decoded_algorithm("ssh-rsa", {:RSAPublicKey, modulus, exponent})
       when modulus >= @minimum_rsa_modulus and exponent >= 65_537 and rem(exponent, 2) == 1,
       do: :ok

  defp validate_decoded_algorithm(
         "ssh-ed25519",
         {{:ECPoint, _point}, {:namedCurve, {1, 3, 101, 112}}}
       ),
       do: :ok

  defp validate_decoded_algorithm(_algorithm, _decoded_key),
    do: {:error, :invalid_public_key}

  defp decode_openssh_key(public_key) do
    case :ssh_file.decode(public_key, :auth_keys) do
      [{decoded_key, _attrs}] -> {:ok, decoded_key}
      _ -> {:error, :invalid_public_key}
    end
  rescue
    _error in [ArgumentError, FunctionClauseError, ErlangError] ->
      {:error, :invalid_public_key}
  end

  defp public_key_error(:unsupported_algorithm) do
    "must use ssh-ed25519 or ssh-rsa"
  end

  defp public_key_error(_), do: "is not a valid OpenSSH public key"
end
