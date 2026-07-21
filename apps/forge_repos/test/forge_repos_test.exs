defmodule ForgeReposTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{AccountView, Organization, OrganizationMember, User}
  alias ForgeRepos.{Collaborator, Repository, RepositoryView}
  alias Fornacast.{AuditEvent, Page, Repo}

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

  test "repository changesets reject NUL in every stored API string field" do
    base = %Repository{owner_user_id: 1, storage_path: "@hashed/aa/bb/nul.git"}

    for {field, value} <- [
          {:name, "name" <> <<0>>},
          {:description, "description" <> <<0>>},
          {:default_branch, "main" <> <<0>>}
        ] do
      attrs =
        %{
          name: "Demo",
          slug: "demo",
          description: "description",
          visibility: :private,
          default_branch: "main"
        }
        |> Map.put(field, value)

      refute Repository.create_changeset(base, attrs).valid?
      refute Repository.api_create_changeset(base, attrs).valid?

      refute Repository.api_update_changeset(
               %Repository{base | slug: "demo", name: "Demo"},
               attrs
             ).valid?
    end
  end

  @tag :tmp_dir
  test "API repositories default public, preserve explicit false settings, and keep browser defaults",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("settings-owner")

    assert {:ok, browser_repository} =
             ForgeRepos.create_repository(owner, %{name: "Browser", slug: "browser"})

    assert browser_repository.visibility == :private
    assert browser_repository.has_issues
    assert browser_repository.allow_merge_commit

    assert {:ok, api_repository} =
             ForgeRepos.create_api_repository(
               owner,
               owner,
               %{
                 "name" => "API Demo",
                 "auto_init" => false,
                 "has_issues" => false,
                 "allow_merge_commit" => false,
                 "has_projects" => false,
                 "has_wiki" => false,
                 "has_discussions" => false,
                 "allow_squash_merge" => false,
                 "allow_rebase_merge" => false,
                 "storage_path" => "attacker/chosen.git"
               },
               request_metadata("settings-create")
             )

    assert api_repository.slug == "api-demo"
    assert api_repository.name == "API Demo"
    assert api_repository.visibility == :public
    refute api_repository.has_issues
    refute api_repository.allow_merge_commit
    assert String.ends_with?(api_repository.storage_path, ".git")
    refute String.contains?(api_repository.storage_path, "api-demo")

    assert {:ok, true} =
             GitCore.is_bare_repository?(ForgeRepos.absolute_storage_path(api_repository))

    assert %AuditEvent{
             action: "repository.created",
             actor_user_id: actor_id,
             target_id: target_id,
             ip_address: "203.0.113.9",
             user_agent: "forge-repos-test",
             metadata: metadata
           } = Repo.get_by!(AuditEvent, action: "repository.created")

    assert actor_id == owner.id
    assert target_id == Integer.to_string(api_repository.id)
    assert metadata["owner"] == owner.username
    assert metadata["name"] == api_repository.slug
    assert metadata["result"] == "success"
    assert metadata["request_id"] == "settings-create"

    assert_validation_error(
      ForgeRepos.create_api_repository(
        owner,
        owner,
        %{"name" => "API Demo", "auto_init" => false},
        request_metadata("duplicate")
      ),
      "name",
      :already_exists
    )

    assert Repo.aggregate(AuditEvent, :count, :id) == 1
    assert length(repository_storage_paths(tmp_dir)) == 2

    assert {:ok, true} =
             GitCore.is_bare_repository?(ForgeRepos.absolute_storage_path(api_repository))
  end

  @tag :tmp_dir
  test "API repository create rejects missing, conflicting, internal, and unsupported values",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("validation-owner")

    assert_validation_error(
      ForgeRepos.create_api_repository(actor, actor, %{"auto_init" => false}, %{}),
      "name",
      :missing_field
    )

    assert_validation_error(
      ForgeRepos.create_api_repository(
        actor,
        actor,
        %{"name" => "conflict", "private" => true, "visibility" => "public"},
        %{}
      ),
      "visibility",
      :invalid
    )

    assert_validation_error(
      ForgeRepos.create_api_repository(
        actor,
        actor,
        %{"name" => "internal", "visibility" => "internal"},
        %{}
      ),
      "visibility",
      :unprocessable
    )

    for {field, value, code} <- [
          {"private", "false", :invalid},
          {"auto_init", "false", :invalid},
          {"has_issues", 1, :invalid},
          {"allow_merge_commit", nil, :invalid},
          {"name", "nul" <> <<0>>, :invalid},
          {"description", "nul" <> <<0>>, :invalid},
          {"default_branch", "main" <> <<0>>, :invalid},
          {"visibility", "public" <> <<0>>, :invalid}
        ] do
      assert_validation_error(
        ForgeRepos.create_api_repository(
          actor,
          actor,
          %{"name" => "invalid-#{field}", field => value},
          %{}
        ),
        field,
        code
      )
    end

    for field <- ~w(has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge) do
      assert_validation_error(
        ForgeRepos.create_api_repository(
          actor,
          actor,
          %{"name" => "unsupported-#{field}", field => true},
          %{}
        ),
        field,
        :unprocessable
      )
    end

    assert Repo.aggregate(Repository, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  @tag :tmp_dir
  test "API mutation normalization gives string keys precedence over atom keys", %{
    tmp_dir: tmp_dir
  } do
    use_storage_root(tmp_dir)
    actor = user_fixture("mixed-keys-owner")

    assert {:ok, repository} =
             ForgeRepos.create_api_repository(
               actor,
               actor,
               %{
                 "name" => "String Name",
                 "has_issues" => false,
                 "auto_init" => false,
                 name: "Atom Name",
                 has_issues: true,
                 auto_init: true
               },
               %{}
             )

    assert repository.slug == "string-name"
    assert repository.name == "String Name"
    refute repository.has_issues
  end

  @tag :tmp_dir
  test "auto_init hands off before database, audit, or storage side effects", %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("initializer-owner")

    assert {:error, :git_initializer_unavailable} =
             ForgeRepos.create_api_repository(
               actor,
               actor,
               %{"name" => "initialized", "auto_init" => true},
               request_metadata("initializer")
             )

    assert ForgeRepos.get_repository(actor.username, "initialized") == nil
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
    assert repository_storage_paths(tmp_dir) == []
  end

  test "git path parser accepts only friendly owner/repo git paths" do
    assert ForgeRepos.parse_git_path("alice/demo.git") == {:ok, "alice", "demo"}
    assert ForgeRepos.parse_git_path("/alice/demo.git") == {:error, :invalid_path}
    assert ForgeRepos.parse_git_path("alice/../../demo.git") == {:error, :invalid_path}
    assert ForgeRepos.parse_git_path("alice/demo.git; rm -rf /") == {:error, :invalid_path}
  end

  test "HTTP clone URLs preserve the owner and repository path without credentials" do
    original_base_url = Application.fetch_env!(:fornacast, :base_url)

    Application.put_env(
      :fornacast,
      :base_url,
      "https://embedded:secret@forge.example.test:8443/ignored?token=secret#fragment"
    )

    on_exit(fn ->
      Application.put_env(:fornacast, :base_url, original_base_url)
    end)

    repository = %Repository{slug: "demo"}
    owner = %User{username: "alice"}

    assert ForgeRepos.http_clone_url(repository, owner) ==
             "https://forge.example.test:8443/alice/demo.git"
  end

  test "repository authorization permits owner and admin" do
    repo = %Repository{id: 10, owner_user_id: 1, visibility: :private}

    assert :ok =
             Fornacast.Access.authorize(
               %User{id: 1, role: :user, state: :active},
               :repository_admin,
               repo
             )

    assert :ok =
             Fornacast.Access.authorize(
               %User{id: 2, role: :admin, state: :active},
               :repository_write,
               repo
             )

    assert {:error, :unauthorized} = Fornacast.Access.authorize(nil, :repository_read, repo)
  end

  test "public repositories are readable anonymously" do
    repo = %Repository{id: 10, owner_user_id: 1, visibility: :public}

    assert :ok = Fornacast.Access.authorize(nil, :repository_read, repo)
    assert {:error, :unauthorized} = Fornacast.Access.authorize(nil, :repository_write, repo)
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

    assert :ok = Fornacast.Access.authorize(owner, :repository_admin, repo)
    assert {:error, :unauthorized} = Fornacast.Access.authorize(member, :repository_read, repo)

    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)
    assert :ok = Fornacast.Access.authorize(member, :repository_read, repo)
    assert {:error, :unauthorized} = Fornacast.Access.authorize(member, :repository_write, repo)
  end

  @tag :tmp_dir
  test "repository views resolve typed owners, permissions, bounded size, and sanitized Git errors",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("view-owner")
    organization = organization_fixture("view-org")
    organization_owner_fixture(organization, owner)

    personal = repository_fixture(owner, slug: "personal", visibility: :private)
    organization_repository = repository_fixture(organization, slug: "organization")

    write_repository_bytes(personal, :binary.copy(<<1>>, 1_025))
    write_repository_bytes(organization_repository, "organization")

    {:ok, personal_bytes} =
      GitCore.repository_disk_usage(ForgeRepos.absolute_storage_path(personal))

    expected_size_kib = div(personal_bytes + 1023, 1024)

    assert {:ok,
            %RepositoryView{
              repository: %Repository{id: personal_id},
              owner: %User{id: owner_id, kind: :user},
              permissions: %{admin: true, push: true, pull: true},
              size_kib: ^expected_size_kib
            }} = ForgeRepos.repository_view(owner, personal)

    assert personal_id == personal.id
    assert owner_id == owner.id

    assert {:ok,
            %RepositoryView{
              owner: %Organization{id: organization_id, kind: :organization},
              permissions: %{admin: true, push: true, pull: true}
            }} = ForgeRepos.repository_view(owner, organization_repository)

    assert organization_id == organization.id

    missing_storage = repository_fixture(owner, slug: "missing-storage")

    assert {:error, {:unavailable, :storage_unavailable}} =
             ForgeRepos.repository_view(owner, missing_storage)
  end

  @tag :tmp_dir
  test "repository views reload stale actors while preserving anonymous public permissions",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("stale-view-owner")
    collaborator = user_fixture("stale-view-collaborator")
    private_repository = repository_fixture(owner, slug: "private", storage: true)

    public_repository =
      repository_fixture(owner, slug: "public", visibility: :public, storage: true)

    collaborator_fixture(private_repository, collaborator, :admin)
    collaborator_fixture(public_repository, collaborator, :admin)

    collaborator
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgeRepos.repository_view(collaborator, private_repository)

    for actor <- [collaborator, :invalid_actor] do
      assert {:ok,
              %RepositoryView{
                repository: %Repository{id: public_id},
                permissions: %{admin: false, push: false, pull: true}
              }} = ForgeRepos.repository_view(actor, public_repository)

      assert public_id == public_repository.id
    end
  end

  @tag :tmp_dir
  test "repository views reject stale soft-deleted rows before resolving storage",
       %{tmp_dir: tmp_dir} do
    owner = user_fixture("deleted-view-owner")
    repository = repository_fixture(owner, slug: "deleted", visibility: :public)

    repository
    |> Ecto.Changeset.change(deleted_at: ~U[2026-07-21 12:00:00Z])
    |> Repo.update!()

    blocked_root = Path.join(tmp_dir, "deleted-view-blocked-root")
    File.write!(blocked_root, "unrelated")
    use_storage_root(blocked_root)

    assert {:error, :not_found} = ForgeRepos.repository_view(nil, repository)
    assert File.read!(blocked_root) == "unrelated"
  end

  @tag :tmp_dir
  test "repository views map an unusable storage root to storage unavailable", %{
    tmp_dir: tmp_dir
  } do
    owner = user_fixture("blocked-view-owner")
    repository = repository_fixture(owner, slug: "blocked", visibility: :public)
    blocked_root = Path.join(tmp_dir, "blocked-view-root")
    File.write!(blocked_root, "unrelated")
    use_storage_root(blocked_root)

    assert {:error, {:unavailable, :storage_unavailable}} =
             ForgeRepos.repository_view(nil, repository)

    assert File.read!(blocked_root) == "unrelated"
  end

  @tag :tmp_dir
  test "repository views map invalid stored paths to storage unavailable", %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("invalid-path-view-owner")
    repository = repository_fixture(owner, slug: "invalid-path", visibility: :public)

    {1, nil} =
      Repository
      |> where(id: ^repository.id)
      |> Repo.update_all(set: [storage_path: "../escape.git"])

    invalid_repository = Repo.get!(Repository, repository.id)

    assert {:error, {:unavailable, :storage_unavailable}} =
             ForgeRepos.repository_view(nil, invalid_repository)
  end

  test "account views count only direct nondeleted ownership and never disclose private counts" do
    account = user_fixture("account-counts")
    other = user_fixture("other-counts")
    site_admin = user_fixture("admin-counts", role: :admin)
    organization = organization_fixture("count-org")
    organization_owner_fixture(organization, account)

    _public = repository_fixture(account, slug: "public", visibility: :public)
    _private = repository_fixture(account, slug: "private", visibility: :private)

    deleted = repository_fixture(account, slug: "deleted", visibility: :public)

    deleted
    |> Ecto.Changeset.change(deleted_at: ~U[2026-07-21 12:00:00Z])
    |> Repo.update!()

    _organization_public =
      repository_fixture(organization, slug: "organization-public", visibility: :public)

    _organization_private =
      repository_fixture(organization, slug: "organization-private", visibility: :private)

    assert %AccountView{account: %User{id: account_id}, public_repos: 1, private_repos: 1} =
             ForgeRepos.account_view(account, account)

    assert account_id == account.id

    for actor <- [nil, other, site_admin] do
      assert %AccountView{public_repos: 1, private_repos: 0} =
               ForgeRepos.account_view(actor, account)
    end

    assert %AccountView{
             account: %Organization{id: organization_id},
             public_repos: 1,
             private_repos: 0
           } = ForgeRepos.account_view(account, organization)

    assert organization_id == organization.id
  end

  @tag :tmp_dir
  test "accessible repository views include every affiliation once with deterministic pagination",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("alice")
    other = user_fixture("bob")
    organization = organization_fixture("acme")
    organization_member_fixture(organization, actor, :member)

    owned = repository_fixture(actor, slug: "owned", visibility: :public, storage: true)

    organization_repository =
      repository_fixture(organization, slug: "organization", storage: true)

    collaborated = repository_fixture(other, slug: "collaborated", storage: true)
    collaborator_fixture(collaborated, actor, :write)
    collaborator_fixture(organization_repository, actor, :read)

    _unrelated_public =
      repository_fixture(other, slug: "unrelated-public", visibility: :public, storage: true)

    _unrelated_private = repository_fixture(other, slug: "unrelated-private", storage: true)

    assert {:ok, %Page{entries: first_page, total: 3, page: 1, per_page: 2}} =
             ForgeRepos.list_accessible_repository_views(actor, page: 1, per_page: 2)

    assert [
             %RepositoryView{repository: %Repository{id: first_id}},
             %RepositoryView{repository: %Repository{id: second_id}}
           ] = first_page

    assert [first_id, second_id] == [organization_repository.id, owned.id]

    assert {:ok, %Page{entries: [%RepositoryView{repository: %Repository{id: third_id}}]}} =
             ForgeRepos.list_accessible_repository_views(actor, page: 2, per_page: 2)

    assert third_id == collaborated.id

    assert {:ok, %Page{entries: owner_views, total: 1}} =
             ForgeRepos.list_accessible_repository_views(actor, affiliation: "owner")

    assert [%RepositoryView{repository: %Repository{id: owned_id}}] = owner_views
    assert owned_id == owned.id

    assert {:ok, %Page{entries: organization_views, total: 1}} =
             ForgeRepos.list_accessible_repository_views(
               actor,
               affiliation: "organization_member"
             )

    assert [%RepositoryView{repository: %Repository{id: organization_repository_id}}] =
             organization_views

    assert organization_repository_id == organization_repository.id

    assert {:ok, %Page{entries: collaborator_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor, affiliation: "collaborator")

    assert Enum.sort(repository_ids(collaborator_views)) ==
             Enum.sort([collaborated.id, organization_repository.id])

    assert {:ok, %Page{entries: public_views, total: 1}} =
             ForgeRepos.list_accessible_repository_views(actor,
               visibility_ceiling: :public,
               visibility: "public"
             )

    assert [%RepositoryView{permissions: %{admin: true}, repository: %Repository{id: public_id}}] =
             public_views

    assert public_id == owned.id

    assert {:ok, %Page{entries: [], total: 0}} =
             ForgeRepos.list_accessible_repository_views(actor,
               visibility_ceiling: :public,
               visibility: "private"
             )
  end

  @tag :tmp_dir
  test "accessible repository pages batch SQL authorization context", %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("batch-member")
    organization = organization_fixture("batch-org")
    organization_member_fixture(organization, actor, :member)

    Enum.each(1..30, fn index ->
      slug = "repository-#{String.pad_leading(Integer.to_string(index), 2, "0")}"
      repository_fixture(organization, slug: slug, storage: true)
    end)

    {result, query_count} =
      count_repo_queries(fn ->
        ForgeRepos.list_accessible_repository_views(actor, per_page: 30)
      end)

    assert {:ok, %Page{entries: views, total: 30, page: 1, per_page: 30}} = result

    assert Enum.map(views, & &1.permissions) ==
             List.duplicate(%{admin: false, push: false, pull: true}, 30)

    assert query_count <= 5
  end

  @tag :tmp_dir
  test "authenticated list validates filters, conflicts, timestamps, and portable pushed ordering",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("filter-owner")
    organization = organization_fixture("filter-org")
    organization_member_fixture(organization, actor, :member)

    older = repository_fixture(actor, slug: "older", visibility: :public, storage: true)
    newer = repository_fixture(actor, slug: "newer", visibility: :private, storage: true)
    nil_pushed = repository_fixture(actor, slug: "nil-pushed", visibility: :public, storage: true)
    member = repository_fixture(organization, slug: "member", visibility: :private, storage: true)

    set_repository_times(older, ~U[2026-07-20 10:00:00Z], ~U[2026-07-20 11:00:00Z])
    set_repository_times(newer, ~U[2026-07-21 10:00:00Z], ~U[2026-07-21 11:00:00Z])
    set_repository_times(nil_pushed, ~U[2026-07-22 10:00:00Z], nil)
    set_repository_times(member, ~U[2026-07-23 10:00:00Z], ~U[2026-07-23 11:00:00Z])

    assert {:ok, %Page{entries: since_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor,
               since: "2026-07-21T10:00:00Z"
             )

    assert repository_ids(since_views) == [member.id, nil_pushed.id]

    assert {:ok, %Page{entries: fractional_since_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor,
               since: "2026-07-21T10:00:00.500Z"
             )

    assert repository_ids(fractional_since_views) == [member.id, nil_pushed.id]

    assert {:ok, %Page{entries: fractional_offset_since_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor,
               since: "2026-07-21T12:00:00.500+02:00"
             )

    assert repository_ids(fractional_offset_since_views) == [member.id, nil_pushed.id]

    assert {:ok, %Page{entries: before_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor,
               before: "2026-07-22T10:00:00Z"
             )

    assert repository_ids(before_views) == [newer.id, older.id]

    assert {:ok, %Page{entries: fractional_before_views, total: 3}} =
             ForgeRepos.list_accessible_repository_views(actor,
               before: "2026-07-22T10:00:00.500Z"
             )

    assert repository_ids(fractional_before_views) == [newer.id, nil_pushed.id, older.id]

    assert {:ok, %Page{entries: fractional_offset_before_views, total: 3}} =
             ForgeRepos.list_accessible_repository_views(actor,
               before: "2026-07-22T12:00:00.500+02:00"
             )

    assert repository_ids(fractional_offset_before_views) == [newer.id, nil_pushed.id, older.id]

    assert {:ok, %Page{entries: offset_since_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor,
               since: "2026-07-21T12:00:00+02:00"
             )

    assert repository_ids(offset_since_views) == [member.id, nil_pushed.id]

    assert {:ok, %Page{entries: offset_before_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor,
               before: "2026-07-22T02:00:00-08:00"
             )

    assert repository_ids(offset_before_views) == [newer.id, older.id]

    assert {:ok, %Page{entries: ascending_pushed}} =
             ForgeRepos.list_accessible_repository_views(actor,
               sort: "pushed",
               direction: "asc"
             )

    assert repository_ids(ascending_pushed) == [older.id, newer.id, member.id, nil_pushed.id]

    assert {:ok, %Page{entries: descending_pushed}} =
             ForgeRepos.list_accessible_repository_views(actor,
               sort: "pushed",
               direction: "desc"
             )

    assert repository_ids(descending_pushed) == [member.id, newer.id, older.id, nil_pushed.id]

    assert {:ok, %Page{entries: member_views, total: 1}} =
             ForgeRepos.list_accessible_repository_views(actor, type: "member")

    assert repository_ids(member_views) == [member.id]

    assert {:ok, %Page{entries: private_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor, type: "private")

    assert Enum.sort(repository_ids(private_views)) == Enum.sort([newer.id, member.id])

    assert {:ok, %Page{entries: owner_type_views, total: 3}} =
             ForgeRepos.list_accessible_repository_views(actor, type: "owner")

    assert Enum.sort(repository_ids(owner_type_views)) ==
             Enum.sort([older.id, newer.id, nil_pushed.id])

    assert {:ok, %Page{entries: public_type_views, total: 2}} =
             ForgeRepos.list_accessible_repository_views(actor, type: "public")

    assert Enum.sort(repository_ids(public_type_views)) == Enum.sort([older.id, nil_pushed.id])

    assert {:ok, %Page{entries: created_default}} =
             ForgeRepos.list_accessible_repository_views(actor, sort: "created")

    assert repository_ids(created_default) == [member.id, nil_pushed.id, newer.id, older.id]

    assert {:ok, %Page{entries: updated_ascending}} =
             ForgeRepos.list_accessible_repository_views(actor,
               sort: "updated",
               direction: "asc"
             )

    assert repository_ids(updated_ascending) == [older.id, newer.id, nil_pushed.id, member.id]

    for {opts, field} <- [
          {[visibility: "internal"], "visibility"},
          {[affiliation: ""], "affiliation"},
          {[affiliation: "owner,owner"], "affiliation"},
          {[affiliation: "owner,unknown"], "affiliation"},
          {[type: "forks"], "type"},
          {[sort: "stars"], "sort"},
          {[direction: "sideways"], "direction"},
          {[since: "2026-07-21 10:00:00"], "since"},
          {[visibility_ceiling: :private], "visibility_ceiling"},
          {[page: 0], "page"},
          {[per_page: 101], "per_page"}
        ] do
      assert_validation_error(
        ForgeRepos.list_accessible_repository_views(actor, opts),
        field,
        :invalid
      )
    end

    for opts <- [
          [type: "all", visibility: "all"],
          [type: "owner", affiliation: "owner"]
        ] do
      assert_validation_error(
        ForgeRepos.list_accessible_repository_views(actor, opts),
        "type",
        :invalid
      )
    end

    oversized_affiliation = Enum.map_join(1..101, ",", fn _ -> "owner" end)

    assert_validation_error(
      ForgeRepos.list_accessible_repository_views(actor,
        affiliation: oversized_affiliation
      ),
      "affiliation",
      :unprocessable
    )
  end

  @tag :tmp_dir
  test "account lists apply active visibility ceilings before filters and keep actor permissions",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    account = user_fixture("account-owner")
    other = user_fixture("account-other")
    organization = organization_fixture("account-org")
    organization_owner_fixture(organization, account)

    public = repository_fixture(account, slug: "public", visibility: :public, storage: true)
    private = repository_fixture(account, slug: "private", visibility: :private, storage: true)

    organization_public =
      repository_fixture(organization, slug: "public", visibility: :public, storage: true)

    organization_private =
      repository_fixture(organization, slug: "private", visibility: :private, storage: true)

    assert {:ok, %Page{entries: anonymous_views, total: 1}} =
             ForgeRepos.list_account_repository_views(nil, account, visibility_ceiling: :all)

    assert repository_ids(anonymous_views) == [public.id]

    assert {:ok, %Page{entries: public_owner_views, total: 1}} =
             ForgeRepos.list_account_repository_views(account, account,
               visibility_ceiling: :public
             )

    assert [
             %RepositoryView{
               repository: %Repository{id: public_id},
               permissions: %{admin: true, push: true, pull: true}
             }
           ] = public_owner_views

    assert public_id == public.id

    assert {:ok, %Page{entries: owner_views, total: 2}} =
             ForgeRepos.list_account_repository_views(account, account, visibility_ceiling: :all)

    assert Enum.sort(repository_ids(owner_views)) == Enum.sort([public.id, private.id])

    assert {:ok, %Page{entries: member_account_views, total: 2}} =
             ForgeRepos.list_account_repository_views(account, account,
               visibility_ceiling: :all,
               type: "member"
             )

    assert Enum.sort(repository_ids(member_account_views)) ==
             Enum.sort([organization_public.id, organization_private.id])

    assert {:ok, %Page{entries: all_account_views, total: 4}} =
             ForgeRepos.list_account_repository_views(account, account,
               visibility_ceiling: :all,
               type: "all"
             )

    assert Enum.sort(repository_ids(all_account_views)) ==
             Enum.sort([
               public.id,
               private.id,
               organization_public.id,
               organization_private.id
             ])

    collaborator_fixture(private, other, :read)

    assert {:ok, %Page{entries: collaborator_views, total: 2}} =
             ForgeRepos.list_account_repository_views(other, account, visibility_ceiling: :all)

    assert Enum.sort(repository_ids(collaborator_views)) == Enum.sort([public.id, private.id])

    assert {:ok, %Page{entries: anonymous_organization_views, total: 1}} =
             ForgeRepos.list_account_repository_views(nil, organization, visibility_ceiling: :all)

    assert repository_ids(anonymous_organization_views) == [organization_public.id]

    assert {:ok, %Page{entries: organization_owner_views, total: 2}} =
             ForgeRepos.list_account_repository_views(account, organization,
               visibility_ceiling: :all
             )

    assert Enum.sort(repository_ids(organization_owner_views)) ==
             Enum.sort([organization_public.id, organization_private.id])

    assert {:ok, %Page{entries: [], total: 0}} =
             ForgeRepos.list_account_repository_views(account, organization,
               visibility_ceiling: :public,
               type: "private"
             )

    assert {:ok,
            %Page{
              entries: [%RepositoryView{repository: %Repository{id: sources_page_one_id}}],
              total: 2,
              page: 1,
              per_page: 1
            }} =
             ForgeRepos.list_account_repository_views(account, organization,
               visibility_ceiling: :all,
               type: "sources",
               page: 1,
               per_page: 1
             )

    assert {:ok,
            %Page{
              entries: [%RepositoryView{repository: %Repository{id: sources_page_two_id}}],
              total: 2,
              page: 2,
              per_page: 1
            }} =
             ForgeRepos.list_account_repository_views(account, organization,
               visibility_ceiling: :all,
               type: "sources",
               page: 2,
               per_page: 1
             )

    assert Enum.sort([sources_page_one_id, sources_page_two_id]) ==
             Enum.sort([organization_public.id, organization_private.id])

    assert {:ok,
            %Page{
              entries: [%RepositoryView{repository: %Repository{id: source_public_id}}],
              total: 1,
              page: 1,
              per_page: 30
            }} =
             ForgeRepos.list_account_repository_views(nil, organization,
               visibility_ceiling: :all,
               type: "sources"
             )

    assert source_public_id == organization_public.id

    for {actor, ceiling} <- [{account, :public}, {other, :all}] do
      assert {:ok,
              %Page{
                entries: [%RepositoryView{repository: %Repository{id: ^source_public_id}}],
                total: 1,
                page: 1,
                per_page: 1
              }} =
               ForgeRepos.list_account_repository_views(actor, organization,
                 visibility_ceiling: ceiling,
                 type: "sources",
                 page: 1,
                 per_page: 1
               )
    end

    for type <- ~w(forks internal member) do
      assert {:ok, %Page{entries: [], total: 0, page: 2, per_page: 1}} =
               ForgeRepos.list_account_repository_views(account, organization,
                 visibility_ceiling: :all,
                 type: type,
                 page: 2,
                 per_page: 1
               )
    end

    for {target, opts, field} <- [
          {account, [type: "private"], "type"},
          {organization, [type: "unknown"], "type"},
          {account, [sort: "stars"], "sort"},
          {account, [direction: "sideways"], "direction"},
          {account, [visibility_ceiling: :private], "visibility_ceiling"}
        ] do
      assert_validation_error(
        ForgeRepos.list_account_repository_views(account, target, opts),
        field,
        :invalid
      )
    end
  end

  @tag :tmp_dir
  test "API create rechecks active typed owners and organization permission", %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("create-actor")
    other = user_fixture("create-other")
    organization = organization_fixture("create-org")
    organization_owner_fixture(organization, actor)
    member = user_fixture("create-member")
    organization_member_fixture(organization, member, :member)
    site_admin = user_fixture("create-site-admin", role: :admin)

    assert {:error, :forbidden} =
             ForgeRepos.create_api_repository(
               actor,
               other,
               %{"name" => "other-personal"},
               %{}
             )

    assert {:ok, organization_repository} =
             ForgeRepos.create_api_repository(
               actor,
               organization,
               %{"name" => "organization-repository"},
               %{}
             )

    assert organization_repository.owner_user_id == organization.id

    assert {:error, :forbidden} =
             ForgeRepos.create_api_repository(
               member,
               organization,
               %{"name" => "member-repository"},
               %{}
             )

    assert {:ok, site_admin_repository} =
             ForgeRepos.create_api_repository(
               site_admin,
               organization,
               %{"name" => "site-admin-repository"},
               %{}
             )

    assert site_admin_repository.owner_user_id == organization.id

    stale_organization = organization_fixture("stale-org")
    stale_membership = organization_owner_fixture(stale_organization, actor)
    Repo.delete!(stale_membership)

    assert {:error, :forbidden} =
             ForgeRepos.create_api_repository(
               actor,
               stale_organization,
               %{"name" => "permission" <> <<0>>},
               %{}
             )

    disabled_organization = organization_fixture("disabled-org")
    organization_owner_fixture(disabled_organization, actor)

    disabled_organization
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgeRepos.create_api_repository(
               actor,
               disabled_organization,
               %{"name" => "disabled-target"},
               %{}
             )

    stale_actor = user_fixture("stale-actor")

    stale_actor
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:error, :forbidden} =
             ForgeRepos.create_api_repository(
               stale_actor,
               stale_actor,
               %{"name" => "disabled-actor"},
               %{}
             )

    wrong_kind_target = %Organization{id: other.id, kind: :user, state: :active}

    assert {:error, :not_found} =
             ForgeRepos.create_api_repository(
               actor,
               wrong_kind_target,
               %{"name" => "wrong-kind"},
               %{}
             )
  end

  @tag :tmp_dir
  test "API create rolls back its row and generated storage when audit insertion fails",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    actor = user_fixture("rollback-create")

    assert_validation_error(
      ForgeRepos.create_api_repository(
        actor,
        actor,
        %{"name" => "rollback", "auto_init" => false},
        %{ip_address: {:invalid, :address}}
      ),
      "base",
      :unprocessable
    )

    assert ForgeRepos.get_repository(actor.username, "rollback") == nil
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
    assert repository_storage_paths(tmp_dir) == []
  end

  @tag :tmp_dir
  test "API create maps storage initialization failures without raising or removing unrelated data",
       %{tmp_dir: tmp_dir} do
    blocked_root = Path.join(tmp_dir, "blocked-root")
    File.write!(blocked_root, "unrelated")
    use_storage_root(blocked_root)
    actor = user_fixture("storage-unavailable-owner")

    assert {:error, {:unavailable, :storage_unavailable}} =
             ForgeRepos.create_api_repository(
               actor,
               actor,
               %{"name" => "storage-unavailable"},
               %{}
             )

    assert File.read!(blocked_root) == "unrelated"
    assert ForgeRepos.get_repository(actor.username, "storage-unavailable") == nil
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  @tag :tmp_dir
  test "API update partitions write/admin fields, renames routes, and preserves storage",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("update-owner")
    writer = user_fixture("update-writer")
    unrelated = user_fixture("update-unrelated")

    assert {:ok, repository} =
             ForgeRepos.create_api_repository(
               owner,
               owner,
               %{"name" => "before", "visibility" => "public"},
               %{}
             )

    collaborator_fixture(repository, writer, :write)

    assert {:ok, flags_updated} =
             ForgeRepos.update_api_repository(
               writer,
               repository,
               %{"has_issues" => false, "allow_merge_commit" => false},
               request_metadata("writer-flags")
             )

    refute flags_updated.has_issues
    refute flags_updated.allow_merge_commit

    assert {:error, :forbidden} =
             ForgeRepos.update_api_repository(
               writer,
               flags_updated,
               %{"name" => "writer-cannot-rename"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeRepos.update_api_repository(
               writer,
               flags_updated,
               %{"default_branch" => "main"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeRepos.update_api_repository(
               unrelated,
               flags_updated,
               %{"name" => "forbidden" <> <<0>>},
               %{}
             )

    storage_path = flags_updated.storage_path

    assert {:ok, renamed} =
             ForgeRepos.update_api_repository(
               owner,
               flags_updated,
               %{
                 "name" => "After Rename",
                 "description" => "renamed",
                 "storage_path" => "attacker/chosen.git"
               },
               request_metadata("owner-rename")
             )

    assert renamed.slug == "after-rename"
    assert renamed.name == "After Rename"
    assert renamed.description == "renamed"
    assert renamed.storage_path == storage_path
    assert ForgeRepos.get_repository(owner.username, "before") == nil
    assert ForgeRepos.get_repository(owner.username, "after-rename").id == repository.id

    update_events =
      AuditEvent
      |> where(action: "repository.updated", target_id: ^"#{repository.id}")
      |> Repo.all()

    assert Enum.any?(update_events, &(&1.metadata["result"] == "success"))
  end

  @tag :tmp_dir
  test "API update rejects a stale expected visibility without changing or auditing the repository",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("visibility-guard-owner")

    assert {:ok, repository} =
             ForgeRepos.create_api_repository(
               owner,
               owner,
               %{"name" => "visibility-guard", "visibility" => "public"},
               %{}
             )

    {1, nil} =
      Repository
      |> where(id: ^repository.id)
      |> Repo.update_all(set: [visibility: :private])

    update_audits_before =
      Repo.aggregate(from(e in AuditEvent, where: e.action == "repository.updated"), :count, :id)

    assert {:error, {:conflict, :repository_changed}} =
             ForgeRepos.update_api_repository(
               owner,
               repository,
               %{"has_issues" => false},
               %{},
               expected_visibility: :public
             )

    persisted = Repo.get!(Repository, repository.id)
    assert persisted.visibility == :private
    assert persisted.has_issues

    assert Repo.aggregate(
             from(e in AuditEvent, where: e.action == "repository.updated"),
             :count,
             :id
           ) == update_audits_before
  end

  @tag :tmp_dir
  test "API update validates only a changed default branch through the canonical selector",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("branch-owner")

    assert {:ok, repository} =
             ForgeRepos.create_api_repository(owner, owner, %{"name" => "branches"}, %{})

    File.rm_rf!(ForgeRepos.absolute_storage_path(repository))

    assert {:ok, unchanged_branch} =
             ForgeRepos.update_api_repository(
               owner,
               repository,
               %{"default_branch" => "main", "description" => "no Git probe"},
               %{}
             )

    assert unchanged_branch.description == "no Git probe"

    assert {:ok, branch_repository} =
             ForgeRepos.create_api_repository(owner, owner, %{"name" => "existing-branch"}, %{})

    create_branch!(branch_repository, "trunk", tmp_dir)

    assert {:ok, changed_branch} =
             ForgeRepos.update_api_repository(
               owner,
               branch_repository,
               %{"default_branch" => "trunk"},
               %{}
             )

    assert changed_branch.default_branch == "trunk"

    assert_validation_error(
      ForgeRepos.update_api_repository(
        owner,
        changed_branch,
        %{"default_branch" => "missing"},
        %{}
      ),
      "default_branch",
      :missing
    )

    assert {:ok, empty_repository} =
             ForgeRepos.create_api_repository(owner, owner, %{"name" => "empty"}, %{})

    assert_validation_error(
      ForgeRepos.update_api_repository(
        owner,
        empty_repository,
        %{"default_branch" => "other"},
        %{}
      ),
      "default_branch",
      :missing
    )
  end

  @tag :tmp_dir
  test "changed default branch maps an unusable storage root to storage unavailable", %{
    tmp_dir: tmp_dir
  } do
    owner = user_fixture("blocked-branch-owner")
    repository = repository_fixture(owner, slug: "blocked-branch")
    blocked_root = Path.join(tmp_dir, "blocked-branch-root")
    File.write!(blocked_root, "unrelated")
    use_storage_root(blocked_root)

    assert {:error, {:unavailable, :storage_unavailable}} =
             ForgeRepos.update_api_repository(
               owner,
               repository,
               %{"default_branch" => "trunk"},
               %{}
             )

    assert File.read!(blocked_root) == "unrelated"
  end

  @tag :tmp_dir
  test "changed default branch maps invalid stored paths to storage unavailable", %{
    tmp_dir: tmp_dir
  } do
    use_storage_root(tmp_dir)
    owner = user_fixture("invalid-path-branch-owner")
    repository = repository_fixture(owner, slug: "invalid-path-branch")

    {1, nil} =
      Repository
      |> where(id: ^repository.id)
      |> Repo.update_all(set: [storage_path: "../escape.git"])

    assert {:error, {:unavailable, :storage_unavailable}} =
             ForgeRepos.update_api_repository(
               owner,
               repository,
               %{"default_branch" => "trunk"},
               %{}
             )
  end

  @tag :tmp_dir
  test "API update normalizes only supplied fields and rejects incompatible settings",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("normalize-update-owner")

    assert {:ok, repository} =
             ForgeRepos.create_api_repository(
               owner,
               owner,
               %{
                 "name" => "Normalize Update",
                 "description" => "preserve me",
                 "visibility" => "private",
                 "has_issues" => true,
                 "allow_merge_commit" => true
               },
               %{}
             )

    assert {:ok, flags_only} =
             ForgeRepos.update_api_repository(
               owner,
               repository,
               %{"has_issues" => false, has_issues: true},
               %{}
             )

    assert flags_only.slug == repository.slug
    assert flags_only.name == repository.name
    assert flags_only.description == "preserve me"
    assert flags_only.visibility == :private
    assert flags_only.default_branch == "main"
    refute flags_only.has_issues
    assert flags_only.allow_merge_commit
    assert flags_only.storage_path == repository.storage_path

    for {attrs, field, code} <- [
          {%{"visibility" => "internal"}, "visibility", :unprocessable},
          {%{"private" => true, "visibility" => "public"}, "visibility", :invalid},
          {%{"private" => "true"}, "private", :invalid},
          {%{"has_issues" => 1}, "has_issues", :invalid},
          {%{"allow_merge_commit" => nil}, "allow_merge_commit", :invalid},
          {%{"name" => "nul" <> <<0>>}, "name", :invalid},
          {%{"description" => "nul" <> <<0>>}, "description", :invalid},
          {%{"default_branch" => "main" <> <<0>>}, "default_branch", :invalid},
          {%{"has_projects" => true}, "has_projects", :unprocessable},
          {%{"has_wiki" => true}, "has_wiki", :unprocessable},
          {%{"has_discussions" => true}, "has_discussions", :unprocessable},
          {%{"allow_squash_merge" => true}, "allow_squash_merge", :unprocessable},
          {%{"allow_rebase_merge" => true}, "allow_rebase_merge", :unprocessable},
          {%{"auto_init" => false}, "auto_init", :unprocessable}
        ] do
      assert_validation_error(
        ForgeRepos.update_api_repository(owner, flags_only, attrs, %{}),
        field,
        code
      )
    end

    assert Repo.get!(Repository, repository.id).description == "preserve me"
  end

  @tag :tmp_dir
  test "API update reloads rows and rolls back repository changes with a failed audit",
       %{tmp_dir: tmp_dir} do
    use_storage_root(tmp_dir)
    owner = user_fixture("update-rollback-owner")

    assert {:ok, repository} =
             ForgeRepos.create_api_repository(owner, owner, %{"name" => "rollback-update"}, %{})

    assert_validation_error(
      ForgeRepos.update_api_repository(
        owner,
        repository,
        %{"description" => "must roll back"},
        %{ip_address: {:invalid, :address}}
      ),
      "base",
      :unprocessable
    )

    assert Repo.get!(Repository, repository.id).description == nil

    stale_repository = repository

    repository
    |> Ecto.Changeset.change(deleted_at: ~U[2026-07-22 01:00:00Z])
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgeRepos.update_api_repository(
               owner,
               stale_repository,
               %{"has_issues" => false},
               %{}
             )
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

  defp user_fixture(username, attrs \\ []) do
    %User{
      username: username,
      email: "#{username}@example.com",
      password_hash: "unused-in-forge-repos-tests",
      kind: :user,
      role: Keyword.get(attrs, :role, :user),
      state: Keyword.get(attrs, :state, :active)
    }
    |> Repo.insert!()
  end

  defp organization_fixture(username, attrs \\ []) do
    %Organization{
      username: username,
      email: "organization+#{username}@example.com",
      display_name: username,
      password_hash: "organization-account",
      kind: :organization,
      state: Keyword.get(attrs, :state, :active)
    }
    |> Repo.insert!()
  end

  defp organization_owner_fixture(organization, user) do
    organization_member_fixture(organization, user, :owner)
  end

  defp organization_member_fixture(organization, user, role) do
    %OrganizationMember{}
    |> OrganizationMember.changeset(%{
      organization_id: organization.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp collaborator_fixture(repository, user, role) do
    %Collaborator{}
    |> Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp repository_fixture(owner, attrs) do
    slug = Keyword.fetch!(attrs, :slug)

    repository =
      %Repository{
        owner_user_id: owner.id,
        storage_path: "@test/#{owner.id}/#{slug}.git"
      }
      |> Repository.create_changeset(%{
        name: Keyword.get(attrs, :name, slug),
        slug: slug,
        description: Keyword.get(attrs, :description),
        visibility: Keyword.get(attrs, :visibility, :private),
        default_branch: Keyword.get(attrs, :default_branch, "main")
      })
      |> Repo.insert!()

    if Keyword.get(attrs, :storage, false), do: write_repository_bytes(repository, "fixture")
    repository
  end

  defp request_metadata(request_id) do
    %{
      request_id: request_id,
      ip_address: "203.0.113.9",
      user_agent: "forge-repos-test"
    }
  end

  defp assert_validation_error(result, field, code) do
    assert {:error, {:validation, errors}} = result

    assert Enum.any?(errors, fn error ->
             error == %{resource: "Repository", field: field, code: code}
           end)
  end

  defp count_repo_queries(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:fornacast, :repo, :query],
        fn _event, _measurements, _metadata, {pid, query_ref} ->
          send(pid, {query_ref, :repo_query})
        end,
        {test_pid, ref}
      )

    try do
      result = fun.()
      {result, drain_repo_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(ref, count) do
    receive do
      {^ref, :repo_query} -> drain_repo_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  defp use_storage_root(tmp_dir) do
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)
  end

  defp write_repository_bytes(repository, bytes) do
    path = ForgeRepos.absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))
    {:ok, _path} = GitCore.init_bare(path)
    File.write!(Path.join(path, "fixture.bin"), bytes)
    repository
  end

  defp repository_storage_paths(root) do
    Path.wildcard(Path.join([root, "**", "*.git"]), match_dot: true)
  end

  defp repository_ids(views) do
    Enum.map(views, & &1.repository.id)
  end

  defp set_repository_times(repository, updated_at, last_pushed_at) do
    {1, nil} =
      Repository
      |> where(id: ^repository.id)
      |> Repo.update_all(
        set: [
          inserted_at: updated_at,
          updated_at: updated_at,
          last_pushed_at: last_pushed_at
        ]
      )
  end

  defp create_branch!(repository, branch, tmp_dir) do
    path = ForgeRepos.absolute_storage_path(repository)
    empty_tree = Path.join(tmp_dir, "empty-tree")
    File.write!(empty_tree, "")

    {tree, 0} =
      System.cmd("git", ["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", empty_tree],
        stderr_to_stdout: true
      )

    identity_env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    {commit, 0} =
      System.cmd(
        "git",
        ["--git-dir=#{path}", "commit-tree", String.trim(tree), "-m", "initial"],
        env: identity_env,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "git",
        ["--git-dir=#{path}", "update-ref", "refs/heads/#{branch}", String.trim(commit)],
        stderr_to_stdout: true
      )
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
