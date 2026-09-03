defmodule ForgeIssues.IssueLabel do
  use Ecto.Schema

  import Ecto.Changeset

  schema "issue_labels" do
    field :issue_id, :integer
    field :label_id, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(issue_label, attrs) do
    issue_label
    |> cast(attrs, [:issue_id, :label_id])
    |> validate_required([:issue_id, :label_id])
    |> unique_constraint([:issue_id, :label_id])
  end

  def import_changeset(issue_label, attrs) do
    issue_label
    |> cast(attrs, [:issue_id, :label_id, :inserted_at, :updated_at])
    |> validate_required([:issue_id, :label_id])
    |> unique_constraint([:issue_id, :label_id])
  end
end
