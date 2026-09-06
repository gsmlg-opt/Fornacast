defmodule GitLFS.RepositoryObject do
  use Ecto.Schema

  import Ecto.Changeset

  schema "lfs_repository_objects" do
    field :repository_id, :integer
    field :oid_sha256, :string
    field :first_seen_ref, :string
    field :reachable, :boolean, default: true
    field :last_reconciled_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :repository_id,
      :oid_sha256,
      :first_seen_ref,
      :reachable,
      :last_reconciled_at
    ])
    |> validate_required([:repository_id, :oid_sha256, :reachable])
    |> validate_number(:repository_id, greater_than: 0)
    |> validate_format(:oid_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:repository_id, :oid_sha256])
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:oid_sha256)
  end
end
