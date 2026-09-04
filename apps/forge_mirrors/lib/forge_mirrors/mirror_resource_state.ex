defmodule ForgeMirrors.MirrorResourceState do
  @moduledoc """
  Persisted immutable resource mapping and baseline. Domain transition policy is owned by later slices.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "mirror_resource_states" do
    field :repository_mirror_id, :integer

    field :resource_kind, Ecto.Enum,
      values: [:repository, :issue, :issue_comment, :pull, :release]

    field :local_resource_type, :string
    field :local_resource_id, :integer
    field :github_object_id, :integer
    field :github_node_id, :string
    field :github_number, :integer
    field :confirmed_local_version, :integer
    field :confirmed_remote_updated_at, :utc_datetime
    field :confirmed_fingerprint, :string
    field :state, Ecto.Enum, values: [:pending, :confirmed, :conflicted, :deleted, :unsupported]
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def persistence_changeset(state, attrs) do
    state
    |> cast(attrs, [
      :repository_mirror_id,
      :resource_kind,
      :local_resource_type,
      :local_resource_id,
      :github_object_id,
      :github_node_id,
      :github_number,
      :confirmed_local_version,
      :confirmed_remote_updated_at,
      :confirmed_fingerprint,
      :state,
      :lock_version
    ])
    |> validate_required([:repository_mirror_id, :resource_kind, :state, :lock_version])
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_identity()
  end

  defp validate_identity(changeset) do
    if Enum.any?(
         [:local_resource_id, :github_object_id, :github_node_id, :github_number],
         fn field ->
           not is_nil(get_field(changeset, field))
         end
       ) do
      changeset
    else
      add_error(changeset, :local_resource_id, "requires an immutable identity")
    end
  end
end
