defmodule ForgeGitHub.IssueClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForgeGitHub.{Error, IssueClient}

  setup {Req.Test, :verify_on_exit!}

  test "creates, gets, and updates issues with supported synchronization fields" do
    parent = self()
    body = String.duplicate("é", 20_000)

    create_stub = stub_name()

    Req.Test.expect(create_stub, fn conn ->
      send(parent, {:request, conn.method, conn.request_path})
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(encoded) == %{
               "assignees" => ["octocat"],
               "body" => body,
               "labels" => ["bug", "sync"],
               "title" => "Mirror me"
             }

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(issue_json(7, body))
    end)

    assert {:ok, %{"id" => 700, "node_id" => "I_7", "body" => ^body}} =
             IssueClient.create_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               %{
                 title: "Mirror me",
                 body: body,
                 labels: ["bug", "sync"],
                 assignees: ["octocat"]
               },
               client_opts(create_stub)
             )

    assert_received {:request, "POST", "/repos/octocat/Hello-World/issues"}

    get_stub = stub_name()
    Req.Test.expect(get_stub, &Req.Test.json(&1, issue_json(7, body)))

    assert {:ok, %{"number" => 7}} =
             IssueClient.get_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               client_opts(get_stub)
             )

    update_stub = stub_name()

    Req.Test.expect(update_stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/octocat/Hello-World/issues/7"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(encoded) == %{
               "assignees" => [],
               "labels" => ["fixed"],
               "state" => "closed",
               "state_reason" => "completed"
             }

      Req.Test.json(
        conn,
        issue_json(7, body,
          state: "closed",
          state_reason: "completed",
          labels: [%{"id" => 11, "node_id" => "L_11", "name" => "fixed"}],
          assignees: []
        )
      )
    end)

    assert {:ok,
            %{
              "state" => "closed",
              "state_reason" => "completed",
              "labels" => [%{"name" => "fixed"}],
              "assignees" => []
            }} =
             IssueClient.update_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               %{state: :closed, state_reason: :completed, labels: ["fixed"], assignees: []},
               client_opts(update_stub)
             )
  end

  test "fetches a pull request's distinct canonical issue identity" do
    pull_issue =
      issue_json(7, "pull body")
      |> Map.put("pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"
      })

    accepted_stub = stub_name()
    Req.Test.expect(accepted_stub, &Req.Test.json(&1, pull_issue))

    assert {:ok, %{"id" => 700, "node_id" => "I_7", "number" => 7}} =
             IssueClient.get_pull_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               client_opts(accepted_stub)
             )

    wrong_number_stub = stub_name()
    Req.Test.expect(wrong_number_stub, &Req.Test.json(&1, %{pull_issue | "number" => 8}))

    assert {:error, %Error{kind: :invalid_response}} =
             IssueClient.get_pull_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               client_opts(wrong_number_stub)
             )

    wrong_repository_stub = stub_name()

    Req.Test.expect(wrong_repository_stub, fn conn ->
      Req.Test.json(
        conn,
        put_in(
          pull_issue,
          ["pull_request", "url"],
          "https://api.github.com/repos/octocat/private/pulls/7"
        )
      )
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             IssueClient.get_pull_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               client_opts(wrong_repository_stub)
             )

    ordinary_issue_stub = stub_name()
    Req.Test.expect(ordinary_issue_stub, &Req.Test.json(&1, issue_json(7, "ordinary")))

    assert {:error, %Error{kind: :invalid_response}} =
             IssueClient.get_pull_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               client_opts(ordinary_issue_stub)
             )

    update_stub = stub_name()

    Req.Test.expect(update_stub, fn conn ->
      assert conn.method == "PATCH"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(encoded) == %{"state" => "closed", "state_reason" => "completed"}

      Req.Test.json(
        conn,
        pull_issue
        |> Map.put("state", "closed")
        |> Map.put("state_reason", "completed")
      )
    end)

    assert {:ok, %{"id" => 700, "state" => "closed", "state_reason" => "completed"}} =
             IssueClient.update_pull_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               %{state: :closed, state_reason: :completed},
               client_opts(update_stub)
             )
  end

  test "creates, gets, updates, and deletes issue comments" do
    parent = self()
    body = String.duplicate("c", 20_000)

    create_stub = stub_name()

    Req.Test.expect(create_stub, fn conn ->
      send(parent, {:request, conn.method, conn.request_path})
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(encoded) == %{"body" => body}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(comment_json(601, 7, body))
    end)

    assert {:ok, %{"id" => 601, "issue_number" => 7, "body" => ^body}} =
             IssueClient.create_comment(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               %{body: body},
               client_opts(create_stub)
             )

    assert_received {:request, "POST", "/repos/octocat/Hello-World/issues/7/comments"}

    get_stub = stub_name()
    Req.Test.expect(get_stub, &Req.Test.json(&1, comment_json(601, 7, body)))

    assert {:ok, %{"id" => 601, "issue_number" => 7}} =
             IssueClient.get_comment(
               "installation_token",
               "octocat",
               "Hello-World",
               601,
               client_opts(get_stub)
             )

    update_stub = stub_name()

    Req.Test.expect(update_stub, fn conn ->
      assert conn.method == "PATCH"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(encoded) == %{"body" => "updated"}
      Req.Test.json(conn, comment_json(601, 7, "updated"))
    end)

    assert {:ok, %{"body" => "updated"}} =
             IssueClient.update_comment(
               "installation_token",
               "octocat",
               "Hello-World",
               601,
               %{"body" => "updated"},
               client_opts(update_stub)
             )

    delete_stub = stub_name()
    Req.Test.expect(delete_stub, &Plug.Conn.send_resp(&1, 204, ""))

    assert :ok =
             IssueClient.delete_comment(
               "installation_token",
               "octocat",
               "Hello-World",
               601,
               client_opts(delete_stub)
             )
  end

  test "fetches one bounded updated issue page, excludes pull requests, and returns a safe cursor" do
    stub = stub_name()
    parent = self()
    since = ~U[2030-01-01 00:00:00Z]

    Req.Test.expect(stub, fn conn ->
      send(parent, {:query, conn.query_string})

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/octocat/Hello-World/issues?state=all&sort=updated&direction=asc&since=2030-01-01T00%3A00%3A00Z&per_page=100&page=2>; rel=\"next\""
      )
      |> Req.Test.json([
        issue_json(7, "issue"),
        Map.put(issue_json(8, "pull"), "pull_request", %{
          "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/8"
        })
      ])
    end)

    assert {:ok, %{issues: [%{"number" => 7}], next_cursor: 2}} =
             IssueClient.list_updated_issues_page(
               "installation_token",
               "octocat",
               "Hello-World",
               since,
               nil,
               client_opts(stub)
             )

    assert_received {:query, query}

    assert URI.decode_query(query) == %{
             "direction" => "asc",
             "page" => "1",
             "per_page" => "100",
             "since" => "2030-01-01T00:00:00Z",
             "sort" => "updated",
             "state" => "all"
           }
  end

  test "fetches one bounded repository-wide updated comment page" do
    stub = stub_name()
    parent = self()
    since = ~U[2030-01-01 00:00:00Z]

    Req.Test.expect(stub, fn conn ->
      send(parent, {:query, conn.query_string})
      Req.Test.json(conn, [comment_json(601, 7, "comment")])
    end)

    assert {:ok, %{comments: [%{"id" => 601, "issue_number" => 7}], next_cursor: nil}} =
             IssueClient.list_updated_comments_page(
               "installation_token",
               "octocat",
               "Hello-World",
               since,
               nil,
               client_opts(stub)
             )

    assert_received {:query, query}

    assert URI.decode_query(query) == %{
             "direction" => "asc",
             "page" => "1",
             "per_page" => "100",
             "since" => "2030-01-01T00:00:00Z",
             "sort" => "updated"
           }
  end

  test "rejects non-installation gates before transport" do
    for gate_key <- [nil, {:saved_credential, 1}, {:github_app, 1}, {:github_installation, 0}] do
      opts = client_opts(stub_name(), gate_key)

      assert {:error, %Error{kind: :invalid_request}} =
               IssueClient.get_issue(
                 "installation_token",
                 "octocat",
                 "Hello-World",
                 7,
                 opts
               )
    end
  end

  test "validates mutation attrs and keeps the generic JSON limit scoped" do
    stub = stub_name()
    Req.Test.stub(stub, fn _conn -> flunk("invalid mutation reached HTTP") end)

    invalid_issues = [
      %{},
      %{title: ""},
      %{title: String.duplicate("x", 257)},
      %{title: "ok", body: String.duplicate("🙂", 65_537)},
      %{title: "ok", state: :closed},
      %{title: "ok", milestone: 1},
      %{title: "ok", labels: [String.duplicate("x", 16_385)]}
    ]

    for attrs <- invalid_issues do
      assert {:error, %Error{kind: :invalid_request}} =
               IssueClient.create_issue(
                 "installation_token",
                 "octocat",
                 "Hello-World",
                 attrs,
                 client_opts(stub)
               )
    end

    assert {:error, %Error{kind: :invalid_request}} =
             IssueClient.update_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               %{state_reason: :completed},
               client_opts(stub)
             )

    assert {:error, %Error{kind: :invalid_request}} =
             IssueClient.create_comment(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               %{body: ""},
               client_opts(stub)
             )
  end

  test "supports the full local body policy without accepting one extra character" do
    accepted = String.duplicate("🙂", 65_536)
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
      assert JSON.decode!(encoded) == %{"body" => accepted}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(comment_json(601, 7, accepted))
    end)

    assert {:ok, %{"body" => ^accepted}} =
             IssueClient.create_comment(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               %{body: accepted},
               client_opts(stub)
             )
  end

  test "rejects malformed resources and unsafe pagination instead of truncating" do
    malformed_stub = stub_name()
    Req.Test.expect(malformed_stub, &Req.Test.json(&1, %{"id" => 1}))

    assert {:error, %Error{kind: :invalid_response}} =
             IssueClient.get_issue(
               "installation_token",
               "octocat",
               "Hello-World",
               7,
               client_opts(malformed_stub)
             )

    unsafe_stub = stub_name()

    Req.Test.expect(unsafe_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/octocat/Hello-World/issues?state=all&sort=updated&direction=desc&since=2030-01-01T00%3A00%3A00Z&per_page=100&page=2>; rel=\"next\""
      )
      |> Req.Test.json([issue_json(7, "body")])
    end)

    assert {:error, %Error{kind: :invalid_pagination}} =
             IssueClient.list_updated_issues_page(
               "installation_token",
               "octocat",
               "Hello-World",
               ~U[2030-01-01 00:00:00Z],
               nil,
               client_opts(unsafe_stub)
             )
  end

  test "large-body profile does not widen title or unknown response fields" do
    for issue <- [
          issue_json(7, "body", title: String.duplicate("t", 16_385)),
          Map.put(issue_json(7, "body"), "unexpected", String.duplicate("x", 16_385))
        ] do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, issue))

      assert {:error, %Error{kind: :invalid_response}} =
               IssueClient.get_issue(
                 "installation_token",
                 "octocat",
                 "Hello-World",
                 7,
                 client_opts(stub)
               )
    end
  end

  test "rejects non-advancing and non-integer cursors" do
    for cursor <- [0, -1, "2", %{"page" => 2}, 2_147_483_648] do
      assert {:error, %Error{kind: :invalid_request}} =
               IssueClient.list_updated_comments_page(
                 "installation_token",
                 "octocat",
                 "Hello-World",
                 ~U[2030-01-01 00:00:00Z],
                 cursor,
                 client_opts(stub_name())
               )
    end
  end

  test "does not expose an installation token through validation errors or logs" do
    token = "installation_secret_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert {:error, %Error{} = error} =
                 IssueClient.create_issue(
                   token,
                   "octocat",
                   "Hello-World",
                   %{title: "ok", body: String.duplicate("x", 65_537)},
                   client_opts(stub_name())
                 )

        refute Exception.message(error) =~ token
        refute inspect(error) =~ token
      end)

    refute log =~ token
  end

  defp client_opts(stub, gate_key \\ {:github_installation, System.unique_integer([:positive])}) do
    [
      plug: {Req.Test, stub},
      gate_key: gate_key,
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defp issue_json(number, body, overrides \\ []) do
    overrides =
      Map.new(overrides, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

    Map.merge(
      %{
        "id" => number * 100,
        "node_id" => "I_#{number}",
        "number" => number,
        "title" => "Issue #{number}",
        "body" => body,
        "state" => "open",
        "state_reason" => nil,
        "labels" => [%{"id" => 10, "node_id" => "L_10", "name" => "bug"}],
        "assignees" => [user_json()],
        "user" => user_json(),
        "created_at" => "2030-01-01T00:00:00Z",
        "updated_at" => "2030-01-02T00:00:00Z",
        "closed_at" => nil
      },
      overrides
    )
  end

  defp comment_json(id, issue_number, body) do
    %{
      "id" => id,
      "node_id" => "IC_#{id}",
      "body" => body,
      "user" => user_json(),
      "issue_url" => "https://api.github.com/repos/octocat/Hello-World/issues/#{issue_number}",
      "created_at" => "2030-01-01T00:00:00Z",
      "updated_at" => "2030-01-02T00:00:00Z"
    }
  end

  defp user_json do
    %{"id" => 99, "node_id" => "U_99", "login" => "octocat"}
  end
end
