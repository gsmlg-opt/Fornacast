defmodule FornacastAPI.IssueControllerTest do
  use FornacastAPI.ConnCase, async: false

  alias ForgeRepos.Repository

  @user_agent "fornacast-issue-api-test/1.0"
  @versions ["2022-11-28", "2026-03-10"]

  test "public issue listing is routed" do
    alice = user("alice")
    repository(alice, "example")

    conn =
      build_conn()
      |> put_req_header("user-agent", @user_agent)
      |> get("/api/v3/repos/alice/example/issues")

    assert json_response(conn, 200) == []
  end

  test "public issue and comment mutations use their REST statuses in both versions" do
    alice = user("alice")
    repository(alice, "example")
    {_key, secret} = pat(alice, ["public_repo"])

    for version <- @versions do
      issue =
        api_conn(secret, version)
        |> post_json("/api/v3/repos/alice/example/issues", %{"title" => "Issue #{version}"})

      issue_body = json_response(issue, 201)
      assert issue_body["number"] > 0
      assert scopes(issue) == "public_repo, repo"

      updated =
        api_conn(secret, version)
        |> patch_json("/api/v3/repos/alice/example/issues/#{issue_body["number"]}", %{
          "title" => "Updated #{version}"
        })

      assert json_response(updated, 200)["title"] == "Updated #{version}"

      comment =
        api_conn(secret, version)
        |> post_json("/api/v3/repos/alice/example/issues/#{issue_body["number"]}/comments", %{
          "body" => "Comment #{version}"
        })

      comment_body = json_response(comment, 201)

      changed =
        api_conn(secret, version)
        |> patch_json("/api/v3/repos/alice/example/issues/comments/#{comment_body["id"]}", %{
          "body" => "Updated comment #{version}"
        })

      assert json_response(changed, 200)["body"] == "Updated comment #{version}"

      deleted =
        api_conn(secret, version)
        |> delete("/api/v3/repos/alice/example/issues/comments/#{comment_body["id"]}")

      assert response(deleted, 204)
      assert scopes(deleted) == "public_repo, repo"
    end
  end

  test "reads and mutations enforce token scopes and mask private repositories" do
    alice = user("alice")
    bob = user("bob")
    repository(alice, "public")
    repository(alice, "private", visibility: :private)
    {_public_key, public_secret} = pat(alice, ["public_repo"])
    {_legacy_key, legacy_secret} = pat(alice, ["repo:write"])
    {_insufficient_key, insufficient_secret} = pat(alice, ["read:org"])
    {_bob_key, bob_secret} = pat(bob, ["public_repo"])

    for version <- @versions do
      public_read = api_conn(nil, version) |> get("/api/v3/repos/alice/public/issues")
      assert json_response(public_read, 200) == []
      assert scopes(public_read) == ""

      invalid = api_conn("fc_pat_invalid", version) |> get("/api/v3/repos/alice/public/issues")
      assert json_response(invalid, 401)["message"] == "Bad credentials"

      missing_credentials =
        api_conn(nil, version)
        |> post_json("/api/v3/repos/alice/public/issues", %{"title" => "No token"})

      assert json_response(missing_credentials, 401)["message"] == "Requires authentication"

      insufficient =
        api_conn(insufficient_secret, version)
        |> post_raw("/api/v3/repos/alice/public/issues", "{")

      assert json_response(insufficient, 403)["message"] ==
               "Resource not accessible by personal access token"

      assert scopes(insufficient) == "public_repo, repo"

      legacy =
        api_conn(legacy_secret, version)
        |> post_json("/api/v3/repos/alice/public/issues", %{"title" => "Legacy"})

      assert json_response(legacy, 403)["message"] ==
               "Resource not accessible by personal access token"

      private_missing =
        api_conn(bob_secret, version)
        |> post_raw("/api/v3/repos/alice/private/issues", "{")

      missing_repository =
        api_conn(bob_secret, version)
        |> post_raw("/api/v3/repos/alice/missing/issues", "{")

      assert json_response(private_missing, 404) == json_response(missing_repository, 404)

      private_read = api_conn(legacy_secret, version) |> get("/api/v3/repos/alice/private/issues")
      assert json_response(private_read, 200) == []
      assert scopes(private_read) == "repo, repo:read, repo:write"
    end

    owned_issue =
      api_conn(public_secret, "2022-11-28")
      |> post_json("/api/v3/repos/alice/public/issues", %{"title" => "Owner only"})

    assert owned_issue_body = json_response(owned_issue, 201)
    assert owned_issue_body["title"] == "Owner only"

    visible_but_forbidden =
      api_conn_for(bob, ["public_repo"])
      |> patch_json("/api/v3/repos/alice/public/issues/#{owned_issue_body["number"]}", %{
        "title" => "No role"
      })

    assert json_response(visible_but_forbidden, 403)["message"] == "Forbidden"
  end

  defp repository(owner, slug, opts \\ []) do
    %Repository{owner_user_id: owner.id, storage_path: "@issue-api/#{owner.id}/#{slug}.git"}
    |> Repository.create_changeset(%{
      name: slug,
      slug: slug,
      visibility: Keyword.get(opts, :visibility, :public),
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp api_conn(secret, version) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_req_header("x-github-api-version", version)
    |> put_optional_authorization(secret)
  end

  defp post_json(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, Jason.encode!(body))
  end

  defp patch_json(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> patch(path, Jason.encode!(body))
  end

  defp post_raw(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, body)
  end

  defp api_conn_for(user, scopes) do
    {_key, secret} = pat(user, scopes)
    api_conn(secret, "2022-11-28")
  end

  defp put_optional_authorization(conn, nil), do: conn

  defp put_optional_authorization(conn, secret),
    do: put_req_header(conn, "authorization", "Bearer #{secret}")

  defp scopes(conn), do: conn |> get_resp_header("x-accepted-oauth-scopes") |> List.first()
end
