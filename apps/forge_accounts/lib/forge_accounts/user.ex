defmodule ForgeAccounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:user, :organization]
  @roles [:admin, :user]
  @states [:active, :disabled]

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :email, :string
    field :display_name, :string
    field :description, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :kind, Ecto.Enum, values: @kinds, default: :user
    field :role, Ecto.Enum, values: @roles, default: :user
    field :state, Ecto.Enum, values: @states, default: :active

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs, opts \\ []) do
    password_min_length = Keyword.get(opts, :password_min_length, 8)

    user
    |> cast(attrs, [:username, :email, :password, :role, :state])
    |> normalize_username()
    |> normalize_email()
    |> put_change(:kind, :user)
    |> validate_required([:username, :email, :password, :kind, :role, :state])
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$/)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:password, min: password_min_length, max: 256)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  def state_changeset(user, attrs) do
    user
    |> cast(attrs, [:state])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
  end

  defp normalize_username(changeset) do
    update_change(changeset, :username, fn username ->
      username
      |> String.trim()
      |> String.downcase()
    end)
  end

  defp normalize_email(changeset) do
    update_change(changeset, :email, fn email ->
      email
      |> String.trim()
      |> String.downcase()
    end)
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true} = changeset) do
    password = get_change(changeset, :password)
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset
end
