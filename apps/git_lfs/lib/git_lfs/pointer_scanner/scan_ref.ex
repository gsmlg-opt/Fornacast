defmodule GitLFS.PointerScanner.ScanRef do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "lfs_pointer_scan_refs" do
    field(:scan_id, :integer)
    field(:ref_name, :string)
    field(:ref_kind, Ecto.Enum, values: [:branch, :tag])
    field(:target_oid, :string)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(scan_ref, attrs) do
    scan_ref
    |> cast(attrs, [:scan_id, :ref_name, :ref_kind, :target_oid])
    |> validate_required([:scan_id, :ref_name, :ref_kind, :target_oid])
    |> validate_number(:scan_id, greater_than: 0)
    |> validate_length(:ref_name, min: 1, max: 1_024, count: :bytes)
    |> validate_format(:target_oid, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> unique_constraint([:scan_id, :ref_name])
    |> foreign_key_constraint(:scan_id)
  end
end
