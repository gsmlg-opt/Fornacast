defmodule ForgeIssues.NumberSequence do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "repository_number_sequences" do
    field :repository_id, :integer, primary_key: true
    field :next_number, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  def changeset(sequence, attrs) do
    sequence
    |> cast(attrs, [:repository_id])
    |> validate_required([:repository_id])
    |> unique_constraint(:repository_id)
  end
end
