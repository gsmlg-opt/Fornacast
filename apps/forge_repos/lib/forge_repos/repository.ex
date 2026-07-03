defmodule ForgeRepos.Repository do
  use Ecto.Schema

  import Ecto.Changeset

  @visibilities [:private, :public]
  @slug_regex ~r/^[a-z0-9][a-z0-9._-]{0,62}$/

  schema "repositories" do
    field :owner_user_id, :integer
    field :slug, :string
    field :name, :string
    field :description, :string
    field :visibility, Ecto.Enum, values: @visibilities, default: :private
    field :storage_path, :string
    field :default_branch, :string, default: "main"
    field :last_pushed_at, :utc_datetime
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def create_changeset(repository, attrs) do
    repository
    |> cast(attrs, [:slug, :name, :description, :visibility, :default_branch])
    |> validate_required([
      :owner_user_id,
      :slug,
      :name,
      :visibility,
      :storage_path,
      :default_branch
    ])
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:default_branch, &String.trim/1)
    |> validate_slug()
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_format(:default_branch, ~r/^[A-Za-z0-9._\/-]+$/)
    |> unique_constraint([:owner_user_id, :slug])
    |> unique_constraint(:storage_path)
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
end
