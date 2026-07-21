defmodule FornacastAPI.OpenAPIContractTest do
  use ExUnit.Case, async: true

  alias ForgeAccounts.{AccountView, Organization, User}
  alias ForgeRepos.Repository

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
  @pipeline_only_error_statuses [408, 413, 414, 415, 429]

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

  test "rate limit contracts retain the exact versioned core schema" do
    rate_bucket_schema = %{
      "properties" => %{
        "limit" => %{"type" => "integer"},
        "remaining" => %{"type" => "integer"},
        "reset" => %{"type" => "integer"},
        "used" => %{"type" => "integer"}
      },
      "required" => ["limit", "remaining", "reset", "used"],
      "title" => "Rate Limit",
      "type" => "object"
    }

    resources_schema = %{
      "properties" => %{"core" => rate_bucket_schema},
      "required" => ["core"],
      "type" => "object"
    }

    for {version, {filename, _source_blob}} <- @contracts do
      document = filename |> contract_path() |> File.read!() |> JSON.decode!()

      schema =
        get_in(document, [
          "paths",
          "/rate_limit",
          "get",
          "responses",
          "200",
          "content",
          "application/json",
          "schema"
        ])

      expected_schema =
        case version do
          "2022-11-28" ->
            %{
              "description" => "Rate Limit Overview",
              "properties" => %{
                "rate" => rate_bucket_schema,
                "resources" => resources_schema
              },
              "required" => ["rate", "resources"],
              "title" => "Rate Limit Overview",
              "type" => "object"
            }

          "2026-03-10" ->
            %{
              "description" => "Rate Limit Overview",
              "properties" => %{"resources" => resources_schema},
              "required" => ["resources"],
              "title" => "Rate Limit Overview",
              "type" => "object"
            }
        end

      assert schema == expected_schema
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

  test "versioned serializers produce complete operation-valid JSON responses" do
    for version <- Map.keys(@contracts) do
      document = decoded_contract(version)

      assert_valid_response(document, "/versions", :get, 200, ["2022-11-28", "2026-03-10"])

      assert_valid_response(
        document,
        "/rate_limit",
        :get,
        200,
        FornacastAPI.Serializer.render(version, :rate_limit, rate_bucket())
      )

      assert_valid_response(
        document,
        "/user",
        :get,
        200,
        FornacastAPI.Serializer.render(version, :private_user, account_view())
      )

      assert_valid_response(
        document,
        "/users/{username}",
        :get,
        200,
        FornacastAPI.Serializer.render(version, :public_user, account_view())
      )

      assert_valid_response(
        document,
        "/user/orgs",
        :get,
        200,
        [FornacastAPI.Serializer.render(version, :organization_simple, organization())]
      )

      assert_valid_response(
        document,
        "/orgs/{org}",
        :get,
        200,
        FornacastAPI.Serializer.render(version, :organization_full, organization_view())
      )

      assert_valid_response(
        document,
        "/users/{username}/repos",
        :get,
        200,
        [FornacastAPI.Serializer.render(version, :minimal_repository, repository_view())]
      )

      assert_valid_response(
        document,
        "/user/repos",
        :get,
        200,
        [FornacastAPI.Serializer.render(version, :repository, repository_view())]
      )

      assert_valid_response(
        document,
        "/repos/{owner}/{repo}",
        :get,
        200,
        FornacastAPI.Serializer.render(version, :full_repository, repository_view())
      )
    end
  end

  test "serializer keys cover required properties without unsupported supersets" do
    resources = [
      {:simple_user, "Simple User", account()},
      {:public_user, "Public User", account_view()},
      {:private_user, "Private User", account_view()},
      {:organization_simple, "Organization Simple", organization()},
      {:organization_full, "Organization Full", organization_view()},
      {:minimal_repository, "Minimal Repository", repository_view()},
      {:repository, "Repository", repository_view()},
      {:full_repository, "Full Repository", repository_view()}
    ]

    for version <- Map.keys(@contracts) do
      schemas = version |> raw_contract() |> schemas_by_title()

      for {resource, title, value} <- resources do
        rendered = FornacastAPI.Serializer.render(version, resource, value)
        schema = Map.fetch!(schemas, title)
        keys = rendered |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
        required = schema |> Map.fetch!("required") |> Enum.sort()
        properties = schema |> Map.fetch!("properties") |> Map.keys() |> Enum.sort()

        assert required -- keys == [],
               "#{version} #{resource} omitted required keys: #{inspect(required -- keys)}"

        assert keys -- properties == [],
               "#{version} #{resource} emitted unsupported keys: #{inspect(keys -- properties)}"
      end
    end
  end

  test "rate and repository key differences are explicitly pinned per version" do
    repository_2022 =
      FornacastAPI.Serializer.render("2022-11-28", :repository, repository_view())

    repository_2026 =
      FornacastAPI.Serializer.render("2026-03-10", :repository, repository_view())

    assert Map.keys(repository_2022) -- Map.keys(repository_2026) == [:has_downloads]
    assert Map.keys(repository_2026) -- Map.keys(repository_2022) == []

    schemas_2022 = "2022-11-28" |> raw_contract() |> schemas_by_title()
    schemas_2026 = "2026-03-10" |> raw_contract() |> schemas_by_title()

    repository_properties_2022 =
      schemas_2022["Repository"] |> Map.fetch!("properties") |> Map.keys()

    repository_properties_2026 =
      schemas_2026["Repository"] |> Map.fetch!("properties") |> Map.keys()

    assert Enum.sort(repository_properties_2022 -- repository_properties_2026) ==
             ~w(has_downloads master_branch use_squash_pr_title_as_default)

    assert repository_properties_2026 -- repository_properties_2022 == []
    refute Map.has_key?(repository_2026, :has_downloads)
    refute Map.has_key?(repository_2026, :master_branch)
    refute Map.has_key?(repository_2026, :use_squash_pr_title_as_default)

    rate_2022 = FornacastAPI.Serializer.render("2022-11-28", :rate_limit, rate_bucket())
    rate_2026 = FornacastAPI.Serializer.render("2026-03-10", :rate_limit, rate_bucket())

    assert Map.keys(rate_2022) |> Enum.sort() == [:rate, :resources]
    assert Map.keys(rate_2026) == [:resources]
  end

  test "every stable error body survives JSON encoding and its pinned schema" do
    documentation_url = "https://docs.example.test/rest"

    for version <- Map.keys(@contracts) do
      document = decoded_contract(version)
      raw_document = raw_contract(version)

      for status <- @pipeline_only_error_statuses do
        refute response_status_declared?(raw_document, status),
               "#{version} unexpectedly declares pipeline-only status #{status}"
      end

      for {name, error, expected_status, expected_message, expected_errors, schema_pin} <-
            stable_error_cases(documentation_url) do
        rendered = FornacastAPI.Serializer.render(version, :error, error)
        {path, method, schema_status} = schema_pin

        assert error.status == expected_status, name
        assert rendered.message == expected_message, name
        assert rendered.documentation_url == documentation_url, name
        refute Map.has_key?(rendered, :status), name

        expected_body =
          %{message: expected_message, documentation_url: documentation_url}
          |> maybe_put_expected_errors(expected_errors)

        assert rendered == expected_body, name
        assert Enum.sort(Map.keys(rendered)) == Enum.sort(Map.keys(expected_body)), name

        encoded = rendered |> JSON.encode!() |> JSON.decode!()
        expected_encoded = expected_body |> JSON.encode!() |> JSON.decode!()

        assert encoded == expected_encoded, name
        assert Enum.sort(Map.keys(encoded)) == Enum.sort(Map.keys(expected_encoded)), name
        assert_valid_response(document, path, method, schema_status, rendered)
      end
    end
  end

  defp stable_error_cases(documentation_url) do
    validation_errors = [
      %{resource: "Repository", field: "name", code: :missing_field}
    ]

    encoded_validation_errors = [
      %{resource: "Repository", field: "name", code: "missing_field"}
    ]

    basic_error_schema = {"/user", :get, 401}
    contents_path = "/repos/{owner}/{repo}/contents/{path}"

    [
      {"bad request", FornacastAPI.Error.new(400, "Bad Request", documentation_url), 400,
       "Bad Request", nil, {"/repos/{owner}/{repo}/commits", :get, 400}},
      {"requires authentication",
       FornacastAPI.Error.new(401, "Requires authentication", documentation_url), 401,
       "Requires authentication", nil, {"/user", :get, 401}},
      {"invalid credentials",
       FornacastAPI.Error.from_domain(:invalid_credentials, documentation_url), 401,
       "Bad credentials", nil, {"/user", :get, 401}},
      {"user agent required",
       FornacastAPI.Error.new(403, "User agent required", documentation_url), 403,
       "User agent required", nil, {"/repos/{owner}/{repo}", :get, 403}},
      {"insufficient scope",
       FornacastAPI.Error.from_domain(:insufficient_scope, documentation_url), 403,
       "Resource not accessible by personal access token", nil,
       {"/repos/{owner}/{repo}", :get, 403}},
      {"forbidden", FornacastAPI.Error.from_domain(:forbidden, documentation_url), 403,
       "Forbidden", nil, {"/repos/{owner}/{repo}", :get, 403}},
      {"not found", FornacastAPI.Error.from_domain(:not_found, documentation_url), 404,
       "Not Found", nil, {contents_path, :delete, 404}},
      {"pull request is not mergeable",
       FornacastAPI.Error.new(405, "Pull Request is not mergeable", documentation_url), 405,
       "Pull Request is not mergeable", nil,
       {"/repos/{owner}/{repo}/pulls/{pull_number}/merge", :put, 405}},
      {"not acceptable", FornacastAPI.Error.new(406, "Not Acceptable", documentation_url), 406,
       "Not Acceptable", nil, {"/repos/{owner}/{repo}/pulls/{pull_number}", :get, 406}},
      {"request timeout", FornacastAPI.Error.new(408, "Request Timeout", documentation_url), 408,
       "Request Timeout", nil, basic_error_schema},
      {"conflict",
       FornacastAPI.Error.from_domain({:conflict, :repository_exists}, documentation_url), 409,
       "Conflict", nil, {contents_path, :delete, 409}},
      {"issues disabled",
       FornacastAPI.Error.new(
         410,
         "Issues are disabled for this repository",
         documentation_url
       ), 410, "Issues are disabled for this repository", nil,
       {"/repos/{owner}/{repo}/issues/{issue_number}", :get, 410}},
      {"payload too large", FornacastAPI.Error.new(413, "Payload Too Large", documentation_url),
       413, "Payload Too Large", nil, basic_error_schema},
      {"uri too long", FornacastAPI.Error.new(414, "URI Too Long", documentation_url), 414,
       "URI Too Long", nil, basic_error_schema},
      {"unsupported media type",
       FornacastAPI.Error.new(415, "Unsupported Media Type", documentation_url), 415,
       "Unsupported Media Type", nil, basic_error_schema},
      {"validation failed",
       FornacastAPI.Error.from_domain({:validation, validation_errors}, documentation_url), 422,
       "Validation Failed", encoded_validation_errors, {contents_path, :delete, 422}},
      {"rate limit exceeded",
       FornacastAPI.Error.new(429, "API rate limit exceeded", documentation_url), 429,
       "API rate limit exceeded", nil, basic_error_schema},
      {"internal server error", FornacastAPI.Error.from_domain(:unclassified, documentation_url),
       500, "Internal Server Error", nil, {"/repos/{owner}/{repo}/commits", :get, 500}},
      {"git initializer unavailable",
       FornacastAPI.Error.from_domain(:git_initializer_unavailable, documentation_url), 503,
       "Service unavailable", nil, {contents_path, :delete, 503}},
      {"dependency unavailable",
       FornacastAPI.Error.from_domain({:unavailable, :storage}, documentation_url), 503,
       "Service unavailable", nil, {contents_path, :delete, 503}}
    ]
  end

  defp maybe_put_expected_errors(body, nil), do: body
  defp maybe_put_expected_errors(body, errors), do: Map.put(body, :errors, errors)

  defp contract_path(filename), do: Path.join(@contract_root, filename)

  defp raw_contract(version) do
    {filename, _source_blob} = Map.fetch!(@contracts, version)
    filename |> contract_path() |> File.read!() |> JSON.decode!()
  end

  defp decoded_contract(version) do
    version
    |> raw_contract()
    |> OpenApiSpex.OpenApi.Decode.decode()
  end

  defp assert_valid_response(document, path, method, status, body) do
    schema =
      document.paths
      |> Map.fetch!(path)
      |> Map.fetch!(method)
      |> Map.fetch!(:responses)
      |> Map.fetch!(Integer.to_string(status))
      |> Map.fetch!(:content)
      |> Map.fetch!("application/json")
      |> Map.fetch!(:schema)

    assert_valid_schema(document, schema, body)
  end

  defp assert_valid_schema(document, schema, body) do
    json_body = body |> JSON.encode_to_iodata!() |> IO.iodata_to_binary() |> JSON.decode!()
    assert {:ok, _cast} = OpenApiSpex.cast_value(json_body, schema, document)
  end

  defp schemas_by_title(document), do: collect_schemas_by_title(document, %{})

  defp collect_schemas_by_title(value, schemas) when is_map(value) do
    schemas =
      case value["title"] do
        title when is_binary(title) -> Map.put_new(schemas, title, value)
        _other -> schemas
      end

    Enum.reduce(Map.values(value), schemas, &collect_schemas_by_title/2)
  end

  defp collect_schemas_by_title(value, schemas) when is_list(value) do
    Enum.reduce(value, schemas, &collect_schemas_by_title/2)
  end

  defp collect_schemas_by_title(_value, schemas), do: schemas

  defp account do
    %User{
      id: 42,
      username: "octocat",
      display_name: "Octo Cat",
      description: "Builds small forges",
      email: "octocat@example.test",
      kind: :user,
      role: :admin,
      inserted_at: ~U[2026-03-10 08:00:00Z],
      updated_at: ~U[2026-03-11 09:30:00Z]
    }
  end

  defp account_view, do: AccountView.new(account(), 7, 2)

  defp organization do
    %Organization{
      id: 84,
      username: "acme",
      display_name: "Acme Forge",
      description: "An example organization",
      kind: :organization,
      inserted_at: ~U[2026-03-08 01:02:03Z],
      updated_at: ~U[2026-03-09 04:05:06Z]
    }
  end

  defp organization_view, do: AccountView.new(organization(), 5, 3)

  defp repository_view do
    %{
      repository: %Repository{
        id: 99,
        owner_user_id: 42,
        slug: "hello-world",
        name: "Hello World",
        description: "A repository fixture",
        visibility: :private,
        default_branch: "trunk",
        storage_path: "@hashed/00/00/hello-world.git",
        last_pushed_at: ~U[2026-03-10 10:30:00Z],
        inserted_at: ~U[2026-03-09 10:00:00Z],
        updated_at: ~U[2026-03-10 11:00:00Z]
      },
      owner: account(),
      permissions: %{
        admin: true,
        pull: true,
        push: true
      },
      size_kib: 512
    }
  end

  defp rate_bucket do
    %{limit: 5_000, remaining: 4_999, reset: 1_800_000_000, used: 1, resource: "core"}
  end

  defp response_status_declared?(document, status) do
    status = Integer.to_string(status)

    Enum.any?(document["paths"], fn {_path, path_item} ->
      Enum.any?(~w(get put post delete options head patch trace), fn method ->
        path_item
        |> get_in([method, "responses"])
        |> case do
          responses when is_map(responses) -> Map.has_key?(responses, status)
          _responses -> false
        end
      end)
    end)
  end

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
