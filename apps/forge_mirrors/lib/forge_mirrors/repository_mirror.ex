defmodule ForgeMirrors.RepositoryMirror do
  use Ecto.Schema

  import Ecto.Changeset

  @states [:discovered, :active, :orphaned, :revoked, :tombstoned]
  @transitions %{
    discovered: [:active, :orphaned, :revoked, :tombstoned],
    active: [:orphaned, :revoked, :tombstoned],
    orphaned: [:active, :revoked, :tombstoned],
    revoked: [:active, :orphaned, :tombstoned],
    tombstoned: []
  }

  @type t :: %__MODULE__{}

  schema "repository_mirrors" do
    field :organization_mirror_id, :integer
    field :repository_id, :integer
    field :github_repository_id, :integer
    field :github_node_id, :string
    field :github_full_name, :string
    field :github_archived, :boolean
    field :inventory_included, :boolean, default: true
    field :inventory_selection, Ecto.Enum, values: [:all, :selected], default: :all
    field :last_inventory_sweep, :string
    field :state, Ecto.Enum, values: @states, default: :discovered
    field :bootstrap_repository_item_id, :integer
    field :last_inventory_at, :utc_datetime
    field :last_synced_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def inventory_create_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :organization_mirror_id,
      :github_repository_id,
      :github_node_id,
      :github_full_name,
      :github_archived,
      :inventory_included,
      :inventory_selection,
      :last_inventory_sweep,
      :last_inventory_at
    ])
    |> put_change(:state, :discovered)
    |> put_change(:lock_version, 1)
    |> validate_inventory()
    |> validate_persistence()
  end

  def inventory_update_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :github_repository_id,
      :github_node_id,
      :github_full_name,
      :github_archived,
      :inventory_included,
      :inventory_selection,
      :last_inventory_sweep,
      :last_inventory_at
    ])
    |> validate_immutable_fields([:github_repository_id, :github_node_id])
    |> maybe_restore_remote_only()
    |> validate_inventory()
    |> validate_persistence()
  end

  def states, do: @states
  def transitions, do: @transitions
  def legal_transition?(state, target), do: target in Map.get(@transitions, state, [])

  def create_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :organization_mirror_id,
      :repository_id,
      :github_repository_id,
      :github_node_id,
      :github_full_name,
      :bootstrap_repository_item_id,
      :last_inventory_at
    ])
    |> put_change(:state, :discovered)
    |> put_change(:lock_version, 1)
    |> validate_persistence()
  end

  def update_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :repository_id,
      :github_repository_id,
      :github_node_id,
      :github_full_name,
      :bootstrap_repository_item_id,
      :last_inventory_at,
      :last_synced_at
    ])
    |> validate_immutable_fields([
      :repository_id,
      :github_repository_id,
      :github_node_id,
      :bootstrap_repository_item_id
    ])
    |> validate_persistence()
  end

  def transition_changeset(mirror, target) when target in @states do
    mirror
    |> change(state: target)
    |> validate_persistence()
  end

  def transition_changeset(mirror, _target),
    do: mirror |> change() |> add_error(:state, "is invalid")

  defp validate_persistence(changeset) do
    changeset
    |> validate_required([:organization_mirror_id, :state, :lock_version])
    |> validate_number(:github_repository_id, greater_than: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_length(:github_node_id, min: 1, max: 255, count: :bytes)
    |> validate_length(:github_full_name, min: 1, max: 255, count: :bytes)
    |> validate_length(:last_inventory_sweep, min: 1, max: 255, count: :bytes)
    |> validate_trimmed([:github_node_id, :github_full_name])
    |> validate_identity()
    |> unique_constraint(:repository_id,
      name: :repository_mirrors_active_local_repository_index
    )
    |> unique_constraint(:github_repository_id,
      name: :repository_mirrors_active_github_repository_index
    )
  end

  defp validate_inventory(changeset) do
    changeset
    |> validate_required([
      :github_repository_id,
      :github_node_id,
      :github_full_name,
      :github_archived,
      :inventory_included,
      :inventory_selection,
      :last_inventory_sweep,
      :last_inventory_at
    ])
    |> validate_trimmed([:last_inventory_sweep])
  end

  defp maybe_restore_remote_only(changeset) do
    if changeset.data.state == :revoked and is_nil(changeset.data.repository_id) do
      put_change(changeset, :state, :discovered)
    else
      changeset
    end
  end

  defp validate_identity(changeset) do
    local_id = get_field(changeset, :repository_id)
    remote_id = get_field(changeset, :github_repository_id)

    cond do
      is_nil(local_id) and is_nil(remote_id) ->
        add_error(changeset, :repository_id, "requires a local or remote immutable identity")

      get_field(changeset, :state) == :active and (is_nil(local_id) or is_nil(remote_id)) ->
        add_error(changeset, :state, "requires both immutable identities")

      true ->
        changeset
    end
  end

  defp validate_trimmed(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if value == String.trim(value),
          do: [],
          else: [{field, "must not have surrounding whitespace"}]
      end)
    end)
  end

  defp validate_immutable_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case {Map.get(acc.data, field), Map.fetch(acc.changes, field)} do
        {existing, {:ok, replacement}} when not is_nil(existing) and existing != replacement ->
          add_error(acc, field, "is immutable once bound")

        _ ->
          acc
      end
    end)
  end
end
