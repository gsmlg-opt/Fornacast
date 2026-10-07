defmodule FornacastAPI.ReleaseControllerTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  alias Fornacast.{AuditEvent, Repo}
  alias ForgeRepos.Collaborator

  @user_agent "fornacast-release-api-test/1.0"
  @versions ["2022-11-28", "2026-03-10"]
  @authentication_url "https://docs.github.com/en/enterprise-server@3.21/rest/authentication/authenticating-to-the-rest-api"
  @docs %{
    index:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#list-releases",
    create:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#create-a-release",
    show:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#get-a-release",
    tag:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#get-a-release-by-tag-name",
    latest:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#get-the-latest-release",
    update:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#update-a-release",
    delete:
      "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#delete-a-release"
  }

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)
    :ok
  end

  test "metadata CRUD, tag lookup, and latest work in both API versions" do
    for version <- @versions do
      alice = user("release-api-#{String.replace(version, "-", "")}")
      repository = repository(alice, "demo-#{String.replace(version, "-", "")}")
      put_tag(repository, "v1.0.0")
      {_key, secret} = pat(alice, ["public_repo"])
      base = "/api/v3/repos/#{alice.username}/#{repository.slug}/releases"

      created =
        api_conn(secret, version)
        |> post_json(base, %{
          "tag_name" => "v1.0.0",
          "name" => "Version 1",
          "body" => "Initial notes",
          "draft" => false,
          "prerelease" => false
        })

      body = json_response(created, 201)
      assert body["tag_name"] == "v1.0.0"
      assert body["target_commitish"] == "main"
      assert body["assets"] == []
      assert body["published_at"]
      assert_scope_headers(created, "public_repo", "public_repo, repo")

      release_id = body["id"]

      listed = api_conn(nil, version) |> get(base)
      assert [%{"id" => ^release_id}] = json_response(listed, 200)
      assert_scope_headers(listed, "", "")

      shown = api_conn(nil, version) |> get("#{base}/#{release_id}")
      assert json_response(shown, 200)["id"] == release_id

      tagged = api_conn(nil, version) |> get("#{base}/tags/v1.0.0")
      assert json_response(tagged, 200)["id"] == release_id

      latest = api_conn(nil, version) |> get("#{base}/latest")
      assert json_response(latest, 200)["id"] == release_id

      updated =
        api_conn(secret, version)
        |> patch_json("#{base}/#{release_id}", %{
          "name" => "Version One",
          "draft" => true
        })

      updated_body = json_response(updated, 200)
      assert updated_body["name"] == "Version One"
      assert updated_body["draft"]
      assert updated_body["published_at"] == nil
      assert_scope_headers(updated, "public_repo", "public_repo, repo")

      assert_error(api_conn(nil, version) |> get("#{base}/#{release_id}"), 404, @docs.show)

      deleted = api_conn(secret, version) |> delete("#{base}/#{release_id}")
      assert response(deleted, 204)
      assert_scope_headers(deleted, "public_repo", "public_repo, repo")
      assert_error(api_conn(secret, version) |> get("#{base}/#{release_id}"), 404, @docs.show)

      assert Repo.aggregate(
               from(audit in AuditEvent,
                 where:
                   audit.target_type == "release" and audit.target_id == ^to_string(release_id)
               ),
               :count,
               :id
             ) == 3
    end
  end

  test "authentication and scopes are checked before mutation bodies are parsed" do
    alice = user("release-auth")
    repository = repository(alice, "public")
    put_tag(repository, "v1")
    {_key, insufficient} = pat(alice, ["read:org"])
    base = "/api/v3/repos/#{alice.username}/public/releases"

    for version <- @versions do
      missing = request(api_conn(nil, version), :post, base, "{")
      assert_error(missing, 401, @docs.create, "Requires authentication")

      invalid = request(api_conn("fc_pat_invalid", version), :post, base, "{")
      assert_error(invalid, 401, @authentication_url, "Bad credentials")

      denied = request(api_conn(insufficient, version), :post, base, "{")

      assert_error(
        denied,
        403,
        @docs.create,
        "Resource not accessible by personal access token"
      )
    end
  end

  test "repository masking and write authorization precede malformed mutation bodies" do
    alice = user("release-owner")
    bob = user("release-reader")
    eve = user("release-outsider")
    repository = repository(alice, "private", visibility: :private)
    collaborator(repository, bob, :read)
    put_tag(repository, "v1")
    {_owner_key, owner_secret} = pat(alice, ["repo"])
    {_bob_key, bob_secret} = pat(bob, ["repo"])
    {_eve_key, eve_secret} = pat(eve, ["repo"])
    base = "/api/v3/repos/#{alice.username}/#{repository.slug}/releases"

    created =
      api_conn(owner_secret, "2022-11-28")
      |> post_json(base, %{"tag_name" => "v1"})

    release_id = json_response(created, 201)["id"]

    for version <- @versions,
        {method, path, docs} <- [
          {:post, base, @docs.create},
          {:patch, "#{base}/#{release_id}", @docs.update}
        ] do
      forbidden = request(api_conn(bob_secret, version), method, path, "{")
      assert_error(forbidden, 403, docs, "Forbidden")
      assert_scope_headers(forbidden, "repo", "repo")
      assert adapter_request_body(forbidden) == "{"

      hidden = request(api_conn(eve_secret, version), method, path, "{")
      assert_error(hidden, 404, docs)
      assert_scope_headers(hidden, "repo", "")
      assert adapter_request_body(hidden) == "{"
    end
  end

  test "update resolves a missing release before parsing its body" do
    alice = user("release-missing-update")
    repository = repository(alice, "demo")
    {_key, secret} = pat(alice, ["public_repo"])
    path = "/api/v3/repos/#{alice.username}/#{repository.slug}/releases/999"

    for version <- @versions do
      missing = request(api_conn(secret, version), :patch, path, "{")
      assert_error(missing, 404, @docs.update)
      assert_scope_headers(missing, "public_repo", "public_repo, repo")
      assert adapter_request_body(missing) == "{"
    end
  end

  test "release pagination emits GitHub Link navigation" do
    for version <- @versions do
      suffix = String.replace(version, "-", "")
      alice = user("release-page-#{suffix}")
      repository = repository(alice, "demo-#{suffix}")
      put_tag(repository, "v1")
      put_tag(repository, "v2")
      {_key, secret} = pat(alice, ["public_repo"])
      base = "/api/v3/repos/#{alice.username}/#{repository.slug}/releases"

      first = api_conn(secret, version) |> post_json(base, %{"tag_name" => "v1"})
      second = api_conn(secret, version) |> post_json(base, %{"tag_name" => "v2"})
      assert response(first, 201)
      assert response(second, 201)

      page = api_conn(nil, version) |> get("#{base}?page=1&per_page=1")
      assert [_release] = json_response(page, 200)
      assert [link] = get_resp_header(page, "link")
      assert link =~ "#{base}?page=2&per_page=1>; rel=\"next\""
      assert link =~ "#{base}?page=2&per_page=1>; rel=\"last\""
    end
  end

  test "encoded slash tags round-trip through the router" do
    for version <- @versions do
      suffix = String.replace(version, "-", "")
      alice = user("release-tag-#{suffix}")
      repository = repository(alice, "demo-#{suffix}")
      put_tag(repository, "release/v1")
      {_key, secret} = pat(alice, ["public_repo"])
      base = "/api/v3/repos/#{alice.username}/#{repository.slug}/releases"

      created =
        api_conn(secret, version)
        |> post_json(base, %{"tag_name" => "release/v1"})

      release_id = json_response(created, 201)["id"]
      tagged = api_conn(nil, version) |> get("#{base}/tags/release%2Fv1")
      assert %{"id" => ^release_id, "tag_name" => "release/v1"} = json_response(tagged, 200)
    end
  end

  test "missing tags and unsupported asset operations are explicit" do
    alice = user("release-assets")
    repository(alice, "demo")
    {_key, secret} = pat(alice, ["public_repo"])
    base = "/api/v3/repos/#{alice.username}/demo/releases"

    for version <- @versions do
      missing =
        api_conn(secret, version)
        |> post_json(base, %{"tag_name" => "missing", "name" => "Missing"})

      response = json_response(missing, 422)
      assert response["documentation_url"] == @docs.create
      assert [%{"field" => "tag_name"}] = response["errors"]

      unsupported =
        api_conn(secret, version)
        |> post_json(base, %{"tag_name" => "missing", "generate_release_notes" => "yes"})

      assert [%{"field" => "generate_release_notes"}] =
               json_response(unsupported, 422)["errors"]

      for {method, path} <- [
            {:get, "#{base}/1/assets"},
            {:post, "#{base}/1/assets"},
            {:get, "#{base}/assets/1"},
            {:patch, "#{base}/assets/1"},
            {:delete, "#{base}/assets/1"}
          ] do
        conn = request(api_conn(secret, version), method, path, nil)
        assert json_response(conn, 404)["message"] == "Not Found"
      end
    end
  end

  test "release assets upload, serialize, download ranges, rename and delete in both versions" do
    for version <- @versions do
      alice = user("asset-api-#{String.replace(version, "-", "")}")
      repository = repository(alice, "assets")
      put_tag(repository, "v1")
      {_key, secret} = pat(alice, ["public_repo"])
      base = "/api/v3/repos/#{alice.username}/assets/releases"

      release_id =
        json_response(post_json(api_conn(secret, version), base, %{"tag_name" => "v1"}), 201)[
          "id"
        ]

      bytes = <<0, 255, 1, 2, 3, 4, 5>>

      upload_path =
        "/api/uploads/repos/#{alice.username}/assets/releases/#{release_id}/assets?name=archive.bin"

      uploaded =
        api_conn(secret, version)
        |> put_req_header("content-type", "application/octet-stream")
        |> post(upload_path, bytes)

      asset = json_response(uploaded, 201)
      assert asset["label"] == nil
      assert asset["size"] == byte_size(bytes)

      assert asset["digest"] ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert asset["uploader"]["login"] == alice.username
      asset_path = "#{base}/assets/#{asset["id"]}"

      assert [listed] =
               json_response(get(api_conn(nil, version), "#{base}/#{release_id}/assets"), 200)

      assert listed["id"] == asset["id"]

      assert [embedded] =
               json_response(get(api_conn(nil, version), "#{base}/#{release_id}"), 200)["assets"]

      assert embedded["id"] == asset["id"]

      downloaded =
        api_conn(nil, version)
        |> put_req_header("accept", "application/octet-stream")
        |> get(asset_path)

      assert response(downloaded, 200) == bytes
      direct = get(api_conn(nil, version), URI.parse(asset["browser_download_url"]).path)
      assert response(direct, 200) == bytes
      assert get_resp_header(downloaded, "x-content-type-options") == ["nosniff"]

      ranged =
        api_conn(nil, version)
        |> put_req_header("accept", "application/octet-stream")
        |> put_req_header("range", "bytes=1-3")
        |> get(asset_path)

      assert response(ranged, 206) == <<255, 1, 2>>
      assert get_resp_header(ranged, "content-range") == ["bytes 1-3/7"]

      invalid =
        api_conn(nil, version)
        |> put_req_header("accept", "application/octet-stream")
        |> put_req_header("range", "bytes=99-")
        |> get(asset_path)

      assert response(invalid, 416) == ""
      assert json_response(get(api_conn(nil, version), asset_path), 200)["download_count"] == 3

      renamed =
        patch_json(api_conn(secret, version), asset_path, %{
          "name" => "renamed.bin",
          "label" => "Binary"
        })

      assert json_response(renamed, 200)["name"] == "renamed.bin"
      assert response(delete(api_conn(secret, version), asset_path), 204) == ""
      assert json_response(get(api_conn(nil, version), asset_path), 404)["message"] == "Not Found"
    end
  end

  test "private and draft assets are masked and mutation authorization precedes body reads" do
    alice = user("private-assets")
    bob = user("asset-outsider")
    repository = repository(alice, "private", visibility: :private)
    put_tag(repository, "v1")
    {_key, secret} = pat(alice, ["repo"])
    {_key, outsider} = pat(bob, ["repo"])
    base = "/api/v3/repos/#{alice.username}/private/releases"

    release_id =
      json_response(
        post_json(api_conn(secret, "2022-11-28"), base, %{"tag_name" => "v1", "draft" => true}),
        201
      )["id"]

    upload =
      "/api/uploads/repos/#{alice.username}/private/releases/#{release_id}/assets?name=private.bin"

    asset =
      api_conn(secret, "2022-11-28")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(upload, "private")
      |> json_response(201)

    path = "#{base}/assets/#{asset["id"]}"

    for actor_secret <- [nil, outsider] do
      assert json_response(get(api_conn(actor_secret, "2022-11-28"), path), 404)["message"] ==
               "Not Found"

      hidden = request(api_conn(actor_secret, "2022-11-28"), :patch, path, "{")
      assert json_response(hidden, if(actor_secret, do: 404, else: 401))["message"]
      assert adapter_request_body(hidden) == "{"
    end

    assert response(
             api_conn(secret, "2022-11-28")
             |> put_req_header("accept", "application/octet-stream")
             |> get(path),
             200
           ) == "private"

    public = repository(alice, "public-draft")
    put_tag(public, "v1")
    public_base = "/api/v3/repos/#{alice.username}/public-draft/releases"

    draft_id =
      json_response(
        post_json(api_conn(secret, "2022-11-28"), public_base, %{
          "tag_name" => "v1",
          "draft" => true
        }),
        201
      )["id"]

    public_upload =
      "/api/uploads/repos/#{alice.username}/public-draft/releases/#{draft_id}/assets?name=draft.bin"

    draft_asset =
      api_conn(secret, "2022-11-28")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(public_upload, "draft")
      |> json_response(201)

    assert json_response(
             get(api_conn(nil, "2022-11-28"), "#{public_base}/assets/#{draft_asset["id"]}"),
             404
           )["message"] == "Not Found"

    assert json_response(
             get(api_conn(nil, "2022-11-28"), "#{public_base}/#{draft_id}/archives/zip"),
             404
           )["message"] == "Not Found"
  end

  test "source archives come from local Git and notes generation uses commit history" do
    alice = user("archive-api")
    repository = repository(alice, "archives")
    put_tag(repository, "v1")
    {_key, secret} = pat(alice, ["public_repo"])
    base = "/api/v3/repos/#{alice.username}/archives/releases"

    release =
      post_json(api_conn(secret, "2022-11-28"), base, %{"tag_name" => "v1"}) |> json_response(201)

    for format <- ["tar", "zip"] do
      archive = get(api_conn(nil, "2022-11-28"), "#{base}/#{release["id"]}/archives/#{format}")
      bytes = response(archive, 200)
      assert byte_size(bytes) > 0
      if format == "zip", do: assert(binary_part(bytes, 0, 2) == "PK")
    end

    notes =
      post_json(api_conn(secret, "2022-11-28"), "#{base}/generate-notes", %{"tag_name" => "v1"})
      |> json_response(200)

    assert notes["name"] == "v1"
    assert notes["body"] =~ "release v1"
    old_max = Application.get_env(:forge_releases, :archive_max_bytes)
    Application.put_env(:forge_releases, :archive_max_bytes, 1)

    try do
      too_large = get(api_conn(nil, "2022-11-28"), "#{base}/#{release["id"]}/archives/tar")
      assert json_response(too_large, 413)["message"] == "Payload Too Large"
    after
      if old_max,
        do: Application.put_env(:forge_releases, :archive_max_bytes, old_max),
        else: Application.delete_env(:forge_releases, :archive_max_bytes)
    end
  end

  defp repository(owner, slug, opts \\ []) do
    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{
        name: slug,
        slug: slug,
        visibility: Keyword.get(opts, :visibility, :public),
        default_branch: "main"
      })

    repository
  end

  defp collaborator(repository, user, role) do
    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  defp put_tag(repository, name) do
    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    commit = git!(path, ["commit-tree", tree, "-m", "release #{name}"])
    git!(path, ["update-ref", "refs/tags/#{name}", commit])
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Release API Test"},
      {"GIT_AUTHOR_EMAIL", "release-api@example.test"},
      {"GIT_COMMITTER_NAME", "Release API Test"},
      {"GIT_COMMITTER_EMAIL", "release-api@example.test"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true)

    String.trim(output)
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

  defp request(conn, :get, path, _body), do: get(conn, path)
  defp request(conn, :delete, path, _body), do: delete(conn, path)

  defp request(conn, method, path, body) when method in [:post, :patch] do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(&dispatch_request(&1, method, path, body || "{}"))
  end

  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)

  defp put_optional_authorization(conn, nil), do: conn

  defp put_optional_authorization(conn, secret),
    do: put_req_header(conn, "authorization", "Bearer #{secret}")

  defp assert_error(conn, status, documentation_url, message \\ "Not Found") do
    body = json_response(conn, status)
    assert body["message"] == message
    assert body["documentation_url"] == documentation_url
  end

  defp assert_scope_headers(conn, oauth_scopes, accepted_scopes) do
    assert get_resp_header(conn, "x-oauth-scopes") == [oauth_scopes]
    assert get_resp_header(conn, "x-accepted-oauth-scopes") == [accepted_scopes]
  end

  defp adapter_request_body(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, state}}),
    do: state.req_body
end
