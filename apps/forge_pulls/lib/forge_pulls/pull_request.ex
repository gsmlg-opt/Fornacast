defmodule ForgePulls.PullRequest do
  use Ecto.Schema

  import Ecto.Changeset

  alias ForgeIssues.Issue

  @mergeable_states [:unknown, :mergeable, :conflicting]

  @type t :: %__MODULE__{}

  schema "pull_requests" do
    field :issue_id, :integer
    field :repository_id, :integer
    field :head_repository_id, :integer
    field :draft, :boolean, default: false
    field :head_ref, :string
    field :base_ref, :string
    field :head_sha, :string
    field :base_sha, :string
    field :mergeable, :boolean
    field :mergeable_state, Ecto.Enum, values: @mergeable_states
    field :merged_at, :utc_datetime
    field :merged_by_user_id, :integer
    field :merged_by_github_identity_id, :integer
    field :merge_commit_sha, :string
    field :merged_by, :map, virtual: true
    field :issue, :map, virtual: true
    field :analysis, :map, virtual: true
    field :capabilities, :map, virtual: true

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{id: nil} = pull_request, attrs) do
    pull_request
    |> cast(attrs, [:issue_id, :repository_id, :head_ref, :base_ref, :head_sha, :base_sha, :draft])
    |> validate_repository_identity(pull_request.repository_id)
    |> same_repository_head()
    |> validate_required([
      :issue_id,
      :repository_id,
      :head_ref,
      :base_ref,
      :head_sha,
      :base_sha,
      :draft
    ])
    |> validate_branch_refs()
    |> validate_distinct_refs()
    |> unique_constraint(:issue_id)
    |> foreign_key_constraint(:head_repository_id)
  end

  def create_changeset(%__MODULE__{} = pull_request, _attrs) do
    pull_request
    |> change()
    |> add_error(:base, "cannot create a persisted pull request")
  end

  def update_changeset(%__MODULE__{} = pull_request, attrs) do
    pull_request
    |> cast(attrs, [:base_ref, :head_sha, :base_sha, :mergeable, :mergeable_state, :draft])
    |> validate_required([:draft])
    |> validate_submitted_head_identity(attrs)
    |> validate_branch_refs()
    |> validate_distinct_refs()
  end

  def import_changeset(
        %__MODULE__{} = pull_request,
        attrs,
        %Issue{} = issue,
        %ForgeRepos.Repository{} = repository
      ) do
    import_changeset(pull_request, attrs, issue, repository, repository.id)
  end

  # Head identity is trusted context input, never provider or user attrs.
  def import_changeset(
        %__MODULE__{} = pull_request,
        attrs,
        %Issue{} = issue,
        %ForgeRepos.Repository{} = repository,
        head_repository_id
      ) do
    pull_request
    |> cast(attrs, [
      :draft,
      :head_ref,
      :base_ref,
      :head_sha,
      :base_sha,
      :mergeable,
      :mergeable_state,
      :merged_at,
      :merged_by_user_id,
      :merged_by_github_identity_id,
      :merge_commit_sha,
      :inserted_at,
      :updated_at
    ])
    |> put_import_head_identity(head_repository_id)
    |> validate_required([
      :draft,
      :issue_id,
      :repository_id,
      :head_ref,
      :base_ref,
      :head_sha,
      :base_sha,
      :inserted_at,
      :updated_at
    ])
    |> validate_canonical_issue(issue, repository)
    |> validate_branch_refs()
    |> validate_distinct_refs()
    |> validate_merged_coherence()
    |> unique_constraint(:issue_id)
    |> foreign_key_constraint(:head_repository_id)
  end

  defp same_repository_head(changeset),
    do: put_change(changeset, :head_repository_id, get_field(changeset, :repository_id))

  defp put_import_head_identity(changeset, head_repository_id) do
    cond do
      not (is_nil(head_repository_id) or
               (is_integer(head_repository_id) and head_repository_id > 0 and
                  head_repository_id <= 9_223_372_036_854_775_807)) ->
        add_error(changeset, :head_repository_id, "must be a positive repository ID or nil")

      not is_nil(changeset.data.id) and
          changeset.data.head_repository_id != head_repository_id ->
        add_error(changeset, :head_repository_id, "is immutable")

      true ->
        put_change(changeset, :head_repository_id, head_repository_id)
    end
  end

  defp validate_submitted_head_identity(changeset, attrs) do
    Enum.reduce([:head_repository_id, "head_repository_id"], changeset, fn key, changeset ->
      case Map.fetch(attrs, key) do
        {:ok, head_id} when head_id != changeset.data.head_repository_id ->
          add_error(changeset, :head_repository_id, "is immutable")

        _ ->
          changeset
      end
    end)
  end

  defp validate_canonical_issue(
         changeset,
         %Issue{} = issue,
         %ForgeRepos.Repository{} = repository
       ) do
    cond do
      issue.kind != :pull_request ->
        add_error(changeset, :issue_id, "must reference a pull request identity")

      issue.repository_id != repository.id ->
        add_error(changeset, :repository_id, "must match the canonical issue repository")

      get_field(changeset, :issue_id) != issue.id ->
        add_error(changeset, :issue_id, "must match the canonical issue")

      true ->
        changeset
    end
  end

  defp validate_merged_coherence(changeset) do
    merged_at = get_field(changeset, :merged_at)
    merge_commit_sha = get_field(changeset, :merge_commit_sha)
    merged_by_user_id = get_field(changeset, :merged_by_user_id)
    merged_by_github_identity_id = get_field(changeset, :merged_by_github_identity_id)

    cond do
      not is_nil(merged_at) and is_nil(merge_commit_sha) ->
        add_error(changeset, :merge_commit_sha, "must be present when merged")

      is_nil(merged_at) and not is_nil(merge_commit_sha) ->
        add_error(changeset, :merged_at, "must be present when merge commit is set")

      not is_nil(merged_by_user_id) and not is_nil(merged_by_github_identity_id) ->
        add_error(changeset, :merged_by_github_identity_id, "must not be set with a local merger")

      is_nil(merged_at) and
          (not is_nil(merged_by_user_id) or not is_nil(merged_by_github_identity_id)) ->
        add_error(changeset, :merged_at, "must be present when a merger is recorded")

      true ->
        changeset
    end
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
    if get_field(changeset, :head_ref) == get_field(changeset, :base_ref) and
         get_field(changeset, :head_repository_id) == get_field(changeset, :repository_id) do
      add_error(changeset, :base_ref, "must differ from head ref")
    else
      changeset
    end
  end
end
