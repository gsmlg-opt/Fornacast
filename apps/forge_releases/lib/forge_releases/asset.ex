defmodule ForgeReleases.Asset do
  use Ecto.Schema
  import Ecto.Changeset

  schema "release_assets" do
    field :repository_id, :integer
    field :release_id, :integer
    field :name, :string
    field :label, :string
    field :content_type, :string
    field :size, :integer
    field :sha256_digest, :string
    field :storage_key, :string
    field :state, Ecto.Enum, values: [:pending, :uploaded, :deleted], default: :pending
    field :download_count, :integer, default: 0
    field :source_download_count, :integer, default: 0
    field :source_asset_id, :integer
    field :uploader_user_id, :integer
    field :uploader_github_identity_id, :integer
    field :uploader, :map, virtual: true
    timestamps(type: :utc_datetime)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:name, :label, :content_type])
    |> validate_required([:name, :content_type])
    |> validate_length(:name, max: 255)
    |> validate_length(:label, max: 255)
    |> validate_length(:content_type, max: 255)
    |> validate_format(:name, ~r/\A[^\x00-\x1f\x7f\/\\]+\z/u)
    |> validate_exclusion(:name, [".", ".."])
    |> validate_format(:content_type, ~r/\A[\w!#$&^.+-]+\/[\w!#$&^.+-]+(?:;[^\r\n\x00]*)?\z/)
    |> unique_constraint(:name, name: :release_assets_active_name_index)
  end
end
