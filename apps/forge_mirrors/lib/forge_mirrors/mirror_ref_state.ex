defmodule ForgeMirrors.MirrorRefState do
  @moduledoc """
  Persisted confirmed-ref baseline. Ref transition policy arrives with the Git sync engine.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "mirror_ref_states" do
    field :repository_mirror_id, :integer
    field :ref_name, :string
    field :ref_kind, Ecto.Enum, values: [:branch, :tag]
    field :confirmed_oid, :string
    field :last_local_oid, :string
    field :last_remote_oid, :string
    field :state, Ecto.Enum, values: [:pending, :confirmed, :conflicted, :deleted, :degraded]
    field :last_confirmed_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def persistence_changeset(state, attrs) do
    state
    |> cast(attrs, [
      :repository_mirror_id,
      :ref_name,
      :ref_kind,
      :confirmed_oid,
      :last_local_oid,
      :last_remote_oid,
      :state,
      :last_confirmed_at,
      :lock_version
    ])
    |> validate_required([:repository_mirror_id, :ref_name, :ref_kind, :state, :lock_version])
    |> validate_length(:ref_name, min: 1, max: 1_024, count: :bytes)
    |> validate_number(:lock_version, greater_than: 0)
    |> unique_constraint([:repository_mirror_id, :ref_name])
  end
end
