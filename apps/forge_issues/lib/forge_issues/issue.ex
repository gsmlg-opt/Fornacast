defmodule ForgeIssues.Issue do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:issue, :pull_request]
  @states [:open, :closed]
  @state_reasons [:completed, :not_planned, :reopened]
  @default_capabilities %{
    can_create: false,
    can_comment: false,
    can_edit: false,
    can_close: false,
    can_manage_relationships: false
  }

  schema "issues" do
    field :repository_id, :integer
    field :number, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :title, :string
    field :body, :string
    field :state, Ecto.Enum, values: @states, default: :open
    field :state_reason, Ecto.Enum, values: @state_reasons
    field :author_user_id, :integer
    field :closed_at, :utc_datetime

    field :labels, {:array, :map}, virtual: true, default: []
    field :assignees, {:array, :map}, virtual: true, default: []
    field :author, :map, virtual: true
    field :author_association, :string, virtual: true, default: "NONE"
    field :comment_count, :integer, virtual: true, default: 0
    field :capabilities, :map, virtual: true, default: @default_capabilities

    timestamps(type: :utc_datetime)
  end

  def create_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :body, :state, :state_reason])
    |> validate_required([:repository_id, :number, :kind, :title, :state, :author_user_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:state_reason, @state_reasons)
    |> validate_length(:title, min: 1, max: 256)
    |> reject_null_bytes([:title, :body])
    |> normalize_closed_fields()
    |> unique_constraint([:repository_id, :number])
  end

  def update_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :body, :state, :state_reason])
    |> validate_required([:title, :state])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:state_reason, @state_reasons)
    |> validate_length(:title, min: 1, max: 256)
    |> reject_null_bytes([:title, :body])
    |> normalize_closed_fields()
  end

  defp normalize_closed_fields(changeset) do
    state = get_field(changeset, :state)
    previous_state = changeset.data.state

    changeset
    |> validate_state_reason(state)
    |> case do
      changeset when state == :closed and previous_state != :closed ->
        put_change(changeset, :closed_at, DateTime.utc_now() |> DateTime.truncate(:second))

      changeset when state == :open and previous_state == :closed ->
        put_change(changeset, :closed_at, nil)

      changeset ->
        changeset
    end
  end

  defp validate_state_reason(changeset, :closed) do
    if get_field(changeset, :state_reason) in [nil, :completed, :not_planned],
      do: changeset,
      else: add_error(changeset, :state_reason, "is only valid when open")
  end

  defp validate_state_reason(changeset, :open) do
    if get_field(changeset, :state_reason) in [nil, :reopened],
      do: changeset,
      else: add_error(changeset, :state_reason, "is only valid when closed")
  end

  defp validate_state_reason(changeset, _state), do: changeset

  defp reject_null_bytes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and :binary.match(value, <<0>>) != :nomatch,
          do: [{field, "must not contain NUL bytes"}],
          else: []
      end)
    end)
  end
end
