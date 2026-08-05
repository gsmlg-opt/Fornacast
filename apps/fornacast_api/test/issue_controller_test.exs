defmodule FornacastAPI.IssueControllerTest do
  use FornacastAPI.ConnCase, async: false

  alias ForgeRepos.Repository
  alias ForgeIssues.{Comment, Issue}

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
      assert comment_body["issue_url"] =~ "/issues/#{issue_body["number"]}"

      comments =
        api_conn(secret, version)
        |> get("/api/v3/repos/alice/example/issues/#{issue_body["number"]}/comments")

      assert [listed_comment] = json_response(comments, 200)
      assert listed_comment["issue_url"] == comment_body["issue_url"]

      changed =
        api_conn(secret, version)
        |> patch_json("/api/v3/repos/alice/example/issues/comments/#{comment_body["id"]}", %{
          "body" => "Updated comment #{version}"
        })

      changed_body = json_response(changed, 200)
      assert changed_body["body"] == "Updated comment #{version}"
      assert changed_body["issue_url"] == comment_body["issue_url"]

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

  test "private mutations require repo while legacy scopes retain read access in both versions" do
    alice = user("alice")
    private = repository(alice, "private", visibility: :private)
    {_repo_key, repo_secret} = pat(alice, ["repo"])

    for {_scope, secret} <-
          Enum.map(["repo:read", "repo:write"], fn scope ->
            {_key, secret} = pat(alice, [scope], name: "#{scope}-private")
            {scope, secret}
          end) do
      for version <- @versions do
        read = api_conn(secret, version) |> get("/api/v3/repos/alice/private/issues")
        assert json_response(read, 200) == []
        assert scopes(read) == "repo, repo:read, repo:write"

        mutation =
          api_conn(secret, version)
          |> post_raw("/api/v3/repos/alice/private/issues", "{")

        assert json_response(mutation, 403)["message"] ==
                 "Resource not accessible by personal access token"

        assert scopes(mutation) == "repo"
      end
    end

    for version <- @versions do
      created =
        api_conn(repo_secret, version)
        |> post_json("/api/v3/repos/alice/private/issues", %{"title" => "Private #{version}"})

      assert created_body = json_response(created, 201)

      comment =
        api_conn(repo_secret, version)
        |> post_json("/api/v3/repos/alice/private/issues/#{created_body["number"]}/comments", %{
          "body" => "Private comment"
        })

      assert json_response(comment, 201)["issue_url"] =~ "/issues/#{created_body["number"]}"
    end

    assert private.visibility == :private
  end

  test "disabled ordinary issue operations return 410 while pull rows remain listed" do
    alice = user("alice")
    repository = repository(alice, "disabled", has_issues: false)
    {_key, secret} = pat(alice, ["public_repo"])
    issue = issue(repository, alice, 1, :issue)
    pull = issue(repository, alice, 2, :pull_request)
    comment = comment(issue, alice)

    for version <- @versions do
      list = api_conn(secret, version) |> get("/api/v3/repos/alice/disabled/issues?state=all")
      assert [pull_body] = json_response(list, 200)
      assert pull_body["number"] == pull.number

      for {method, path, body} <- [
            {:post, "/api/v3/repos/alice/disabled/issues", ~s({"title":"blocked"})},
            {:get, "/api/v3/repos/alice/disabled/issues/#{issue.number}", nil},
            {:patch, "/api/v3/repos/alice/disabled/issues/#{issue.number}",
             ~s({"title":"blocked"})},
            {:get, "/api/v3/repos/alice/disabled/issues/#{issue.number}/comments", nil},
            {:post, "/api/v3/repos/alice/disabled/issues/#{issue.number}/comments",
             ~s({"body":"blocked"})},
            {:patch, "/api/v3/repos/alice/disabled/issues/comments/#{comment.id}",
             ~s({"body":"blocked"})},
            {:delete, "/api/v3/repos/alice/disabled/issues/comments/#{comment.id}", nil}
          ] do
        conn = request(api_conn(secret, version), method, path, body)
        assert json_response(conn, 410)["message"] == "Issues are disabled for this repository"
      end
    end
  end

  defp repository(owner, slug, opts \\ []) do
    %Repository{owner_user_id: owner.id, storage_path: "@issue-api/#{owner.id}/#{slug}.git"}
    |> Repository.create_changeset(%{
      name: slug,
      slug: slug,
      visibility: Keyword.get(opts, :visibility, :public),
      default_branch: "main",
      has_issues: Keyword.get(opts, :has_issues, true),
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

  defp issue(repository, author, number, kind) do
    Repo.insert!(%Issue{
      repository_id: repository.id,
      number: number,
      kind: kind,
      title: "#{kind} #{number}",
      state: :open,
      author_user_id: author.id
    })
  end

  defp comment(issue, author) do
    Repo.insert!(%Comment{issue_id: issue.id, author_user_id: author.id, body: "existing"})
  end

  defp request(conn, :get, path, _body), do: get(conn, path)
  defp request(conn, :delete, path, _body), do: delete(conn, path)

  defp request(conn, :post, path, body), do: post_raw(conn, path, body)
  defp request(conn, :patch, path, body), do: patch_raw(conn, path, body)

  defp patch_raw(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> patch(path, body)
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
