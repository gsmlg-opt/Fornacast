defmodule GitLFS.PointerScanner.WorkItem do
  use Ecto.Schema

  import Ecto.Changeset

  @object_kinds [:commit, :tree, :blob, :tag, :tag_or_commit]
  @states [:pending, :processing, :done]

  @type t :: %__MODULE__{}

  schema "lfs_pointer_scan_work_items" do
    field(:scan_id, :integer)
    field(:ref_name, :string)
    field(:object_oid, :string)
    field(:object_kind, Ecto.Enum, values: @object_kinds)
    field(:state, Ecto.Enum, values: @states, default: :pending)
    field(:tree_offset, :integer, default: 0)
    field(:attempt_count, :integer, default: 0)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime)
    field(:last_expanded_offset, :integer)
    field(:last_result_fingerprint, :string)
    field(:last_owner, :string)

    timestamps(type: :utc_datetime)
  end

  def object_kinds, do: @object_kinds

  @doc false
  def creation_changeset(work_item, attrs) do
    work_item
    |> cast(attrs, [:scan_id, :ref_name, :object_oid, :object_kind])
    |> put_change(:state, :pending)
    |> put_change(:tree_offset, 0)
    |> put_change(:attempt_count, 0)
    |> validate_persistence()
    |> unique_constraint([:scan_id, :ref_name, :object_oid],
      name: :lfs_pointer_scan_work_items_scan_ref_oid_index
    )
    |> foreign_key_constraint(:scan_id)
  end

  @doc false
  def claim_changeset(work_item, owner, expires_at) do
    work_item
    |> change(
      state: :processing,
      lease_owner: owner,
      lease_expires_at: expires_at,
      attempt_count: work_item.attempt_count + 1
    )
    |> validate_persistence()
  end

  @doc false
  def expansion_changeset(work_item, attrs) do
    work_item
    |> cast(attrs, [
      :object_kind,
      :state,
      :tree_offset,
      :last_expanded_offset,
      :last_result_fingerprint,
      :last_owner
    ])
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
    |> validate_persistence()
  end

  defp validate_persistence(changeset) do
    changeset
    |> validate_required([
      :scan_id,
      :ref_name,
      :object_oid,
      :object_kind,
      :state,
      :tree_offset,
      :attempt_count
    ])
    |> validate_number(:scan_id, greater_than: 0)
    |> validate_length(:ref_name, min: 1, max: 1_024, count: :bytes)
    |> validate_format(:object_oid, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> validate_number(:tree_offset, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_length(:lease_owner, min: 1, max: 255, count: :bytes)
    |> validate_length(:last_result_fingerprint, is: 64)
    |> validate_format(:last_result_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:last_owner, min: 1, max: 255, count: :bytes)
  end
end
