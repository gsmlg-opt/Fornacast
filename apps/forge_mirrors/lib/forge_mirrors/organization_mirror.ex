defmodule ForgeMirrors.OrganizationMirror do
  use Ecto.Schema

  import Ecto.Changeset

  @states [
    :pending_installation,
    :ready_to_bootstrap,
    :bootstrapping,
    :catching_up,
    :active,
    :paused,
    :degraded,
    :conflicted,
    :revoked
  ]
  @resume_states [
    :ready_to_bootstrap,
    :bootstrapping,
    :catching_up,
    :active,
    :degraded,
    :conflicted
  ]
  @transitions %{
    pending_installation: [:ready_to_bootstrap, :revoked],
    ready_to_bootstrap: [:bootstrapping, :paused, :revoked],
    bootstrapping: [:catching_up, :paused, :degraded, :conflicted, :revoked],
    catching_up: [:active, :paused, :degraded, :conflicted, :revoked],
    active: [:paused, :degraded, :conflicted, :revoked],
    degraded: [:active, :paused, :conflicted, :revoked],
    conflicted: [:active, :paused, :degraded, :revoked],
    paused: @resume_states ++ [:revoked],
    revoked: []
  }

  @type t :: %__MODULE__{}

  schema "organization_mirrors" do
    field :organization_id, :integer
    field :provider, :string
    field :github_installation_id, :integer
    field :github_account_id, :integer
    field :github_account_login, :string
    field :state, Ecto.Enum, values: @states, default: :pending_installation
    field :resume_state, Ecto.Enum, values: @states
    field :capabilities, :map, default: %{}
    field :policy, :map, default: %{}
    field :bootstrap_import_run_id, :integer
    field :last_webhook_at, :utc_datetime
    field :last_reconciled_at, :utc_datetime
    field :next_reconcile_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def transitions, do: @transitions

  def create_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :organization_id,
      :provider,
      :github_installation_id,
      :github_account_id,
      :github_account_login,
      :capabilities,
      :policy,
      :bootstrap_import_run_id,
      :next_reconcile_at
    ])
    |> put_change(:state, :pending_installation)
    |> put_change(:resume_state, nil)
    |> put_change(:lock_version, 1)
    |> validate_persistence()
  end

  def update_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :github_installation_id,
      :github_account_id,
      :github_account_login,
      :capabilities,
      :policy,
      :bootstrap_import_run_id,
      :last_webhook_at,
      :last_reconciled_at,
      :next_reconcile_at
    ])
    |> validate_immutable_fields([
      :github_installation_id,
      :github_account_id,
      :bootstrap_import_run_id
    ])
    |> validate_persistence()
  end

  def transition_changeset(mirror, target, resume_state \\ nil)

  def transition_changeset(mirror, target, resume_state) when target in @states do
    mirror
    |> change(state: target, resume_state: resume_state)
    |> validate_persistence()
  end

  def transition_changeset(mirror, _target, _resume_state),
    do: mirror |> change() |> add_error(:state, "is invalid")

  def legal_transition?(state, target), do: target in Map.get(@transitions, state, [])

  defp validate_persistence(changeset) do
    changeset
    |> validate_required([
      :organization_id,
      :provider,
      :state,
      :capabilities,
      :policy,
      :lock_version
    ])
    |> validate_length(:provider, min: 1, max: 255, count: :bytes)
    |> validate_length(:github_account_login, min: 1, max: 255, count: :bytes)
    |> validate_trimmed([:provider, :github_account_login])
    |> validate_number(:github_installation_id, greater_than: 0)
    |> validate_number(:github_account_id, greater_than: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_map(:capabilities)
    |> validate_map(:policy)
    |> validate_resume_state()
    |> unique_constraint([:organization_id, :provider],
      name: :organization_mirrors_active_organization_provider_index
    )
    |> unique_constraint([:provider, :github_installation_id],
      name: :organization_mirrors_active_installation_index
    )
    |> unique_constraint([:provider, :github_account_id],
      name: :organization_mirrors_active_account_index
    )
  end

  defp validate_resume_state(changeset) do
    state = get_field(changeset, :state)
    resume_state = get_field(changeset, :resume_state)

    if (state == :paused and resume_state in @resume_states) or
         (state != :paused and is_nil(resume_state)) do
      changeset
    else
      add_error(changeset, :resume_state, "does not match the lifecycle state")
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_map(value) -> [{field, "must be an object"}]
        encoded_size(value) > 65_536 -> [{field, "is too large"}]
        true -> []
      end
    end)
  end

  defp encoded_size(value) do
    value |> JSON.encode_to_iodata!() |> IO.iodata_length()
  rescue
    _ -> 65_537
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
