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
    field :issue, :map, virtual: true

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{id: nil} = pull_request, attrs) do
    pull_request
    |> cast(attrs, [:issue_id, :repository_id, :head_ref, :base_ref, :head_sha, :base_sha])
    |> validate_repository_identity(pull_request.repository_id)
    |> validate_required([:issue_id, :repository_id, :head_ref, :base_ref, :head_sha, :base_sha])
    |> validate_branch_refs()
    |> validate_distinct_refs()
    |> unique_constraint(:issue_id)
  end

  def create_changeset(%__MODULE__{} = pull_request, _attrs) do
    pull_request
    |> change()
    |> add_error(:base, "cannot create a persisted pull request")
  end

  def update_changeset(%__MODULE__{} = pull_request, attrs) do
    pull_request
    |> cast(attrs, [:base_ref, :head_sha, :base_sha, :mergeable, :mergeable_state])
    |> validate_branch_refs()
    |> validate_distinct_refs()
  end

  defp validate_repository_identity(changeset, nil), do: changeset

  defp validate_repository_identity(changeset, repository_id) do
    case fetch_change(changeset, :repository_id) do
      {:ok, submitted_repository_id} when submitted_repository_id != repository_id ->
        changeset
        |> delete_change(:repository_id)
        |> add_error(:repository_id, "is immutable")

      {:ok, ^repository_id} ->
        changeset

      :error ->
        changeset
    end
  end

  defp validate_branch_refs(changeset) do
    Enum.reduce([:head_ref, :base_ref], changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, ref ->
        if canonical_branch_ref?(ref),
          do: [],
          else: [{field, "must be a canonical branch ref"}]
      end)
    end)
  end

  # This follows Git's check-ref-format rules for branch names without invoking Git.
  defp canonical_branch_ref?("refs/heads/" <> name) do
    name != "" and
      not String.contains?(name, ["..", "@{"]) and
      not String.ends_with?(name, ".") and
      not Regex.match?(~r/[\x00-\x20\x7f ~^:?*\[\\]/u, name) and
      Enum.all?(String.split(name, "/"), fn component ->
        component not in ["", ".", ".."] and not String.starts_with?(component, ".") and
          not String.ends_with?(component, ".lock")
      end)
  end

  defp canonical_branch_ref?(_ref), do: false

  defp validate_distinct_refs(changeset) do
    if get_field(changeset, :head_ref) == get_field(changeset, :base_ref) do
      add_error(changeset, :base_ref, "must differ from head ref")
    else
      changeset
    end
  end
end
