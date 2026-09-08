defmodule ForgeMirrors.MirrorResourceState do
  @moduledoc """
  Persisted immutable resource mapping and baseline. Domain transition policy is owned by later slices.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @max_snapshot_bytes 2_000_000

  schema "mirror_resource_states" do
    field :repository_mirror_id, :integer

    field :resource_kind, Ecto.Enum,
      values: [:repository, :label, :issue, :issue_comment, :pull, :release]

    field :local_resource_type, :string
    field :local_resource_id, :integer
    field :github_object_id, :integer
    field :github_node_id, :string
    field :github_number, :integer
    field :confirmed_local_version, :integer
    field :confirmed_remote_updated_at, :utc_datetime
    field :confirmed_fingerprint, :string
    field :confirmed_snapshot, :map
    field :confirmed_merge_state, :map
    field :provider_identity, :map
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
      :confirmed_snapshot,
      :confirmed_merge_state,
      :provider_identity,
      :state,
      :lock_version
    ])
    |> validate_required([:repository_mirror_id, :resource_kind, :state, :lock_version])
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_change(:confirmed_snapshot, &validate_snapshot/2)
    |> validate_change(:confirmed_merge_state, &validate_metadata/2)
    |> validate_change(:provider_identity, &validate_metadata/2)
    |> immutable_provider_identity(state)
    |> check_constraint(:confirmed_snapshot, name: :mirror_resource_states_snapshot_check)
    |> check_constraint(:provider_identity, name: :mirror_resource_states_provider_identity_check)
    |> check_constraint(:confirmed_merge_state,
      name: :mirror_resource_states_confirmed_merge_state_check
    )
    |> validate_identity()
  end

  defp immutable_provider_identity(changeset, %{provider_identity: identity})
       when not is_nil(identity) do
    if get_field(changeset, :provider_identity) == identity,
      do: changeset,
      else: add_error(changeset, :provider_identity, "is immutable")
  end

  defp immutable_provider_identity(changeset, _), do: changeset

  defp validate_metadata(field, value) do
    if is_map(value) and byte_size(JSON.encode!(value)) <= 16_384,
      do: [],
      else: [{field, "must be a JSON object of at most 16384 encoded bytes"}]
  rescue
    _ -> [{field, "must be a JSON object"}]
  end

  defp validate_snapshot(field, snapshot) do
    if byte_size(JSON.encode!(snapshot)) <= @max_snapshot_bytes,
      do: [],
      else: [{field, "must be at most #{@max_snapshot_bytes} encoded bytes"}]
  rescue
    _invalid -> [{field, "must be a JSON object"}]
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
