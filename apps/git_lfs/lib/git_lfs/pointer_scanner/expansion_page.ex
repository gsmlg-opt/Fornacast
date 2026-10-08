defmodule GitLFS.PointerScanner.ExpansionPage do
  use Ecto.Schema

  import Ecto.Changeset

  @format_version 1

  schema "lfs_pointer_scan_expansion_pages" do
    field(:scan_id, :integer)
    field(:object_oid, :string)
    field(:tree_offset, :integer)
    field(:batch_limit, :integer)
    field(:format_version, :integer)
    field(:object_kind, Ecto.Enum, values: [:commit, :tree, :blob, :tag])
    field(:children, {:array, :map}, default: [])
    field(:candidate_data, :binary)
    field(:candidate_size, :integer)
    field(:next_offset, :integer)
    field(:result_fingerprint, :string)

    timestamps(type: :utc_datetime)
  end

  def format_version, do: @format_version

  def changeset(page, attrs) do
    page
    |> cast(
      attrs,
      [
        :scan_id,
        :object_oid,
        :tree_offset,
        :batch_limit,
        :format_version,
        :object_kind,
        :children,
        :candidate_data,
        :candidate_size,
        :next_offset,
        :result_fingerprint
      ],
      empty_values: []
    )
    |> validate_required([
      :scan_id,
      :object_oid,
      :tree_offset,
      :batch_limit,
      :format_version,
      :object_kind,
      :result_fingerprint
    ])
    |> validate_number(:scan_id, greater_than: 0)
    |> validate_format(:object_oid, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
    |> validate_number(:tree_offset, greater_than_or_equal_to: 0)
    |> validate_number(:batch_limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 200)
    |> validate_number(:format_version, equal_to: @format_version)
    |> validate_length(:children, max: 200)
    |> validate_length(:candidate_data, max: 1_024, count: :bytes)
    |> validate_number(:candidate_size, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_024)
    |> validate_number(:next_offset, greater_than_or_equal_to: 0)
    |> validate_format(:result_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:scan_id, :object_oid, :tree_offset, :batch_limit, :format_version],
      name: :lfs_pointer_scan_expansion_pages_key_index
    )
    |> foreign_key_constraint(:scan_id)
  end
end
