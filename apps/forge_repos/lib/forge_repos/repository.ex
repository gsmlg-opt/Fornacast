defmodule ForgeRepos.Repository do
  use Ecto.Schema

  import Ecto.Changeset

  @visibilities [:private, :public]
  @lifecycles [:importing, :ready, :tombstoned]
  @slug_regex ~r/^[a-z0-9][a-z0-9._-]{0,62}$/
  @api_fields [
    :slug,
    :name,
    :description,
    :visibility,
    :default_branch,
    :has_issues,
    :allow_merge_commit
  ]
  @import_fields [
    :owner_user_id,
    :slug,
    :name,
    :visibility,
    :storage_path,
    :lifecycle,
    :generation
  ]
  @publication_fields [
    :owner_user_id,
    :slug,
    :name,
    :description,
    :visibility,
    :default_branch,
    :has_issues,
    :allow_merge_commit,
    :generation
  ]

  @type t :: %__MODULE__{}

  schema "repositories" do
    field :owner_user_id, :integer
    field :slug, :string
    field :name, :string
    field :description, :string
    field :visibility, Ecto.Enum, values: @visibilities, default: :private
    field :storage_path, :string
    field :default_branch, :string, default: "main"
    field :has_issues, :boolean, default: true
    field :allow_merge_commit, :boolean, default: true
    field :last_pushed_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :lifecycle, Ecto.Enum, values: @lifecycles, default: :ready
    field :generation, :integer, default: 1
    field :write_version, :integer, default: 0
    field :storage_reclaimed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def create_changeset(repository, attrs) do
    repository
    |> cast(attrs, @api_fields)
    |> put_change(:write_version, 0)
    |> validate_required([
      :owner_user_id,
      :slug,
      :name,
      :visibility,
      :storage_path,
      :default_branch,
      :has_issues,
      :allow_merge_commit
    ])
    |> validate_repository_fields()
    |> unique_constraint([:owner_user_id, :slug], name: owner_slug_constraint())
    |> unique_constraint(:storage_path, name: storage_path_constraint())
  end

  def import_changeset(%__MODULE__{id: nil} = repository, attrs) do
    repository
    |> cast(attrs, @import_fields)
    |> put_change(:write_version, 0)
    |> validate_required(@import_fields)
    |> validate_explicit_import_fields(attrs)
    |> validate_repository_fields()
    |> validate_import_lifecycle()
    |> validate_private_import()
    |> validate_number(:generation, greater_than: 0)
    |> unique_constraint([:owner_user_id, :slug], name: owner_slug_constraint())
    |> unique_constraint(:storage_path, name: storage_path_constraint())
  end

  def import_changeset(%__MODULE__{} = repository, _attrs) do
    repository
    |> change()
    |> add_error(:id, "must be new", validation: :creation_only)
  end

  @doc false
  def import_adoption_changeset(
        %__MODULE__{
          lifecycle: :importing,
          deleted_at: nil,
          write_version: 0,
          visibility: :private
        } = repository,
        item_id
      )
      when is_integer(item_id) and item_id > 0 do
    with {:ok, suffix} <- import_shadow_suffix(repository.slug) do
      repository
      |> change(%{
        slug: "import-#{item_id}-#{suffix}",
        name: "GitHub import #{item_id}"
      })
      |> validate_import_lifecycle()
      |> validate_private_import()
      |> unique_constraint([:owner_user_id, :slug], name: owner_slug_constraint())
    else
      :error ->
        repository |> change() |> add_error(:slug, "is not an import shadow")
    end
  end

  def import_adoption_changeset(%__MODULE__{} = repository, _item_id),
    do: repository |> change() |> add_error(:lifecycle, "is not an importing shadow")

  defp import_shadow_suffix(slug) when is_binary(slug) do
    case Regex.run(~r/\Aimport-[0-9]+-([0-9a-f]{24})\z/, slug) do
      [_, suffix] -> {:ok, suffix}
      _ -> :error
    end
  end

  defp import_shadow_suffix(_slug), do: :error

  @doc false
  def import_publication_changeset(
        %__MODULE__{lifecycle: :importing, deleted_at: nil, write_version: 0} = repository,
        attrs
      )
      when is_map(attrs) do
    if exact_fields?(attrs, @publication_fields) do
      repository
      |> cast(attrs, @publication_fields)
      |> put_change(:lifecycle, :ready)
      |> put_change(:deleted_at, nil)
      |> validate_required([
        :owner_user_id,
        :slug,
        :name,
        :visibility,
        :default_branch,
        :has_issues,
        :allow_merge_commit,
        :generation
      ])
      |> validate_repository_fields()
      |> validate_number(:owner_user_id, greater_than: 0)
      |> validate_number(:generation, greater_than: 0)
      |> unique_constraint([:owner_user_id, :slug], name: owner_slug_constraint())
    else
      repository |> change() |> add_error(:base, "contains invalid publication fields")
    end
  end

  def import_publication_changeset(%__MODULE__{} = repository, _attrs),
    do: repository |> change() |> add_error(:lifecycle, "is not an importing shadow")

  @doc false
  def import_tombstone_changeset(
        %__MODULE__{lifecycle: :ready, deleted_at: nil} = repository,
        %DateTime{} = deleted_at
      ) do
    repository
    |> change(lifecycle: :tombstoned, deleted_at: DateTime.truncate(deleted_at, :second))
  end

  def import_tombstone_changeset(%__MODULE__{} = repository, _deleted_at),
    do: repository |> change() |> add_error(:lifecycle, "cannot be tombstoned")

  def api_create_changeset(repository, attrs) do
    repository
    |> cast(attrs, @api_fields)
    |> put_change(:write_version, 0)
    |> validate_required([
      :owner_user_id,
      :slug,
      :name,
      :visibility,
      :storage_path,
      :default_branch,
      :has_issues,
      :allow_merge_commit
    ])
    |> validate_repository_fields()
    |> unique_constraint([:owner_user_id, :slug], name: owner_slug_constraint())
    |> unique_constraint(:storage_path, name: storage_path_constraint())
  end

  def api_update_changeset(repository, attrs) do
    repository
    |> cast(attrs, @api_fields)
    |> validate_required([
      :slug,
      :name,
      :visibility,
      :default_branch,
      :has_issues,
      :allow_merge_commit
    ])
    |> validate_repository_fields()
    |> unique_constraint([:owner_user_id, :slug], name: owner_slug_constraint())
  end

  defp validate_repository_fields(changeset) do
    changeset
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:default_branch, &String.trim/1)
    |> validate_slug()
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_no_nul([:name, :description, :default_branch])
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_number(:write_version, greater_than_or_equal_to: 0)
    |> validate_format(:default_branch, ~r/^[A-Za-z0-9._\/-]+$/)
    |> check_constraint(:write_version, name: :repositories_write_version_nonnegative_check)
  end

  defp validate_explicit_import_fields(changeset, attrs) do
    Enum.reduce(@import_fields, changeset, fn field, changeset ->
      if import_attr_present?(attrs, field) or Keyword.has_key?(changeset.errors, field),
        do: changeset,
        else: add_error(changeset, field, "can't be blank", validation: :required)
    end)
  end

  defp import_attr_present?(attrs, field) when is_map(attrs) do
    Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
  end

  defp import_attr_present?(_attrs, _field), do: false

  defp exact_fields?(attrs, fields) do
    keys =
      Enum.map(Map.keys(attrs), fn
        key when is_atom(key) -> key
        key when is_binary(key) -> Enum.find(fields, &(Atom.to_string(&1) == key))
        _key -> nil
      end)

    Enum.sort(keys) == Enum.sort(fields)
  end

  defp validate_import_lifecycle(changeset) do
    if get_field(changeset, :lifecycle) == :importing,
      do: changeset,
      else: add_error(changeset, :lifecycle, "is invalid", validation: :inclusion)
  end

  defp validate_private_import(changeset) do
    if get_field(changeset, :visibility) == :private,
      do: changeset,
      else: add_error(changeset, :visibility, "is invalid", validation: :inclusion)
  end

  def normalize_slug(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_slug()

  def normalize_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace_suffix(".git", "")
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  def normalize_slug(_), do: ""

  def canonical_slug?(slug) when is_binary(slug) do
    String.valid?(slug) and slug == normalize_slug(slug) and Regex.match?(@slug_regex, slug) and
      slug not in [".", ".."] and
      not String.ends_with?(slug, ".") and not String.ends_with?(slug, ".git")
  end

  def canonical_slug?(_slug), do: false

  defp validate_slug(changeset) do
    changeset
    |> validate_format(:slug, @slug_regex)
    |> validate_change(:slug, fn :slug, slug ->
      cond do
        slug in [".", ".."] -> [slug: "is reserved"]
        String.ends_with?(slug, ".") -> [slug: "must not end with a dot"]
        String.ends_with?(slug, ".git") -> [slug: "must not end with .git"]
        true -> []
      end
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

  defp owner_slug_constraint do
    ~r/^repositories_(?:owner_user_id_slug|\(owner_user_id_slug\))(?: \(\d+\))?_index$/
  end

  defp storage_path_constraint do
    ~r/^repositories_storage_path(?: \(\d+\))?_index$/
  end
end
