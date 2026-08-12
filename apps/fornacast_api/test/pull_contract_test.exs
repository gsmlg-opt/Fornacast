defmodule FornacastAPI.PullContractTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.User
  alias ForgeIssues.Issue
  alias ForgePulls.PullRequest
  alias ForgeRepos.{Repository, RepositoryView}
  alias FornacastAPI.{Error, RequestValidator, Serializer, URL}

  @versions ["2022-11-28", "2026-03-10"]
  @pull_paths [
    {"/repos/{owner}/{repo}/pulls", [:get, :post]},
    {"/repos/{owner}/{repo}/pulls/{pull_number}", [:get, :patch]},
    {"/repos/{owner}/{repo}/pulls/{pull_number}/merge", [:get, :put]}
  ]
  @pull_fields_2022 ~w(_links additions assignee assignees author_association auto_merge base body changed_files closed_at comments comments_url commits commits_url created_at deletions diff_url draft head html_url id issue_url labels locked maintainer_can_modify merge_commit_sha mergeable mergeable_state merged merged_at merged_by milestone node_id number patch_url requested_reviewers requested_teams review_comment_url review_comments review_comments_url state statuses_url title updated_at url user)
  @pull_fields_2026 ~w(_links additions assignees author_association auto_merge base body changed_files closed_at comments comments_url commits commits_url created_at deletions diff_url draft head html_url id issue_url labels locked maintainer_can_modify mergeable mergeable_state merged merged_at merged_by milestone node_id number patch_url requested_reviewers requested_teams review_comment_url review_comments review_comments_url state statuses_url title updated_at url user)
  @repository_fields_2022 ~w(allow_merge_commit allow_rebase_merge allow_squash_merge archive_url archived assignees_url blobs_url branches_url clone_url collaborators_url comments_url commits_url compare_url contents_url contributors_url created_at default_branch deployments_url description disabled downloads_url events_url fork forks forks_count forks_url full_name git_commits_url git_refs_url git_tags_url git_url has_discussions has_downloads has_issues has_pages has_projects has_wiki homepage hooks_url html_url id issue_comment_url issue_events_url issues_url keys_url labels_url language languages_url license merges_url milestones_url mirror_url name node_id notifications_url open_issues open_issues_count owner permissions private pulls_url pushed_at releases_url size ssh_url stargazers_count stargazers_url statuses_url subscribers_url subscription_url svn_url tags_url teams_url topics trees_url updated_at url visibility watchers watchers_count)
  @repository_fields_2026 ~w(allow_merge_commit allow_rebase_merge allow_squash_merge archive_url archived assignees_url blobs_url branches_url clone_url collaborators_url comments_url commits_url compare_url contents_url contributors_url created_at default_branch deployments_url description disabled downloads_url events_url fork forks forks_count forks_url full_name git_commits_url git_refs_url git_tags_url git_url has_discussions has_issues has_pages has_projects has_wiki homepage hooks_url html_url id issue_comment_url issue_events_url issues_url keys_url labels_url language languages_url license merges_url milestones_url mirror_url name node_id notifications_url open_issues open_issues_count owner permissions private pulls_url pushed_at releases_url size ssh_url stargazers_count stargazers_url statuses_url subscribers_url subscription_url svn_url tags_url teams_url topics trees_url updated_at url visibility watchers watchers_count)

  setup do
    previous = %{
      base_url: Application.fetch_env!(:fornacast, :base_url),
      ssh_host: Application.fetch_env!(:fornacast, :ssh_host),
      ssh_port: Application.fetch_env!(:fornacast, :ssh_port)
    }

    Application.put_env(:fornacast, :base_url, "https://forge.test")
    Application.put_env(:fornacast, :ssh_host, "forge.test")
    Application.put_env(:fornacast, :ssh_port, 2222)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:fornacast, key, value) end)
    end)
  end

  test "pinned contracts own all pull routes and advance only the delivery marker" do
    overlay = openapi_json("fornacast-overlay.json")
    assert overlay["implemented_through_slice"] == "4"

    for version <- @versions do
      document = openapi_json("ghes-3.21-#{version}.json")
      assert document["x-fornacast-implemented-through-slice"] == "4"

      for {path, methods} <- @pull_paths, method <- methods do
        assert is_map(get_in(document, ["paths", path, Atom.to_string(method)]))
      end
    end
  end

  test "both versions accept only the approved pull mutation fields" do
    valid = [
      pull_create: %{
        "title" => "Add API",
        "head" => "feature/api",
        "base" => "main",
        "body" => "Implements the subset"
      },
      pull_update: %{"title" => "Updated", "body" => nil, "state" => "closed", "base" => "next"},
      pull_merge: %{
        "commit_title" => "Merge pull",
        "commit_message" => "Body",
        "sha" => String.duplicate("b", 40),
        "merge_method" => "merge"
      }
    ]

    for version <- @versions, {operation, body} <- valid do
      assert {:ok, ^body} = RequestValidator.validate(version, operation, body)
    end

    for version <- @versions,
        {operation, body, field, code} <- [
          {:pull_create, %{"head" => "h", "base" => "b"}, "title", :missing_field},
          {:pull_create, %{"title" => "x", "base" => "b"}, "head", :missing_field},
          {:pull_create, %{"title" => "x", "head" => "h"}, "base", :missing_field},
          {:pull_create, %{"title" => "x", "head" => "h", "base" => "b", "draft" => false},
           "draft", :unprocessable},
          {:pull_create, %{"title" => "x", "head" => "h", "base" => "b", "head_repo" => "x"},
           "head_repo", :unprocessable},
          {:pull_create, %{"title" => "x", "head" => "h", "base" => "b", "issue" => 1}, "issue",
           :unprocessable},
          {:pull_create,
           %{"title" => "x", "head" => "h", "base" => "b", "maintainer_can_modify" => true},
           "maintainer_can_modify", :unprocessable},
          {:pull_update, %{"head" => "feature/api"}, "head", :unprocessable},
          {:pull_update, %{"maintainer_can_modify" => true}, "maintainer_can_modify",
           :unprocessable},
          {:pull_merge, %{"squash" => false}, "squash", :unprocessable},
          {:pull_create, %{"title" => "", "head" => "h", "base" => "b"}, "title", :invalid},
          {:pull_create, %{"title" => 1, "head" => "h", "base" => "b"}, "title", :invalid},
          {:pull_create, %{"title" => "x", "head" => "", "base" => "b"}, "head", :invalid},
          {:pull_create, %{"title" => "x", "head" => 1, "base" => "b"}, "head", :invalid},
          {:pull_create, %{"title" => "x", "head" => "h", "base" => ""}, "base", :invalid},
          {:pull_create, %{"title" => "x", "head" => "h", "base" => 1}, "base", :invalid},
          {:pull_create, %{"title" => "x", "head" => "h", "base" => "b", "body" => 1}, "body",
           :invalid},
          {:pull_update, %{"title" => ""}, "title", :invalid},
          {:pull_update, %{"title" => 1}, "title", :invalid},
          {:pull_update, %{"body" => 1}, "body", :invalid},
          {:pull_update, %{"state" => ""}, "state", :invalid},
          {:pull_update, %{"state" => 1}, "state", :invalid},
          {:pull_update, %{"state" => "merged"}, "state", :invalid},
          {:pull_update, %{"base" => ""}, "base", :invalid},
          {:pull_update, %{"base" => 1}, "base", :invalid},
          {:pull_merge, %{"commit_title" => ""}, "commit_title", :invalid},
          {:pull_merge, %{"commit_title" => 1}, "commit_title", :invalid},
          {:pull_merge, %{"commit_message" => 1}, "commit_message", :invalid},
          {:pull_merge, %{"sha" => ""}, "sha", :invalid},
          {:pull_merge, %{"sha" => 1}, "sha", :invalid},
          {:pull_merge, %{"merge_method" => ""}, "merge_method", :invalid},
          {:pull_merge, %{"merge_method" => 1}, "merge_method", :invalid},
          {:pull_merge, %{"merge_method" => "squash"}, "merge_method", :invalid},
          {:pull_merge, %{"unknown" => true}, "unknown", :unprocessable}
        ] do
      assert {:error, {:validation, [%{resource: "PullRequest", field: ^field, code: ^code}]}} =
               RequestValidator.validate(version, operation, body)
    end
  end

  test "pull domain errors map to the approved HTTP statuses" do
    docs = "https://docs.example.test/pulls"

    assert %Error{status: 405, message: "Pull Request is not mergeable"} =
             Error.from_domain(:conflict, docs)

    assert %Error{status: 405, message: "Pull Request is not mergeable"} =
             Error.from_domain(:merge_commits_disabled, docs)

    assert %Error{status: 409, message: "Conflict"} = Error.from_domain(:head_changed, docs)
    assert %Error{status: 409, message: "Conflict"} = Error.from_domain(:ref_conflict, docs)
    assert %Error{status: 503} = Error.from_domain({:unavailable, :deadline}, docs)
  end

  test "pull serializers render loaded issue assignees for the selected version" do
    assignee = %{fixed_user() | id: 42, username: "hubot", email: "hubot@example.test"}
    pull = put_in(fixed_pull().issue.assignees, [assignee])

    for version <- @versions do
      rendered =
        Serializer.render(version, :pull, pull,
          owner: "octocat",
          repo: "hello-world",
          actor: nil,
          repository_view: fixed_repository_view()
        )

      assert [%{id: 42, login: "hubot"} = rendered_assignee] = rendered.assignees

      if version == "2022-11-28" do
        assert rendered.assignee == rendered_assignee
      else
        refute Map.has_key?(rendered, :assignee)
      end
    end
  end

  test "pull browser URL resolves to pull HTML while REST relations remain API URLs" do
    web = "https://forge.test/alice/demo/pulls/8"
    api = "https://forge.test/api/v3/repos/alice/demo/pulls/8"

    assert URL.pull_web("alice", "demo", 8) == web

    assert URL.pull_web("alice/team", "demo repo", 8) ==
             "https://forge.test/alice%2Fteam/demo%20repo/pulls/8"

    uri = URI.parse(web)

    assert %{plug: FornacastWeb.PullRequestController, plug_opts: :show} =
             Phoenix.Router.route_info(FornacastWeb.Router, "GET", uri.path, uri.host)

    for version <- @versions do
      rendered =
        Serializer.render(version, :pull, fixed_pull(),
          owner: "alice",
          repo: "demo",
          actor: nil,
          repository_view: fixed_repository_view()
        )

      assert rendered.html_url == web
      assert rendered._links.html.href == web
      assert rendered.url == api

      assert rendered.comments_url ==
               "https://forge.test/api/v3/repos/alice/demo/issues/8/comments"

      assert rendered._links.self.href == api

      assert rendered._links.issue.href ==
               "https://forge.test/api/v3/repos/alice/demo/issues/8"
    end
  end

  test "checked-in pull fixtures are literal JSON for both versions" do
    merge_literal = %{
      "sha" => String.duplicate("c", 40),
      "merged" => true,
      "message" => "Pull Request successfully merged"
    }

    for version <- @versions do
      root = Path.join([__DIR__, "fixtures", version, "pulls"])
      pull_literal = pull_literal(version)
      list_literal = [pull_literal]

      pull_bytes = File.read!(Path.join(root, "pull.json"))
      list_bytes = File.read!(Path.join(root, "pull-list.json"))
      merge_bytes = File.read!(Path.join(root, "merge.json"))
      pull = JSON.decode!(pull_bytes)
      list = JSON.decode!(list_bytes)
      merge = JSON.decode!(merge_bytes)

      assert pull == pull_literal
      assert list == list_literal
      assert merge == merge_literal
      assert pull_bytes == JSON.encode!(pull_literal)
      assert list_bytes == JSON.encode!(list_literal)
      assert merge_bytes == JSON.encode!(merge_literal)

      rendered =
        version
        |> Serializer.render(:pull, fixed_pull(),
          owner: "octocat",
          repo: "hello-world",
          actor: nil,
          repository_view: fixed_repository_view()
        )
        |> JSON.encode!()
        |> JSON.decode!()

      assert rendered == pull_literal

      document = openapi_document(version)
      assert_valid_fixture(document, "pull.json", pull)
      assert_valid_fixture(document, "pull-list.json", list)
      assert_valid_fixture(document, "merge.json", merge)
    end
  end

  test "merge interoperability fields are explicit in both raw contracts" do
    for version <- @versions do
      document = openapi_json("ghes-3.21-#{version}.json")

      merge_schema =
        get_in(document, [
          "paths",
          "/repos/{owner}/{repo}/pulls/{pull_number}/merge",
          "put",
          "responses",
          "200",
          "content",
          "application/json",
          "schema"
        ])

      pull_schema =
        get_in(document, [
          "paths",
          "/repos/{owner}/{repo}/pulls/{pull_number}",
          "get",
          "responses",
          "200",
          "content",
          "application/json",
          "schema"
        ])

      issue_schema =
        get_in(document, [
          "paths",
          "/repos/{owner}/{repo}/issues/{issue_number}",
          "get",
          "responses",
          "200",
          "content",
          "application/json",
          "schema"
        ])

      assert Enum.sort(merge_schema["required"]) == ~w(merged message sha)
      assert Map.has_key?(pull_schema["properties"], "merged_at")
      assert Map.has_key?(issue_schema["properties"]["pull_request"]["properties"], "merged_at")
    end
  end

  def pull_literal("2022-11-28" = version),
    do: version |> pull_literal_map() |> Map.take(@pull_fields_2022)

  def pull_literal("2026-03-10" = version),
    do: version |> pull_literal_map() |> Map.take(@pull_fields_2026)

  defp pull_literal_map(version) do
    user = user_literal()
    repository = repository_literal(version)
    pull_url = "https://forge.test/api/v3/repos/octocat/hello-world/pulls/8"
    issue_url = "https://forge.test/api/v3/repos/octocat/hello-world/issues/8"
    pull_web_url = "https://forge.test/octocat/hello-world/pulls/8"

    statuses_url =
      "https://forge.test/api/v3/repos/octocat/hello-world/statuses/" <>
        String.duplicate("b", 40)

    %{
      "_links" => %{
        "comments" => %{"href" => issue_url <> "/comments"},
        "commits" => %{"href" => pull_url <> "/commits"},
        "html" => %{"href" => pull_web_url},
        "issue" => %{"href" => issue_url},
        "review_comment" => %{"href" => pull_url <> "/comments{/number}"},
        "review_comments" => %{"href" => pull_url <> "/comments"},
        "self" => %{"href" => pull_url},
        "statuses" => %{"href" => statuses_url}
      },
      "additions" => 0,
      "assignee" => nil,
      "assignees" => [],
      "author_association" => "NONE",
      "auto_merge" => nil,
      "base" => branch_literal("main", String.duplicate("a", 40), repository, user),
      "body" => "Implements the subset",
      "changed_files" => 0,
      "closed_at" => nil,
      "comments" => 0,
      "comments_url" => issue_url <> "/comments",
      "commits" => 0,
      "commits_url" => pull_url <> "/commits",
      "created_at" => "2026-07-21T00:00:00Z",
      "deletions" => 0,
      "diff_url" => pull_url,
      "draft" => false,
      "head" => branch_literal("feature/api", String.duplicate("b", 40), repository, user),
      "html_url" => pull_web_url,
      "id" => 4001,
      "issue_url" => issue_url,
      "labels" => [],
      "locked" => false,
      "maintainer_can_modify" => false,
      "merge_commit_sha" => nil,
      "mergeable" => true,
      "mergeable_state" => "mergeable",
      "merged" => false,
      "merged_at" => nil,
      "merged_by" => nil,
      "milestone" => nil,
      "node_id" => "UHVsbFJlcXVlc3Q6NDAwMQ",
      "number" => 8,
      "patch_url" => pull_url,
      "requested_reviewers" => [],
      "requested_teams" => [],
      "review_comment_url" => pull_url <> "/comments{/number}",
      "review_comments" => 0,
      "review_comments_url" => pull_url <> "/comments",
      "state" => "open",
      "statuses_url" => statuses_url,
      "title" => "Add API",
      "updated_at" => "2026-07-21T00:00:00Z",
      "url" => pull_url,
      "user" => user
    }
  end

  defp branch_literal(ref, sha, repository, user),
    do: %{
      "label" => "octocat:#{ref}",
      "ref" => ref,
      "repo" => repository,
      "sha" => sha,
      "user" => user
    }

  defp user_literal do
    base = "https://forge.test/api/v3/users/octocat"

    %{
      "avatar_url" => "https://forge.test/octocat",
      "events_url" => base <> "/events{/privacy}",
      "followers_url" => base <> "/followers",
      "following_url" => base <> "/following{/other_user}",
      "gists_url" => base <> "/gists{/gist_id}",
      "gravatar_id" => nil,
      "html_url" => "https://forge.test/octocat",
      "id" => 41,
      "login" => "octocat",
      "node_id" => "VXNlcjo0MQ",
      "organizations_url" => base <> "/orgs",
      "received_events_url" => base <> "/received_events",
      "repos_url" => base <> "/repos",
      "site_admin" => false,
      "starred_url" => base <> "/starred{/owner}{/repo}",
      "subscriptions_url" => base <> "/subscriptions",
      "type" => "User",
      "url" => base
    }
  end

  defp repository_literal("2022-11-28" = version),
    do: version |> repository_literal_map() |> Map.take(@repository_fields_2022)

  defp repository_literal("2026-03-10" = version),
    do: version |> repository_literal_map() |> Map.take(@repository_fields_2026)

  defp repository_literal_map(_version) do
    api = "https://forge.test/api/v3/repos/octocat/hello-world"
    web = "https://forge.test/octocat/hello-world"

    %{
      "allow_merge_commit" => true,
      "allow_rebase_merge" => false,
      "allow_squash_merge" => false,
      "archive_url" => api <> "/{archive_format}{/ref}",
      "archived" => false,
      "assignees_url" => api <> "/assignees{/user}",
      "blobs_url" => api <> "/git/blobs{/sha}",
      "branches_url" => api <> "/branches{/branch}",
      "clone_url" => web <> ".git",
      "collaborators_url" => api <> "/collaborators{/collaborator}",
      "comments_url" => api <> "/comments{/number}",
      "commits_url" => api <> "/commits{/sha}",
      "compare_url" => api <> "/compare/{base}...{head}",
      "contents_url" => api <> "/contents/{+path}",
      "contributors_url" => api <> "/contributors",
      "created_at" => "2026-07-21T00:00:00Z",
      "default_branch" => "main",
      "deployments_url" => api <> "/deployments",
      "description" => nil,
      "disabled" => false,
      "downloads_url" => api <> "/downloads",
      "events_url" => api <> "/events",
      "fork" => false,
      "forks" => 0,
      "forks_count" => 0,
      "forks_url" => api <> "/forks",
      "full_name" => "octocat/hello-world",
      "git_commits_url" => api <> "/git/commits{/sha}",
      "git_refs_url" => api <> "/git/refs{/sha}",
      "git_tags_url" => api <> "/git/tags{/sha}",
      "git_url" => web <> ".git",
      "has_discussions" => false,
      "has_downloads" => false,
      "has_issues" => true,
      "has_pages" => false,
      "has_projects" => false,
      "has_wiki" => false,
      "homepage" => nil,
      "hooks_url" => api <> "/hooks",
      "html_url" => web,
      "id" => 2001,
      "issue_comment_url" => api <> "/issues/comments{/number}",
      "issue_events_url" => api <> "/issues/events{/number}",
      "issues_url" => api <> "/issues{/number}",
      "keys_url" => api <> "/keys{/key_id}",
      "labels_url" => api <> "/labels{/name}",
      "language" => nil,
      "languages_url" => api <> "/languages",
      "license" => nil,
      "merges_url" => api <> "/merges",
      "milestones_url" => api <> "/milestones{/number}",
      "mirror_url" => nil,
      "name" => "hello-world",
      "node_id" => "UmVwb3NpdG9yeToyMDAx",
      "notifications_url" => api <> "/notifications{?since,all,participating}",
      "open_issues" => 0,
      "open_issues_count" => 0,
      "owner" => user_literal(),
      "permissions" => %{
        "admin" => false,
        "maintain" => false,
        "pull" => true,
        "push" => false,
        "triage" => false
      },
      "private" => false,
      "pulls_url" => api <> "/pulls{/number}",
      "pushed_at" => nil,
      "releases_url" => api <> "/releases{/id}",
      "size" => 0,
      "ssh_url" => "ssh://octocat@forge.test:2222/octocat/hello-world.git",
      "stargazers_count" => 0,
      "stargazers_url" => api <> "/stargazers",
      "statuses_url" => api <> "/statuses/{sha}",
      "subscribers_url" => api <> "/subscribers",
      "subscription_url" => api <> "/subscription",
      "svn_url" => web <> ".git",
      "tags_url" => api <> "/tags",
      "teams_url" => api <> "/teams",
      "topics" => [],
      "trees_url" => api <> "/git/trees{/sha}",
      "updated_at" => "2026-07-21T00:00:00Z",
      "url" => api,
      "visibility" => "public",
      "watchers" => 0,
      "watchers_count" => 0
    }
  end

  defp fixed_pull do
    %PullRequest{
      id: 4001,
      issue_id: 3001,
      repository_id: 2001,
      head_ref: "refs/heads/feature/api",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("b", 40),
      base_sha: String.duplicate("a", 40),
      mergeable: true,
      mergeable_state: :mergeable,
      issue: %Issue{
        id: 3001,
        repository_id: 2001,
        number: 8,
        kind: :pull_request,
        title: "Add API",
        body: "Implements the subset",
        state: :open,
        author_user_id: 41,
        author: fixed_user(),
        labels: [],
        assignees: [],
        comment_count: 0,
        author_association: "NONE",
        inserted_at: ~U[2026-07-21 00:00:00Z],
        updated_at: ~U[2026-07-21 00:00:00Z]
      },
      inserted_at: ~U[2026-07-21 00:00:00Z],
      updated_at: ~U[2026-07-21 00:00:00Z]
    }
  end

  defp fixed_repository_view do
    %RepositoryView{
      repository: %Repository{
        id: 2001,
        owner_user_id: 41,
        slug: "hello-world",
        name: "hello-world",
        visibility: :public,
        storage_path: "@hashed/example.git",
        default_branch: "main",
        has_issues: true,
        allow_merge_commit: true,
        inserted_at: ~U[2026-07-21 00:00:00Z],
        updated_at: ~U[2026-07-21 00:00:00Z]
      },
      owner: fixed_user(),
      permissions: %{admin: false, push: false, pull: true},
      size_kib: 0
    }
  end

  defp fixed_user do
    %User{
      id: 41,
      username: "octocat",
      email: "octocat@example.test",
      kind: :user,
      role: :user,
      state: :active,
      inserted_at: ~U[2026-07-21 00:00:00Z],
      updated_at: ~U[2026-07-21 00:00:00Z]
    }
  end

  defp openapi_json(filename) do
    Path.expand("../priv/openapi/#{filename}", __DIR__)
    |> File.read!()
    |> JSON.decode!()
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
        "pull.json" -> {"/repos/{owner}/{repo}/pulls/{pull_number}", :get, "200"}
        "pull-list.json" -> {"/repos/{owner}/{repo}/pulls", :get, "200"}
        "merge.json" -> {"/repos/{owner}/{repo}/pulls/{pull_number}/merge", :put, "200"}
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
