defmodule FornacastAPI.IssueControllerTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias Fornacast.AuditEvent
  alias ForgeRepos.Repository
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label}

  @user_agent "fornacast-issue-api-test/1.0"
  @versions ["2022-11-28", "2026-03-10"]
  @issue_docs %{
    index:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#list-repository-issues",
    create:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#create-an-issue",
    show: "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#get-an-issue",
    update:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#update-an-issue",
    comment_index:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/comments#list-issue-comments",
    comment_create:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/comments#create-an-issue-comment",
    comment_update:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/comments#update-an-issue-comment",
    comment_delete:
      "https://docs.github.com/en/enterprise-server@3.21/rest/issues/comments#delete-an-issue-comment"
  }

  test "anonymous public show and comment listing return complete maps in both versions" do
    alice = user("alice")
    repository = repository(alice, "example")
    issue = issue(repository, alice, 7, :issue)
    comment = comment(issue, alice)

    for version <- @versions do
      shown = api_conn(nil, version) |> get("/api/v3/repos/alice/example/issues/7")
      assert json_response(shown, 200) == expected_issue(issue, alice, "alice", "example")
      assert_scope_headers(shown, "", "")

      listed =
        api_conn(nil, version)
        |> get("/api/v3/repos/alice/example/issues/7/comments")

      assert json_response(listed, 200) == [
               expected_comment(comment, issue, alice, "alice", "example")
             ]

      assert_scope_headers(listed, "", "")
    end
  end

  test "credentials and scopes are decided before mutation body parsing in both versions" do
    alice = user("alice")
    bob = user("bob")
    repository = repository(alice, "example")
    issue(repository, alice, 1, :issue)
    {_key, insufficient_secret} = pat(alice, ["read:org"])
    {_key, bob_secret} = pat(bob, ["public_repo"])

    for version <- @versions do
      for {path, method} <- [
            {"/api/v3/repos/alice/example/issues", :post},
            {"/api/v3/repos/alice/example/issues/1/comments", :post},
            {"/api/v3/repos/alice/example/issues/comments/1", :patch}
          ] do
        missing = request(api_conn(nil, version), method, path, "{")
        assert_error(missing, 401, "Requires authentication", docs_for(method, path))
        assert_scope_headers(missing, "", "")

        invalid = request(api_conn("fc_pat_invalid", version), method, path, "{")
        assert json_response(invalid, 401)["message"] == "Bad credentials"
        assert_scope_headers(invalid, "", "")

        insufficient = request(api_conn(insufficient_secret, version), method, path, "{")

        assert_error(
          insufficient,
          403,
          "Resource not accessible by personal access token",
          docs_for(method, path)
        )

        assert_scope_headers(insufficient, "read:org", "public_repo, repo")
      end

      forbidden =
        api_conn(bob_secret, version)
        |> patch_json("/api/v3/repos/alice/example/issues/1", %{"title" => "No role"})

      assert_error(forbidden, 403, "Forbidden", @issue_docs.update)
      assert_scope_headers(forbidden, "public_repo", "public_repo, repo")
    end
  end

  test "repo scope succeeds on every public and private route while legacy scopes never mutate" do
    alice = user("alice")
    public = repository(alice, "public")
    private = repository(alice, "private", visibility: :private)
    {_repo_key, repo_secret} = pat(alice, ["repo"])
    {_public_key, public_secret} = pat(alice, ["public_repo"])
    {_legacy_key, legacy_secret} = pat(alice, ["repo:write"])
    private_seed = issue(private, alice, 99, :issue)
    private_comment = comment(private_seed, alice)

    for version <- @versions do
      for slug <- [public.slug, private.slug] do
        accepted_read =
          if slug == "public",
            do: "public_repo, repo, repo:read, repo:write",
            else: "repo, repo:read, repo:write"

        accepted_mutation = if slug == "public", do: "public_repo, repo", else: "repo"

        listed = api_conn(repo_secret, version) |> get("/api/v3/repos/alice/#{slug}/issues")
        assert is_list(json_response(listed, 200))
        assert_scope_headers(listed, "repo", accepted_read)

        created =
          api_conn(repo_secret, version)
          |> post_json("/api/v3/repos/alice/#{slug}/issues", %{"title" => "#{slug} #{version}"})

        created_body = json_response(created, 201)
        assert_scope_headers(created, "repo", accepted_mutation)

        shown =
          api_conn(repo_secret, version)
          |> get("/api/v3/repos/alice/#{slug}/issues/#{created_body["number"]}")

        assert json_response(shown, 200)["title"] == created_body["title"]
        assert_scope_headers(shown, "repo", accepted_read)

        updated =
          api_conn(repo_secret, version)
          |> patch_json("/api/v3/repos/alice/#{slug}/issues/#{created_body["number"]}", %{
            "title" => "updated #{slug} #{version}"
          })

        assert json_response(updated, 200)["title"] == "updated #{slug} #{version}"
        assert_scope_headers(updated, "repo", accepted_mutation)

        created_comment =
          api_conn(repo_secret, version)
          |> post_json(
            "/api/v3/repos/alice/#{slug}/issues/#{created_body["number"]}/comments",
            %{"body" => "comment"}
          )

        comment_body = json_response(created_comment, 201)
        assert_scope_headers(created_comment, "repo", accepted_mutation)

        comments =
          api_conn(repo_secret, version)
          |> get("/api/v3/repos/alice/#{slug}/issues/#{created_body["number"]}/comments")

        assert [_] = json_response(comments, 200)
        assert_scope_headers(comments, "repo", accepted_read)

        updated_comment =
          api_conn(repo_secret, version)
          |> patch_json("/api/v3/repos/alice/#{slug}/issues/comments/#{comment_body["id"]}", %{
            "body" => "updated"
          })

        assert json_response(updated_comment, 200)["body"] == "updated"
        assert_scope_headers(updated_comment, "repo", accepted_mutation)

        for {method, path, body} <- [
              {:patch, "/api/v3/repos/alice/#{slug}/issues/#{created_body["number"]}",
               ~s({"title":"legacy denied"})},
              {:post, "/api/v3/repos/alice/#{slug}/issues/#{created_body["number"]}/comments",
               ~s({"body":"legacy denied"})},
              {:patch, "/api/v3/repos/alice/#{slug}/issues/comments/#{comment_body["id"]}",
               ~s({"body":"legacy denied"})},
              {:delete, "/api/v3/repos/alice/#{slug}/issues/comments/#{comment_body["id"]}", nil}
            ] do
          legacy = request(api_conn(legacy_secret, version), method, path, body)

          assert_error(
            legacy,
            403,
            "Resource not accessible by personal access token",
            docs_for_mutation(method, path)
          )

          assert_scope_headers(legacy, "repo:write", accepted_mutation)
        end

        deleted =
          api_conn(repo_secret, version)
          |> delete("/api/v3/repos/alice/#{slug}/issues/comments/#{comment_body["id"]}")

        assert response(deleted, 204)
        assert_scope_headers(deleted, "repo", accepted_mutation)
      end

      for {method, path, body, docs, accepted} <- [
            {:get, "/api/v3/repos/alice/private/issues", nil, @issue_docs.index,
             "repo, repo:read, repo:write"},
            {:get, "/api/v3/repos/alice/private/issues/99", nil, @issue_docs.show,
             "repo, repo:read, repo:write"},
            {:get, "/api/v3/repos/alice/private/issues/99/comments", nil,
             @issue_docs.comment_index, "repo, repo:read, repo:write"},
            {:post, "/api/v3/repos/alice/private/issues", ~s({"title":"denied"}),
             @issue_docs.create, "repo"},
            {:patch, "/api/v3/repos/alice/private/issues/99", ~s({"title":"denied"}),
             @issue_docs.update, "repo"},
            {:post, "/api/v3/repos/alice/private/issues/99/comments", ~s({"body":"denied"}),
             @issue_docs.comment_create, "repo"},
            {:patch, "/api/v3/repos/alice/private/issues/comments/#{private_comment.id}",
             ~s({"body":"denied"}), @issue_docs.comment_update, "repo"},
            {:delete, "/api/v3/repos/alice/private/issues/comments/#{private_comment.id}", nil,
             @issue_docs.comment_delete, "repo"}
          ] do
        denied = request(api_conn(public_secret, version), method, path, body)

        assert_error(
          denied,
          403,
          "Resource not accessible by personal access token",
          docs
        )

        assert_scope_headers(denied, "public_repo", accepted)
      end
    end
  end

  test "anonymous and inaccessible private reads match missing repositories" do
    alice = user("alice")
    bob = user("bob")
    private = repository(alice, "private", visibility: :private)
    private_issue = issue(private, alice, 7, :issue)
    comment(private_issue, alice)
    {_key, bob_secret} = pat(bob, ["repo"])

    for version <- @versions do
      for {path, missing_path, docs} <- [
            {"/api/v3/repos/alice/private/issues", "/api/v3/repos/alice/missing/issues",
             @issue_docs.index},
            {"/api/v3/repos/alice/private/issues/7", "/api/v3/repos/alice/missing/issues/7",
             @issue_docs.show},
            {"/api/v3/repos/alice/private/issues/7/comments",
             "/api/v3/repos/alice/missing/issues/7/comments", @issue_docs.comment_index}
          ] do
        for secret <- [nil, bob_secret] do
          hidden = api_conn(secret, version) |> get(path)
          missing = api_conn(secret, version) |> get(missing_path)
          assert_error(hidden, 404, "Not Found", docs)
          assert json_response(hidden, 404) == json_response(missing, 404)
          oauth = if secret, do: "repo", else: ""
          assert_scope_headers(hidden, oauth, "")
          assert_scope_headers(missing, oauth, "")
        end
      end
    end
  end

  test "legacy and unrelated PAT scopes cover every public read and mutation route" do
    alice = user("alice")
    public = repository(alice, "public")
    public_issue = issue(public, alice, 7, :issue)
    public_comment = comment(public_issue, alice)

    secrets =
      Map.new(["repo:read", "repo:write", "read:org"], fn scope ->
        {_key, secret} = pat(alice, [scope], name: "#{scope}-public-matrix")
        {scope, secret}
      end)

    reads = [
      {"/api/v3/repos/alice/public/issues", @issue_docs.index},
      {"/api/v3/repos/alice/public/issues/7", @issue_docs.show},
      {"/api/v3/repos/alice/public/issues/7/comments", @issue_docs.comment_index}
    ]

    mutations = [
      {:post, "/api/v3/repos/alice/public/issues", ~s({"title":"denied"}), @issue_docs.create},
      {:patch, "/api/v3/repos/alice/public/issues/7", ~s({"title":"denied"}), @issue_docs.update},
      {:post, "/api/v3/repos/alice/public/issues/7/comments", ~s({"body":"denied"}),
       @issue_docs.comment_create},
      {:patch, "/api/v3/repos/alice/public/issues/comments/#{public_comment.id}",
       ~s({"body":"denied"}), @issue_docs.comment_update},
      {:delete, "/api/v3/repos/alice/public/issues/comments/#{public_comment.id}", nil,
       @issue_docs.comment_delete}
    ]

    for version <- @versions do
      for scope <- ["repo:read", "repo:write"] do
        for {path, _docs} <- reads do
          conn = api_conn(secrets[scope], version) |> get(path)
          assert conn.status == 200
          assert_scope_headers(conn, scope, "public_repo, repo, repo:read, repo:write")
        end
      end

      for {path, docs} <- reads do
        denied = api_conn(secrets["read:org"], version) |> get(path)

        assert_error(
          denied,
          403,
          "Resource not accessible by personal access token",
          docs
        )

        assert_scope_headers(
          denied,
          "read:org",
          "public_repo, repo, repo:read, repo:write"
        )
      end

      for scope <- ["repo:read", "repo:write", "read:org"],
          {method, path, body, docs} <- mutations do
        denied = request(api_conn(secrets[scope], version), method, path, body)

        assert_error(
          denied,
          403,
          "Resource not accessible by personal access token",
          docs
        )

        assert_scope_headers(denied, scope, "public_repo, repo")
      end
    end
  end

  test "invalid identifiers are stable and global comment routes cannot be captured as issue numbers" do
    alice = user("alice")
    repository(alice, "example")
    {_key, secret} = pat(alice, ["public_repo"])

    for version <- @versions do
      for {method, path, docs, oauth, accepted} <- [
            {:get, "/api/v3/repos/alice/example/issues/0", @issue_docs.show, "", ""},
            {:get, "/api/v3/repos/alice/example/issues/nope", @issue_docs.show, "", ""},
            {:patch, "/api/v3/repos/alice/example/issues/-1", @issue_docs.update, "public_repo",
             ""},
            {:get, "/api/v3/repos/alice/example/issues/0/comments", @issue_docs.comment_index, "",
             ""},
            {:post, "/api/v3/repos/alice/example/issues/nope/comments",
             @issue_docs.comment_create, "public_repo", ""},
            {:patch, "/api/v3/repos/alice/example/issues/comments/0", @issue_docs.comment_update,
             "public_repo", ""},
            {:delete, "/api/v3/repos/alice/example/issues/comments/nope",
             @issue_docs.comment_delete, "public_repo", ""}
          ] do
        conn =
          request(
            api_conn(if(oauth == "", do: nil, else: secret), version),
            method,
            path,
            ~s({"body":"x"})
          )

        assert_error(conn, 404, "Not Found", docs)
        assert_scope_headers(conn, oauth, accepted)
      end
    end
  end

  test "all eight actions use operation-specific documentation URLs for validation or domain errors" do
    alice = user("alice")
    repository = repository(alice, "example")
    issue = issue(repository, alice, 1, :issue)
    {_key, secret} = pat(alice, ["public_repo"])

    for version <- @versions do
      cases = [
        {:get, "/api/v3/repos/alice/example/issues?state=invalid", nil, 422, @issue_docs.index},
        {:post, "/api/v3/repos/alice/example/issues", ~s({"title":""}), 422, @issue_docs.create},
        {:get, "/api/v3/repos/alice/example/issues/999", nil, 404, @issue_docs.show},
        {:patch, "/api/v3/repos/alice/example/issues/1", ~s({"title":""}), 422,
         @issue_docs.update},
        {:get, "/api/v3/repos/alice/example/issues/1/comments?since=nope", nil, 422,
         @issue_docs.comment_index},
        {:post, "/api/v3/repos/alice/example/issues/1/comments", ~s({"body":""}), 422,
         @issue_docs.comment_create},
        {:patch, "/api/v3/repos/alice/example/issues/comments/999", ~s({"body":"x"}), 404,
         @issue_docs.comment_update},
        {:delete, "/api/v3/repos/alice/example/issues/comments/999", nil, 404,
         @issue_docs.comment_delete}
      ]

      for {method, path, body, status, docs} <- cases do
        conn = request(api_conn(secret, version), method, path, body)
        response_body = json_response(conn, status)
        assert response_body["documentation_url"] == docs

        assert Enum.sort(Map.keys(response_body)) in [
                 ["documentation_url", "message"],
                 ["documentation_url", "errors", "message"]
               ]

        assert_scope_headers(conn, "public_repo", expected_accepted(method, path))
      end
    end

    assert issue.id
  end

  test "issue and comment filters, pagination, ordering, and Link headers are observable" do
    alice = user("alice")
    repository = repository(alice, "filters")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    before = DateTime.add(now, -60, :second)
    first = issue(repository, alice, 1, :issue)
    second = issue(repository, alice, 2, :issue)
    excluded = issue(repository, alice, 3, :issue)

    Repo.update_all(from(row in Issue, where: row.id in ^[first.id, second.id]),
      set: [state: :closed, closed_at: now, inserted_at: now, updated_at: now]
    )

    Repo.update_all(from(row in Issue, where: row.id == ^excluded.id),
      set: [inserted_at: before, updated_at: before]
    )

    label =
      %Label{}
      |> Label.changeset(%{
        repository_id: repository.id,
        name: "bug",
        normalized_name: "bug",
        color: "ff0000",
        default: false
      })
      |> Repo.insert!()

    for row <- [first, second] do
      %IssueLabel{}
      |> IssueLabel.changeset(%{issue_id: row.id, label_id: label.id})
      |> Repo.insert!()

      %IssueAssignee{}
      |> IssueAssignee.changeset(%{issue_id: row.id, user_id: alice.id})
      |> Repo.insert!()
    end

    comment(first, alice)
    comment(second, alice)
    second_comment = comment(second, alice)

    for version <- @versions do
      query =
        URI.encode_query(%{
          "state" => "closed",
          "labels" => "bug",
          "assignee" => "alice",
          "creator" => "alice",
          "sort" => "comments",
          "direction" => "asc",
          "since" => DateTime.to_iso8601(now)
        })

      filtered = api_conn(nil, version) |> get("/api/v3/repos/alice/filters/issues?#{query}")
      assert Enum.map(json_response(filtered, 200), & &1["number"]) == [1, 2]
      assert_scope_headers(filtered, "", "")

      page_two =
        api_conn(nil, version)
        |> get(
          "/api/v3/repos/alice/filters/issues?state=all&sort=created&direction=asc&page=2&per_page=1"
        )

      assert [page_two_body] = json_response(page_two, 200)
      assert page_two_body["number"] == 1
      assert [link] = get_resp_header(page_two, "link")
      assert link =~ "page=1"
      assert link =~ ~s(rel="prev")
      assert link =~ "page=3"
      assert link =~ ~s(rel="next")

      comments =
        api_conn(nil, version)
        |> get(
          "/api/v3/repos/alice/filters/issues/2/comments?since=#{URI.encode_www_form(DateTime.to_iso8601(second_comment.updated_at))}&page=2&per_page=1"
        )

      assert [comment_body] = json_response(comments, 200)
      assert comment_body["id"] == second_comment.id
      assert [comment_link] = get_resp_header(comments, "link")
      assert comment_link =~ "page=1"
      assert comment_link =~ ~s(rel="prev")
      assert_scope_headers(comments, "", "")
    end
  end

  test "issue and comment mutation audits preserve complete request metadata" do
    alice = user("alice")
    repository = repository(alice, "audit")
    {api_key, secret} = pat(alice, ["public_repo"])

    for version <- @versions do
      created =
        api_conn(secret, version)
        |> put_req_header("x-request-id", "issue-create-#{version}")
        |> post_json("/api/v3/repos/alice/audit/issues", %{"title" => "audit #{version}"})

      issue_body = json_response(created, 201)

      updated =
        api_conn(secret, version)
        |> put_req_header("x-request-id", "issue-update-#{version}")
        |> patch_json("/api/v3/repos/alice/audit/issues/#{issue_body["number"]}", %{
          "title" => "updated #{version}"
        })

      assert json_response(updated, 200)["title"] == "updated #{version}"

      created_comment =
        api_conn(secret, version)
        |> put_req_header("x-request-id", "comment-create-#{version}")
        |> post_json("/api/v3/repos/alice/audit/issues/#{issue_body["number"]}/comments", %{
          "body" => "comment"
        })

      comment_body = json_response(created_comment, 201)

      updated_comment =
        api_conn(secret, version)
        |> put_req_header("x-request-id", "comment-update-#{version}")
        |> patch_json("/api/v3/repos/alice/audit/issues/comments/#{comment_body["id"]}", %{
          "body" => "updated"
        })

      assert json_response(updated_comment, 200)["body"] == "updated"

      deleted =
        api_conn(secret, version)
        |> put_req_header("x-request-id", "comment-delete-#{version}")
        |> delete("/api/v3/repos/alice/audit/issues/comments/#{comment_body["id"]}")

      assert response(deleted, 204)

      for {action, target_type, target_id, request_conn} <- [
            {"issue.created", "repository", to_string(repository.id), created},
            {"issue.updated", "issue", to_string(issue_body["id"]), updated},
            {"issue_comment.created", "issue_comment", to_string(comment_body["id"]),
             created_comment},
            {"issue_comment.updated", "issue_comment", to_string(comment_body["id"]),
             updated_comment},
            {"issue_comment.deleted", "issue_comment", to_string(comment_body["id"]), deleted}
          ] do
        audit =
          from(event in AuditEvent,
            where:
              event.action == ^action and event.target_type == ^target_type and
                event.target_id == ^target_id
          )
          |> Repo.all()
          |> Enum.find(&(&1.metadata["api_version"] == version))

        assert audit

        [request_id] = get_resp_header(request_conn, "x-github-request-id")
        assert audit.actor_user_id == alice.id
        assert audit.ip_address == "127.0.0.1"
        assert audit.user_agent == @user_agent
        assert audit.metadata["request_id"] == request_id
        assert audit.metadata["api_version"] == version
        assert audit.metadata["token_id"] == api_key.id
        assert audit.metadata["repository_id"] == repository.id
        assert audit.metadata["result"] == "success"
      end
    end
  end

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
      persisted_issue = Repo.get!(Issue, issue_body["id"])
      assert issue_body == expected_issue(persisted_issue, alice, "alice", "example")

      issue_list = api_conn(secret, version) |> get("/api/v3/repos/alice/example/issues")
      assert issue_body in json_response(issue_list, 200)

      updated =
        api_conn(secret, version)
        |> patch_json("/api/v3/repos/alice/example/issues/#{issue_body["number"]}", %{
          "title" => "Updated #{version}"
        })

      updated_body = json_response(updated, 200)
      updated_issue = Repo.get!(Issue, issue_body["id"])
      assert updated_body == expected_issue(updated_issue, alice, "alice", "example")

      comment =
        api_conn(secret, version)
        |> post_json("/api/v3/repos/alice/example/issues/#{issue_body["number"]}/comments", %{
          "body" => "Comment #{version}"
        })

      comment_body = json_response(comment, 201)
      persisted_comment = Repo.get!(Comment, comment_body["id"])

      assert comment_body ==
               expected_comment(persisted_comment, updated_issue, alice, "alice", "example")

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
      changed_comment = Repo.get!(Comment, comment_body["id"])

      assert changed_body ==
               expected_comment(changed_comment, updated_issue, alice, "alice", "example")

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

      private_body = json_response(private_missing, 404)
      assert private_body == json_response(missing_repository, 404)

      assert private_body == %{
               "message" => "Not Found",
               "documentation_url" => @issue_docs.create
             }

      assert_scope_headers(private_missing, "public_repo", "")
      assert_scope_headers(missing_repository, "public_repo", "")

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
    seeded_issue = issue(private, alice, 99, :issue)
    seeded_comment = comment(seeded_issue, alice)

    for {scope, secret} <-
          Enum.map(["repo:read", "repo:write"], fn scope ->
            {_key, secret} = pat(alice, [scope], name: "#{scope}-private")
            {scope, secret}
          end) do
      for version <- @versions do
        read = api_conn(secret, version) |> get("/api/v3/repos/alice/private/issues")
        assert Enum.any?(json_response(read, 200), &(&1["number"] == 99))
        assert_scope_headers(read, scope, "repo, repo:read, repo:write")

        shown = api_conn(secret, version) |> get("/api/v3/repos/alice/private/issues/99")
        assert json_response(shown, 200)["number"] == 99
        assert_scope_headers(shown, scope, "repo, repo:read, repo:write")

        comments =
          api_conn(secret, version) |> get("/api/v3/repos/alice/private/issues/99/comments")

        assert [comment_body] = json_response(comments, 200)
        assert comment_body["id"] == seeded_comment.id
        assert_scope_headers(comments, scope, "repo, repo:read, repo:write")

        for {method, path, body, docs} <- [
              {:post, "/api/v3/repos/alice/private/issues", "{", @issue_docs.create},
              {:patch, "/api/v3/repos/alice/private/issues/99", "{", @issue_docs.update},
              {:post, "/api/v3/repos/alice/private/issues/99/comments", "{",
               @issue_docs.comment_create},
              {:patch, "/api/v3/repos/alice/private/issues/comments/#{seeded_comment.id}", "{",
               @issue_docs.comment_update},
              {:delete, "/api/v3/repos/alice/private/issues/comments/#{seeded_comment.id}", nil,
               @issue_docs.comment_delete}
            ] do
          mutation = request(api_conn(secret, version), method, path, body)

          assert_error(
            mutation,
            403,
            "Resource not accessible by personal access token",
            docs
          )

          assert_scope_headers(mutation, scope, "repo")
        end
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
      assert pull_body == expected_pull(pull, alice, "alice", "disabled", version)
      assert_scope_headers(list, "public_repo", "public_repo, repo, repo:read, repo:write")

      shown_pull =
        api_conn(secret, version)
        |> get("/api/v3/repos/alice/disabled/issues/#{pull.number}")

      assert json_response(shown_pull, 200) ==
               expected_pull(pull, alice, "alice", "disabled", version)

      pull_comment =
        api_conn(secret, version)
        |> post_json("/api/v3/repos/alice/disabled/issues/#{pull.number}/comments", %{
          "body" => "pull continuity"
        })

      pull_comment_body = json_response(pull_comment, 201)

      changed_pull_comment =
        api_conn(secret, version)
        |> patch_json(
          "/api/v3/repos/alice/disabled/issues/comments/#{pull_comment_body["id"]}",
          %{"body" => "still routed"}
        )

      assert json_response(changed_pull_comment, 200)["body"] == "still routed"

      pull_comments =
        api_conn(secret, version)
        |> get("/api/v3/repos/alice/disabled/issues/#{pull.number}/comments")

      assert Enum.any?(json_response(pull_comments, 200), &(&1["id"] == pull_comment_body["id"]))

      deleted_pull_comment =
        api_conn(secret, version)
        |> delete("/api/v3/repos/alice/disabled/issues/comments/#{pull_comment_body["id"]}")

      assert response(deleted_pull_comment, 204)

      for {method, path, body, docs} <- [
            {:post, "/api/v3/repos/alice/disabled/issues", ~s({"title":"blocked"}),
             @issue_docs.create},
            {:get, "/api/v3/repos/alice/disabled/issues/#{issue.number}", nil, @issue_docs.show},
            {:patch, "/api/v3/repos/alice/disabled/issues/#{issue.number}",
             ~s({"title":"blocked"}), @issue_docs.update},
            {:get, "/api/v3/repos/alice/disabled/issues/#{issue.number}/comments", nil,
             @issue_docs.comment_index},
            {:post, "/api/v3/repos/alice/disabled/issues/#{issue.number}/comments",
             ~s({"body":"blocked"}), @issue_docs.comment_create},
            {:patch, "/api/v3/repos/alice/disabled/issues/comments/#{comment.id}",
             ~s({"body":"blocked"}), @issue_docs.comment_update},
            {:delete, "/api/v3/repos/alice/disabled/issues/comments/#{comment.id}", nil,
             @issue_docs.comment_delete}
          ] do
        conn = request(api_conn(secret, version), method, path, body)
        assert_error(conn, 410, "Issues are disabled for this repository", docs)
        assert_scope_headers(conn, "public_repo", expected_accepted(method, path))
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

  defp assert_error(conn, status, message, documentation_url) do
    assert json_response(conn, status) == %{
             "message" => message,
             "documentation_url" => documentation_url
           }
  end

  defp assert_scope_headers(conn, oauth_scopes, accepted_scopes) do
    assert get_resp_header(conn, "x-oauth-scopes") == [oauth_scopes]
    assert get_resp_header(conn, "x-accepted-oauth-scopes") == [accepted_scopes]
  end

  defp docs_for(:post, path) do
    if String.ends_with?(path, "/comments"),
      do: @issue_docs.comment_create,
      else: @issue_docs.create
  end

  defp docs_for(:patch, path) do
    if String.contains?(path, "/issues/comments/"),
      do: @issue_docs.comment_update,
      else: @issue_docs.update
  end

  defp docs_for_mutation(:post, path), do: docs_for(:post, path)
  defp docs_for_mutation(:patch, path), do: docs_for(:patch, path)
  defp docs_for_mutation(:delete, _path), do: @issue_docs.comment_delete

  defp expected_accepted(:get, _path), do: "public_repo, repo, repo:read, repo:write"
  defp expected_accepted(_method, _path), do: "public_repo, repo"

  defp expected_issue(issue, author, owner, repo) do
    api_url = "http://localhost:4890/api/v3/repos/#{owner}/#{repo}/issues/#{issue.number}"

    %{
      "active_lock_reason" => nil,
      "assignee" => nil,
      "assignees" => [],
      "author_association" => "OWNER",
      "body" => issue.body,
      "closed_at" => timestamp(issue.closed_at),
      "closed_by" => nil,
      "comments" =>
        Repo.aggregate(from(row in Comment, where: row.issue_id == ^issue.id), :count),
      "comments_url" => api_url <> "/comments",
      "created_at" => timestamp(issue.inserted_at),
      "draft" => false,
      "events_url" => api_url <> "/events",
      "html_url" => api_url,
      "id" => issue.id,
      "labels" => [],
      "labels_url" => api_url <> "/labels{/name}",
      "locked" => false,
      "milestone" => nil,
      "node_id" => Base.url_encode64("Issue:#{issue.id}", padding: false),
      "number" => issue.number,
      "performed_via_github_app" => nil,
      "reactions" => reactions(api_url <> "/reactions"),
      "repository_url" => "http://localhost:4890/api/v3/repos/#{owner}/#{repo}",
      "state" => Atom.to_string(issue.state),
      "state_reason" => nil,
      "timeline_url" => api_url <> "/timeline",
      "title" => issue.title,
      "updated_at" => timestamp(issue.updated_at),
      "url" => api_url,
      "user" => expected_user(author)
    }
  end

  defp expected_comment(comment, issue, author, owner, repo) do
    api_url = "http://localhost:4890/api/v3/repos/#{owner}/#{repo}/issues/comments/#{comment.id}"

    %{
      "author_association" => "OWNER",
      "body" => comment.body,
      "created_at" => timestamp(comment.inserted_at),
      "html_url" => api_url,
      "id" => comment.id,
      "issue_url" => "http://localhost:4890/api/v3/repos/#{owner}/#{repo}/issues/#{issue.number}",
      "node_id" => Base.url_encode64("IssueComment:#{comment.id}", padding: false),
      "performed_via_github_app" => nil,
      "reactions" => reactions(api_url <> "/reactions"),
      "updated_at" => timestamp(comment.updated_at),
      "url" => api_url,
      "user" => expected_user(author)
    }
  end

  defp expected_pull(issue, author, owner, repo, version) do
    pull_url = "http://localhost:4890/api/v3/repos/#{owner}/#{repo}/pulls/#{issue.number}"

    pull_request = %{
      "diff_url" => pull_url,
      "html_url" => pull_url,
      "patch_url" => pull_url,
      "url" => pull_url
    }

    pull_request =
      if version == "2022-11-28",
        do: Map.put(pull_request, "merged_at", nil),
        else: pull_request

    issue
    |> expected_issue(author, owner, repo)
    |> Map.put("pull_request", pull_request)
  end

  defp expected_user(%User{} = user) do
    api_url = "http://localhost:4890/api/v3/users/#{user.username}"
    web_url = "http://localhost:4890/#{user.username}"

    %{
      "avatar_url" => web_url,
      "events_url" => api_url <> "/events{/privacy}",
      "followers_url" => api_url <> "/followers",
      "following_url" => api_url <> "/following{/other_user}",
      "gists_url" => api_url <> "/gists{/gist_id}",
      "gravatar_id" => nil,
      "html_url" => web_url,
      "id" => user.id,
      "login" => user.username,
      "node_id" => Base.url_encode64("User:#{user.id}", padding: false),
      "organizations_url" => api_url <> "/orgs",
      "received_events_url" => api_url <> "/received_events",
      "repos_url" => api_url <> "/repos",
      "site_admin" => false,
      "starred_url" => api_url <> "/starred{/owner}{/repo}",
      "subscriptions_url" => api_url <> "/subscriptions",
      "type" => "User",
      "url" => api_url
    }
  end

  defp reactions(url) do
    %{
      "+1" => 0,
      "-1" => 0,
      "confused" => 0,
      "eyes" => 0,
      "heart" => 0,
      "hooray" => 0,
      "laugh" => 0,
      "rocket" => 0,
      "total_count" => 0,
      "url" => url
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)

  defp scopes(conn), do: conn |> get_resp_header("x-accepted-oauth-scopes") |> List.first()
end
