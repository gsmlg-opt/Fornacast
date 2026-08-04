defmodule ForgeIssues.Label do
  use Ecto.Schema

  import Ecto.Changeset

  schema "repository_labels" do
    field :repository_id, :integer
    field :name, :string
    field :normalized_name, :string
    field :color, :string
    field :description, :string
    field :default, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:repository_id, :name, :normalized_name, :color, :description, :default])
    |> update_change(:normalized_name, &(String.trim(&1) |> String.downcase()))
    |> validate_required([:repository_id, :name, :normalized_name, :color, :default])
    |> validate_format(:color, ~r/^[0-9a-f]{6}$/)
    |> unique_constraint([:repository_id, :normalized_name])
  end
end
