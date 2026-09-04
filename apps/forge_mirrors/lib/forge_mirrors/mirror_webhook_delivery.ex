defmodule ForgeMirrors.MirrorWebhookDelivery do
  @moduledoc """
  Durable webhook inbox row with lease-owned asynchronous processing state.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @max_raw_payload_bytes 1_048_576
  @states [:pending, :pending_unsupported, :processing, :completed, :failed, :ignored]

  @type t :: %__MODULE__{}

  schema "mirror_webhook_deliveries" do
    field :organization_mirror_id, :integer
    field :delivery_guid, :string
    field :hook_id, :integer
    field :event, :string
    field :action, :string
    field :installation_id, :integer
    field :github_repository_id, :integer
    field :signature_version, :string
    field :raw_payload, :binary, redact: true
    field :state, Ecto.Enum, values: @states
    field :attempt_count, :integer, default: 0
    field :internal_failure_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :received_at, :utc_datetime
    field :processed_at, :utc_datetime
    field :failure_class, :string
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def persistence_changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :organization_mirror_id,
      :delivery_guid,
      :hook_id,
      :event,
      :action,
      :installation_id,
      :github_repository_id,
      :signature_version,
      :raw_payload,
      :state,
      :attempt_count,
      :internal_failure_count,
      :next_attempt_at,
      :lease_owner,
      :lease_expires_at,
      :received_at,
      :processed_at,
      :failure_class,
      :lock_version
    ])
    |> validate_required([
      :delivery_guid,
      :event,
      :signature_version,
      :raw_payload,
      :state,
      :attempt_count,
      :internal_failure_count,
      :next_attempt_at,
      :received_at,
      :lock_version
    ])
    |> validate_length(:raw_payload, max: @max_raw_payload_bytes, count: :bytes)
    |> validate_length(:delivery_guid, min: 1, max: 255, count: :bytes)
    |> validate_length(:event, min: 1, max: 255, count: :bytes)
    |> validate_length(:action, min: 1, max: 255, count: :bytes)
    |> validate_length(:signature_version, min: 1, max: 255, count: :bytes)
    |> validate_length(:lease_owner, min: 1, max: 255, count: :bytes)
    |> validate_length(:failure_class, min: 1, max: 255, count: :bytes)
    |> validate_number(:hook_id, greater_than: 0)
    |> validate_number(:installation_id, greater_than: 0)
    |> validate_number(:github_repository_id, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:internal_failure_count, greater_than_or_equal_to: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> unique_constraint(:delivery_guid)
  end
end
