defmodule ForgeAccounts.OrganizationMember do
  use Ecto.Schema

  import Ecto.Changeset

  @roles [:owner, :member]

  schema "organization_members" do
    field :organization_id, :integer
    field :user_id, :integer
    field :role, Ecto.Enum, values: @roles, default: :member

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:organization_id, :user_id, :role])
    |> validate_required([:organization_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:organization_id, :user_id])
  end
end
