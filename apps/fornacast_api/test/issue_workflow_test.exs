defmodule FornacastAPI.IssueWorkflowTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  alias ForgeIssues.{Comment, Issue}
  alias ForgeRepos.{Collaborator, Repository}
  alias Fornacast.{AuditEvent, Repo}

  @user_agent "fornacast-issue-workflow-test/1.0"
  @versions ["2022-11-28", "2026-03-10"]

  test "the REST workflow preserves author, writer, schema, and audit contracts" do
    owner = user("workflow-owner")
    reader = user("workflow-reader")
    writer = user("workflow-writer")
    assignee = user("workflow-assignee")
    repository = repository(owner, "workflow")
    grant(repository, reader, :read)
    grant(repository, writer, :write)
    grant(repository, assignee, :read)
    {_reader_key, reader_secret} = pat(reader, ["public_repo"])
    {writer_key, writer_secret} = pat(writer, ["public_repo"])

    for version <- @versions do
      issue =
        api_conn(reader_secret, version)
        |> post_json("/api/v3/repos/workflow-owner/workflow/issues", %{
          "title" => "reader issue #{version}",
          "body" => "reader body #{version}",
          "labels" => ["bug"],
          "assignees" => [assignee.username]
        })

      created = assert_schema(issue, "/repos/{owner}/{repo}/issues", :post, 201)
      assert created["number"] == if(version == hd(@versions), do: 1, else: 2)
      assert created["labels"] == []
      assert created["assignees"] == []

      shown =
        api_conn(reader_secret, version)
        |> get("/api/v3/repos/workflow-owner/workflow/issues/#{created["number"]}")

      assert assert_schema(shown, "/repos/{owner}/{repo}/issues/{issue_number}", :get, 200)["id"] ==
               created["id"]

      edited =
        api_conn(reader_secret, version)
        |> patch_json("/api/v3/repos/workflow-owner/workflow/issues/#{created["number"]}", %{
          "title" => "edited #{version}",
          "body" => "edited body #{version}"
        })

      edited_body =
        assert_schema(edited, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      assert edited_body["title"] == "edited #{version}"
      assert edited_body["body"] == "edited body #{version}"

      comment =
        api_conn(reader_secret, version)
        |> post_json(
          "/api/v3/repos/workflow-owner/workflow/issues/#{created["number"]}/comments",
          %{
            "body" => "comment #{version}"
          }
        )

      comment_body =
        assert_schema(comment, "/repos/{owner}/{repo}/issues/{issue_number}/comments", :post, 201)

      changed_comment =
        api_conn(reader_secret, version)
        |> patch_json(
          "/api/v3/repos/workflow-owner/workflow/issues/comments/#{comment_body["id"]}",
          %{
            "body" => "changed comment #{version}"
          }
        )

      assert assert_schema(
               changed_comment,
               "/repos/{owner}/{repo}/issues/comments/{comment_id}",
               :patch,
               200
             )["body"] == "changed comment #{version}"

      assigned =
        api_conn(writer_secret, version)
        |> put_req_header("x-request-id", "workflow-#{version}")
        |> patch_json("/api/v3/repos/workflow-owner/workflow/issues/#{created["number"]}", %{
          "labels" => ["bug"],
          "assignee" => assignee.username
        })

      assert %{"labels" => [%{"name" => "bug"}], "assignees" => [%{"login" => login}]} =
               assert_schema(assigned, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      assert login == assignee.username

      query =
        URI.encode_query(%{
          "state" => "open",
          "labels" => "bug",
          "assignee" => assignee.username,
          "creator" => reader.username,
          "since" => "2020-01-01T00:00:00Z"
        })

      filtered =
        api_conn(reader_secret, version)
        |> get("/api/v3/repos/workflow-owner/workflow/issues?#{query}")

      assert Enum.any?(
               assert_schema(filtered, "/repos/{owner}/{repo}/issues", :get, 200),
               &(&1["id"] == created["id"])
             )

      closed =
        api_conn(reader_secret, version)
        |> patch_json("/api/v3/repos/workflow-owner/workflow/issues/#{created["number"]}", %{
          "state" => "closed",
          "state_reason" => "completed"
        })

      assert %{"state" => "closed", "state_reason" => "completed"} =
               assert_schema(closed, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      reopened =
        api_conn(reader_secret, version)
        |> patch_json("/api/v3/repos/workflow-owner/workflow/issues/#{created["number"]}", %{
          "state" => "open",
          "state_reason" => "reopened"
        })

      assert %{"state" => "open", "state_reason" => "reopened"} =
               assert_schema(reopened, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      deleted =
        api_conn(reader_secret, version)
        |> delete("/api/v3/repos/workflow-owner/workflow/issues/comments/#{comment_body["id"]}")

      assert response(deleted, 204)

      assert_audits_safe(
        repository,
        writer_key.id,
        [reader_secret, writer_secret],
        ["reader issue #{version}", "reader body #{version}", "edited body #{version}"],
        version
      )
    end
  end

  test "disabled issue routes retain pull identities while ordinary identities return 410" do
    owner = user("disabled-owner")
    repository = repository(owner, "disabled", has_issues: false)
    {_key, secret} = pat(owner, ["public_repo"])
    ordinary = issue(repository, owner, 1, :issue)
    pull = issue(repository, owner, 2, :pull_request)

    ordinary_comment =
      Repo.insert!(%Comment{issue_id: ordinary.id, author_user_id: owner.id, body: "blocked"})

    for version <- @versions do
      list =
        api_conn(secret, version) |> get("/api/v3/repos/disabled-owner/disabled/issues?state=all")

      assert [%{"id" => pull_id}] = assert_schema(list, "/repos/{owner}/{repo}/issues", :get, 200)
      assert pull_id == pull.id

      for {method, path, body} <- [
            {:post, "/api/v3/repos/disabled-owner/disabled/issues", %{"title" => "blocked"}},
            {:get, "/api/v3/repos/disabled-owner/disabled/issues/#{ordinary.number}", nil},
            {:patch, "/api/v3/repos/disabled-owner/disabled/issues/#{ordinary.number}",
             %{"title" => "blocked"}},
            {:get, "/api/v3/repos/disabled-owner/disabled/issues/#{ordinary.number}/comments",
             nil},
            {:post, "/api/v3/repos/disabled-owner/disabled/issues/#{ordinary.number}/comments",
             %{"body" => "blocked"}},
            {:patch,
             "/api/v3/repos/disabled-owner/disabled/issues/comments/#{ordinary_comment.id}",
             %{"body" => "blocked"}}
          ] do
        assert %{"message" => "Issues are disabled for this repository"} =
                 request(api_conn(secret, version), method, path, body) |> json_response(410)
      end

      shown =
        api_conn(secret, version)
        |> get("/api/v3/repos/disabled-owner/disabled/issues/#{pull.number}")

      assert %{"id" => ^pull_id} =
               assert_schema(shown, "/repos/{owner}/{repo}/issues/{issue_number}", :get, 200)

      comment =
        api_conn(secret, version)
        |> post_json("/api/v3/repos/disabled-owner/disabled/issues/#{pull.number}/comments", %{
          "body" => "pull comment"
        })

      comment_body =
        assert_schema(comment, "/repos/{owner}/{repo}/issues/{issue_number}/comments", :post, 201)

      pull_comments =
        api_conn(secret, version)
        |> get("/api/v3/repos/disabled-owner/disabled/issues/#{pull.number}/comments")

      assert Enum.any?(
               assert_schema(
                 pull_comments,
                 "/repos/{owner}/{repo}/issues/{issue_number}/comments",
                 :get,
                 200
               ),
               &(&1["id"] == comment_body["id"])
             )

      changed =
        api_conn(secret, version)
        |> patch_json(
          "/api/v3/repos/disabled-owner/disabled/issues/comments/#{comment_body["id"]}",
          %{"body" => "mutable"}
        )

      assert %{"body" => "mutable"} =
               assert_schema(
                 changed,
                 "/repos/{owner}/{repo}/issues/comments/{comment_id}",
                 :patch,
                 200
               )
    end
  end

  test "pagination exposes the complete Link navigation without overlapping page entries" do
    owner = user("page-owner")
    repository = repository(owner, "pages")
    {_key, secret} = pat(owner, ["public_repo"])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Issue,
      for number <- 1..105 do
        %{
          repository_id: repository.id,
          number: number,
          kind: :issue,
          title: "page #{number}",
          state: :open,
          author_user_id: owner.id,
          inserted_at: now,
          updated_at: now
        }
      end
    )

    for version <- @versions do
      first =
        api_conn(secret, version)
        |> get("/api/v3/repos/page-owner/pages/issues?per_page=100&sort=created&direction=asc")

      first_entries = assert_schema(first, "/repos/{owner}/{repo}/issues", :get, 200)
      assert length(first_entries) == 100

      assert [first_link, next_link, last_link] =
               first
               |> get_resp_header("link")
               |> List.first()
               |> String.split(", ")
               |> Enum.map(&String.trim/1)

      assert first_link =~ ~s(rel="first")
      assert next_link =~ ~s(rel="next")
      assert last_link =~ ~s(rel="last")

      second =
        api_conn(secret, version)
        |> get(
          "/api/v3/repos/page-owner/pages/issues?per_page=100&page=2&sort=created&direction=asc"
        )

      second_entries = assert_schema(second, "/repos/{owner}/{repo}/issues", :get, 200)
      assert length(second_entries) == 5
      assert Enum.map(second_entries, & &1["number"]) == Enum.to_list(101..105)

      assert MapSet.disjoint?(
               MapSet.new(Enum.map(first_entries, & &1["id"])),
               MapSet.new(Enum.map(second_entries, & &1["id"]))
             )
    end
  end

  defp repository(owner, slug, opts \\ []) do
    %Repository{owner_user_id: owner.id, storage_path: "@issue-workflow/#{owner.id}/#{slug}.git"}
    |> Repository.create_changeset(%{
      name: slug,
      slug: slug,
      visibility: :public,
      default_branch: "main",
      has_issues: Keyword.get(opts, :has_issues, true),
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp grant(repository, user, role) do
    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
    |> Repo.insert!()
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

  defp api_conn(secret, version) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_req_header("x-github-api-version", version)
    |> put_req_header("authorization", "Bearer #{secret}")
  end

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp patch_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> patch(path, Jason.encode!(body))

  defp request(conn, :get, path, _body), do: get(conn, path)
  defp request(conn, :post, path, body), do: post_json(conn, path, body)
  defp request(conn, :patch, path, body), do: patch_json(conn, path, body)

  defp assert_schema(conn, path, method, status) do
    body = json_response(conn, status)
    [version] = get_req_header(conn, "x-github-api-version")
    document = openapi_document(version)

    schema =
      document.paths
      |> Map.fetch!(path)
      |> Map.fetch!(method)
      |> Map.fetch!(:responses)
      |> Map.fetch!(Integer.to_string(status))
      |> Map.fetch!(:content)
      |> Map.fetch!("application/json")
      |> Map.fetch!(:schema)

    assert {:ok, _} = OpenApiSpex.cast_value(body, schema, document)
    body
  end

  defp openapi_document(version) do
    Path.expand("../priv/openapi/ghes-3.21-#{version}.json", __DIR__)
    |> File.read!()
    |> JSON.decode!()
    |> OpenApiSpex.OpenApi.Decode.decode()
  end

  defp assert_audits_safe(repository, token_id, secrets, request_values, version) do
    audits =
      from(event in AuditEvent,
        where:
          event.metadata["repository_id"] == ^repository.id and
            event.metadata["api_version"] == ^version
      )
      |> Repo.all()

    assert Enum.any?(
             audits,
             &(&1.metadata["token_id"] == token_id and &1.metadata["result"] == "success")
           )

    Enum.each(audits, fn audit ->
      metadata = JSON.encode!(audit.metadata)
      Enum.each(secrets, &refute(metadata =~ &1))
      Enum.each(request_values, &refute(metadata =~ &1))
    end)
  end
end
