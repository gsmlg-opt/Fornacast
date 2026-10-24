defmodule ForgeImports.PatSyncRun do
  @moduledoc "Durable execution and safe progress for an organization PAT synchronization."
  use Ecto.Schema

  schema "organization_pat_sync_runs" do
    field :credential_source, Ecto.Enum,
      values: [:personal, :organization_device, :public],
      default: :personal

    field :requested_by_user_id, :integer
    field :github_organization_id, :integer
    field :organization_connection_id, :integer
    field :organization_connection_version, :integer
    field :organization_credential_id, :integer
    field :organization_credential_version, :integer
    field :github_installation_id, :integer
    field :configuration_id, :integer
    field :public_configuration_version, :integer
    field :organization_id, :integer
    field :owner_user_id, :integer
    field :github_identity_id, :integer
    field :github_organization, :string
    field :import_run_id, :integer
    field :state, :string, default: "queued"
    field :progress, :map, default: %{}
    field :request_metadata, :map, default: %{}
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :started_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :last_progress_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :error, :string
    timestamps(type: :utc_datetime)
  end
end
