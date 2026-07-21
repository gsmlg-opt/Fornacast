defmodule ForgeAccounts.APIKey do
  use Ecto.Schema

  import Ecto.Changeset

  @classic_scopes ["repo", "public_repo", "read:org", "write:org"]
  @legacy_scopes ["repo:read", "repo:write"]

  schema "api_keys" do
    field :user_id, :integer
    field :name, :string
    field :token_prefix, :string
    field :token_hash, :string, redact: true
    field :scopes, :map
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def classic_scopes, do: @classic_scopes
  def legacy_scopes, do: @legacy_scopes

  def creation_changeset(api_key, attrs) do
    attrs = normalize_scope_attrs(attrs)

    api_key
    |> cast(attrs, [:name, :scopes, :expires_at])
    |> validate_required([:user_id, :name, :token_prefix, :token_hash, :scopes])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_scopes()
  end

  def generate_secret do
    secret = "fc_pat_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {secret, String.slice(secret, 0, 15), hash(secret)}
  end

  def hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp normalize_scope_attrs(attrs) do
    scope_key = if Map.has_key?(attrs, "scopes"), do: "scopes", else: :scopes

    case Map.fetch(attrs, scope_key) do
      {:ok, scopes} when is_list(scopes) ->
        Map.put(attrs, scope_key, Map.new(scopes, &{&1, true}))

      _ ->
        attrs
    end
  end

  defp validate_scopes(changeset) do
    scopes = get_field(changeset, :scopes) || %{}

    if map_size(scopes) > 0 and
         Enum.all?(scopes, fn {scope, enabled} ->
           scope in @classic_scopes and enabled == true
         end) do
      changeset
    else
      add_error(changeset, :scopes, "must contain repo, public_repo, read:org, or write:org")
    end
  end
end
