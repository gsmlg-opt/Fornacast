defmodule ForgeReleases.AssetOperation do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:staging, :staged, :metadata_ready, :completed, :failed]
  schema "release_asset_operations" do
    field :asset_id, :integer
    field :repository_id, :integer
    field :repository_generation, :integer
    field :source_key, :string
    field :kind, Ecto.Enum, values: [:local, :import]
    field :state, Ecto.Enum, values: @states, default: :staging
    field :staging_key, :string
    field :storage_key, :string
    field :size, :integer
    field :failure, :string
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def terminal_states, do: [:completed, :failed]

  def lease_update_changeset(operation, updates) do
    operation
    |> cast(Map.new(updates), [:state, :staging_key, :storage_key, :size, :failure])
  end
end
