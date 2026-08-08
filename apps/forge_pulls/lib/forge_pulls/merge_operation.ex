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
  @lease_failure_reasons ~w(effect_not_started ref_not_advanced unexpected_ref)
  @lease_mutable_fields [:state, :merge_oid, :failure_reason]
  @oid_regex ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  @type t :: %__MODULE__{}

  schema "pull_merge_operations" do
    field :pull_request_id, :integer
    field :repository_id, :integer
    field :actor_user_id, :integer
    field :request_id, :string
    field :api_version, :string
    field :ip_address, :string
    field :user_agent, :string
    field :token_id, :string
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
      :api_version,
      :ip_address,
      :user_agent,
      :token_id,
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

  def lease_update_changeset(operation, updates) when is_list(updates) do
    if exact_fields?(updates, @lease_mutable_fields) do
      operation
      |> cast(Map.new(updates), @lease_mutable_fields)
      |> normalize_oid(:merge_oid)
      |> validate_oid(:merge_oid)
      |> validate_inclusion(:failure_reason, @lease_failure_reasons)
      |> reject_explicit_nil(:merge_oid)
      |> validate_lease_transition()
      |> validate_failure_reason_transition(operation)
      |> validate_merge_oid_transition()
      |> validate_effective_transition_values(operation)
    else
      operation |> change() |> add_error(:base, "contains immutable fields")
    end
  end

  def lease_update_changeset(operation, _updates),
    do: operation |> change() |> add_error(:base, "is invalid")

  def transition_changeset(operation, state) when is_atom(state) do
    if state in Map.get(@transitions, operation.state, []) do
      change(operation, state: state)
    else
      invalid_transition_changeset(operation)
    end
  end

  def transition_changeset(operation, _state), do: invalid_transition_changeset(operation)

  def merge_written_changeset(operation), do: transition_changeset(operation, :merge_written)

  def merge_written_changeset(%__MODULE__{state: :prepared} = operation, merge_oid) do
    operation
    |> change(state: :merge_written, merge_oid: normalize_oid_value(merge_oid))
    |> validate_required([:merge_oid])
    |> validate_oid(:merge_oid)
  end

  def merge_written_changeset(operation, _merge_oid), do: invalid_transition_changeset(operation)

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

  defp normalize_oid(changeset, field) do
    update_change(changeset, field, fn
      oid when is_binary(oid) -> String.downcase(oid)
      oid -> oid
    end)
  end

  defp validate_oid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@oid_regex, value),
        do: [],
        else: [{field, "is invalid"}]
    end)
  end

  defp reject_explicit_nil(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, nil} -> add_error(changeset, field, "cannot be cleared")
      _ -> changeset
    end
  end

  defp validate_lease_transition(changeset) do
    case fetch_change(changeset, :state) do
      {:ok, target} ->
        source = changeset.data.state

        changeset =
          if target in Map.get(@transitions, source, []) or
               (target == :failed and source in @failure_states),
             do: changeset,
             else: add_error(changeset, :state, "is not a valid transition")

        if target == :failed do
          validate_required(changeset, [:failure_reason])
        else
          changeset
        end

      :error ->
        changeset
    end
  end

  defp validate_merge_oid_transition(changeset) do
    if get_change(changeset, :merge_oid) != nil do
      cond do
        changeset.data.merge_oid != nil ->
          add_error(changeset, :merge_oid, "is already recorded")

        changeset.data.state != :prepared or
            get_change(changeset, :state) not in [nil, :merge_written] ->
          add_error(changeset, :merge_oid, "is not valid in this transition")

        true ->
          changeset
      end
    else
      changeset
    end
  end

  defp validate_failure_reason_transition(changeset, operation) do
    case fetch_change(changeset, :failure_reason) do
      {:ok, reason} ->
        valid? =
          operation.failure_reason == nil and
            case reason do
              "effect_not_started" ->
                operation.state == :prepared and get_change(changeset, :state) == :failed

              "ref_not_advanced" ->
                operation.state == :merge_written and get_change(changeset, :state) == :failed

              "unexpected_ref" ->
                operation.state in [:prepared, :merge_written, :ref_advanced] and
                  get_change(changeset, :state) == nil

              _ ->
                false
            end

        if valid?, do: changeset, else: add_error(changeset, :failure_reason, "is invalid here")

      :error ->
        changeset
    end
  end

  defp validate_effective_transition_values(changeset, operation) do
    case get_change(changeset, :state) do
      :merge_written ->
        if valid_oid?(get_field(changeset, :merge_oid)) do
          changeset
        else
          add_error(changeset, :merge_oid, "is required for merge_written")
        end

      :failed ->
        expected_reason =
          case operation.state do
            :prepared -> "effect_not_started"
            :merge_written -> "ref_not_advanced"
            _ -> nil
          end

        if expected_reason != nil and get_field(changeset, :failure_reason) == expected_reason do
          changeset
        else
          add_error(changeset, :failure_reason, "is invalid for terminal failure")
        end

      _state ->
        changeset
    end
  end

  defp valid_oid?(oid), do: is_binary(oid) and Regex.match?(@oid_regex, oid)

  defp normalize_oid_value(oid) when is_binary(oid), do: String.downcase(oid)
  defp normalize_oid_value(oid), do: oid

  defp exact_fields?(updates, allowed) do
    keys = Keyword.keys(updates)
    keys != [] and length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in allowed))
  end

  defp invalid_transition_changeset(operation) do
    operation |> change() |> add_error(:state, "is not a valid transition")
  end
end
