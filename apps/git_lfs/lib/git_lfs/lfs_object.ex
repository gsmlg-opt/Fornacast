defmodule GitLFS.LFSObject do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @states [:ready]

  schema "lfs_objects" do
    field :oid_sha256, :string, primary_key: true
    field :size, :integer
    field :storage_key, :string
    field :verified_at, :utc_datetime
    field :state, Ecto.Enum, values: @states, default: :ready

    timestamps(type: :utc_datetime)
  end

  @doc false
  def ready_changeset(object, attrs) do
    object
    |> cast(attrs, [:oid_sha256, :size, :storage_key, :verified_at])
    |> put_change(:state, :ready)
    |> validate_required([:oid_sha256, :size, :storage_key, :verified_at, :state])
    |> validate_format(:oid_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:storage_key, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> unique_constraint(:oid_sha256)
  end
end
