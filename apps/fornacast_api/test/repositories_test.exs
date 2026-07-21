defmodule FornacastAPI.RepositoriesTest do
  use FornacastAPI.ConnCase, async: false

  defmodule PausingBodyAdapter do
    @behaviour Plug.Conn.Adapter

    def read_req_body(%{delegate: delegate, test_pid: test_pid, ref: ref} = state, opts) do
      send(test_pid, {ref, :body_read, self()})

      receive do
        {^ref, :continue_body} ->
          delegate
          |> Plug.Adapters.Test.Conn.read_req_body(opts)
          |> wrap_state(state)
      end
    end

    def send_resp(%{delegate: delegate} = state, status, headers, body) do
      delegate
      |> Plug.Adapters.Test.Conn.send_resp(status, headers, body)
      |> wrap_state(state)
    end

    def send_file(%{delegate: delegate} = state, status, headers, path, offset, length) do
      delegate
      |> Plug.Adapters.Test.Conn.send_file(status, headers, path, offset, length)
      |> wrap_state(state)
    end

    def send_chunked(%{delegate: delegate} = state, status, headers) do
      delegate
      |> Plug.Adapters.Test.Conn.send_chunked(status, headers)
      |> wrap_state(state)
    end

    def chunk(%{delegate: delegate} = state, body) do
      delegate
      |> Plug.Adapters.Test.Conn.chunk(body)
      |> wrap_state(state)
    end

    def inform(%{delegate: delegate}, status, headers),
      do: Plug.Adapters.Test.Conn.inform(delegate, status, headers)

    def upgrade(%{delegate: delegate} = state, protocol, opts) do
      case Plug.Adapters.Test.Conn.upgrade(delegate, protocol, opts) do
        {:ok, updated_delegate} -> {:ok, %{state | delegate: updated_delegate}}
        {:error, reason} -> {:error, reason}
      end
    end

    def push(%{delegate: delegate}, path, headers),
      do: Plug.Adapters.Test.Conn.push(delegate, path, headers)

    def get_peer_data(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_peer_data(delegate)

    def get_sock_data(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_sock_data(delegate)

    def get_ssl_data(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_ssl_data(delegate)

    def get_http_protocol(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_http_protocol(delegate)

    defp wrap_state({status, body, updated_delegate}, state) when status in [:ok, :more],
      do: {status, body, %{state | delegate: updated_delegate}}
  end

  import Ecto.Query

  alias ForgeAccounts.OrganizationMember
  alias ForgeRepos.{Collaborator, Repository}
  alias Fornacast.{AuditEvent, Repo}

  @moduletag :tmp_dir

  @versions ["2022-11-28", "2026-03-10"]
  @user_agent "fornacast-repository-api-test/1.0"
  @json_media_type "application/vnd.github+json"
  @authentication_url "https://docs.github.com/en/enterprise-server@3.21/rest/authentication/authenticating-to-the-rest-api"
  @authenticated_list_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#list-repositories-for-the-authenticated-user"
  @user_list_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#list-repositories-for-a-user"
  @organization_list_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#list-organization-repositories"
  @personal_create_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#create-a-repository-for-the-authenticated-user"
  @organization_create_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#create-an-organization-repository"
  @show_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#get-a-repository"
  @update_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#update-a-repository"

  @private_read_scopes "repo, repo:read, repo:write"

  @minimal_repository_keys ~w(
    archive_url archived assignees_url blobs_url branches_url clone_url collaborators_url
    comments_url commits_url compare_url contents_url contributors_url created_at default_branch
    deployments_url description disabled downloads_url events_url fork forks forks_count forks_url
    full_name git_commits_url git_refs_url git_tags_url git_url has_discussions has_issues has_pages
    has_projects has_wiki homepage hooks_url html_url id issue_comment_url issue_events_url issues_url
    keys_url labels_url language languages_url license merges_url milestones_url mirror_url name
    network_count node_id notifications_url open_issues open_issues_count owner permissions private
    pulls_url pushed_at releases_url size ssh_url stargazers_count stargazers_url statuses_url
    subscribers_count subscribers_url subscription_url svn_url tags_url teams_url topics trees_url
    updated_at url visibility watchers watchers_count
  )
  @repository_keys (@minimal_repository_keys ++
                      ~w(allow_merge_commit allow_rebase_merge allow_squash_merge)) --
                     ~w(network_count subscribers_count)
  @full_repository_keys @repository_keys ++ ~w(network_count subscribers_count)

  setup %{tmp_dir: tmp_dir} do
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    alice = user("alice", display_name: "Alice")
    %{alice: alice, storage_root: tmp_dir}
  end

  test "all repository reads are routed, versioned, and use their complete resource shapes", %{
    alice: alice
  } do
    organization = organization(alice, "acme")
    personal = repository(alice, "personal", visibility: :public)
    organization_repository = repository(organization, "organization", visibility: :public)
    {_key, secret} = pat(alice, ["repo"])

    for version <- @versions do
      authenticated =
        api_conn(secret: secret, version: version)
        |> get("/api/v3/user/repos")

      authenticated_bodies = json_response(authenticated, 200)

      assert Enum.sort(repository_ids(authenticated_bodies)) ==
               Enum.sort([personal.id, organization_repository.id])

      authenticated_body = Enum.find(authenticated_bodies, &(&1["id"] == personal.id))
      assert_repository_keys(authenticated_body, :repository, version)

      user_list = api_conn(version: version) |> get("/api/v3/users/alice/repos")
      assert [user_body] = json_response(user_list, 200)
      assert user_body["id"] == personal.id
      assert_repository_keys(user_body, :minimal, version)

      organization_list =
        api_conn(version: version)
        |> get("/api/v3/orgs/acme/repos")

      assert [organization_body] = json_response(organization_list, 200)
      assert organization_body["id"] == organization_repository.id
      assert_repository_keys(organization_body, :minimal, version)

      show = api_conn(version: version) |> get("/api/v3/repos/alice/personal")
      show_body = json_response(show, 200)
      assert show_body["id"] == personal.id
      assert_repository_keys(show_body, :full, version)

      for conn <- [authenticated, user_list, organization_list, show] do
        assert get_resp_header(conn, "x-github-api-version-selected") == [version]
        assert [request_id] = get_resp_header(conn, "x-github-request-id")
        assert request_id != ""
      end
    end
  end

  test "authenticated listing includes owned, organization, and collaborator repositories with pinned scope ceilings",
       %{alice: alice} do
    bob = user("bob")
    organization = organization(alice, "acme")
    owned_public = repository(alice, "owned-public", visibility: :public)
    owned_private = repository(alice, "owned-private", visibility: :private)
    organization_private = repository(organization, "organization-private", visibility: :private)
    collaborated = repository(bob, "collaborated", visibility: :private)
    collaborator(collaborated, alice, :read)
    _unrelated = repository(bob, "unrelated", visibility: :private)

    {_public_key, public_secret} = pat(alice, ["public_repo"])
    public = api_conn(secret: public_secret) |> get("/api/v3/user/repos")
    assert repository_ids(json_response(public, 200)) == [owned_public.id]
    assert accepted_scopes(public) == "public_repo"

    for scope <- ["repo", "repo:read", "repo:write"] do
      {_key, secret} = pat(alice, [scope], name: "list-#{scope}")
      conn = api_conn(secret: secret) |> get("/api/v3/user/repos")

      assert Enum.sort(repository_ids(json_response(conn, 200))) ==
               Enum.sort([
                 owned_public.id,
                 owned_private.id,
                 organization_private.id,
                 collaborated.id
               ])

      assert accepted_scopes(conn) == @private_read_scopes
    end

    {_org_key, org_secret} = pat(alice, ["read:org"])
    insufficient = api_conn(secret: org_secret) |> get("/api/v3/user/repos")

    assert_error(
      insufficient,
      403,
      "Resource not accessible by personal access token",
      @authenticated_list_url,
      "public_repo"
    )

    assert_error(
      api_conn() |> get("/api/v3/user/repos"),
      401,
      "Bad credentials",
      @authenticated_list_url,
      "public_repo"
    )
  end

  test "account lists expose public rows anonymously and private rows only to a capable reader",
       %{
         alice: alice
       } do
    bob = user("bob")
    organization = organization(alice, "acme")
    public_personal = repository(alice, "public-personal", visibility: :public)
    private_personal = repository(alice, "private-personal", visibility: :private)
    public_organization = repository(organization, "public-organization", visibility: :public)
    private_organization = repository(organization, "private-organization", visibility: :private)

    anonymous_user = api_conn() |> get("/api/v3/users/alice/repos")
    assert repository_ids(json_response(anonymous_user, 200)) == [public_personal.id]
    assert accepted_scopes(anonymous_user) == ""

    {_public_key, public_secret} = pat(alice, ["public_repo"])
    public_only = api_conn(secret: public_secret) |> get("/api/v3/users/alice/repos?type=all")

    assert Enum.sort(repository_ids(json_response(public_only, 200))) ==
             Enum.sort([public_personal.id, public_organization.id])

    assert accepted_scopes(public_only) == ""

    {_private_key, private_secret} = pat(alice, ["repo"])

    private_capable =
      api_conn(secret: private_secret)
      |> get("/api/v3/users/alice/repos?type=all")

    assert Enum.sort(repository_ids(json_response(private_capable, 200))) ==
             Enum.sort([
               public_personal.id,
               private_personal.id,
               public_organization.id,
               private_organization.id
             ])

    assert accepted_scopes(private_capable) == @private_read_scopes

    {_bob_key, bob_secret} = pat(bob, ["repo"])
    unrelated = api_conn(secret: bob_secret) |> get("/api/v3/users/alice/repos")
    assert repository_ids(json_response(unrelated, 200)) == [public_personal.id]
    assert accepted_scopes(unrelated) == @private_read_scopes

    organization_list = api_conn() |> get("/api/v3/orgs/acme/repos")
    assert repository_ids(json_response(organization_list, 200)) == [public_organization.id]
    assert accepted_scopes(organization_list) == ""
  end

  test "account routes resolve active exact account kinds and preserve invalid-token rejection",
       %{
         alice: alice
       } do
    organization = organization(alice, "acme")
    disabled_user = user("disabled-user", state: :disabled)
    disabled_organization = organization(alice, "disabled-org", state: :disabled)

    for path <- [
          "/api/v3/users/#{organization.username}/repos",
          "/api/v3/users/#{disabled_user.username}/repos",
          "/api/v3/users/missing/repos"
        ] do
      assert_error(api_conn() |> get(path), 404, "Not Found", @user_list_url, "")
    end

    for path <- [
          "/api/v3/orgs/#{alice.username}/repos",
          "/api/v3/orgs/#{disabled_organization.username}/repos",
          "/api/v3/orgs/missing/repos"
        ] do
      assert_error(api_conn() |> get(path), 404, "Not Found", @organization_list_url, "")
    end

    invalid = api_conn(secret: "fc_pat_invalid") |> get("/api/v3/users/alice/repos")
    assert_error(invalid, 401, "Bad credentials", @authentication_url, "")
  end

  test "authenticated filters, timestamps, and canonical pagination links retain only supported parameters",
       %{alice: alice} do
    bob = user("bob")
    organization = organization(alice, "acme")
    old_public = repository(alice, "old-public", visibility: :public)
    new_private = repository(alice, "new-private", visibility: :private)
    member = repository(organization, "member", visibility: :private)
    collaborated = repository(bob, "collaborated", visibility: :private)
    collaborator(collaborated, alice, :read)

    set_times(old_public, ~U[2026-07-20 10:00:00Z], ~U[2026-07-20 11:00:00Z])
    set_times(new_private, ~U[2026-07-21 10:00:00Z], ~U[2026-07-21 11:00:00Z])
    set_times(member, ~U[2026-07-22 10:00:00Z], ~U[2026-07-22 11:00:00Z])
    set_times(collaborated, ~U[2026-07-23 10:00:00Z], nil)
    {_key, secret} = pat(alice, ["repo"])

    assert [body] =
             api_conn(secret: secret)
             |> get("/api/v3/user/repos?visibility=public")
             |> json_response(200)

    assert body["id"] == old_public.id

    assert [body] =
             api_conn(secret: secret)
             |> get("/api/v3/user/repos?affiliation=collaborator")
             |> json_response(200)

    assert body["id"] == collaborated.id

    assert [body] =
             api_conn(secret: secret)
             |> get("/api/v3/user/repos?type=member")
             |> json_response(200)

    assert body["id"] == member.id

    assert repository_ids(
             api_conn(secret: secret)
             |> get("/api/v3/user/repos?since=2026-07-21T10%3A00%3A00.500Z")
             |> json_response(200)
           ) == [member.id, collaborated.id]

    assert repository_ids(
             api_conn(secret: secret)
             |> get("/api/v3/user/repos?before=2026-07-22T10%3A00%3A00.500Z")
             |> json_response(200)
           ) == [member.id, new_private.id, old_public.id]

    page =
      api_conn(secret: secret)
      |> get(
        "/api/v3/user/repos?sort=updated&direction=asc&affiliation=owner&page=1&per_page=1&ignored=drop-me"
      )

    assert [first] = json_response(page, 200)
    assert first["id"] == old_public.id
    assert [link] = get_resp_header(page, "link")
    assert link =~ "affiliation=owner"
    assert link =~ "direction=asc"
    assert link =~ "sort=updated"
    assert link =~ "page=2"
    assert link =~ "per_page=1"
    refute link =~ "ignored"
    assert link == canonicalized_link(link)
  end

  test "account list type filters and pagination follow the user and organization contracts", %{
    alice: alice
  } do
    organization = organization(alice, "acme")
    personal = repository(alice, "personal", visibility: :public)
    organization_public = repository(organization, "org-public", visibility: :public)
    organization_private = repository(organization, "org-private", visibility: :private)
    {_key, secret} = pat(alice, ["repo"])

    owner = api_conn(secret: secret) |> get("/api/v3/users/alice/repos?type=owner")
    assert repository_ids(json_response(owner, 200)) == [personal.id]

    member = api_conn(secret: secret) |> get("/api/v3/users/alice/repos?type=member")

    assert Enum.sort(repository_ids(json_response(member, 200))) ==
             Enum.sort([organization_public.id, organization_private.id])

    sources =
      api_conn(secret: secret)
      |> get("/api/v3/orgs/acme/repos?type=sources&sort=full_name&direction=asc")

    assert repository_ids(json_response(sources, 200)) ==
             [organization_private.id, organization_public.id]

    for type <- ~w(forks internal member) do
      conn = api_conn(secret: secret) |> get("/api/v3/orgs/acme/repos?type=#{type}")
      assert json_response(conn, 200) == []
    end

    public = api_conn(secret: secret) |> get("/api/v3/orgs/acme/repos?type=public")
    assert repository_ids(json_response(public, 200)) == [organization_public.id]

    private = api_conn(secret: secret) |> get("/api/v3/orgs/acme/repos?type=private")
    assert repository_ids(json_response(private, 200)) == [organization_private.id]

    canonical_user =
      api_conn(secret: secret)
      |> get("/api/v3/users/ALICE/repos?type=all&page=1&per_page=1")

    assert [user_link] = get_resp_header(canonical_user, "link")
    assert user_link =~ "http://localhost:4890/api/v3/users/alice/repos?"
    refute user_link =~ "/users/ALICE/"

    canonical_organization =
      api_conn(secret: secret)
      |> get("/api/v3/orgs/ACME/repos?type=sources&page=1&per_page=1")

    assert [organization_link] = get_resp_header(canonical_organization, "link")
    assert organization_link =~ "http://localhost:4890/api/v3/orgs/acme/repos?"
    refute organization_link =~ "/orgs/ACME/"
  end

  test "all list validators reject invalid values and huge positive pages are empty", %{
    alice: alice
  } do
    organization(alice, "acme")
    repository(alice, "only", visibility: :public)
    {_key, secret} = pat(alice, ["repo"])

    for {path, field, documentation_url} <- [
          {"/api/v3/user/repos?page=0", "page", @authenticated_list_url},
          {"/api/v3/user/repos?per_page=101", "per_page", @authenticated_list_url},
          {"/api/v3/user/repos?visibility=internal", "visibility", @authenticated_list_url},
          {"/api/v3/user/repos?affiliation=owner,owner", "affiliation", @authenticated_list_url},
          {"/api/v3/user/repos?type=owner&visibility=public", "type", @authenticated_list_url},
          {"/api/v3/user/repos?sort=stars", "sort", @authenticated_list_url},
          {"/api/v3/user/repos?direction=sideways", "direction", @authenticated_list_url},
          {"/api/v3/user/repos?since=yesterday", "since", @authenticated_list_url},
          {"/api/v3/user/repos?before=tomorrow", "before", @authenticated_list_url},
          {"/api/v3/users/alice/repos?type=private", "type", @user_list_url},
          {"/api/v3/users/alice/repos?sort=stars", "sort", @user_list_url},
          {"/api/v3/orgs/acme/repos?type=unknown", "type", @organization_list_url}
        ] do
      conn = api_conn(secret: secret) |> get(path)
      assert_validation(conn, field, documentation_url)
      assert accepted_scopes(conn) == @private_read_scopes
    end

    for path <- [
          "/api/v3/user/repos?page=9223372036854775807&per_page=100",
          "/api/v3/users/alice/repos?page=9223372036854775807&per_page=100",
          "/api/v3/orgs/acme/repos?page=9223372036854775807&per_page=100"
        ] do
      conn = api_conn(secret: secret) |> get(path)
      assert json_response(conn, 200) == []
    end
  end

  test "show allows anonymous public reads, masks private rows, and applies private scopes after authorization",
       %{alice: alice} do
    bob = user("bob")
    public = repository(alice, "public", visibility: :public)
    private = repository(alice, "private", visibility: :private)
    collaborated = repository(bob, "collaborated", visibility: :private)
    collaborator(collaborated, alice, :read)

    public_conn = api_conn() |> get("/api/v3/repos/alice/public")
    assert json_response(public_conn, 200)["id"] == public.id
    assert accepted_scopes(public_conn) == ""

    assert_error(
      api_conn() |> get("/api/v3/repos/alice/private"),
      404,
      "Not Found",
      @show_url,
      ""
    )

    {_public_key, public_secret} = pat(alice, ["public_repo"])

    visible_but_unscoped =
      api_conn(secret: public_secret)
      |> get("/api/v3/repos/alice/private")

    assert_error(
      visible_but_unscoped,
      403,
      "Resource not accessible by personal access token",
      @show_url,
      @private_read_scopes
    )

    for scope <- ["repo", "repo:read", "repo:write"] do
      {_key, secret} = pat(alice, [scope], name: "show-#{scope}")
      conn = api_conn(secret: secret) |> get("/api/v3/repos/bob/collaborated")
      assert json_response(conn, 200)["id"] == collaborated.id
      assert accepted_scopes(conn) == @private_read_scopes
    end

    {_bob_key, bob_secret} = pat(bob, ["repo"])
    hidden = api_conn(secret: bob_secret) |> get("/api/v3/repos/alice/private")
    assert_error(hidden, 404, "Not Found", @show_url, "")

    invalid = api_conn(secret: "fc_pat_invalid") |> get("/api/v3/repos/alice/public")
    assert_error(invalid, 401, "Bad credentials", @authentication_url, "")

    Repo.delete!(private)

    assert_error(
      api_conn() |> get("/api/v3/repos/alice/private"),
      404,
      "Not Found",
      @show_url,
      ""
    )
  end

  test "personal creation defaults public, preserves false flags, creates bare storage, and audits metadata",
       %{alice: alice} do
    {api_key, secret} = pat(alice, ["public_repo"])

    for {version, name} <- Enum.zip(@versions, ["Public 2022", "Public 2026"]) do
      conn =
        api_conn(secret: secret, version: version, request_id: "create-#{version}")
        |> post_json("/api/v3/user/repos", %{
          "name" => name,
          "description" => "API repository",
          "auto_init" => false,
          "has_issues" => false,
          "allow_merge_commit" => false,
          "has_projects" => false,
          "has_wiki" => false,
          "has_discussions" => false,
          "allow_squash_merge" => false,
          "allow_rebase_merge" => false
        })

      body = json_response(conn, 201)
      assert body["visibility"] == "public"
      assert body["private"] == false
      assert body["has_issues"] == false
      assert body["allow_merge_commit"] == false
      assert body["url"] == "http://localhost:4890/api/v3/repos/alice/#{body["name"] |> slug()}"
      assert body["html_url"] == "http://localhost:4890/alice/#{body["name"] |> slug()}"
      assert body["clone_url"] == "http://localhost:4890/alice/#{body["name"] |> slug()}.git"
      assert body["ssh_url"] =~ "alice/#{body["name"] |> slug()}.git"

      assert body["permissions"] == %{
               "admin" => true,
               "maintain" => false,
               "pull" => true,
               "push" => true,
               "triage" => false
             }

      assert_repository_keys(body, :full, version)
      assert accepted_scopes(conn) == "public_repo"

      repository = ForgeRepos.get_repository("alice", slug(body["name"]))

      assert {:ok, true} =
               GitCore.is_bare_repository?(ForgeRepos.absolute_storage_path(repository))

      assert {:ok, true} = GitCore.empty?(ForgeRepos.absolute_storage_path(repository))

      assert %AuditEvent{} =
               audit = Repo.get_by!(AuditEvent, target_id: Integer.to_string(repository.id))

      assert audit.action == "repository.created"
      assert audit.actor_user_id == alice.id
      assert audit.ip_address == "127.0.0.1"
      assert audit.user_agent == @user_agent

      assert audit.metadata["request_id"] ==
               List.first(get_resp_header(conn, "x-github-request-id"))

      assert audit.metadata["token_id"] == api_key.id
    end
  end

  test "private and organization creation require exact scopes and namespace permission before body admission",
       %{alice: alice} do
    organization = organization(alice, "acme")
    member = user("member")
    organization_member(organization, member, :member)
    site_admin = user("site-admin", role: :admin)
    {_owner_key, owner_repo_secret} = pat(alice, ["repo"])
    {_owner_public_key, owner_public_secret} = pat(alice, ["public_repo"])
    {_member_key, member_secret} = pat(member, ["repo"])
    {_admin_key, admin_secret} = pat(site_admin, ["public_repo"])

    private =
      api_conn(secret: owner_repo_secret)
      |> post_json("/api/v3/user/repos", %{
        "name" => "private-repository",
        "private" => true,
        "auto_init" => false
      })

    assert json_response(private, 201)["visibility"] == "private"
    assert accepted_scopes(private) == "repo"

    public_to_private =
      api_conn(secret: owner_public_secret)
      |> post_json("/api/v3/user/repos", %{"name" => "denied-private", "private" => true})

    assert_error(
      public_to_private,
      403,
      "Resource not accessible by personal access token",
      @personal_create_url,
      "repo"
    )

    owner_created =
      api_conn(secret: owner_public_secret)
      |> post_json("/api/v3/orgs/acme/repos", %{"name" => "owner-created", "auto_init" => false})

    assert json_response(owner_created, 201)["full_name"] == "acme/owner-created"
    assert accepted_scopes(owner_created) == "public_repo"

    malformed_member = api_conn(secret: member_secret) |> post_raw("/api/v3/orgs/acme/repos", "{")
    assert_error(malformed_member, 403, "Forbidden", @organization_create_url, "public_repo")

    admin_created =
      api_conn(secret: admin_secret)
      |> post_json("/api/v3/orgs/acme/repos", %{"name" => "admin-created", "auto_init" => false})

    assert json_response(admin_created, 201)["full_name"] == "acme/admin-created"

    {_legacy_key, legacy_secret} = pat(alice, ["repo:write"])
    legacy = api_conn(secret: legacy_secret) |> post_raw("/api/v3/user/repos", "{")

    assert_error(
      legacy,
      403,
      "Resource not accessible by personal access token",
      @personal_create_url,
      "public_repo"
    )

    missing = api_conn() |> post_raw("/api/v3/user/repos", "{")
    assert_error(missing, 401, "Bad credentials", @personal_create_url, "public_repo")
  end

  test "create validates both versions, conflicts, and every unsupported feature without side effects",
       %{alice: alice} do
    {_key, secret} = pat(alice, ["repo"])
    before_rows = Repo.aggregate(Repository, :count, :id)
    before_audits = Repo.aggregate(AuditEvent, :count, :id)

    for version <- @versions do
      missing = api_conn(secret: secret, version: version) |> post_json("/api/v3/user/repos", %{})
      assert_validation(missing, "name", @personal_create_url, "missing_field")
    end

    for {body, field, code} <- [
          {%{"name" => "conflict", "private" => true, "visibility" => "public"}, "visibility",
           "unprocessable"},
          {%{"name" => "internal", "visibility" => "internal"}, "visibility", "unprocessable"},
          {%{"name" => "unknown", "unknown" => true}, "unknown", "unprocessable"}
        ] do
      conn = api_conn(secret: secret) |> post_json("/api/v3/user/repos", body)
      assert_validation(conn, field, @personal_create_url, code)
    end

    for feature <- ~w(has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge) do
      conn =
        api_conn(secret: secret)
        |> post_json("/api/v3/user/repos", %{"name" => "unsupported-#{feature}", feature => true})

      assert_validation(conn, feature, @personal_create_url, "unprocessable")
    end

    assert Repo.aggregate(Repository, :count, :id) == before_rows
    assert Repo.aggregate(AuditEvent, :count, :id) == before_audits
  end

  test "auto_init true returns a sanitized unavailable response with no row, storage, or audit",
       %{
         alice: alice,
         storage_root: storage_root
       } do
    {_key, secret} = pat(alice, ["public_repo"])
    before_paths = repository_paths(storage_root)

    unavailable =
      api_conn(secret: secret)
      |> post_json("/api/v3/user/repos", %{"name" => "initialized", "auto_init" => true})

    assert_error(unavailable, 503, "Service unavailable", @personal_create_url, "public_repo")
    refute unavailable.resp_body =~ "initializer"
    assert ForgeRepos.get_repository("alice", "initialized") == nil
    assert repository_paths(storage_root) == before_paths
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "writers update flags while administrators rename, change branches, and receive full versioned resources",
       %{alice: alice, storage_root: storage_root} do
    writer = user("writer")
    repository = repository(alice, "before", visibility: :public)
    collaborator(repository, writer, :write)
    {_writer_key, writer_secret} = pat(writer, ["public_repo"])
    {_owner_key, owner_secret} = pat(alice, ["public_repo"])

    flags =
      api_conn(secret: writer_secret)
      |> patch_json("/api/v3/repos/alice/before", %{
        "has_issues" => false,
        "allow_merge_commit" => false
      })

    flags_body = json_response(flags, 200)
    assert flags_body["has_issues"] == false
    assert flags_body["allow_merge_commit"] == false
    assert accepted_scopes(flags) == "public_repo"

    create_branch!(repository, "trunk", storage_root)

    for {version, name} <- Enum.zip(@versions, ["After 2022", "After 2026"]) do
      current = Repo.get!(Repository, repository.id)

      renamed =
        api_conn(secret: owner_secret, version: version, request_id: "update-#{version}")
        |> patch_json("/api/v3/repos/alice/#{current.slug}", %{
          "name" => name,
          "description" => "renamed",
          "default_branch" => "trunk"
        })

      body = json_response(renamed, 200)
      assert body["name"] == name
      assert body["full_name"] == "alice/#{slug(name)}"
      assert body["description"] == "renamed"
      assert body["default_branch"] == "trunk"
      assert body["url"] == "http://localhost:4890/api/v3/repos/alice/#{slug(name)}"
      assert_repository_keys(body, :full, version)
      assert accepted_scopes(renamed) == "public_repo"

      assert %AuditEvent{metadata: %{"request_id" => request_id}} =
               Repo.one!(
                 from event in AuditEvent,
                   where: event.action == "repository.updated",
                   order_by: [desc: event.id],
                   limit: 1
               )

      assert request_id == List.first(get_resp_header(renamed, "x-github-request-id"))
    end

    assert ForgeRepos.get_repository("alice", "before") == nil

    assert ForgeRepos.get_repository("alice", "after-2026").storage_path ==
             repository.storage_path
  end

  test "update enforces stored and resulting visibility scopes and exact domain permissions", %{
    alice: alice
  } do
    writer = user("writer")
    reader = user("reader")
    public = repository(alice, "public", visibility: :public)
    _private = repository(alice, "private", visibility: :private)
    _hidden_private = repository(alice, "hidden-private", visibility: :private)
    readable_private = repository(alice, "readable-private", visibility: :private)
    collaborator(public, writer, :write)
    collaborator(public, reader, :read)
    collaborator(readable_private, reader, :read)
    {_writer_key, writer_secret} = pat(writer, ["public_repo"])
    {_reader_key, reader_secret} = pat(reader, ["public_repo"])
    {_owner_public_key, owner_public_secret} = pat(alice, ["public_repo"])
    {_owner_repo_key, owner_repo_secret} = pat(alice, ["repo"])

    writer_admin =
      api_conn(secret: writer_secret)
      |> patch_json("/api/v3/repos/alice/public", %{"name" => "writer-rename"})

    assert_error(writer_admin, 403, "Forbidden", @update_url, "public_repo")

    reader_malformed =
      api_conn(secret: reader_secret) |> patch_raw("/api/v3/repos/alice/public", "{")

    assert_error(reader_malformed, 403, "Forbidden", @update_url, "public_repo")

    {_reader_private_key, reader_private_secret} = pat(reader, ["repo"])

    private_reader_malformed =
      api_conn(secret: reader_private_secret)
      |> patch_raw("/api/v3/repos/alice/readable-private", "{")

    assert_error(private_reader_malformed, 403, "Forbidden", @update_url, "repo")

    resulting_private =
      api_conn(secret: owner_public_secret)
      |> patch_json("/api/v3/repos/alice/public", %{"private" => true})

    assert_error(
      resulting_private,
      403,
      "Resource not accessible by personal access token",
      @update_url,
      "repo"
    )

    private_to_public =
      api_conn(secret: owner_repo_secret)
      |> patch_json("/api/v3/repos/alice/private", %{"private" => false})

    assert json_response(private_to_public, 200)["visibility"] == "public"
    assert accepted_scopes(private_to_public) == "repo"

    hidden =
      api_conn(secret: writer_secret)
      |> patch_raw("/api/v3/repos/alice/hidden-private", "{")

    assert_error(hidden, 404, "Not Found", @update_url, "public_repo")

    {_legacy_key, legacy_secret} = pat(alice, ["repo:write"])
    legacy = api_conn(secret: legacy_secret) |> patch_raw("/api/v3/repos/alice/public", "{")

    assert_error(
      legacy,
      403,
      "Resource not accessible by personal access token",
      @update_url,
      "public_repo"
    )
  end

  test "a visibility change while a PATCH body is in flight is rechecked before mutation", %{
    alice: alice
  } do
    repository = repository(alice, "racing", visibility: :public)
    {_key, secret} = pat(alice, ["public_repo"])
    ref = make_ref()

    conn =
      api_conn(secret: secret)
      |> put_req_header("content-type", @json_media_type)
      |> pausing_patch_conn(
        "/api/v3/repos/alice/racing",
        JSON.encode!(%{"has_issues" => false}),
        ref
      )

    task =
      Task.async(fn ->
        receive do
          {^ref, :start} -> FornacastAPI.Endpoint.call(conn, FornacastAPI.Endpoint.init([]))
        end
      end)

    allow_database_access(task.pid)
    send(task.pid, {ref, :start})
    assert_receive {^ref, :body_read, request_pid}, 2_000

    {1, nil} =
      Repository
      |> where(id: ^repository.id)
      |> Repo.update_all(set: [visibility: :private])

    send(request_pid, {ref, :continue_body})
    response = Task.await(task, 5_000)

    assert_error(
      response,
      403,
      "Resource not accessible by personal access token",
      @update_url,
      "repo"
    )

    persisted = Repo.get!(Repository, repository.id)
    assert persisted.visibility == :private
    assert persisted.has_issues
    refute Repo.exists?(from event in AuditEvent, where: event.action == "repository.updated")
  end

  test "update validates bodies, visibility conflicts, unsupported fields, and existing default branches",
       %{alice: alice} do
    repository(alice, "settings", visibility: :public)
    {_key, secret} = pat(alice, ["repo"])
    before_audits = Repo.aggregate(AuditEvent, :count, :id)

    for {body, field, code} <- [
          {%{"private" => true, "visibility" => "public"}, "visibility", "unprocessable"},
          {%{"visibility" => "internal"}, "visibility", "unprocessable"},
          {%{"auto_init" => false}, "auto_init", "unprocessable"},
          {%{"default_branch" => "missing"}, "default_branch", "missing"},
          {%{"unknown" => true}, "unknown", "unprocessable"}
        ] do
      conn =
        api_conn(secret: secret)
        |> patch_json("/api/v3/repos/alice/settings", body)

      assert_validation(conn, field, @update_url, code)
    end

    for feature <- ~w(has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge) do
      conn =
        api_conn(secret: secret)
        |> patch_json("/api/v3/repos/alice/settings", %{feature => true})

      assert_validation(conn, feature, @update_url, "unprocessable")
    end

    assert Repo.aggregate(AuditEvent, :count, :id) == before_audits
  end

  test "mutation failures keep common GitHub headers and operation-specific error bodies", %{
    alice: alice
  } do
    repository(alice, "public", visibility: :public)
    unavailable = repository(alice, "unavailable", visibility: :public)
    {_key, secret} = pat(alice, ["public_repo"])

    duplicate =
      api_conn(secret: secret)
      |> post_json("/api/v3/user/repos", %{"name" => "public", "auto_init" => false})

    assert_validation(duplicate, "name", @personal_create_url, "already_exists")

    missing = api_conn() |> patch_json("/api/v3/repos/alice/public", %{"description" => "x"})
    assert_error(missing, 401, "Bad credentials", @update_url, "public_repo")

    {1, nil} =
      Repository
      |> where(id: ^unavailable.id)
      |> Repo.update_all(set: [storage_path: "../escape.git"])

    post_update_view_failure =
      api_conn(secret: secret)
      |> patch_json("/api/v3/repos/alice/unavailable", %{"description" => "updated"})

    assert_error(
      post_update_view_failure,
      503,
      "Service unavailable",
      @update_url,
      "public_repo"
    )

    for conn <- [duplicate, missing, post_update_view_failure] do
      assert [_] = get_resp_header(conn, "x-github-request-id")
      assert [_] = get_resp_header(conn, "x-github-api-version-selected")
      assert [_] = get_resp_header(conn, "x-github-media-type")
      assert [_] = get_resp_header(conn, "x-ratelimit-limit")
    end
  end

  defp api_conn(opts \\ []) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_optional_header("x-github-api-version", opts[:version])
    |> put_optional_header("x-request-id", opts[:request_id])
    |> put_optional_authorization(opts[:secret])
  end

  defp pausing_patch_conn(conn, path, body, ref) do
    conn = Plug.Adapters.Test.Conn.conn(conn, :patch, path, body)
    {Plug.Adapters.Test.Conn, delegate} = conn.adapter

    %{
      conn
      | adapter: {PausingBodyAdapter, %{delegate: delegate, test_pid: self(), ref: ref}}
    }
  end

  defp allow_database_access(request_pid) do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), request_pid)
    else
      :ok
    end
  end

  defp post_json(conn, path, body), do: post_raw(conn, path, JSON.encode!(body))
  defp patch_json(conn, path, body), do: patch_raw(conn, path, JSON.encode!(body))

  defp post_raw(conn, path, body) do
    conn |> put_req_header("content-type", @json_media_type) |> post(path, body)
  end

  defp patch_raw(conn, path, body) do
    conn |> put_req_header("content-type", @json_media_type) |> patch(path, body)
  end

  defp put_optional_header(conn, _name, nil), do: conn
  defp put_optional_header(conn, name, value), do: put_req_header(conn, name, value)
  defp put_optional_authorization(conn, nil), do: conn

  defp put_optional_authorization(conn, secret) do
    {name, value} = authorization(secret, "Bearer")
    put_req_header(conn, name, value)
  end

  defp repository(owner, slug, opts) do
    storage_path = "@api-test/#{owner.id}/#{slug}-#{System.unique_integer([:positive])}.git"

    repository =
      %Repository{owner_user_id: owner.id, storage_path: storage_path}
      |> Repository.create_changeset(%{
        name: Keyword.get(opts, :name, slug),
        slug: slug,
        description: Keyword.get(opts, :description),
        visibility: Keyword.get(opts, :visibility, :private),
        default_branch: Keyword.get(opts, :default_branch, "main"),
        has_issues: Keyword.get(opts, :has_issues, true),
        allow_merge_commit: Keyword.get(opts, :allow_merge_commit, true)
      })
      |> Repo.insert!()

    path = ForgeRepos.absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))
    {:ok, _path} = GitCore.init_bare(path)
    repository
  end

  defp collaborator(repository, user, role) do
    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  defp organization_member(organization, user, role) do
    %OrganizationMember{}
    |> OrganizationMember.changeset(%{
      organization_id: organization.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp set_times(repository, updated_at, last_pushed_at) do
    {1, nil} =
      Repository
      |> where(id: ^repository.id)
      |> Repo.update_all(
        set: [inserted_at: updated_at, updated_at: updated_at, last_pushed_at: last_pushed_at]
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

    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.test"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.test"}
    ]

    {commit, 0} =
      System.cmd(
        "git",
        ["--git-dir=#{path}", "commit-tree", String.trim(tree), "-m", "initial"],
        env: env,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "git",
        ["--git-dir=#{path}", "update-ref", "refs/heads/#{branch}", String.trim(commit)],
        stderr_to_stdout: true
      )
  end

  defp repository_ids(bodies), do: Enum.map(bodies, & &1["id"])

  defp accepted_scopes(conn),
    do: conn |> get_resp_header("x-accepted-oauth-scopes") |> List.first()

  defp slug(name), do: Repository.normalize_slug(name)

  defp repository_paths(root),
    do: Path.wildcard(Path.join([root, "**", "*.git"]), match_dot: true)

  defp assert_repository_keys(body, resource, version) do
    expected =
      case resource do
        :minimal -> @minimal_repository_keys
        :repository -> @repository_keys
        :full -> @full_repository_keys
      end

    expected = if version == "2022-11-28", do: ["has_downloads" | expected], else: expected
    assert Enum.sort(Map.keys(body)) == Enum.sort(expected)
  end

  defp assert_validation(conn, field, documentation_url, code \\ nil) do
    body = json_response(conn, 422)
    assert body["message"] == "Validation Failed"
    assert body["documentation_url"] == documentation_url

    assert Enum.any?(body["errors"], fn error ->
             error["field"] == field and (is_nil(code) or error["code"] == code)
           end)
  end

  defp assert_error(conn, status, message, documentation_url, accepted_scopes) do
    body = json_response(conn, status)
    assert body == %{"documentation_url" => documentation_url, "message" => message}
    assert get_resp_header(conn, "x-accepted-oauth-scopes") == [accepted_scopes]
  end

  defp canonicalized_link(link) do
    link
    |> String.split(", ")
    |> Enum.map_join(", ", fn entry ->
      [wrapped_url, relation] = String.split(entry, ">; ", parts: 2)
      "<" <> url = wrapped_url
      uri = URI.parse(url)

      query =
        uri.query
        |> URI.query_decoder()
        |> Enum.sort()
        |> URI.encode_query(:rfc3986)

      "<#{URI.to_string(%{uri | query: query})}>; #{relation}"
    end)
  end
end
