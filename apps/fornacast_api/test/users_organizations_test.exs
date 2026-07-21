defmodule FornacastAPI.UsersOrganizationsTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias Fornacast.{AuditEvent, Repo}

  @versions ["2022-11-28", "2026-03-10"]
  @user_agent "fornacast-account-api-test/1.0"
  @json_media_type "application/vnd.github+json"
  @authentication_url "https://docs.github.com/en/enterprise-server@3.21/rest/authentication/authenticating-to-the-rest-api"
  @authenticated_user_url "https://docs.github.com/en/enterprise-server@3.21/rest/users/users#get-the-authenticated-user"
  @create_url "https://docs.github.com/en/enterprise-server@3.21/rest/enterprise-admin/orgs#create-an-organization"
  @update_url "https://docs.github.com/en/enterprise-server@3.21/rest/orgs/orgs#update-an-organization"

  @private_user_keys ~w(
    avatar_url bio blog collaborators company created_at disk_usage email events_url followers
    followers_url following following_url gists_url gravatar_id hireable html_url id location login
    name node_id organizations_url owned_private_repos private_gists public_gists public_repos
    received_events_url repos_url site_admin starred_url subscriptions_url total_private_repos
    two_factor_authentication type updated_at url
  )
  @public_user_keys @private_user_keys --
                      ~w(collaborators disk_usage owned_private_repos private_gists
                         total_private_repos two_factor_authentication)
  @organization_simple_keys ~w(
    avatar_url description events_url hooks_url id issues_url login members_url node_id
    public_members_url repos_url url
  )
  @organization_full_keys @organization_simple_keys ++
                            ~w(archived_at created_at followers following has_organization_projects
                               has_repository_projects html_url name public_gists public_repos type
                               updated_at)

  setup do
    alice = user("alice", display_name: "Alice Example", description: "Maintainer")
    %{alice: alice}
  end

  test "GET /user renders the complete private account for both API versions", %{alice: alice} do
    for {version, scope} <-
          for(
            version <- @versions,
            scope <- ["repo", "public_repo", "read:org", "write:org", "repo:read", "repo:write"],
            do: {version, scope}
          ) do
      {_api_key, secret} = pat(alice, [scope], name: "#{version}-#{scope}")

      conn = api_conn(secret: secret, version: version) |> get("/api/v3/user")
      body = json_response(conn, 200)

      assert_complete_private_user(body, alice)
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == [""]
      assert get_resp_header(conn, "x-github-api-version-selected") == [version]
    end
  end

  test "GET /user requires a valid PAT and reports no accepted alternatives" do
    missing = api_conn() |> get("/api/v3/user")
    assert_error(missing, 401, "Bad credentials", @authenticated_user_url, "")

    invalid = api_conn(secret: "fc_pat_invalid") |> get("/api/v3/user")
    assert_error(invalid, 401, "Bad credentials", @authentication_url, "")
  end

  test "GET /users/:username is anonymous, typed, active, and versioned", %{alice: alice} do
    org = organization(alice, "alice-labs")
    disabled = user("disabled-user", state: :disabled)

    for version <- @versions do
      conn = api_conn(version: version) |> get("/api/v3/users/Alice")
      body = json_response(conn, 200)

      assert_complete_public_user(body, alice)
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == [""]
      assert get_resp_header(conn, "x-github-api-version-selected") == [version]
    end

    assert_not_found(api_conn() |> get("/api/v3/users/#{disabled.username}"))
    assert_not_found(api_conn() |> get("/api/v3/users/#{org.username}"))
    assert_not_found(api_conn() |> get("/api/v3/users/missing"))

    invalid = api_conn(secret: "fc_pat_invalid") |> get("/api/v3/users/alice")
    assert_error(invalid, 401, "Bad credentials", @authentication_url, "")
  end

  test "GET /user/orgs paginates active memberships and exposes only read:org", %{alice: alice} do
    alpha = organization(alice, "alpha")
    beta = organization(alice, "beta")
    _gamma = organization(alice, "gamma")
    _disabled = organization(alice, "hidden-org", state: :disabled)

    for version <- @versions do
      {_api_key, secret} = pat(alice, ["write:org"], name: "org-list-#{version}")

      conn =
        api_conn(secret: secret, version: version)
        |> get("/api/v3/user/orgs?page=1&per_page=2")

      assert [first, second] = json_response(conn, 200)
      assert first["login"] == alpha.username
      assert second["login"] == beta.username
      assert Enum.sort(Map.keys(first)) == Enum.sort(@organization_simple_keys)
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == ["read:org"]

      assert [link] = get_resp_header(conn, "link")
      assert link =~ "<http://localhost:4890/api/v3/user/orgs?page=2&per_page=2>; rel=\"next\""
      assert link =~ "<http://localhost:4890/api/v3/user/orgs?page=2&per_page=2>; rel=\"last\""
    end

    for scope <- ["read:org", "write:org"] do
      {_key, secret} = pat(alice, [scope], name: "allowed-#{scope}")
      conn = api_conn(secret: secret) |> get("/api/v3/user/orgs")
      assert is_list(json_response(conn, 200))
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == ["read:org"]
    end

    for scope <- ["repo", "public_repo", "repo:read", "repo:write"] do
      {_key, secret} = pat(alice, [scope], name: "rejected-#{scope}")
      conn = api_conn(secret: secret) |> get("/api/v3/user/orgs")
      assert_error(conn, 403, "Resource not accessible by personal access token", nil, "read:org")
    end

    assert_error(api_conn() |> get("/api/v3/user/orgs"), 401, "Bad credentials", nil, "read:org")

    {_key, secret} = pat(alice, ["read:org"], name: "bad-pagination")
    invalid = api_conn(secret: secret) |> get("/api/v3/user/orgs?page=0&per_page=101")
    body = json_response(invalid, 422)
    assert Enum.map(body["errors"], & &1["field"]) == ["page", "per_page"]
    assert get_resp_header(invalid, "x-accepted-oauth-scopes") == ["read:org"]
  end

  test "GET /orgs/:org is anonymous, typed, active, and versioned", %{alice: alice} do
    org = organization(alice, "acme", display_name: "ACME", description: "Tools")
    user("person-only")
    disabled = organization(alice, "disabled-org", state: :disabled)

    for version <- @versions do
      conn = api_conn(version: version) |> get("/api/v3/orgs/ACME")
      body = json_response(conn, 200)

      assert body["login"] == org.username
      assert body["name"] == "ACME"
      assert body["description"] == "Tools"
      assert body["type"] == "Organization"
      assert body["public_repos"] == 0
      assert Enum.sort(Map.keys(body)) == Enum.sort(@organization_full_keys)
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == [""]
    end

    assert_not_found(api_conn() |> get("/api/v3/orgs/person-only"))
    assert_not_found(api_conn() |> get("/api/v3/orgs/#{disabled.username}"))
    assert_not_found(api_conn() |> get("/api/v3/orgs/missing"))

    invalid = api_conn(secret: "fc_pat_invalid") |> get("/api/v3/orgs/acme")
    assert_error(invalid, 401, "Bad credentials", @authentication_url, "")
  end

  test "POST /admin/organizations creates self-admin organizations in both versions", %{
    alice: alice
  } do
    {api_key, secret} = pat(alice, ["write:org"])

    for {version, login} <- Enum.zip(@versions, ["acme-2022", "acme-2026"]) do
      conn =
        api_conn(secret: secret, version: version, request_id: "create-#{version}")
        |> post_json("/api/v3/admin/organizations", %{
          "login" => login,
          "admin" => " ALICE ",
          "profile_name" => "  ACME Engineering  "
        })

      body = json_response(conn, 201)
      assert body["login"] == login
      assert Enum.sort(Map.keys(body)) == Enum.sort(@organization_simple_keys)
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == ["write:org"]

      assert %AuditEvent{} =
               audit = Repo.get_by!(AuditEvent, target_id: Integer.to_string(body["id"]))

      assert audit.action == "organization.created"
      assert audit.actor_user_id == alice.id
      assert audit.ip_address == "127.0.0.1"
      assert audit.user_agent == @user_agent
      assert [request_id] = get_resp_header(conn, "x-github-request-id")
      assert audit.metadata["request_id"] == request_id
      assert audit.metadata["token_id"] == api_key.id
    end
  end

  test "organization creation enforces site-admin targets and fixed validation errors", %{
    alice: alice
  } do
    bob = user("bob")
    disabled = user("disabled-target", state: :disabled)
    site_admin = user("site-admin", role: :admin)
    {_key, alice_secret} = pat(alice, ["write:org"])
    {_key, admin_secret} = pat(site_admin, ["write:org"])

    forbidden =
      api_conn(secret: alice_secret)
      |> post_json("/api/v3/admin/organizations", %{"login" => "bob-team", "admin" => "bob"})

    assert_error(forbidden, 403, "Forbidden", @create_url, "write:org")

    created =
      api_conn(secret: admin_secret)
      |> post_json("/api/v3/admin/organizations", %{"login" => "admin-team", "admin" => "bob"})

    body = json_response(created, 201)
    organization = ForgeAccounts.get_organization_by_slug(body["login"])
    assert ForgeAccounts.organization_role(bob, organization) == :owner
    assert ForgeAccounts.organization_role(site_admin, organization) == nil

    inactive_target =
      api_conn(secret: admin_secret)
      |> post_json("/api/v3/admin/organizations", %{
        "login" => "inactive-team",
        "admin" => disabled.username
      })

    assert_validation(inactive_target, "admin", "invalid")

    duplicate =
      api_conn(secret: alice_secret)
      |> post_json("/api/v3/admin/organizations", %{"login" => "admin-team", "admin" => "alice"})

    assert_validation(duplicate, "login", "already_exists")

    for {body, field} <- [
          {%{"login" => "new-team", "admin" => "alice", "unknown" => true}, "unknown"},
          {%{"login" => "x", "admin" => "alice"}, "login"},
          {%{
             "login" => "long-profile",
             "admin" => "alice",
             "profile_name" => String.duplicate("x", 121)
           }, "profile_name"}
        ] do
      before_count = audit_count()
      response = api_conn(secret: alice_secret) |> post_json("/api/v3/admin/organizations", body)
      assert_validation(response, field)
      assert audit_count() == before_count
    end
  end

  test "organization creation authenticates and authorizes scope before reading the body", %{
    alice: alice
  } do
    {_key, read_secret} = pat(alice, ["read:org"])

    missing = api_conn() |> post_json("/api/v3/admin/organizations", %{"login" => "x"})
    assert_error(missing, 401, "Bad credentials", nil, "write:org")

    invalid =
      api_conn(secret: "fc_pat_invalid")
      |> post_json("/api/v3/admin/organizations", %{"login" => "x"})

    assert_error(invalid, 401, "Bad credentials", @authentication_url, "")

    before_count = audit_count()

    oversized =
      api_conn(secret: read_secret)
      |> put_req_header("content-length", "1048577")
      |> post_raw("/api/v3/admin/organizations", "{")

    assert_error(
      oversized,
      403,
      "Resource not accessible by personal access token",
      @create_url,
      "write:org"
    )

    assert audit_count() == before_count

    {_legacy_key, legacy_secret} = pat(alice, ["repo:write"])
    legacy = api_conn(secret: legacy_secret) |> post_raw("/api/v3/admin/organizations", "{")

    assert_error(
      legacy,
      403,
      "Resource not accessible by personal access token",
      @create_url,
      "write:org"
    )
  end

  test "PATCH /orgs/:org lets owners and site admins update complete resources", %{alice: alice} do
    org = organization(alice, "maintainers", display_name: "Maintainers")
    site_admin = user("site-admin", role: :admin)
    {_owner_key, owner_secret} = pat(alice, ["write:org"])
    {_admin_key, admin_secret} = pat(site_admin, ["write:org"])

    for {version, name} <- Enum.zip(@versions, ["Maintainers 2022", "Maintainers 2026"]) do
      conn =
        api_conn(secret: owner_secret, version: version, request_id: "update-#{version}")
        |> patch_json("/api/v3/orgs/#{org.username}", %{
          "name" => name,
          "description" => "Compiler tools"
        })

      body = json_response(conn, 200)
      assert body["name"] == name
      assert body["description"] == "Compiler tools"
      assert Enum.sort(Map.keys(body)) == Enum.sort(@organization_full_keys)
      assert get_resp_header(conn, "x-accepted-oauth-scopes") == ["write:org"]
      assert [request_id] = get_resp_header(conn, "x-github-request-id")

      assert %AuditEvent{metadata: %{"request_id" => ^request_id}} =
               Repo.one!(
                 from event in AuditEvent,
                   where: event.action == "organization.updated",
                   order_by: [desc: event.id],
                   limit: 1
               )
    end

    admin_update =
      api_conn(secret: admin_secret)
      |> patch_json("/api/v3/orgs/#{org.username}", %{"description" => "Admin updated"})

    assert json_response(admin_update, 200)["description"] == "Admin updated"

    audits =
      AuditEvent
      |> where([event], event.action == "organization.updated")
      |> order_by([event], asc: event.id)
      |> Repo.all()

    assert [owner_2022, owner_2026, admin_audit] = audits
    assert owner_2022.actor_user_id == alice.id
    assert owner_2026.actor_user_id == alice.id
    assert admin_audit.actor_user_id == site_admin.id
  end

  test "organization update denies members and insufficient scopes before body admission", %{
    alice: alice
  } do
    org = organization(alice, "protected-org")
    member = user("member")
    assert {:ok, _membership} = ForgeAccounts.add_organization_member(org, member, :member)

    {_member_key, member_secret} = pat(member, ["write:org"])
    {_owner_key, owner_read_secret} = pat(alice, ["read:org"])
    before_count = audit_count()

    malformed =
      api_conn(secret: member_secret)
      |> patch_raw("/api/v3/orgs/#{org.username}", "{")

    assert_error(malformed, 403, "Forbidden", @update_url, "write:org")

    oversized =
      api_conn(secret: owner_read_secret)
      |> put_req_header("content-length", "1048577")
      |> patch_raw("/api/v3/orgs/#{org.username}", "{")

    assert_error(
      oversized,
      403,
      "Resource not accessible by personal access token",
      @update_url,
      "write:org"
    )

    assert audit_count() == before_count
  end

  test "organization update rejects inactive principals, targets, and invalid fields", %{
    alice: alice
  } do
    org = organization(alice, "validation-org")
    {_key, secret} = pat(alice, ["write:org"])

    for {body, field} <- [
          {%{"unknown" => true}, "unknown"},
          {%{"name" => String.duplicate("n", 121)}, "name"},
          {%{"description" => String.duplicate("d", 501)}, "description"},
          {%{"name" => "   "}, "name"}
        ] do
      before_count = audit_count()
      response = api_conn(secret: secret) |> patch_json("/api/v3/orgs/#{org.username}", body)
      assert_validation(response, field)
      assert audit_count() == before_count
    end

    missing =
      api_conn()
      |> patch_json("/api/v3/orgs/#{org.username}", %{"name" => "No auth"})

    assert_error(missing, 401, "Bad credentials", nil, "write:org")

    disabled_org = org |> Ecto.Changeset.change(state: :disabled) |> Repo.update!()

    hidden =
      api_conn(secret: secret)
      |> patch_json("/api/v3/orgs/#{disabled_org.username}", %{"name" => "Hidden"})

    assert_not_found(hidden, "write:org")

    active_actor = user("soon-disabled")
    {_disabled_key, disabled_secret} = pat(active_actor, ["write:org"])
    active_actor |> User.state_changeset(%{state: :disabled}) |> Repo.update!()

    disabled_actor =
      api_conn(secret: disabled_secret)
      |> patch_json("/api/v3/orgs/#{org.username}", %{"name" => "Denied"})

    assert_error(disabled_actor, 401, "Bad credentials", @authentication_url, "")
  end

  defp api_conn(opts \\ []) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_optional_header("x-github-api-version", opts[:version])
    |> put_optional_header("x-request-id", opts[:request_id])
    |> put_optional_authorization(opts[:secret])
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

  defp assert_complete_private_user(body, user) do
    assert body["login"] == user.username
    assert body["email"] == user.email
    assert body["name"] == user.display_name
    assert body["bio"] == user.description
    assert body["type"] == "User"
    assert body["public_repos"] == 0
    assert body["total_private_repos"] == 0
    assert body["two_factor_authentication"] == false
    assert Enum.sort(Map.keys(body)) == Enum.sort(@private_user_keys)
  end

  defp assert_complete_public_user(body, user) do
    assert body["login"] == user.username
    assert body["email"] == nil
    assert body["name"] == user.display_name
    assert body["bio"] == user.description
    assert body["type"] == "User"
    assert body["public_repos"] == 0
    assert Enum.sort(Map.keys(body)) == Enum.sort(@public_user_keys)
  end

  defp assert_not_found(conn, accepted_scopes \\ "") do
    assert_error(conn, 404, "Not Found", nil, accepted_scopes)
  end

  defp assert_validation(conn, field, code \\ nil) do
    body = json_response(conn, 422)
    assert body["message"] == "Validation Failed"

    assert Enum.any?(body["errors"], fn error ->
             error["field"] == field and (is_nil(code) or error["code"] == code)
           end)
  end

  defp assert_error(conn, status, message, documentation_url, accepted_scopes) do
    body = json_response(conn, status)
    assert body["message"] == message

    if documentation_url do
      assert body["documentation_url"] == documentation_url
    end

    assert get_resp_header(conn, "x-accepted-oauth-scopes") == [accepted_scopes]
  end

  defp audit_count, do: Repo.aggregate(AuditEvent, :count, :id)
end
