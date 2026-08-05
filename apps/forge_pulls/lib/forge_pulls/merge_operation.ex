defmodule ForgePulls.MergeOperation do
  use Ecto.Schema

  import Ecto.Changeset

  @states [:prepared, :merge_written, :ref_advanced, :completed, :failed]
  @transitions %{
    prepared: [:merge_written],
    merge_written: [:ref_advanced],
    ref_advanced: [:completed]
  }
  @failure_states [:prepared, :merge_written]

  schema "pull_merge_operations" do
    field :pull_request_id, :integer
    field :repository_id, :integer
    field :actor_user_id, :integer
    field :request_id, :string
    field :base_ref, :string
    field :head_ref, :string
    field :expected_base_oid, :string
    field :expected_head_oid, :string
    field :merge_oid, :string
    field :failure_reason, :string
    field :state, Ecto.Enum, values: @states
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def prepare_changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :pull_request_id,
      :repository_id,
      :actor_user_id,
      :request_id,
      :base_ref,
      :head_ref,
      :expected_base_oid,
      :expected_head_oid,
      :state,
      :lease_owner,
      :lease_expires_at
    ])
    |> validate_required([
      :pull_request_id,
      :repository_id,
      :request_id,
      :base_ref,
      :head_ref,
      :expected_base_oid,
      :expected_head_oid,
      :state
    ])
    |> validate_inclusion(:state, [:prepared])
  end

  def transition_changeset(operation, state) when is_atom(state) do
    if state in Map.get(@transitions, operation.state, []) do
      change(operation, state: state)
    else
      invalid_transition_changeset(operation)
    end
  end

  def transition_changeset(operation, _state), do: invalid_transition_changeset(operation)

  def merge_written_changeset(operation), do: transition_changeset(operation, :merge_written)

  def ref_advanced_changeset(operation), do: transition_changeset(operation, :ref_advanced)

  def completed_changeset(operation), do: transition_changeset(operation, :completed)

  def failed_changeset(%__MODULE__{state: state} = operation, reason)
      when state in @failure_states do
    operation
    |> change(state: :failed, failure_reason: sanitize_failure_reason(reason))
    |> validate_required([:failure_reason])
  end

  def failed_changeset(operation, _reason), do: invalid_transition_changeset(operation)

  def public(%__MODULE__{} = operation), do: %{operation | failure_reason: nil}

  def sanitize_failure_reason(reason) when is_binary(reason) do
    reason
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 512)
  end

  def sanitize_failure_reason(_reason), do: nil

  defp invalid_transition_changeset(operation) do
    operation |> change() |> add_error(:state, "is not a valid transition")
  end
end
