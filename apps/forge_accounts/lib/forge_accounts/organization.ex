defmodule ForgeAccounts.Organization do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:user, :organization]
  @states [:active, :disabled]

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :email, :string
    field :display_name, :string
    field :description, :string
    field :password_hash, :string, redact: true
    field :kind, Ecto.Enum, values: @kinds, default: :organization
    field :state, Ecto.Enum, values: @states, default: :active

    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:username, :display_name, :description, :state])
    |> normalize_username()
    |> normalize_display_name()
    |> put_change(:kind, :organization)
    |> put_generated_credentials()
    |> validate_required([:username, :display_name, :kind, :state, :email, :password_hash])
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$/)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_no_nul([:display_name, :description])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:username, name: ~r/^users_username(?: \(\d+\))?_index$/)
    |> unique_constraint(:email, name: ~r/^users_email(?: \(\d+\))?_index$/)
  end

  def profile_changeset(organization, attrs) do
    attrs = normalize_profile_attrs(attrs)

    organization
    |> cast(attrs, [:display_name, :description], empty_values: [])
    |> trim_optional_string(:display_name)
    |> trim_optional_string(:description)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_no_nul([:display_name, :description])
  end

  defp normalize_profile_attrs(attrs) do
    display_name =
      case fetch_profile_attr(attrs, :name) do
        :missing -> fetch_profile_attr(attrs, :display_name)
        value -> value
      end

    %{}
    |> put_profile_attr(:display_name, display_name)
    |> put_profile_attr(:description, fetch_profile_attr(attrs, :description))
  end

  defp fetch_profile_attr(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_field) -> {:ok, Map.fetch!(attrs, string_field)}
      Map.has_key?(attrs, field) -> {:ok, Map.fetch!(attrs, field)}
      true -> :missing
    end
  end

  defp put_profile_attr(attrs, _field, :missing), do: attrs
  defp put_profile_attr(attrs, field, {:ok, value}), do: Map.put(attrs, field, value)

  defp trim_optional_string(changeset, field) do
    update_change(changeset, field, fn
      nil -> nil
      value -> String.trim(value)
    end)
  end

  defp validate_no_nul(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and :binary.match(value, <<0>>) != :nomatch,
          do: [{field, "must not contain NUL bytes"}],
          else: []
      end)
    end)
  end

  defp normalize_username(changeset) do
    update_change(changeset, :username, fn username ->
      username
      |> String.trim()
      |> String.downcase()
    end)
  end

  defp normalize_display_name(changeset) do
    display_name =
      changeset
      |> get_change(:display_name)
      |> case do
        nil -> get_field(changeset, :username)
        value -> String.trim(value)
      end

    put_change(changeset, :display_name, display_name)
  end

  defp put_generated_credentials(changeset) do
    username = get_field(changeset, :username) || ""

    changeset
    |> put_change(:email, "organization+#{username}@fornacast.invalid")
    |> put_change(:password_hash, "organization-account")
  end
end
