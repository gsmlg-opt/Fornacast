defmodule ForgeImports.PatSyncRepositoryResult do
  @moduledoc "Independent, lease-fenced repository outcomes within a PAT sync."
  use Ecto.Schema

  schema "organization_pat_sync_repository_results" do
    field :pat_sync_run_id, :integer
    field :repository_item_id, :integer
    field :item_key, :string
    field :data, :map, default: %{}
    field :state, :string, default: "pending"
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :finished_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
