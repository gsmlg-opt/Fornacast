defmodule FornacastAPI.OpenAPIContractTest do
  use ExUnit.Case, async: true

  @contract_root Path.expand("../priv/openapi", __DIR__)
  @fixture_root Path.expand("fixtures", __DIR__)
  @source_commit "03ca9c1cac754ec9b8369dc75de8a8c753c6e087"
  @contracts %{
    "2022-11-28" => {
      "ghes-3.21-2022-11-28.json",
      "bb38aa30e1d0a15a847180794970f25ef2454b8c"
    },
    "2026-03-10" => {
      "ghes-3.21-2026-03-10.json",
      "02e93bd95f712c171b23c6a869ac9c0d88d89640"
    }
  }

  @declared_delivery_slices %{
    "1" => [
      ["get", "/versions"],
      ["get", "/rate_limit"],
      ["get", "/user"],
      ["get", "/users/{username}"],
      ["get", "/user/orgs"],
      ["get", "/orgs/{org}"],
      ["patch", "/orgs/{org}"],
      ["post", "/admin/organizations"],
      ["get", "/user/repos"],
      ["post", "/user/repos"],
      ["get", "/users/{username}/repos"],
      ["get", "/orgs/{org}/repos"],
      ["post", "/orgs/{org}/repos"],
      ["get", "/repos/{owner}/{repo}"],
      ["patch", "/repos/{owner}/{repo}"]
    ],
    "2" => [
      ["get", "/repos/{owner}/{repo}/branches"],
      ["get", "/repos/{owner}/{repo}/branches/{branch}"],
      ["get", "/repos/{owner}/{repo}/git/ref/{ref}"],
      ["post", "/repos/{owner}/{repo}/git/refs"],
      ["patch", "/repos/{owner}/{repo}/git/refs/{ref}"],
      ["get", "/repos/{owner}/{repo}/commits"],
      ["get", "/repos/{owner}/{repo}/commits/{ref}"],
      ["get", "/repos/{owner}/{repo}/contents/{path}"],
      ["put", "/repos/{owner}/{repo}/contents/{path}"],
      ["delete", "/repos/{owner}/{repo}/contents/{path}"]
    ],
    "3" => [
      ["get", "/repos/{owner}/{repo}/issues"],
      ["post", "/repos/{owner}/{repo}/issues"],
      ["get", "/repos/{owner}/{repo}/issues/{issue_number}"],
      ["patch", "/repos/{owner}/{repo}/issues/{issue_number}"],
      ["get", "/repos/{owner}/{repo}/issues/{issue_number}/comments"],
      ["post", "/repos/{owner}/{repo}/issues/{issue_number}/comments"],
      ["patch", "/repos/{owner}/{repo}/issues/comments/{comment_id}"],
      ["delete", "/repos/{owner}/{repo}/issues/comments/{comment_id}"]
    ],
    "4" => [
      ["get", "/repos/{owner}/{repo}/pulls"],
      ["post", "/repos/{owner}/{repo}/pulls"],
      ["get", "/repos/{owner}/{repo}/pulls/{pull_number}"],
      ["patch", "/repos/{owner}/{repo}/pulls/{pull_number}"],
      ["get", "/repos/{owner}/{repo}/pulls/{pull_number}/merge"],
      ["put", "/repos/{owner}/{repo}/pulls/{pull_number}/merge"]
    ],
    "5" => [
      ["get", "/repos/{owner}/{repo}/releases"],
      ["post", "/repos/{owner}/{repo}/releases"],
      ["get", "/repos/{owner}/{repo}/releases/latest"],
      ["get", "/repos/{owner}/{repo}/releases/tags/{tag}"],
      ["get", "/repos/{owner}/{repo}/releases/{release_id}"],
      ["patch", "/repos/{owner}/{repo}/releases/{release_id}"],
      ["delete", "/repos/{owner}/{repo}/releases/{release_id}"],
      ["get", "/repos/{owner}/{repo}/releases/{release_id}/assets"],
      ["post", "/repos/{owner}/{repo}/releases/{release_id}/assets"],
      ["get", "/repos/{owner}/{repo}/releases/assets/{asset_id}"],
      ["patch", "/repos/{owner}/{repo}/releases/assets/{asset_id}"],
      ["delete", "/repos/{owner}/{repo}/releases/assets/{asset_id}"]
    ]
  }

  @delivery_slices Map.new(@declared_delivery_slices, fn {slice, operations} ->
                     {slice, Enum.sort(operations)}
                   end)

  @all_operations @delivery_slices
                  |> Map.values()
                  |> Enum.flat_map(& &1)
                  |> Enum.map(fn [method, path] -> {method, path} end)
                  |> MapSet.new()

  @foundation_operations MapSet.new([
                           {"get", "/versions"},
                           {"get", "/rate_limit"},
                           {"get", "/user"},
                           {"get", "/users/{username}"},
                           {"get", "/user/orgs"},
                           {"get", "/orgs/{org}"},
                           {"patch", "/orgs/{org}"},
                           {"post", "/admin/organizations"},
                           {"get", "/user/repos"},
                           {"post", "/user/repos"},
                           {"get", "/users/{username}/repos"},
                           {"get", "/orgs/{org}/repos"},
                           {"post", "/orgs/{org}/repos"},
                           {"get", "/repos/{owner}/{repo}"},
                           {"patch", "/repos/{owner}/{repo}"}
                         ])

  @mutation_fields %{
    "POST /admin/organizations" => ~w(login admin profile_name),
    "PATCH /orgs/{org}" => ~w(name description),
    "POST /user/repos" =>
      ~w(name description private visibility default_branch has_issues auto_init allow_merge_commit has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
    "POST /orgs/{org}/repos" =>
      ~w(name description private visibility default_branch has_issues auto_init allow_merge_commit has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
    "PATCH /repos/{owner}/{repo}" =>
      ~w(name description private visibility default_branch has_issues allow_merge_commit has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
    "POST /repos/{owner}/{repo}/git/refs" => ~w(ref sha),
    "PATCH /repos/{owner}/{repo}/git/refs/{ref}" => ~w(sha force),
    "PUT /repos/{owner}/{repo}/contents/{path}" =>
      ~w(message content sha branch committer author),
    "DELETE /repos/{owner}/{repo}/contents/{path}" => ~w(message sha branch committer author),
    "POST /repos/{owner}/{repo}/issues" => ~w(title body assignee assignees labels),
    "PATCH /repos/{owner}/{repo}/issues/{issue_number}" =>
      ~w(title body state state_reason assignee assignees labels),
    "POST /repos/{owner}/{repo}/issues/{issue_number}/comments" => ~w(body),
    "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}" => ~w(body),
    "POST /repos/{owner}/{repo}/pulls" => ~w(title head base body),
    "PATCH /repos/{owner}/{repo}/pulls/{pull_number}" => ~w(title body state base),
    "PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge" =>
      ~w(commit_title commit_message sha merge_method),
    "POST /repos/{owner}/{repo}/releases" =>
      ~w(tag_name target_commitish name body draft prerelease),
    "PATCH /repos/{owner}/{repo}/releases/{release_id}" => ~w(name body draft prerelease),
    "POST /api/uploads/repos/{owner}/{repo}/releases/{release_id}/assets" => ~w(name label),
    "PATCH /repos/{owner}/{repo}/releases/assets/{asset_id}" => ~w(name label)
  }

  @required_mutation_fields %{
    "POST /admin/organizations" => ~w(login admin),
    "POST /user/repos" => ~w(name),
    "POST /orgs/{org}/repos" => ~w(name),
    "POST /repos/{owner}/{repo}/git/refs" => ~w(ref sha),
    "PATCH /repos/{owner}/{repo}/git/refs/{ref}" => ~w(sha),
    "PUT /repos/{owner}/{repo}/contents/{path}" => ~w(message content),
    "DELETE /repos/{owner}/{repo}/contents/{path}" => ~w(message sha),
    "POST /repos/{owner}/{repo}/issues" => ~w(title),
    "POST /repos/{owner}/{repo}/issues/{issue_number}/comments" => ~w(body),
    "PATCH /repos/{owner}/{repo}/issues/comments/{comment_id}" => ~w(body),
    "POST /repos/{owner}/{repo}/pulls" => ~w(title head base),
    "POST /repos/{owner}/{repo}/releases" => ~w(tag_name),
    "POST /api/uploads/repos/{owner}/{repo}/releases/{release_id}/assets" => ~w(name)
  }

  @query_fields %{
    "authenticated_repositories" =>
      ~w(page per_page visibility affiliation type sort direction since before),
    "account_repositories" => ~w(page per_page type sort direction),
    "branches" => ~w(page per_page protected),
    "commits" => ~w(page per_page sha path author since until),
    "contents" => ~w(ref),
    "issues" => ~w(page per_page state labels assignee creator sort direction since),
    "issue_comments" => ~w(page per_page since),
    "pulls" => ~w(page per_page state head base sort direction),
    "releases" => ~w(page per_page),
    "release_assets" => ~w(page per_page)
  }

  @divergences %{
    "organization_creation" => "ordinary_self_or_site_admin",
    "organization_update_scope" => "write:org",
    "personal_access_token_prefix" => "fc_pat_",
    "repository_auto_init_owner" => "delivery_slice_2",
    "repository_visibility" => ["public", "private"],
    "repository_false_only_fields" =>
      ~w(has_projects has_wiki has_discussions allow_squash_merge allow_rebase_merge),
    "git_ref_writes" => "branch_refs_fast_forward_only",
    "unsupported_issue_features" => ~w(milestone type locked active_lock_reason),
    "merge_method" => "merge",
    "release_assets_server" => "/api/uploads",
    "release_archives" => nil,
    "issue_pull_release_html_url" => "corresponding_public_api_url",
    "commit_pull_diff_patch_media" => "not_acceptable"
  }

  @fixture_base %{
    "versions" => %{"status" => 200, "body" => ["2022-11-28", "2026-03-10"]},
    "bad_credentials" => %{"status" => 401, "body" => %{"message" => "Bad credentials"}},
    "missing_user_agent" => %{
      "status" => 403,
      "body" => %{"message" => "User agent required"}
    },
    "validation_failed" => %{
      "status" => 422,
      "body" => %{
        "message" => "Validation Failed",
        "errors" => [%{"resource" => "Repository", "field" => "name", "code" => "missing_field"}]
      }
    },
    "repository_defaults" => %{
      "status" => 200,
      "body" => %{
        "private" => false,
        "visibility" => "public",
        "has_issues" => true,
        "has_projects" => false,
        "has_wiki" => false,
        "has_discussions" => false,
        "allow_merge_commit" => true,
        "allow_squash_merge" => false,
        "allow_rebase_merge" => false
      }
    }
  }

  test "contracts retain pinned provenance and the foundation operations" do
    for {version, {filename, source_blob}} <- @contracts do
      document = filename |> contract_path() |> File.read!() |> JSON.decode!()

      assert document["openapi"] =~ ~r/^3\.0\./
      assert document["x-fornacast-source-commit"] == @source_commit
      assert document["x-fornacast-source-blob"] == source_blob
      assert document["x-github-api-version"] == version
      assert document["x-fornacast-implemented-through-slice"] == "1"
      assert MapSet.subset?(@foundation_operations, operations(document))
      assert get_in(document, ["paths", "/repos/{owner}/{repo}", "get"])
      assert document["x-fornacast-delivery-slices"] == @delivery_slices
      assert operations(document) == @all_operations
    end
  end

  test "overlay owns every operation and reserves the upload server" do
    overlay = "fornacast-overlay.json" |> contract_path() |> File.read!() |> JSON.decode!()

    assert overlay["source_commit"] == @source_commit
    assert overlay["versions"] == ["2022-11-28", "2026-03-10"]
    assert overlay["servers"]["rest"] == "/api/v3"
    assert overlay["servers"]["uploads"] == "/api/uploads"
    assert overlay["implemented_through_slice"] == "1"
    assert overlay["delivery_slices"] == @delivery_slices
    assert overlay["mutation_fields"] == @mutation_fields
    assert overlay["required_mutation_fields"] == @required_mutation_fields
    assert overlay["query_fields"] == @query_fields
    assert overlay["divergences"] == @divergences

    expected_foundation =
      @foundation_operations
      |> MapSet.to_list()
      |> Enum.map(fn {method, path} -> [method, path] end)
      |> Enum.sort()

    assert overlay["delivery_slices"]["1"] == expected_foundation
    assert Enum.sort(Map.keys(overlay["delivery_slices"])) == ~w(1 2 3 4 5)
  end

  test "foundation fixtures exactly match the versioned golden envelopes" do
    for {version, rate_top_level} <- [{"2022-11-28", true}, {"2026-03-10", false}] do
      fixture =
        @fixture_root
        |> Path.join(version)
        |> Path.join("foundation.json")
        |> File.read!()
        |> JSON.decode!()

      assert fixture == Map.put(@fixture_base, "rate_top_level", rate_top_level)
    end
  end

  defp contract_path(filename), do: Path.join(@contract_root, filename)

  defp operations(document) do
    document["paths"]
    |> Enum.flat_map(fn {path, item} ->
      for method <- ~w(get put post delete options head patch trace),
          Map.has_key?(item, method),
          do: {method, path}
    end)
    |> MapSet.new()
  end
end
