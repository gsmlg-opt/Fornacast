defmodule FornacastAPI.IssueWorkflowTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label}
  alias ForgeRepos.{Collaborator, Repository}
  alias Fornacast.{AuditEvent, Repo}

  @user_agent "fornacast-issue-workflow-test/1.0"
  @versions ["2022-11-28", "2026-03-10"]

  test "the REST workflow preserves author, writer, schema, and audit contracts" do
    owner = user("workflow-owner")
    reader = user("workflow-reader")
    writer = user("workflow-writer")
    assignee = user("workflow-assignee")
    private_repository = repository(owner, "workflow-private", visibility: :private)
    grant(private_repository, reader, :read)
    {reader_key, reader_secret} = pat(reader, ["repo"])
    {writer_key, writer_secret} = pat(writer, ["public_repo"])

    for version <- @versions do
      private_read =
        api_conn(reader_secret, version)
        |> get("/api/v3/repos/workflow-owner/workflow-private/issues")

      assert [] = assert_schema(private_read, "/repos/{owner}/{repo}/issues", :get, 200)
      slug = "workflow-#{String.replace(version, "-", "")}"
      repository = repository(owner, slug)
      grant(repository, reader, :read)
      grant(repository, writer, :write)
      grant(repository, assignee, :read)
      path = "/api/v3/repos/workflow-owner/#{slug}"

      issue =
        api_conn(reader_secret, version)
        |> post_json("#{path}/issues", %{
          "title" => "reader issue #{version}",
          "body" => "reader body #{version}",
          "labels" => ["bug"],
          "assignees" => [assignee.username]
        })

      created = assert_schema(issue, "/repos/{owner}/{repo}/issues", :post, 201)
      assert created["number"] == 1
      assert created["labels"] == []
      assert created["assignees"] == []

      shown =
        api_conn(reader_secret, version)
        |> get("#{path}/issues/#{created["number"]}")

      assert assert_schema(shown, "/repos/{owner}/{repo}/issues/{issue_number}", :get, 200)["id"] ==
               created["id"]

      edited =
        api_conn(reader_secret, version)
        |> patch_json("#{path}/issues/#{created["number"]}", %{
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
          "#{path}/issues/#{created["number"]}/comments",
          %{
            "body" => "comment #{version}"
          }
        )

      comment_body =
        assert_schema(comment, "/repos/{owner}/{repo}/issues/{issue_number}/comments", :post, 201)

      changed_comment =
        api_conn(reader_secret, version)
        |> patch_json(
          "#{path}/issues/comments/#{comment_body["id"]}",
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
        |> patch_json("#{path}/issues/#{created["number"]}", %{
          "labels" => ["bug", "help wanted"],
          "assignee" => assignee.username
        })

      assigned_body =
        assert_schema(assigned, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      assert MapSet.new(Enum.map(assigned_body["labels"], & &1["name"])) ==
               MapSet.new(["bug", "help wanted"])

      assert [%{"login" => login}] = assigned_body["assignees"]
      assert login == assignee.username

      labels =
        from(label in Label,
          where:
            label.repository_id == ^repository.id and
              label.normalized_name in ["bug", "help wanted"]
        )
        |> Repo.all()

      assert MapSet.new(Enum.map(labels, & &1.normalized_name)) ==
               MapSet.new(["bug", "help wanted"])

      target = Repo.get!(Issue, created["id"])
      since = target.updated_at
      suffix = String.replace(version, "-", "")
      other_creator = user("workflow-other-creator-#{suffix}")
      other_assignee = user("workflow-other-assignee-#{suffix}")

      decoys = %{
        "state" =>
          filtered_issue(repository, reader, 2, labels, assignee,
            state: :closed,
            updated_at: since
          ),
        "labels" =>
          filtered_issue(repository, reader, 3, [label(labels, "bug")], assignee,
            updated_at: since
          ),
        "assignee" =>
          filtered_issue(repository, reader, 4, labels, other_assignee, updated_at: since),
        "creator" =>
          filtered_issue(repository, other_creator, 5, labels, assignee, updated_at: since),
        "since" =>
          filtered_issue(repository, reader, 6, labels, assignee,
            updated_at: DateTime.add(since, -1, :second)
          )
      }

      _pull_decoy =
        filtered_issue(repository, other_creator, 7, [], nil,
          kind: :pull_request,
          state: :closed,
          updated_at: DateTime.add(since, -1, :second)
        )

      filters = %{
        "state" => "open",
        "labels" => "bug,help wanted",
        "assignee" => assignee.username,
        "creator" => reader.username,
        "since" => DateTime.to_iso8601(since)
      }

      filtered =
        api_conn(reader_secret, version)
        |> get("#{path}/issues?#{URI.encode_query(filters)}")

      assert [%{"id" => target_id, "number" => target_number}] =
               assert_schema(filtered, "/repos/{owner}/{repo}/issues", :get, 200)

      assert target_id == created["id"]
      assert target_number == created["number"]

      for {filter, decoy} <- decoys do
        relaxed_filters =
          if filter == "state",
            do: Map.put(filters, "state", "all"),
            else: Map.delete(filters, filter)

        relaxed =
          api_conn(reader_secret, version)
          |> get("#{path}/issues?#{URI.encode_query(relaxed_filters)}")
          |> assert_schema("/repos/{owner}/{repo}/issues", :get, 200)

        assert MapSet.new(Enum.map(relaxed, & &1["id"])) ==
                 MapSet.new([created["id"], decoy.id])
      end

      closed =
        api_conn(reader_secret, version)
        |> patch_json("#{path}/issues/#{created["number"]}", %{
          "state" => "closed",
          "state_reason" => "completed"
        })

      assert %{"state" => "closed", "state_reason" => "completed"} =
               assert_schema(closed, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      reopened =
        api_conn(reader_secret, version)
        |> patch_json("#{path}/issues/#{created["number"]}", %{
          "state" => "open",
          "state_reason" => "reopened"
        })

      assert %{"state" => "open", "state_reason" => "reopened"} =
               assert_schema(reopened, "/repos/{owner}/{repo}/issues/{issue_number}", :patch, 200)

      deleted =
        api_conn(reader_secret, version)
        |> delete("#{path}/issues/comments/#{comment_body["id"]}")

      assert response(deleted, 204)

      assert_workflow_audits(
        repository,
        version,
        writer,
        reader_key.id,
        writer_key.id,
        created,
        comment_body,
        [
          {"issue.created", issue, reader},
          {"issue.updated", edited, reader},
          {"issue_comment.created", comment, reader},
          {"issue_comment.updated", changed_comment, reader},
          {"issue.updated", assigned, writer},
          {"issue.updated", closed, reader},
          {"issue.updated", reopened, reader},
          {"issue_comment.deleted", deleted, reader}
        ],
        [
          reader_secret,
          writer_secret,
          "reader issue #{version}",
          "reader body #{version}",
          "edited #{version}",
          "edited body #{version}",
          "comment #{version}",
          "changed comment #{version}",
          "bug",
          "help wanted",
          assignee.username,
          "closed",
          "completed",
          "open",
          "reopened"
        ]
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
             %{"body" => "blocked"}},
            {:delete,
             "/api/v3/repos/disabled-owner/disabled/issues/comments/#{ordinary_comment.id}", nil}
          ] do
        conn = request(api_conn(secret, version), method, path, body)
        error = json_response(conn, 410)
        assert %{"message" => "Issues are disabled for this repository"} = error
        assert_basic_error_schema(version, error)
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

      assert response(
               api_conn(secret, version)
               |> delete(
                 "/api/v3/repos/disabled-owner/disabled/issues/comments/#{comment_body["id"]}"
               ),
               204
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
      visibility: Keyword.get(opts, :visibility, :public),
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

  defp filtered_issue(repository, author, number, labels, assignee, opts) do
    updated_at = Keyword.fetch!(opts, :updated_at)
    state = Keyword.get(opts, :state, :open)

    issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: number,
        kind: Keyword.get(opts, :kind, :issue),
        title: "filter decoy #{number}",
        state: state,
        state_reason: if(state == :closed, do: :completed),
        author_user_id: author.id,
        inserted_at: updated_at,
        updated_at: updated_at
      })

    Enum.each(labels, fn label ->
      %IssueLabel{}
      |> IssueLabel.changeset(%{issue_id: issue.id, label_id: label.id})
      |> Repo.insert!()
    end)

    if assignee do
      %IssueAssignee{}
      |> IssueAssignee.changeset(%{issue_id: issue.id, user_id: assignee.id})
      |> Repo.insert!()
    end

    issue
  end

  defp label(labels, normalized_name) do
    Enum.find(labels, &(&1.normalized_name == normalized_name))
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
  defp request(conn, :delete, path, _body), do: delete(conn, path)

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

  defp assert_basic_error_schema(version, body) do
    document = openapi_document(version)

    schema =
      document.paths
      |> Map.fetch!("/repos/{owner}/{repo}/issues")
      |> Map.fetch!(:post)
      |> Map.fetch!(:responses)
      |> Map.fetch!("410")
      |> Map.fetch!(:content)
      |> Map.fetch!("application/json")
      |> Map.fetch!(:schema)

    assert {:ok, _} = OpenApiSpex.cast_value(body, schema, document)
  end

  defp assert_workflow_audits(
         repository,
         version,
         writer,
         reader_token_id,
         writer_token_id,
         issue,
         comment,
         events,
         sensitive_values
       ) do
    audits =
      from(event in AuditEvent,
        where:
          event.metadata["repository_id"] == ^repository.id and
            event.metadata["api_version"] == ^version
      )
      |> Repo.all()

    assert length(audits) == 8

    Enum.each(events, fn {action, conn, actor} ->
      target =
        if String.starts_with?(action, "issue_comment"),
          do: {"issue_comment", to_string(comment["id"])},
          else:
            if(action == "issue.created",
              do: {"repository", to_string(repository.id)},
              else: {"issue", to_string(issue["id"])}
            )

      [request_id] = get_resp_header(conn, "x-github-request-id")

      assert %AuditEvent{} =
               audit =
               Enum.find(audits, fn row ->
                 row.action == action and row.target_type == elem(target, 0) and
                   row.target_id == elem(target, 1) and
                   row.metadata["request_id"] == request_id
               end)

      assert audit.actor_user_id == actor.id
      assert audit.ip_address == "127.0.0.1"
      assert audit.user_agent == @user_agent
      assert audit.metadata["repository_id"] == repository.id
      assert audit.metadata["api_version"] == version
      assert audit.metadata["result"] == "success"

      assert audit.metadata["token_id"] ==
               if(actor.id == writer.id, do: writer_token_id, else: reader_token_id)

      serialized_details =
        audit
        |> Map.from_struct()
        |> Map.take([:metadata, :details])
        |> JSON.encode!()

      Enum.each(sensitive_values, &refute(serialized_details =~ &1))
    end)
  end
end
