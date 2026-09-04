defmodule Fornacast.DomainOutboxEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @states [:pending, :processing, :completed, :failed]
  @terminal_states [:completed, :failed]
  @origins [:fornacast, :github, :system]
  @max_string_bytes 255
  @max_payload_bytes 65_536

  @type t :: %__MODULE__{}

  schema "domain_outbox_events" do
    field :event_id, :string
    field :aggregate_type, :string
    field :aggregate_id, :string
    field :event_type, :string
    field :origin, Ecto.Enum, values: @origins
    field :causation_id, :string
    field :correlation_id, :string
    field :payload, :map, default: %{}
    field :state, Ecto.Enum, values: @states, default: :pending
    field :attempt_count, :integer, default: 0
    field :available_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def terminal_states, do: @terminal_states

  def record_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :aggregate_type,
      :aggregate_id,
      :event_type,
      :origin,
      :causation_id,
      :correlation_id,
      :payload,
      :available_at
    ])
    |> put_change(:state, :pending)
    |> put_change(:attempt_count, 0)
    |> put_change(:lock_version, 0)
    |> put_default_available_at()
    |> validate_required([
      :event_id,
      :aggregate_type,
      :aggregate_id,
      :event_type,
      :origin,
      :payload,
      :state,
      :attempt_count,
      :available_at
    ])
    |> validate_strings()
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_payload()
    |> unique_constraint(:event_id)
    |> check_constraint(:payload,
      name: :domain_outbox_events_payload_check,
      message: "is too large"
    )
  end

  defp put_default_available_at(changeset) do
    case get_field(changeset, :available_at) do
      nil -> put_change(changeset, :available_at, DateTime.utc_now(:second))
      _available_at -> changeset
    end
  end

  defp validate_strings(changeset) do
    Enum.reduce(
      [
        :event_id,
        :aggregate_type,
        :aggregate_id,
        :event_type,
        :causation_id,
        :correlation_id
      ],
      changeset,
      fn field, changeset ->
        changeset
        |> validate_length(field, min: 1, max: @max_string_bytes, count: :bytes)
        |> validate_change(field, fn ^field, value ->
          if value == String.trim(value),
            do: [],
            else: [{field, "must not have surrounding whitespace"}]
        end)
      end
    )
  end

  defp validate_payload(changeset) do
    validate_change(changeset, :payload, fn :payload, payload ->
      cond do
        not is_map(payload) ->
          [payload: "must be an object"]

        encoded_payload_size(payload) > @max_payload_bytes ->
          [payload: "is too large"]

        true ->
          []
      end
    end)
  end

  defp encoded_payload_size(payload) do
    payload
    |> JSON.encode_to_iodata!()
    |> IO.iodata_length()
  rescue
    _error -> @max_payload_bytes + 1
  end
end
