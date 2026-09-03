defmodule ForgeIssues.Import do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts.GitHubIdentity

  alias ForgeIssues.{
    Comment,
    DefaultLabels,
    Issue,
    IssueAssignee,
    IssueLabel,
    Label,
    NumberSequence
  }

  alias ForgeRepos.Repository

  @spec import_label_multi(Multi.t(), Multi.name(), Repository.t(), map()) :: Multi.t()
  def import_label_multi(multi, key, %Repository{} = repository, attrs) when is_map(attrs) do
    Multi.run(multi, key, fn repo, _changes ->
      normalized_name = DefaultLabels.normalize_name(Map.fetch!(attrs, :name))

      case repo.get_by(Label,
             repository_id: repository.id,
             normalized_name: normalized_name
           ) do
        nil ->
          attrs =
            attrs
            |> Map.put(:repository_id, repository.id)
            |> Map.put(:normalized_name, normalized_name)
            |> Map.put_new(:default, false)

          %Label{}
          |> Label.import_changeset(attrs)
          |> repo.insert()

        %Label{} = existing ->
          if label_compatible?(existing, attrs) do
            {:ok, existing}
          else
            {:error, :label_normalization_conflict}
          end
      end
    end)
  end

  @spec import_identity_multi(
          Multi.t(),
          Multi.name(),
          Repository.t(),
          GitHubIdentity.t(),
          :issue | :pull_request,
          map()
        ) :: Multi.t()
  def import_identity_multi(
        multi,
        key,
        %Repository{} = repository,
        %GitHubIdentity{} = identity,
        kind,
        attrs
      )
      when kind in [:issue, :pull_request] and is_map(attrs) do
    Multi.insert(multi, key, fn _changes ->
      %Issue{
        repository_id: repository.id,
        kind: kind,
        author_github_identity_id: identity.id
      }
      |> Issue.import_changeset(attrs)
    end)
  end

  @spec import_comment_multi(
          Multi.t(),
          Multi.name(),
          Issue.t(),
          GitHubIdentity.t(),
          map()
        ) :: Multi.t()
  def import_comment_multi(multi, key, %Issue{} = issue, %GitHubIdentity{} = identity, attrs)
      when is_map(attrs) do
    Multi.insert(multi, key, fn _changes ->
      %Comment{
        issue_id: issue.id,
        author_github_identity_id: identity.id
      }
      |> Comment.import_changeset(attrs)
    end)
  end

  @spec import_issue_label_multi(Multi.t(), Multi.name(), Issue.t(), Label.t(), map()) ::
          Multi.t()
  def import_issue_label_multi(multi, key, %Issue{} = issue, %Label{} = label, attrs \\ %{}) do
    Multi.insert(multi, key, fn _changes ->
      attrs =
        attrs
        |> Map.put(:issue_id, issue.id)
        |> Map.put(:label_id, label.id)

      %IssueLabel{}
      |> IssueLabel.import_changeset(attrs)
    end)
  end

  @spec import_assignee_multi(
          Multi.t(),
          Multi.name(),
          Issue.t(),
          GitHubIdentity.t(),
          map()
        ) :: Multi.t()
  def import_assignee_multi(
        multi,
        key,
        %Issue{} = issue,
        %GitHubIdentity{} = identity,
        attrs \\ %{}
      ) do
    Multi.insert(multi, key, fn _changes ->
      attrs =
        attrs
        |> Map.put(:issue_id, issue.id)
        |> Map.put(:github_identity_id, identity.id)

      %IssueAssignee{}
      |> IssueAssignee.import_changeset(attrs)
    end)
  end

  @spec finalize_import_sequence_multi(Multi.t(), Multi.name(), Repository.t()) :: Multi.t()
  def finalize_import_sequence_multi(multi, key, %Repository{} = repository) do
    Multi.run(multi, key, fn repo, _changes ->
      highest =
        Issue
        |> where([issue], issue.repository_id == ^repository.id)
        |> select([issue], max(issue.number))
        |> repo.one()

      next_number = (highest || 0) + 1
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case repo.get(NumberSequence, repository.id) do
        nil ->
          %NumberSequence{repository_id: repository.id, next_number: next_number}
          |> NumberSequence.finalize_changeset(%{next_number: next_number})
          |> repo.insert()

        %NumberSequence{} = sequence ->
          sequence
          |> NumberSequence.finalize_changeset(%{next_number: next_number, updated_at: now})
          |> repo.update()
      end
    end)
  end

  defp label_compatible?(existing, attrs) do
    existing.color == Map.get(attrs, :color) and
      (Map.get(attrs, :description) in [nil, existing.description] or
         existing.description == Map.get(attrs, :description))
  end
end
