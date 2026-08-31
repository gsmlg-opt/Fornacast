defmodule ForgeRepos.Collaborator do
  use Ecto.Schema

  import Ecto.Changeset

  @roles [:read, :write, :admin]

  schema "repository_collaborators" do
    field :repository_id, :integer
    field :user_id, :integer
    field :role, Ecto.Enum, values: @roles

    timestamps(type: :utc_datetime)
  end

  def changeset(collaborator, attrs) do
    collaborator
    |> cast(attrs, [:repository_id, :user_id, :role])
    |> validate_required([:repository_id, :user_id, :role])
    |> validate_number(:repository_id, greater_than: 0)
    |> validate_number(:user_id, greater_than: 0)
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:repository_id, :user_id])
  end
end
