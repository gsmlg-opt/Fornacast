defmodule ForgeIssues.IssueAssignee do
  use Ecto.Schema

  import Ecto.Changeset

  schema "issue_assignees" do
    field :issue_id, :integer
    field :user_id, :integer
    field :github_identity_id, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(issue_assignee, attrs) do
    issue_assignee
    |> cast(attrs, [:issue_id, :user_id])
    |> validate_required([:issue_id, :user_id])
    |> unique_constraint([:issue_id, :user_id])
  end

  def import_changeset(issue_assignee, attrs) do
    issue_assignee
    |> cast(attrs, [:issue_id, :github_identity_id, :inserted_at, :updated_at])
    |> validate_required([:issue_id, :github_identity_id])
    |> unique_constraint([:issue_id, :github_identity_id])
  end
end
