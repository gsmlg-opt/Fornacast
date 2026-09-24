defmodule ForgeMirrors.PatConfiguration do
  @moduledoc "Saved PAT synchronization intent. No scheduler consumes this configuration yet."
  use Ecto.Schema
  import Ecto.Changeset

  schema "organization_pat_configurations" do
    field :organization_id, :integer
    field :owner_user_id, :integer
    field :github_identity_id, :integer
    field :github_organization, :string
    field :enabled, :boolean, default: false
    field :paused, :boolean, default: false
    field :trigger_mode, :string, default: "manual"
    field :interval_minutes, :integer, default: 360
    field :last_sync_at, :utc_datetime
    field :last_sync_status, :string
    field :direction, :string, default: "github_to_fornacast"
    field :repository_selection, :string, default: "all"
    field :selected_repository_ids, {:array, :integer}, default: []
    field :inventory, :map, default: %{}
    field :inventory_refreshed_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :owner_user_id,
      :github_identity_id,
      :github_organization,
      :enabled,
      :paused,
      :trigger_mode,
      :interval_minutes
    ])
    |> update_change(:github_organization, &String.downcase(String.trim(&1)))
    |> validate_required([:github_organization, :enabled])
    |> validate_format(
      :github_organization,
      ~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?\z/
    )
    |> validate_length(:github_organization, max: 39)
    |> validate_inclusion(:trigger_mode, ["manual", "interval"])
    |> validate_number(:interval_minutes,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 10_080
    )
    |> unique_constraint(:organization_id)
    |> foreign_key_constraint(:github_identity_id)
    |> foreign_key_constraint(:owner_user_id)
  end
end
