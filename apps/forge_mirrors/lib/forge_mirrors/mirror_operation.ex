defmodule ForgeMirrors.MirrorOperation do
  use Ecto.Schema

  import Ecto.Changeset

  @states [:pending, :processing, :effect_pending, :completed, :failed]
  @failure_dispositions %{
    "credential_revoked" => :terminal,
    "permission_missing" => :degraded,
    "primary_rate_limit" => :retry,
    "secondary_rate_limit" => :retry,
    "network" => :retry,
    "provider_validation" => :terminal,
    "local_validation" => :terminal,
    "stale_baseline" => :conflict,
    "git_divergence" => :conflict,
    "lfs_missing" => :degraded,
    "lfs_integrity" => :degraded,
    "namespace_collision" => :conflict,
    "unsupported_resource" => :terminal
  }

  @type t :: %__MODULE__{}

  schema "mirror_operations" do
    field :organization_mirror_id, :integer
    field :repository_mirror_id, :integer
    field :kind, :string
    field :dedupe_key, :string
    field :state, Ecto.Enum, values: @states, default: :pending
    field :cursor, :map, default: %{}
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :failure_class, :string
    field :failure_disposition, Ecto.Enum, values: [:retry, :degraded, :conflict, :terminal]
    field :failure_detail, :string
    field :external_effect_marker, :map
    field :effect_marked_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def terminal_states, do: [:completed, :failed]
  def failure_classes, do: Map.keys(@failure_dispositions)

  def failure_disposition(failure_class) when is_binary(failure_class) do
    Map.fetch(@failure_dispositions, failure_class)
  end

  def failure_disposition(_failure_class), do: :error

  def enqueue_changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :organization_mirror_id,
      :repository_mirror_id,
      :kind,
      :dedupe_key,
      :cursor,
      :next_attempt_at
    ])
    |> put_change(:state, :pending)
    |> put_change(:attempt_count, 0)
    |> put_change(:lock_version, 1)
    |> put_default_due_at()
    |> validate_required([
      :organization_mirror_id,
      :kind,
      :dedupe_key,
      :state,
      :cursor,
      :attempt_count,
      :next_attempt_at,
      :lock_version
    ])
    |> validate_length(:kind, min: 1, max: 255, count: :bytes)
    |> validate_length(:dedupe_key, min: 1, max: 512, count: :bytes)
    |> validate_trimmed([:kind, :dedupe_key])
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_object(:cursor)
    |> unique_constraint(:dedupe_key)
  end

  defp put_default_due_at(changeset) do
    if get_field(changeset, :next_attempt_at),
      do: changeset,
      else: put_change(changeset, :next_attempt_at, DateTime.utc_now(:second))
  end

  defp validate_object(changeset, field) do
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
end
