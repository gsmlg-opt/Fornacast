defmodule Fornacast.AuditEvent do
  use Ecto.Schema

  import Ecto.Changeset

  schema "audit_events" do
    field :actor_user_id, :integer
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    field :metadata, :map, default: %{}
    field :ip_address, :string
    field :user_agent, :string

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [
      :actor_user_id,
      :action,
      :target_type,
      :target_id,
      :metadata,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:action, :target_type, :metadata])
    |> validate_length(:action, min: 1, max: 120)
    |> validate_length(:target_type, min: 1, max: 120)
  end
end
