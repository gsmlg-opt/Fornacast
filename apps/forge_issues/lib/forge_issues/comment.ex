defmodule ForgeIssues.Comment do
  use Ecto.Schema

  import Ecto.Changeset

  @default_capabilities %{can_edit: false, can_delete: false}

  schema "issue_comments" do
    field :issue_id, :integer
    field :author_user_id, :integer
    field :author_github_identity_id, :integer
    field :body, :string

    field :author, :map, virtual: true
    field :author_association, :string, virtual: true, default: "NONE"
    field :issue_number, :integer, virtual: true
    field :capabilities, :map, virtual: true, default: @default_capabilities

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:issue_id, :author_user_id, :body])
    |> validate_required([:issue_id, :author_user_id, :body])
    |> validate_length(:body, min: 1)
    |> validate_no_nul(:body)
  end

  def update_changeset(comment, attrs) when is_map(attrs) do
    changeset = cast(comment, attrs, [:body])

    changeset =
      if Map.has_key?(attrs, "body") or Map.has_key?(attrs, :body),
        do: changeset,
        else: add_error(changeset, :body, "can't be blank")

    changeset
    |> validate_required([:body])
    |> validate_length(:body, min: 1)
    |> validate_no_nul(:body)
  end

  def import_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :author_github_identity_id, :inserted_at, :updated_at])
    |> validate_required([
      :issue_id,
      :body,
      :author_github_identity_id,
      :inserted_at,
      :updated_at
    ])
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
