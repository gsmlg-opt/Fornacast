defmodule ForgePulls.Import do
  @moduledoc false

  alias Ecto.Multi
  alias ForgeAccounts.GitHubIdentity
  alias ForgeIssues.Issue
  alias ForgePulls.PullRequest
  alias ForgeRepos.Repository

  @spec import_pull_request_multi(
          Multi.t(),
          Multi.name(),
          Repository.t(),
          Issue.t(),
          GitHubIdentity.t() | nil,
          map()
        ) :: Multi.t()
  def import_pull_request_multi(
        multi,
        key,
        %Repository{} = repository,
        %Issue{} = canonical_issue,
        merger_identity,
        attrs
      )
      when is_map(attrs) do
    Multi.insert(multi, key, fn _changes ->
      attrs = Map.merge(attrs, merger_fields(merger_identity))

      %PullRequest{
        issue_id: canonical_issue.id,
        repository_id: repository.id
      }
      |> PullRequest.import_changeset(attrs, canonical_issue, repository)
    end)
  end

  defp merger_fields(nil), do: %{}

  defp merger_fields(%GitHubIdentity{id: identity_id}) do
    %{merged_by_github_identity_id: identity_id, merged_by_user_id: nil}
  end
end
