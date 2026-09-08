defmodule ForgeGitHub.PullClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForgeGitHub.{Error, PullClient}

  setup {Req.Test, :verify_on_exit!}

  test "creates same-repository and cross-repository pull requests with bounded metadata" do
    body = String.duplicate("é", 20_000)
    same_repo = stub_name()

    Req.Test.expect(same_repo, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/base/pulls"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(encoded) == %{
               "base" => "main",
               "body" => body,
               "draft" => true,
               "head" => "feature",
               "maintainer_can_modify" => false,
               "title" => "Mirror pull"
             }

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(pull_json(7, body, draft: true))
    end)

    assert {:ok,
            %{
              "id" => 700,
              "node_id" => "PR_7",
              "number" => 7,
              "draft" => true,
              "head" => %{
                "ref" => "feature",
                "sha" => "1111111111111111111111111111111111111111",
                "repo" => %{"id" => 1001, "node_id" => "R_base", "full_name" => "acme/base"}
              },
              "base" => %{
                "ref" => "main",
                "sha" => "2222222222222222222222222222222222222222",
                "repo" => %{"id" => 1001, "node_id" => "R_base", "full_name" => "acme/base"}
              }
            }} =
             PullClient.create_pull(
               "installation_token",
               "acme",
               "base",
               %{
                 title: "Mirror pull",
                 body: body,
                 head: "feature",
                 base: "main",
                 draft: true,
                 maintainer_can_modify: false
               },
               client_opts(same_repo)
             )

    cross_repo = stub_name()

    Req.Test.expect(cross_repo, fn conn ->
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(encoded) == %{
               "base" => "main",
               "head" => "contributor:feature",
               "head_repo" => "fork",
               "title" => "Cross repository"
             }

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(
        pull_json(8, nil,
          title: "Cross repository",
          head_repo: repository_json(2002, "R_fork", "contributor/fork")
        )
      )
    end)

    assert {:ok,
            %{
              "head" => %{
                "repo" => %{
                  "id" => 2002,
                  "node_id" => "R_fork",
                  "full_name" => "contributor/fork"
                }
              },
              "base" => %{"repo" => %{"id" => 1001}}
            }} =
             PullClient.create_pull(
               "installation_token",
               "acme",
               "base",
               %{
                 title: "Cross repository",
                 head: "contributor:feature",
                 head_repo: "fork",
                 base: "main"
               },
               client_opts(cross_repo)
             )
  end

  test "gets an explicit inaccessible head without relaxing base or missing-field checks" do
    stub = stub_name()
    pull = pull_json(7, "body", head_repo: nil)
    Req.Test.expect(stub, &Req.Test.json(&1, pull))

    assert {:ok, %{"head" => %{"repo" => nil}, "base" => %{"repo" => %{"id" => 1001}}}} =
             PullClient.get_pull("installation_token", "acme", "base", 7, client_opts(stub))

    for invalid <- [
          put_in(pull, ["base", "repo"], nil),
          Map.update!(pull, "head", &Map.delete(&1, "repo"))
        ] do
      Req.Test.expect(stub, &Req.Test.json(&1, invalid))

      assert {:error, %Error{kind: :invalid_response}} =
               PullClient.get_pull("installation_token", "acme", "base", 7, client_opts(stub))
    end
  end

  test "gets and updates supported pull request metadata without hiding draft effects" do
    get_stub = stub_name()
    Req.Test.expect(get_stub, &Req.Test.json(&1, pull_json(7, "body")))

    assert {:ok,
            %{
              "number" => 7,
              "merged" => false,
              "mergeable" => true,
              "rebaseable" => true,
              "mergeable_state" => "clean",
              "merge_commit_sha" => "3333333333333333333333333333333333333333"
            }} =
             PullClient.get_pull(
               "installation_token",
               "acme",
               "base",
               7,
               client_opts(get_stub)
             )

    update_stub = stub_name()

    Req.Test.expect(update_stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/base/pulls/7"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(encoded) == %{
               "base" => "release",
               "body" => "updated",
               "maintainer_can_modify" => true,
               "state" => "closed",
               "title" => "Updated pull"
             }

      Req.Test.json(
        conn,
        pull_json(7, "updated",
          title: "Updated pull",
          state: "closed",
          base_ref: "release",
          closed_at: "2030-01-03T00:00:00Z"
        )
      )
    end)

    assert {:ok, %{"state" => "closed", "base" => %{"ref" => "release"}}} =
             PullClient.update_pull(
               "installation_token",
               "acme",
               "base",
               7,
               %{
                 title: "Updated pull",
                 body: "updated",
                 state: :closed,
                 base: "release",
                 maintainer_can_modify: true
               },
               client_opts(update_stub)
             )

    assert {:error, %Error{kind: :invalid_request}} =
             PullClient.update_pull(
               "installation_token",
               "acme",
               "base",
               7,
               %{draft: true},
               client_opts(stub_name())
             )
  end

  test "normalizes an omitted optional rebaseable detail and rejects invalid values" do
    omitted_stub = stub_name()

    Req.Test.expect(omitted_stub, fn conn ->
      conn
      |> Req.Test.json(Map.delete(pull_json(7, "body"), "rebaseable"))
    end)

    assert {:ok, %{"rebaseable" => nil}} =
             PullClient.get_pull(
               "installation_token",
               "acme",
               "base",
               7,
               client_opts(omitted_stub)
             )

    invalid_stub = stub_name()

    Req.Test.expect(invalid_stub, fn conn ->
      conn
      |> Req.Test.json(Map.put(pull_json(7, "body"), "rebaseable", "unknown"))
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             PullClient.get_pull(
               "installation_token",
               "acme",
               "base",
               7,
               client_opts(invalid_stub)
             )
  end

  test "converts an existing pull to draft and marks it ready through one GraphQL effect" do
    for {desired, operation, field} <- [
          {true, "ConvertPullRequestToDraft", "convertPullRequestToDraft"},
          {false, "MarkPullRequestReadyForReview", "markPullRequestReadyForReview"}
        ] do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/graphql"
        assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(encoded)

        assert payload["variables"] == %{"input" => %{"pullRequestId" => "PR_kwDOABCD"}}
        assert payload["query"] =~ "mutation #{operation}"
        assert payload["query"] =~ field
        assert payload["query"] =~ "pullRequest { id isDraft }"

        Req.Test.json(conn, %{
          "data" => %{field => %{"pullRequest" => %{"id" => "PR_kwDOABCD", "isDraft" => desired}}}
        })
      end)

      assert {:ok, %{"id" => "PR_kwDOABCD", "isDraft" => ^desired}} =
               PullClient.set_draft(
                 "installation_token",
                 "PR_kwDOABCD",
                 desired,
                 client_opts(stub)
               )
    end
  end

  test "fails closed on GraphQL errors, identity substitution, or an unconfirmed draft state" do
    responses = [
      %{"errors" => [%{"message" => "forbidden"}]},
      %{
        "data" => %{
          "convertPullRequestToDraft" => %{
            "pullRequest" => %{"id" => "PR_other", "isDraft" => true}
          }
        }
      },
      %{
        "data" => %{
          "convertPullRequestToDraft" => %{
            "pullRequest" => %{"id" => "PR_kwDOABCD", "isDraft" => false}
          }
        }
      }
    ]

    for response <- responses do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, response))

      assert {:error, %Error{kind: :invalid_response}} =
               PullClient.set_draft(
                 "installation_token",
                 "PR_kwDOABCD",
                 true,
                 client_opts(stub)
               )
    end
  end

  test "lists one full-sweep page in stable updated order with a safe cursor" do
    stub = stub_name()
    parent = self()

    Req.Test.expect(stub, fn conn ->
      send(parent, {:query, conn.query_string})

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/acme/base/pulls?state=all&sort=updated&direction=asc&per_page=100&page=2>; rel=\"next\""
      )
      |> Req.Test.json([pull_json(7, "body", detail: false)])
    end)

    assert {:ok, %{pulls: [%{"number" => 7}], next_cursor: 2}} =
             PullClient.list_pulls_page(
               "installation_token",
               "acme",
               "base",
               nil,
               client_opts(stub)
             )

    assert_received {:query, query}

    assert URI.decode_query(query) == %{
             "direction" => "asc",
             "page" => "1",
             "per_page" => "100",
             "sort" => "updated",
             "state" => "all"
           }
  end

  test "rejects malformed pull identities, refs, object IDs, and unsafe pagination" do
    malformed = [
      put_in(pull_json(7, "body"), ["head", "repo", "id"], 0),
      put_in(pull_json(7, "body"), ["base", "repo", "node_id"], ""),
      put_in(pull_json(7, "body"), ["base", "repo", "full_name"], "attacker/other"),
      put_in(pull_json(7, "body"), ["head", "ref"], ""),
      put_in(pull_json(7, "body"), ["base", "sha"], "not-an-oid"),
      Map.delete(pull_json(7, "body"), "merge_commit_sha"),
      Map.put(pull_json(7, "body"), "number", 0),
      Map.put(pull_json(7, "body"), "number", 8),
      put_in(pull_json(7, "body"), ["head", "repo", "node_id"], "R_substituted")
    ]

    for response <- malformed do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, response))

      assert {:error, %Error{kind: :invalid_response}} =
               PullClient.get_pull(
                 "installation_token",
                 "acme",
                 "base",
                 7,
                 client_opts(stub)
               )
    end

    unsafe_stub = stub_name()

    Req.Test.expect(unsafe_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/acme/base/pulls?state=all&sort=updated&direction=desc&per_page=100&page=2>; rel=\"next\""
      )
      |> Req.Test.json([pull_json(7, "body", detail: false)])
    end)

    assert {:error, %Error{kind: :invalid_pagination}} =
             PullClient.list_pulls_page(
               "installation_token",
               "acme",
               "base",
               nil,
               client_opts(unsafe_stub)
             )
  end

  test "keeps the long-body profile scoped to body fields" do
    for pull <- [
          pull_json(7, "body", title: String.duplicate("t", 16_385)),
          Map.put(pull_json(7, "body"), "unexpected", String.duplicate("x", 16_385))
        ] do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, pull))

      assert {:error, %Error{kind: :invalid_response}} =
               PullClient.get_pull(
                 "installation_token",
                 "acme",
                 "base",
                 7,
                 client_opts(stub)
               )
    end
  end

  test "rejects unsupported attrs, invalid cursors, and non-installation gates before transport" do
    for attrs <- [
          %{},
          %{title: ""},
          %{title: String.duplicate("x", 257), head: "feature", base: "main"},
          %{title: "pull", head: "feature", base: "main", body: String.duplicate("🙂", 65_537)},
          %{title: "pull", head: "feature", base: "main", labels: ["bug"]},
          %{title: "pull", head: "feature", base: "main", head_repo: "owner/fork"}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               PullClient.create_pull(
                 "installation_token",
                 "acme",
                 "base",
                 attrs,
                 client_opts(stub_name())
               )
    end

    for cursor <- [0, -1, "2", %{"page" => 2}, 2_147_483_648] do
      assert {:error, %Error{kind: :invalid_request}} =
               PullClient.list_pulls_page(
                 "installation_token",
                 "acme",
                 "base",
                 cursor,
                 client_opts(stub_name())
               )
    end

    for gate_key <- [nil, {:saved_credential, 1}, {:github_app, 1}, {:github_installation, 0}] do
      assert {:error, %Error{kind: :invalid_request}} =
               PullClient.get_pull(
                 "installation_token",
                 "acme",
                 "base",
                 7,
                 client_opts(stub_name(), gate_key)
               )
    end
  end

  test "does not expose an installation token through validation errors or logs" do
    token = "installation_secret_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert {:error, %Error{} = error} =
                 PullClient.create_pull(
                   token,
                   "acme",
                   "base",
                   %{
                     title: "pull",
                     head: "feature",
                     base: "main",
                     body: String.duplicate("x", 65_537)
                   },
                   client_opts(stub_name())
                 )

        refute Exception.message(error) =~ token
        refute inspect(error) =~ token
      end)

    refute log =~ token
  end

  defp pull_json(number, body, overrides \\ []) do
    overrides = Map.new(overrides)
    head_repo = Map.get(overrides, :head_repo, repository_json(1001, "R_base", "acme/base"))
    detail? = Map.get(overrides, :detail, true)

    pull = %{
      "id" => number * 100,
      "node_id" => "PR_#{number}",
      "number" => number,
      "title" => Map.get(overrides, :title, "Pull #{number}"),
      "body" => body,
      "state" => Map.get(overrides, :state, "open"),
      "draft" => Map.get(overrides, :draft, false),
      "user" => user_json(),
      "created_at" => "2030-01-01T00:00:00Z",
      "updated_at" => "2030-01-02T00:00:00Z",
      "closed_at" => Map.get(overrides, :closed_at),
      "merged_at" => Map.get(overrides, :merged_at),
      "merge_commit_sha" =>
        Map.get(overrides, :merge_commit_sha, "3333333333333333333333333333333333333333"),
      "head" => %{
        "ref" => "feature",
        "sha" => "1111111111111111111111111111111111111111",
        "repo" => head_repo
      },
      "base" => %{
        "ref" => Map.get(overrides, :base_ref, "main"),
        "sha" => "2222222222222222222222222222222222222222",
        "repo" => repository_json(1001, "R_base", "acme/base")
      }
    }

    if detail? do
      Map.merge(pull, %{
        "merged" => false,
        "mergeable" => true,
        "rebaseable" => true,
        "mergeable_state" => "clean"
      })
    else
      pull
    end
  end

  defp repository_json(id, node_id, full_name) do
    %{"id" => id, "node_id" => node_id, "full_name" => full_name}
  end

  defp user_json do
    %{"id" => 99, "node_id" => "U_99", "login" => "octocat"}
  end

  defp client_opts(stub, gate_key \\ {:github_installation, System.unique_integer([:positive])}) do
    [
      plug: {Req.Test, stub},
      gate_key: gate_key,
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}
end
