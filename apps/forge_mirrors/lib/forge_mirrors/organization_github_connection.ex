defmodule ForgeMirrors.OrganizationGitHubConnection do
  @moduledoc "An organization-owned App user grant's verified installation binding."
  use Ecto.Schema
  import Ecto.Changeset

  schema "organization_github_connections" do
    field :organization_id, :integer
    field :credential_id, :integer
    field :credential_version, :integer
    field :github_app_id, :integer
    field :client_id, :string
    field :github_organization_id, :integer
    field :github_organization, :string
    field :installation_id, :integer
    field :inventory, :map, default: %{}
    field :permissions, :map, default: %{}
    field :repository_selection, :string

    field :state, Ecto.Enum,
      values: [:installation_required, :ready, :permissions_missing, :disconnected],
      default: :installation_required

    field :observed_at, :utc_datetime
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :credential_id,
      :credential_version,
      :github_app_id,
      :client_id,
      :github_organization_id,
      :github_organization,
      :installation_id,
      :inventory,
      :permissions,
      :repository_selection,
      :state,
      :observed_at,
      :lock_version
    ])
    |> validate_required([
      :organization_id,
      :credential_id,
      :credential_version,
      :github_app_id,
      :client_id,
      :state
    ])
    |> unique_constraint(:organization_id)
    |> unique_constraint(:installation_id)
    |> check_constraint(:state, name: :organization_github_connection_shape)
  end
end
