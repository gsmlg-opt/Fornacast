defmodule ForgeReleases.Release do
  use Ecto.Schema

  import Ecto.Changeset

  @fields [:tag_name, :name, :body, :draft, :prerelease, :target_commitish, :make_latest]
  @import_fields @fields ++
                   [:published_at, :inserted_at, :updated_at, :immutable, :source_metadata]
  @sync_fields @fields ++ [:published_at, :updated_at]
  @max_body_codepoints 65_536
  @max_body_bytes 262_144
  @default_capabilities %{can_edit: false, can_delete: false}

  @type t :: %__MODULE__{}

  schema "releases" do
    field :repository_id, :integer
    field :tag_name, :string
    field :name, :string
    field :body, :string
    field :draft, :boolean, default: false
    field :prerelease, :boolean, default: false
    field :target_commitish, :string
    field :published_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :author_user_id, :integer
    field :author_github_identity_id, :integer
    field :sync_version, :integer, default: 1
    field :immutable, :boolean, default: false
    field :make_latest, :string, default: "legacy"
    field :source_metadata, :map, default: %{}
    field :assets, {:array, :map}, virtual: true, default: []

    field :author, :map, virtual: true
    field :capabilities, :map, virtual: true, default: @default_capabilities

    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = release, attrs) when is_map(attrs) do
    release
    |> cast(attrs, @fields)
    |> validate_metadata()
    |> normalize_publication_state()
    |> validate_author_identity()
    |> database_constraints()
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = release, attrs) when is_map(attrs) do
    release
    |> cast(attrs, @fields)
    |> validate_metadata()
    |> normalize_publication_state()
    |> clear_historical_body()
    |> validate_author_identity()
    |> database_constraints()
    |> optimistic_lock(:sync_version, &(&1 + 1))
  end

  @spec import_changeset(t(), map()) :: Ecto.Changeset.t()
  def import_changeset(%__MODULE__{} = release, attrs) when is_map(attrs) do
    release
    |> cast(attrs, @import_fields)
    |> validate_metadata()
    |> validate_source_metadata()
    |> validate_author_identity()
    |> validate_publication_state()
    |> database_constraints()
  end

  @doc false
  @spec sync_changeset(t(), map()) :: Ecto.Changeset.t()
  def sync_changeset(%__MODULE__{} = release, attrs) when is_map(attrs) do
    release
    |> cast(attrs, @sync_fields)
    |> validate_metadata()
    |> validate_author_identity()
    |> validate_publication_state()
    |> database_constraints()
    |> optimistic_lock(:sync_version, &(&1 + 1))
  end

  @spec delete_changeset(t()) :: Ecto.Changeset.t()
  def delete_changeset(%__MODULE__{} = release) do
    release
    |> change(deleted_at: utc_now())
    |> optimistic_lock(:sync_version, &(&1 + 1))
  end

  @doc false
  @spec sync_delete_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def sync_delete_changeset(%__MODULE__{} = release, %DateTime{} = updated_at) do
    release
    |> change(deleted_at: updated_at, updated_at: updated_at)
    |> optimistic_lock(:sync_version, &(&1 + 1))
  end

  defp validate_metadata(changeset) do
    changeset
    |> validate_required([:repository_id, :tag_name, :target_commitish])
    |> validate_length(:tag_name, min: 1, max: 255)
    |> validate_length(:name, max: 255)
    |> validate_length(:body, max: @max_body_codepoints, count: :codepoints)
    |> validate_length(:body, max: @max_body_bytes, count: :bytes)
    |> validate_length(:target_commitish, min: 1, max: 255)
    |> validate_inclusion(:make_latest, ["true", "false", "legacy"])
    |> reject_null_bytes([:tag_name, :name, :body, :target_commitish])
    |> validate_tag_name()
  end

  defp clear_historical_body(changeset) do
    if changed?(changeset, :body) do
      put_change(
        changeset,
        :source_metadata,
        Map.drop(get_field(changeset, :source_metadata), [
          "body_html",
          "body_text",
          "mentions_count"
        ])
      )
    else
      changeset
    end
  end

  defp validate_source_metadata(changeset) do
    validate_change(changeset, :source_metadata, fn :source_metadata, metadata ->
      if valid_source_metadata?(metadata), do: [], else: [source_metadata: "is invalid"]
    end)
  end

  def valid_source_metadata?(metadata) when is_map(metadata) do
    allowed = ~w(body_html body_text mentions_count reactions discussion_url)

    Enum.all?(metadata, fn
      {key, value} when key in ["body_html", "body_text"] ->
        is_nil(value) or
          (is_binary(value) and String.valid?(value) and byte_size(value) <= 1_048_576)

      {"mentions_count", value} ->
        is_integer(value) and value >= 0

      {"discussion_url", nil} ->
        true

      {"discussion_url", value} when is_binary(value) ->
        uri = URI.parse(value)

        uri.scheme == "https" and uri.host == "github.com" and is_nil(uri.userinfo) and
          is_binary(uri.path) and String.contains?(uri.path, "/discussions/")

      {"reactions", values} when is_map(values) ->
        keys = ~w(url total_count +1 -1 laugh hooray confused heart rocket eyes)

        Enum.sort(Map.keys(values)) == Enum.sort(keys) and
          Enum.all?(values, fn
            {"url", value} when is_binary(value) and byte_size(value) <= 2_048 ->
              uri = URI.parse(value)

              uri.scheme == "https" and uri.host == "api.github.com" and is_nil(uri.userinfo) and
                is_binary(uri.path) and
                Regex.match?(~r{\A/repos/[^/]+/[^/]+/releases/[1-9][0-9]*/reactions\z}, uri.path)

            {key, value} ->
              key in keys and is_integer(value) and value in 0..9_223_372_036_854_775_807
          end)

      _ ->
        false
    end) and Enum.all?(Map.keys(metadata), &(&1 in allowed))
  end

  def valid_source_metadata?(_), do: false

  defp validate_tag_name(changeset) do
    validate_change(changeset, :tag_name, fn :tag_name, tag_name ->
      full_ref = "refs/tags/#{tag_name}"

      if String.starts_with?(tag_name, "refs/") or
           not match?({:ok, _}, GitCore.tracking_ref_name("release-validation", full_ref)) do
        [tag_name: "is not a valid tag name"]
      else
        []
      end
    end)
  end

  defp normalize_publication_state(changeset) do
    draft = get_field(changeset, :draft)
    published_at = get_field(changeset, :published_at)

    cond do
      draft -> put_change(changeset, :published_at, nil)
      is_nil(published_at) -> put_change(changeset, :published_at, utc_now())
      true -> changeset
    end
  end

  defp validate_publication_state(changeset) do
    case {get_field(changeset, :draft), get_field(changeset, :published_at)} do
      {true, nil} ->
        changeset

      {false, %DateTime{}} ->
        changeset

      {true, %DateTime{}} ->
        add_error(changeset, :published_at, "must be blank for a draft")

      {false, nil} ->
        add_error(changeset, :published_at, "can't be blank for a published release")

      _invalid ->
        changeset
    end
  end

  defp validate_author_identity(changeset) do
    case {get_field(changeset, :author_user_id), get_field(changeset, :author_github_identity_id)} do
      {user_id, nil} when is_integer(user_id) and user_id > 0 ->
        changeset

      {nil, identity_id} when is_integer(identity_id) and identity_id > 0 ->
        changeset

      {nil, nil} ->
        add_error(changeset, :author_user_id, "must identify exactly one author")

      {_user_id, _identity_id} ->
        add_error(changeset, :author_github_identity_id, "must identify exactly one author")
    end
  end

  defp database_constraints(changeset) do
    changeset
    |> unique_constraint(:tag_name, name: :releases_active_repository_tag_index)
    |> check_constraint(:author_user_id, name: :releases_author_identity_check)
    |> check_constraint(:published_at, name: :releases_publication_state_check)
    |> check_constraint(:sync_version, name: :releases_sync_version_positive)
  end

  defp reject_null_bytes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and :binary.match(value, <<0>>) != :nomatch,
          do: [{field, "must not contain NUL bytes"}],
          else: []
      end)
    end)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
