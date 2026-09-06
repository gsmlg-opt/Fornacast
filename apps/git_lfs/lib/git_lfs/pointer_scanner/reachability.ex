defmodule GitLFS.PointerScanner.Reachability do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "lfs_pointer_reachabilities" do
    field(:scan_id, :integer)
    field(:ref_name, :string)
    field(:ref_kind, Ecto.Enum, values: [:branch, :tag])
    field(:target_oid, :string)
    field(:oid_sha256, :string)
    field(:size, :integer)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reachability, attrs) do
    reachability
    |> cast(attrs, [:scan_id, :ref_name, :ref_kind, :target_oid, :oid_sha256, :size])
    |> validate_required([:scan_id, :ref_name, :ref_kind, :target_oid, :oid_sha256, :size])
    |> validate_number(:scan_id, greater_than: 0)
    |> validate_length(:ref_name, min: 1, max: 1_024, count: :bytes)
    |> validate_format(:target_oid, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> validate_format(:oid_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> unique_constraint([:scan_id, :ref_name, :oid_sha256],
      name: :lfs_pointer_reachabilities_scan_ref_oid_index
    )
    |> foreign_key_constraint(:scan_id)
  end
end
