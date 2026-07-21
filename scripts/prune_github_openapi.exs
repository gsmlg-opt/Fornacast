defmodule Fornacast.OpenAPIPruner do
  @source_commit "03ca9c1cac754ec9b8369dc75de8a8c753c6e087"
  @sources %{
    "2022-11-28" => %{
      blob: "bb38aa30e1d0a15a847180794970f25ef2454b8c",
      path: "descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json"
    },
    "2026-03-10" => %{
      blob: "02e93bd95f712c171b23c6a869ac9c0d88d89640",
      path: "descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json"
    }
  }

  @delivery_slices %{
    "1" => [
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
    ],
    "2" => [
      {"get", "/repos/{owner}/{repo}/branches"},
      {"get", "/repos/{owner}/{repo}/branches/{branch}"},
      {"get", "/repos/{owner}/{repo}/git/ref/{ref}"},
      {"post", "/repos/{owner}/{repo}/git/refs"},
      {"patch", "/repos/{owner}/{repo}/git/refs/{ref}"},
      {"get", "/repos/{owner}/{repo}/commits"},
      {"get", "/repos/{owner}/{repo}/commits/{ref}"},
      {"get", "/repos/{owner}/{repo}/contents/{path}"},
      {"put", "/repos/{owner}/{repo}/contents/{path}"},
      {"delete", "/repos/{owner}/{repo}/contents/{path}"}
    ],
    "3" => [
      {"get", "/repos/{owner}/{repo}/issues"},
      {"post", "/repos/{owner}/{repo}/issues"},
      {"get", "/repos/{owner}/{repo}/issues/{issue_number}"},
      {"patch", "/repos/{owner}/{repo}/issues/{issue_number}"},
      {"get", "/repos/{owner}/{repo}/issues/{issue_number}/comments"},
      {"post", "/repos/{owner}/{repo}/issues/{issue_number}/comments"},
      {"patch", "/repos/{owner}/{repo}/issues/comments/{comment_id}"},
      {"delete", "/repos/{owner}/{repo}/issues/comments/{comment_id}"}
    ],
    "4" => [
      {"get", "/repos/{owner}/{repo}/pulls"},
      {"post", "/repos/{owner}/{repo}/pulls"},
      {"get", "/repos/{owner}/{repo}/pulls/{pull_number}"},
      {"patch", "/repos/{owner}/{repo}/pulls/{pull_number}"},
      {"get", "/repos/{owner}/{repo}/pulls/{pull_number}/merge"},
      {"put", "/repos/{owner}/{repo}/pulls/{pull_number}/merge"}
    ],
    "5" => [
      {"get", "/repos/{owner}/{repo}/releases"},
      {"post", "/repos/{owner}/{repo}/releases"},
      {"get", "/repos/{owner}/{repo}/releases/latest"},
      {"get", "/repos/{owner}/{repo}/releases/tags/{tag}"},
      {"get", "/repos/{owner}/{repo}/releases/{release_id}"},
      {"patch", "/repos/{owner}/{repo}/releases/{release_id}"},
      {"delete", "/repos/{owner}/{repo}/releases/{release_id}"},
      {"get", "/repos/{owner}/{repo}/releases/{release_id}/assets"},
      {"post", "/repos/{owner}/{repo}/releases/{release_id}/assets"},
      {"get", "/repos/{owner}/{repo}/releases/assets/{asset_id}"},
      {"patch", "/repos/{owner}/{repo}/releases/assets/{asset_id}"},
      {"delete", "/repos/{owner}/{repo}/releases/assets/{asset_id}"}
    ]
  }

  def run([source_root, output_root, implemented_through])
      when implemented_through in ~w(1 2 3 4 5) do
    File.mkdir_p!(output_root)

    Enum.each(@sources, fn {version, source} ->
      source_file = Path.join(source_root, source.path)
      verify_commit_blob!(source_root, source.path, source.blob)
      verify_working_blob!(source_file, source.blob)
      document = source_file |> File.read!() |> JSON.decode!()
      pruned = prune(document, version, source.blob, implemented_through)

      output = Path.join(output_root, "ghes-3.21-#{version}.json")
      File.write!(output, JSON.encode!(pruned))
    end)

    File.write!(
      Path.join(output_root, "fornacast-overlay.json"),
      JSON.encode!(overlay(implemented_through))
    )
  end

  def run(_args) do
    raise "usage: mix run --no-start scripts/prune_github_openapi.exs SOURCE_ROOT OUTPUT_ROOT IMPLEMENTED_THROUGH_SLICE"
  end

  defp verify_commit_blob!(source_root, path, expected) do
    source_ref = "#{@source_commit}:#{path}"

    case System.cmd("git", ["-C", source_root, "rev-parse", "--verify", source_ref],
           stderr_to_stdout: true
         ) do
      {actual, 0} ->
        actual = String.trim(actual)

        if actual != expected do
          raise "[openapi_source_commit_mismatch] OpenAPI source blob mismatch for #{source_ref}: expected #{expected}, got #{actual}"
        end

      {message, status} ->
        raise "[openapi_source_commit_mismatch] unable to resolve #{source_ref} in #{source_root} (git exit #{status}): #{String.trim(message)}"
    end
  end

  defp verify_working_blob!(path, expected) do
    case System.cmd("git", ["hash-object", path], stderr_to_stdout: true) do
      {actual, 0} ->
        actual = String.trim(actual)

        if actual != expected do
          raise "[openapi_working_blob_mismatch] OpenAPI working blob mismatch for #{path}: expected #{expected}, got #{actual}"
        end

      {message, status} ->
        raise "[openapi_working_blob_mismatch] unable to hash #{path} (git exit #{status}): #{String.trim(message)}"
    end
  end

  defp prune(document, version, source_blob, implemented_through) do
    operations = @delivery_slices |> Map.values() |> List.flatten()

    paths =
      operations
      |> Enum.reject(fn {_method, path} -> path == "/versions" end)
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Map.new(fn {path, methods} ->
        path_item = Map.fetch!(document["paths"], path)
        preserved = Map.take(path_item, ["parameters", "servers", "summary", "description"])

        operations =
          Map.new(methods, fn method ->
            {method, Map.fetch!(path_item, method)}
          end)

        {path, Map.merge(preserved, operations)}
      end)
      |> Map.put_new("/versions", versions_path())

    %{
      "openapi" => document["openapi"],
      "info" => Map.put(document["info"], "title", "Fornacast GitHub-compatible subset"),
      "servers" => [%{"url" => "/api/v3"}],
      "paths" => paths,
      "components" => Map.take(document["components"] || %{}, ["securitySchemes"]),
      "x-github-api-version" => version,
      "x-fornacast-source-commit" => @source_commit,
      "x-fornacast-source-blob" => source_blob,
      "x-fornacast-implemented-through-slice" => implemented_through,
      "x-fornacast-delivery-slices" =>
        Map.new(@delivery_slices, fn {slice, operations} ->
          {slice, operations |> Enum.map(fn {method, path} -> [method, path] end) |> Enum.sort()}
        end)
    }
  end

  defp versions_path do
    %{
      "get" => %{
        "operationId" => "meta/versions",
        "responses" => %{
          "200" => %{
            "description" => "Supported API versions",
            "content" => %{
              "application/json" => %{
                "schema" => %{
                  "type" => "array",
                  "items" => %{"type" => "string", "enum" => ["2022-11-28", "2026-03-10"]},
                  "minItems" => 2,
                  "maxItems" => 2
                }
              }
            }
          }
        }
      }
    }
  end

  defp overlay(implemented_through) do
    %{
      "source_commit" => @source_commit,
      "versions" => ["2022-11-28", "2026-03-10"],
      "servers" => %{"rest" => "/api/v3", "uploads" => "/api/uploads"},
      "implemented_through_slice" => implemented_through,
      "delivery_slices" =>
        Map.new(@delivery_slices, fn {slice, operations} ->
          {slice, operations |> Enum.map(fn {method, path} -> [method, path] end) |> Enum.sort()}
        end),
      "mutation_fields" => mutation_fields(),
      "required_mutation_fields" => required_mutation_fields(),
      "query_fields" => query_fields(),
      "divergences" => %{
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
    }
  end

  defp mutation_fields do
    %{
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
  end

  defp required_mutation_fields do
    %{
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
  end

  defp query_fields do
    %{
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
  end
end

Fornacast.OpenAPIPruner.run(System.argv())
