defmodule ForgeIssues.Fixtures do
  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  def pull_extension_fixture(%ForgeIssues.Issue{kind: :pull_request} = issue) do
    now = DateTime.utc_now(:second)

    {1, _} =
      Repo.insert_all("pull_requests", [
        %{
          issue_id: issue.id,
          repository_id: issue.repository_id,
          head_repository_id: issue.repository_id,
          draft: false,
          head_ref: "refs/heads/feature",
          base_ref: "refs/heads/main",
          head_sha: String.duplicate("a", 40),
          base_sha: String.duplicate("b", 40),
          inserted_at: now,
          updated_at: now
        }
      ])

    issue
  end

  def reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        unless Process.get(:forge_issues_sandbox_checked_out) do
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
          Process.put(:forge_issues_sandbox_checked_out, true)
        end

      value when value in ["libsql", "turso"] ->
        reset_turso_database!()
        ExUnit.Callbacks.on_exit(&reset_turso_database!/0)
    end

    :ok
  end

  def user_fixture(username, attrs \\ %{}) when is_binary(username) and is_map(attrs) do
    {:ok, %User{} = user} =
      ForgeAccounts.create_user(
        Map.merge(
          %{
            username: username,
            email: "#{username}@example.test",
            password: "correct horse battery staple"
          },
          attrs
        )
      )

    user
  end

  def repository_fixture(owner, attrs \\ %{}) when is_map(attrs) do
    slug = Map.get(attrs, :slug, "repository-#{System.unique_integer([:positive])}")

    {:ok, %Repository{} = repository} =
      ForgeRepos.create_repository(
        owner,
        Map.merge(%{slug: slug, name: slug, visibility: :private}, attrs)
      )

    repository
  end

  defp reset_turso_database! do
    Enum.each(
      [
        "issue_assignees",
        "issue_labels",
        "issue_comments",
        "issues",
        "repository_labels",
        "repository_number_sequences",
        "audit_events",
        "repository_collaborators",
        "repositories",
        "organization_members",
        "api_keys",
        "ssh_keys",
        "github_credentials",
        "github_identities",
        "users"
      ],
      &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", [])
    )
  end
end
