defmodule ForgeIssues.Comment do
  use Ecto.Schema

  import Ecto.Changeset

  schema "issue_comments" do
    field :issue_id, :integer
    field :author_user_id, :integer
    field :body, :string

    field :author, :map, virtual: true
    field :author_association, :string, virtual: true, default: "NONE"

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:issue_id, :author_user_id, :body])
    |> validate_required([:issue_id, :author_user_id, :body])
    |> validate_length(:body, min: 1)
    |> validate_no_nul(:body)
  end

  defp validate_no_nul(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and :binary.match(value, <<0>>) != :nomatch,
        do: [{field, "must not contain NUL bytes"}],
        else: []
    end)
  end
end
