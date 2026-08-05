defmodule FornacastAPI.IssueContractTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.User
  alias ForgeIssues.{Comment, Issue, Label}

  alias FornacastAPI.{
    IssueContract,
    IssueFixtureLiterals,
    RequestValidator,
    Serializer
  }

  @versions IssueFixtureLiterals.versions()

  setup do
    previous_base_url = Application.fetch_env!(:fornacast, :base_url)
    Application.put_env(:fornacast, :base_url, "https://forge.test")
    on_exit(fn -> Application.put_env(:fornacast, :base_url, previous_base_url) end)
  end

  test "accepts every issue mutation operation for both versions" do
    valid_mutations = [
      issue_create: %{
        "title" => "API issue",
        "body" => nil,
        "assignee" => nil,
        "assignees" => ["octocat"],
        "labels" => ["bug", %{"name" => "api"}]
      },
      issue_update: %{
        "title" => "Updated issue",
        "body" => "Updated body",
        "state" => "closed",
        "state_reason" => "completed",
        "assignee" => "octocat",
        "assignees" => ["octocat"],
        "labels" => ["bug", %{"name" => "api"}]
      },
      issue_comment_create: %{"body" => "First comment"},
      issue_comment_update: %{"body" => "Updated comment"}
    ]

    for version <- @versions, {operation, body} <- valid_mutations do
      assert {:ok, ^body} = RequestValidator.validate(version, operation, body)
    end
  end

  test "rejects every invalid issue mutation shape for both versions" do
    invalid_mutations = [
      {:issue_create, %{}, "title", :missing_field},
      {:issue_create, %{"title" => ""}, "title", :invalid},
      {:issue_create, %{"title" => "  "}, "title", :invalid},
      {:issue_create, %{"title" => 1}, "title", :invalid},
      {:issue_create, %{"title" => "Issue", "body" => 1}, "body", :invalid},
      {:issue_create, %{"title" => "Issue", "unknown" => true}, "unknown", :unprocessable},
      {:issue_update, %{"title" => ""}, "title", :invalid},
      {:issue_update, %{"title" => 1}, "title", :invalid},
      {:issue_update, %{"body" => 1}, "body", :invalid},
      {:issue_update, %{"state" => 1}, "state", :invalid},
      {:issue_update, %{"state" => "merged"}, "state", :invalid},
      {:issue_update, %{"state_reason" => 1}, "state_reason", :invalid},
      {:issue_update, %{"state_reason" => "duplicate"}, "state_reason", :invalid},
      {:issue_update, %{"assignee" => []}, "assignee", :invalid},
      {:issue_update, %{"assignees" => "octocat"}, "assignees", :invalid},
      {:issue_update, %{"assignees" => [1]}, "assignees", :invalid},
      {:issue_update, %{"labels" => "bug"}, "labels", :invalid},
      {:issue_update, %{"labels" => [1]}, "labels", :invalid},
      {:issue_update, %{"labels" => [%{}]}, "labels", :invalid},
      {:issue_update, %{"labels" => [%{"name" => 1}]}, "labels", :invalid},
      {:issue_update, %{"labels" => [%{"label" => "bug"}]}, "labels", :invalid},
      {:issue_update, %{"labels" => [%{"name" => "bug", "color" => "fff"}]}, "labels", :invalid},
      {:issue_update, %{"unknown" => true}, "unknown", :unprocessable},
      {:issue_comment_create, %{}, "body", :missing_field},
      {:issue_comment_create, %{"body" => ""}, "body", :invalid},
      {:issue_comment_create, %{"body" => "  "}, "body", :invalid},
      {:issue_comment_create, %{"body" => 1}, "body", :invalid},
      {:issue_comment_create, %{"body" => "ok", "unknown" => true}, "unknown", :unprocessable},
      {:issue_comment_update, %{}, "body", :missing_field},
      {:issue_comment_update, %{"body" => ""}, "body", :invalid},
      {:issue_comment_update, %{"body" => "  "}, "body", :invalid},
      {:issue_comment_update, %{"body" => 1}, "body", :invalid},
      {:issue_comment_update, %{"body" => "ok", "unknown" => true}, "unknown", :unprocessable}
    ]

    for version <- @versions, {operation, body, field, code} <- invalid_mutations do
      assert {:error, {:validation, [%{resource: "Issue", field: ^field, code: ^code}]}} =
               RequestValidator.validate(version, operation, body)
    end
  end

  test "parses exact issue and comment filter contracts" do
    assert {:ok, filters} =
             IssueContract.list_filters(%{
               "page" => "2",
               "per_page" => "100",
               "labels" => "bug, api",
               "state" => "all",
               "assignee" => "octocat",
               "creator" => "hubot",
               "sort" => "updated",
               "direction" => "asc",
               "since" => "2026-07-21T00:00:00Z",
               "ignored" => "yes"
             })

    assert filters == [
             page: 2,
             per_page: 100,
             state: :all,
             labels: ["bug", "api"],
             assignee: "octocat",
             creator: "hubot",
             sort: :updated,
             direction: :asc,
             since: ~U[2026-07-21 00:00:00Z]
           ]

    assert {:ok,
            [
              page: 1,
              per_page: 30,
              state: :open,
              labels: [],
              assignee: nil,
              creator: nil,
              sort: :created,
              direction: :desc,
              since: nil
            ]} = IssueContract.list_filters(%{"unknown" => []})

    assert {:ok, [page: 1, per_page: 30, since: nil]} =
             IssueContract.comment_filters(%{"unknown" => []})

    assert {:ok, [page: 2, per_page: 50, since: ~U[2026-07-21 00:00:00Z]]} =
             IssueContract.comment_filters(%{
               "page" => "2",
               "per_page" => "50",
               "since" => "2026-07-21T00:00:00Z"
             })
  end

  test "rejects invalid filters and enforces label and pagination bounds" do
    issue_filter_errors = [
      {%{"state" => "merged"}, "Issue", "state", :invalid},
      {%{"state" => 1}, "Issue", "state", :invalid},
      {%{"labels" => []}, "Issue", "labels", :invalid},
      {%{"assignee" => []}, "Issue", "assignee", :invalid},
      {%{"creator" => []}, "Issue", "creator", :invalid},
      {%{"sort" => "relevance"}, "Issue", "sort", :invalid},
      {%{"sort" => 1}, "Issue", "sort", :invalid},
      {%{"direction" => "sideways"}, "Issue", "direction", :invalid},
      {%{"direction" => 1}, "Issue", "direction", :invalid},
      {%{"since" => "yesterday"}, "Issue", "since", :invalid},
      {%{"since" => "2026-07-21T08:00:00+08:00"}, "Issue", "since", :invalid},
      {%{"since" => 1}, "Issue", "since", :invalid},
      {%{"page" => "0"}, "Pagination", "page", :invalid},
      {%{"page" => 1}, "Pagination", "page", :invalid},
      {%{"per_page" => "0"}, "Pagination", "per_page", :invalid},
      {%{"per_page" => "101"}, "Pagination", "per_page", :invalid}
    ]

    for {params, resource, field, code} <- issue_filter_errors do
      assert {:error, {:validation, [%{resource: ^resource, field: ^field, code: ^code}]}} =
               IssueContract.list_filters(params)
    end

    for params <- [
          %{"since" => "yesterday"},
          %{"since" => "2026-07-21T08:00:00+08:00"},
          %{"since" => 1}
        ] do
      assert {:error, {:validation, [%{resource: "Issue", field: "since", code: :invalid}]}} =
               IssueContract.comment_filters(params)
    end

    labels = Enum.map_join(1..100, ",", &"label-#{&1}")
    assert {:ok, filters} = IssueContract.list_filters(%{"labels" => labels})
    assert length(filters[:labels]) == 100

    assert {:error, {:validation, [%{resource: "Issue", field: "labels", code: :unprocessable}]}} =
             IssueContract.list_filters(%{"labels" => labels <> ",label-101"})

    maximum_page = "9223372036854775807"

    assert {:ok, filters} = IssueContract.list_filters(%{"page" => maximum_page})
    assert filters[:page] == 9_223_372_036_854_775_807
  end

  test "renders complete pinned issue resources" do
    for version <- @versions do
      opts = [
        owner: "acme",
        repo: "widget",
        issue_number: 7,
        pull_links_by_issue_id: %{3001 => %{merged_at: nil}}
      ]

      assert Serializer.render(version, :issue, %{issue() | kind: :issue}, opts) ==
               IssueFixtureLiterals.issue()

      assert Serializer.render(version, :issue, issue(), opts) ==
               IssueFixtureLiterals.pull_issue(version)

      assert Serializer.render(version, :issue_comment, comment(), opts) ==
               IssueFixtureLiterals.comment()

      assert Serializer.render(version, :label, label(), opts) == IssueFixtureLiterals.label()

      assert_fixtures(version)
    end
  end

  test "2022 serializers ignore a conflicting version option" do
    opts = [
      owner: "acme",
      repo: "widget",
      issue_number: 7,
      pull_links_by_issue_id: %{3001 => %{merged_at: nil}},
      version: "2026-03-10"
    ]

    assert Serializer.render("2022-11-28", :issue, issue(), opts) ==
             IssueFixtureLiterals.pull_issue("2022-11-28")

    assert Serializer.render("2022-11-28", :issue_comment, comment(), opts) ==
             IssueFixtureLiterals.comment()

    assert Serializer.render("2022-11-28", :label, label(), opts) ==
             IssueFixtureLiterals.label()
  end

  defp issue do
    %Issue{
      id: 3001,
      number: 7,
      kind: :pull_request,
      title: "API issue",
      body: "Track compatibility",
      state: :open,
      author: author(),
      labels: [],
      assignees: [],
      comment_count: 0,
      author_association: "NONE",
      inserted_at: ~U[2026-07-21 00:00:00Z],
      updated_at: ~U[2026-07-21 00:00:00Z]
    }
  end

  defp comment do
    %Comment{
      id: 3101,
      issue_id: 3001,
      body: "First comment",
      author: author(),
      author_association: "NONE",
      inserted_at: ~U[2026-07-21 00:00:00Z],
      updated_at: ~U[2026-07-21 00:00:00Z]
    }
  end

  defp label,
    do: %Label{id: 3201, name: "bug", color: "ff0000", default: false, description: nil}

  defp author, do: %User{id: 41, username: "octocat", kind: :user, role: :user}

  defp assert_fixtures(version) do
    root = Path.join([Path.expand("fixtures", __DIR__), version, "issues"])
    document = openapi_document(version)

    for {filename, literal} <- IssueFixtureLiterals.files(version) do
      bytes = File.read!(Path.join(root, filename))
      encoded_literal = JSON.encode!(literal)
      assert bytes == encoded_literal

      decoded = JSON.decode!(bytes)
      assert decoded == literal
      assert_valid_fixture(document, filename, decoded)
    end
  end

  defp openapi_document(version) do
    Path.expand("../priv/openapi/ghes-3.21-#{version}.json", __DIR__)
    |> File.read!()
    |> JSON.decode!()
    |> OpenApiSpex.OpenApi.Decode.decode()
  end

  defp assert_valid_fixture(document, filename, body) do
    {path, method, status} =
      case filename do
        "issue.json" ->
          {"/repos/{owner}/{repo}/issues/{issue_number}", :get, "200"}

        "pull-issue.json" ->
          {"/repos/{owner}/{repo}/issues/{issue_number}", :get, "200"}

        "issue-list.json" ->
          {"/repos/{owner}/{repo}/issues", :get, "200"}

        "issue-comment.json" ->
          {"/repos/{owner}/{repo}/issues/{issue_number}/comments", :post, "201"}

        "issue-comment-list.json" ->
          {"/repos/{owner}/{repo}/issues/{issue_number}/comments", :get, "200"}
      end

    schema =
      document.paths
      |> Map.fetch!(path)
      |> Map.fetch!(method)
      |> Map.fetch!(:responses)
      |> Map.fetch!(status)
      |> Map.fetch!(:content)
      |> Map.fetch!("application/json")
      |> Map.fetch!(:schema)

    assert {:ok, _} = OpenApiSpex.cast_value(body, schema, document)
  end
end
