defmodule ForgePulls.PullRequest do
  use Ecto.Schema

  import Ecto.Changeset

  @mergeable_states [:unknown, :mergeable, :conflicting]

  schema "pull_requests" do
    field :issue_id, :integer
    field :repository_id, :integer
    field :head_ref, :string
    field :base_ref, :string
    field :head_sha, :string
    field :base_sha, :string
    field :mergeable, :boolean
    field :mergeable_state, Ecto.Enum, values: @mergeable_states
    field :merged_at, :utc_datetime
    field :merged_by_user_id, :integer
    field :merge_commit_sha, :string

    timestamps(type: :utc_datetime)
  end

  def create_changeset(pull_request, attrs) do
    pull_request
    |> cast(attrs, [:issue_id, :head_ref, :base_ref, :head_sha, :base_sha])
    |> validate_repository_identity(attrs)
    |> validate_required([:issue_id, :repository_id, :head_ref, :base_ref, :head_sha, :base_sha])
    |> validate_branch_refs()
    |> validate_distinct_refs()
    |> unique_constraint(:issue_id)
  end

  defp validate_repository_identity(changeset, attrs) do
    submitted_repository_id = Map.get(attrs, :repository_id, Map.get(attrs, "repository_id"))
    repository_id = get_field(changeset, :repository_id)

    if not is_nil(submitted_repository_id) and submitted_repository_id != repository_id do
      add_error(changeset, :repository_id, "is immutable")
    else
      changeset
    end
  end

  defp validate_branch_refs(changeset) do
    Enum.reduce([:head_ref, :base_ref], changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, ref ->
        if is_binary(ref) and String.starts_with?(ref, "refs/heads/") and
             byte_size(ref) > byte_size("refs/heads/"),
          do: [],
          else: [{field, "must be a canonical branch ref"}]
      end)
    end)
  end

  defp validate_distinct_refs(changeset) do
    if get_field(changeset, :head_ref) == get_field(changeset, :base_ref) do
      add_error(changeset, :base_ref, "must differ from head ref")
    else
      changeset
    end
  end
end
