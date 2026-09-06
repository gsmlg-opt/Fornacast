defmodule ForgeMirrors.MirrorConflict do
  use Ecto.Schema

  import Ecto.Changeset

  @max_snapshot_bytes 2_000_000

  @type t :: %__MODULE__{}

  schema "mirror_conflicts" do
    field :organization_mirror_id, :integer
    field :repository_mirror_id, :integer
    field :resource_kind, :string
    field :resource_identity, :string
    field :conflict_kind, :string
    field :baseline_snapshot, :map, default: %{}
    field :local_snapshot, :map, default: %{}
    field :remote_snapshot, :map, default: %{}
    field :state, Ecto.Enum, values: [:open, :resolved], default: :open
    field :resolution, :map
    field :resolved_by_user_id, :integer
    field :resolved_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def record_changeset(conflict, attrs) do
    conflict
    |> cast(attrs, [
      :organization_mirror_id,
      :repository_mirror_id,
      :resource_kind,
      :resource_identity,
      :conflict_kind,
      :baseline_snapshot,
      :local_snapshot,
      :remote_snapshot
    ])
    |> put_change(:state, :open)
    |> put_change(:lock_version, 1)
    |> validate_required([
      :organization_mirror_id,
      :resource_kind,
      :resource_identity,
      :conflict_kind,
      :baseline_snapshot,
      :local_snapshot,
      :remote_snapshot
    ])
    |> validate_strings()
    |> validate_snapshots()
    |> unique_constraint([:organization_mirror_id, :resource_kind, :resource_identity],
      name: :mirror_conflicts_one_open_identity_index
    )
  end

  def resolve_changeset(conflict, resolution, user_id, now) do
    conflict
    |> change(
      state: :resolved,
      resolution: resolution,
      resolved_by_user_id: user_id,
      resolved_at: now
    )
    |> validate_required([:resolution, :resolved_at])
    |> validate_map(:resolution)
  end

  defp validate_strings(changeset) do
    Enum.reduce([:resource_kind, :resource_identity, :conflict_kind], changeset, fn field, acc ->
      acc
      |> validate_length(field, min: 1, max: 512, count: :bytes)
      |> validate_change(field, fn ^field, value ->
        if value == String.trim(value),
          do: [],
          else: [{field, "must not have surrounding whitespace"}]
      end)
    end)
  end

  defp validate_snapshots(changeset) do
    Enum.reduce(
      [:baseline_snapshot, :local_snapshot, :remote_snapshot],
      changeset,
      &validate_map(&2, &1)
    )
  end

  defp validate_map(changeset, field) do
    limit = if field == :resolution, do: 65_536, else: @max_snapshot_bytes

    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_map(value) -> [{field, "must be an object"}]
        encoded_size(value) > limit -> [{field, "is too large"}]
        true -> []
      end
    end)
  end

  defp encoded_size(value) do
    value |> JSON.encode_to_iodata!() |> IO.iodata_length()
  rescue
    _ -> @max_snapshot_bytes + 1
  end
end
