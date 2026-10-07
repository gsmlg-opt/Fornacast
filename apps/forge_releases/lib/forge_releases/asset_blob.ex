defmodule ForgeReleases.AssetBlob do
  use Ecto.Schema
  @primary_key {:storage_key, :string, autogenerate: false}
  schema "release_asset_blobs" do
    field :size, :integer
    field :state, Ecto.Enum, values: [:pending, :ready, :candidate, :deleting, :absent, :corrupt]
    field :gc_after, :utc_datetime
    field :version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end
end
