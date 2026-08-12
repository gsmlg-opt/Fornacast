defmodule ForgeIssues.IssueAssignee do
  use Ecto.Schema

  import Ecto.Changeset

  schema "issue_assignees" do
    field :issue_id, :integer
    field :user_id, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(issue_assignee, attrs) do
    issue_assignee
    |> cast(attrs, [:issue_id, :user_id])
    |> validate_required([:issue_id, :user_id])
    |> unique_constraint([:issue_id, :user_id])
  end
end
