defmodule ForgeReleases.Fixtures do
  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  def reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        unless Process.get(:forge_releases_sandbox_checked_out) do
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
          Process.put(:forge_releases_sandbox_checked_out, true)
        end

      value when value in ["libsql", "turso"] ->
        reset_turso_database!()
        ExUnit.Callbacks.on_exit(&reset_turso_database!/0)
    end

    :ok
  end

  def user_fixture(username) when is_binary(username) do
    {:ok, %User{} = user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  def repository_fixture(owner, attrs \\ %{}) when is_struct(owner, User) and is_map(attrs) do
    slug = Map.get(attrs, :slug, "releases-#{System.unique_integer([:positive])}")

    {:ok, %Repository{} = repository} =
      ForgeRepos.create_repository(
        owner,
        Map.merge(
          %{slug: slug, name: slug, visibility: :private, default_branch: "main"},
          attrs
        )
      )

    repository
  end

  def put_tag(repository, name) when is_struct(repository, Repository) and is_binary(name) do
    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    commit = git!(path, ["commit-tree", tree, "-m", "release #{name}"])
    _output = git!(path, ["update-ref", "refs/tags/#{name}", commit])
    commit
  end

  def delete_tag(repository, name) when is_struct(repository, Repository) and is_binary(name) do
    path = ForgeRepos.absolute_storage_path(repository)
    _output = git!(path, ["update-ref", "-d", "refs/tags/#{name}"])
    :ok
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Release Test"},
      {"GIT_AUTHOR_EMAIL", "release@example.test"},
      {"GIT_COMMITTER_NAME", "Release Test"},
      {"GIT_COMMITTER_EMAIL", "release@example.test"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true)

    String.trim(output)
  end

  defp reset_turso_database! do
    Enum.each(
      [
        "releases",
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
