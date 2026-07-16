defmodule ForgeReposTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.Organization
  alias Fornacast.Repo
  alias ForgeRepos.Repository

  setup do
    reset_database!()
  end

  test "repository slugs are normalized and validated" do
    assert Repository.normalize_slug("Demo Repo.git") == "demo-repo"

    changeset =
      Repository.create_changeset(
        %Repository{owner_user_id: 1, storage_path: "@hashed/aa/bb/demo.git"},
        %{name: "Demo", slug: "Demo Repo", visibility: :private, default_branch: "main"}
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :slug) == "demo-repo"
  end

  test "git path parser accepts only friendly owner/repo git paths" do
    assert ForgeRepos.parse_git_path("alice/demo.git") == {:ok, "alice", "demo"}
    assert ForgeRepos.parse_git_path("/alice/demo.git") == {:error, :invalid_path}
    assert ForgeRepos.parse_git_path("alice/../../demo.git") == {:error, :invalid_path}
    assert ForgeRepos.parse_git_path("alice/demo.git; rm -rf /") == {:error, :invalid_path}
  end

  test "organization-owned repositories resolve by namespace and use actor in clone URLs" do
    assert {:ok, owner} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-org-repo@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, member} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-org-repo@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(owner, %{
               username: "Acme",
               display_name: "ACME"
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(organization, %{
               name: "Demo",
               slug: "demo"
             })

    assert repo.owner_user_id == organization.id
    assert {:ok, resolved} = ForgeRepos.resolve_git_path("acme/demo.git")
    assert resolved.id == repo.id
    assert ForgeRepos.get_repository("acme", "demo").id == repo.id

    clone_url = ForgeRepos.ssh_clone_url(repo, organization, owner)
    assert clone_url =~ "ssh://alice@"
    assert clone_url =~ "/acme/demo.git"

    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)
  end

  @tag :tmp_dir
  test "creates a repository record and bare Git storage", %{tmp_dir: tmp_dir} do
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, owner} =
             ForgeAccounts.create_user(%{
               username: "Alice",
               email: "alice@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(owner, %{
               name: "Demo",
               slug: "demo",
               description: "test repository"
             })

    assert repo.owner_user_id == owner.id
    assert repo.slug == "demo"
    assert repo.visibility == :private
    assert String.ends_with?(repo.storage_path, ".git")
    refute String.contains?(repo.storage_path, "demo")

    path = ForgeRepos.absolute_storage_path(repo)
    assert File.dir?(path)
    assert {:ok, true} = GitCore.is_bare_repository?(path)
    assert {:ok, true} = GitCore.empty?(path)
    assert {:ok, resolved} = ForgeRepos.resolve_git_path("alice/demo.git")
    assert resolved.id == repo.id
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", []))
    end
  end

  defp reset_tables do
    [
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "ssh_keys",
      "users"
    ]
  end
end
