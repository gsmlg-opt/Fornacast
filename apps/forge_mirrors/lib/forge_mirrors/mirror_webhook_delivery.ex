defmodule ForgeMirrors.MirrorWebhookDelivery do
  @moduledoc """
  Durable webhook inbox row. Signature verification and delivery processing arrive in PR6.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "mirror_webhook_deliveries" do
    field :organization_mirror_id, :integer
    field :delivery_guid, :string
    field :hook_id, :integer
    field :event, :string
    field :action, :string
    field :installation_id, :integer
    field :github_repository_id, :integer
    field :signature_version, :string
    field :raw_payload, :map
    field :state, Ecto.Enum, values: [:pending, :processing, :completed, :failed]
    field :attempt_count, :integer, default: 0
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
      :next_attempt_at,
      :lease_owner,
      :lease_expires_at,
      :received_at,
      :processed_at,
      :failure_class,
      :lock_version
    ])
    |> validate_required([
      :organization_mirror_id,
      :delivery_guid,
      :event,
      :installation_id,
      :signature_version,
      :raw_payload,
      :state,
      :attempt_count,
      :next_attempt_at,
      :received_at,
      :lock_version
    ])
    |> unique_constraint(:delivery_guid)
  end
end
