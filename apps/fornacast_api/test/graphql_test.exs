defmodule FornacastAPI.GraphQLTest do
  use FornacastAPI.ConnCase, async: false

  @moduletag :tmp_dir

  @user_agent "fornacast-graphql-test/1.0"

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, previous)
    end)

    alice = user("alice", display_name: "Alice Example", description: "Maintainer")
    bob = user("bob", display_name: "Bob Example")
    org = organization(alice, "acme", display_name: "Acme Org", description: "Widgets")

    {:ok, public_repo} =
      ForgeRepos.create_repository(alice, %{
        name: "public-demo",
        visibility: :public,
        description: "Public demo"
      })

    {:ok, _private_repo} =
      ForgeRepos.create_repository(alice, %{
        name: "private-demo",
        visibility: :private,
        description: "Private demo"
      })

    %{alice: alice, bob: bob, org: org, public_repo: public_repo}
  end

  test "viewer returns the authenticated private user", %{alice: alice} do
    {_key, secret} = pat(alice, ["repo"])

    body =
      graphql(secret: secret, query: "{ viewer { login databaseId email name bio isSiteAdmin } }")

    assert body["errors"] == nil
    assert body["data"]["viewer"]["login"] == "alice"
    assert body["data"]["viewer"]["databaseId"] == alice.id
    assert body["data"]["viewer"]["email"] == alice.email
    assert body["data"]["viewer"]["name"] == "Alice Example"
    assert body["data"]["viewer"]["bio"] == "Maintainer"
    assert body["data"]["viewer"]["isSiteAdmin"] == false
  end

  test "viewer requires authentication; invalid PAT is rejected before GraphQL" do
    unauthenticated = graphql(query: "{ viewer { login } }")
    assert unauthenticated["data"]["viewer"] == nil
    assert hd(unauthenticated["errors"])["message"] == "Bad credentials"

    invalid = graphql_conn(secret: "fc_pat_invalid") |> post_graphql("{ viewer { login } }")
    assert json_response(invalid, 401)["message"] == "Bad credentials"
  end

  test "user and organization lookups are public and return null when missing", %{
    alice: alice,
    org: org
  } do
    user_body = graphql(query: ~s|{ user(login: "alice") { login databaseId name url email } }|)
    assert user_body["errors"] == nil
    assert user_body["data"]["user"]["login"] == "alice"
    assert user_body["data"]["user"]["databaseId"] == alice.id
    assert user_body["data"]["user"]["name"] == "Alice Example"
    assert user_body["data"]["user"]["email"] == nil
    assert user_body["data"]["user"]["url"] == FornacastAPI.URL.user("alice")

    missing_user = graphql(query: ~s|{ user(login: "missing") { login } }|)
    assert missing_user["data"]["user"] == nil

    org_body =
      graphql(
        query: ~s|{ organization(login: "acme") { login databaseId name description url } }|
      )

    assert org_body["errors"] == nil
    assert org_body["data"]["organization"]["login"] == "acme"
    assert org_body["data"]["organization"]["databaseId"] == org.id
    assert org_body["data"]["organization"]["name"] == "Acme Org"
    assert org_body["data"]["organization"]["description"] == "Widgets"
    assert org_body["data"]["organization"]["url"] == FornacastAPI.URL.organization("acme")

    missing_org = graphql(query: ~s|{ organization(login: "missing") { login } }|)
    assert missing_org["data"]["organization"] == nil
  end

  test "repository returns public repos and hides unauthorized private repos", %{
    alice: alice,
    bob: bob,
    public_repo: public_repo
  } do
    public =
      graphql(query: ~s|{ repository(owner: "alice", name: "public-demo") {
          name nameWithOwner description isPrivate databaseId url id
        } }|)

    assert public["errors"] == nil
    assert public["data"]["repository"]["name"] == "public-demo"
    assert public["data"]["repository"]["nameWithOwner"] == "alice/public-demo"
    assert public["data"]["repository"]["description"] == "Public demo"
    assert public["data"]["repository"]["isPrivate"] == false
    assert public["data"]["repository"]["databaseId"] == public_repo.id

    assert public["data"]["repository"]["url"] ==
             FornacastAPI.URL.repository("alice", "public-demo")

    assert public["data"]["repository"]["id"] ==
             Base.url_encode64("Repository:#{public_repo.id}", padding: false)

    anonymous_private =
      graphql(query: ~s|{ repository(owner: "alice", name: "private-demo") { name } }|)

    assert anonymous_private["data"]["repository"] == nil

    {_bob_key, bob_secret} = pat(bob, ["repo"])

    bob_private =
      graphql(
        secret: bob_secret,
        query: ~s|{ repository(owner: "alice", name: "private-demo") { name } }|
      )

    assert bob_private["data"]["repository"] == nil

    {_alice_key, alice_secret} = pat(alice, ["repo"])

    alice_private =
      graphql(
        secret: alice_secret,
        query: ~s|{ repository(owner: "alice", name: "private-demo") {
          name isPrivate description
        } }|
      )

    assert alice_private["errors"] == nil
    assert alice_private["data"]["repository"]["name"] == "private-demo"
    assert alice_private["data"]["repository"]["isPrivate"] == true
    assert alice_private["data"]["repository"]["description"] == "Private demo"

    missing = graphql(query: ~s|{ repository(owner: "alice", name: "nope") { name } }|)
    assert missing["data"]["repository"] == nil
  end

  test "GraphQL requires User-Agent and does not require API version", %{alice: alice} do
    {_key, secret} = pat(alice, ["repo"])

    missing_ua =
      build_conn()
      |> put_req_header("authorization", "Bearer #{secret}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", Jason.encode!(%{query: "{ viewer { login } }"}))

    assert json_response(missing_ua, 403)["message"] == "User agent required"

    conn =
      graphql_conn(secret: secret)
      |> post_graphql("{ viewer { login } }")

    body = json_response(conn, 200)
    assert body["data"]["viewer"]["login"] == "alice"
    assert get_resp_header(conn, "x-github-api-version-selected") == []
  end

  test "GET /api/graphql supports introspection" do
    conn =
      graphql_conn()
      |> get("/api/graphql", %{
        "query" => "{ __schema { queryType { name } } }"
      })

    body = json_response(conn, 200)
    assert body["data"]["__schema"]["queryType"]["name"] == "RootQueryType"
  end

  defp graphql(opts) do
    query = Keyword.fetch!(opts, :query)
    secret = Keyword.get(opts, :secret)

    graphql_conn(secret: secret)
    |> post_graphql(query)
    |> json_response(200)
  end

  defp post_graphql(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", Jason.encode!(%{query: query}))
  end

  defp graphql_conn(opts \\ []) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_optional_authorization(opts[:secret])
  end

  defp put_optional_authorization(conn, nil), do: conn

  defp put_optional_authorization(conn, secret) do
    {name, value} = authorization(secret, "Bearer")
    put_req_header(conn, name, value)
  end
end
