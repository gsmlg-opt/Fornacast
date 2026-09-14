defmodule ForgeGitHub.ReleaseClientTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Client, Error, ReleaseClient}

  setup {Req.Test, :verify_on_exit!}

  test "lists one exact bounded page and retains only canonical release metadata" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/widgets/releases"
      assert URI.decode_query(conn.query_string) == %{"page" => "1", "per_page" => "100"}

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/acme/widgets/releases?page=2&per_page=100>; rel=\"next\""
      )
      |> Req.Test.json([
        release_json(41,
          assets: [%{"id" => 1, "browser_download_url" => "https://objects.example/secret"}],
          extra: %{
            "upload_url" => "https://uploads.github.com/secret{?name}",
            "secret" => "token"
          }
        )
      ])
    end)

    assert {:ok, %{releases: [release], next_cursor: 2}} =
             ReleaseClient.list_releases_page(
               "installation_token",
               "acme",
               "widgets",
               nil,
               client_opts(stub)
             )

    assert release == canonical_release(41, asset_count: 1)
    refute Map.has_key?(release, "assets")
    refute Map.has_key?(release, "url")
    refute Map.has_key?(release, "upload_url")
    refute inspect(release) =~ "secret"
  end

  test "gets by immutable id and by an encoded unique tag without route injection" do
    by_id = stub_name()

    Req.Test.expect(by_id, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/releases/41"
      Req.Test.json(conn, release_json(41))
    end)

    assert {:ok, %{"id" => 41, "tag_name" => "release/v1.0"}} =
             ReleaseClient.get_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               client_opts(by_id)
             )

    by_tag = stub_name()

    Req.Test.expect(by_tag, fn conn ->
      assert conn.request_path == "/repos/acme/widgets/releases/tags/release%2Fv1.0"
      assert conn.query_string == ""
      Req.Test.json(conn, release_json(41))
    end)

    assert {:ok, %{"id" => 41}} =
             ReleaseClient.get_release_by_tag(
               "installation_token",
               "acme",
               "widgets",
               "release/v1.0",
               client_opts(by_tag)
             )

    assert {:error, %Error{kind: :invalid_request}} =
             ReleaseClient.get_release_by_tag(
               "installation_token",
               "acme",
               "widgets",
               "release/v1?per_page=100",
               client_opts(stub_name())
             )
  end

  test "creates and updates only supported bounded release fields" do
    body = String.duplicate("🙂", 65_536)
    create_stub = stub_name()

    Req.Test.expect(create_stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/widgets/releases"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn, length: 1_000_000)

      assert JSON.decode!(encoded) == %{
               "body" => body,
               "draft" => true,
               "name" => "Preview",
               "prerelease" => true,
               "tag_name" => "release/v1.0",
               "target_commitish" => "main"
             }

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(
        release_json(41, body: body, draft: true, prerelease: true, published_at: nil)
      )
    end)

    assert {:ok, %{"id" => 41, "body" => ^body, "draft" => true}} =
             ReleaseClient.create_release(
               "installation_token",
               "acme",
               "widgets",
               %{
                 tag_name: "release/v1.0",
                 target_commitish: "main",
                 name: "Preview",
                 body: body,
                 draft: true,
                 prerelease: true
               },
               client_opts(create_stub)
             )

    update_stub = stub_name()

    Req.Test.expect(update_stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/widgets/releases/41"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(encoded) == %{"draft" => false, "name" => "Version 1.0"}
      Req.Test.json(conn, release_json(41, name: "Version 1.0"))
    end)

    assert {:ok, %{"name" => "Version 1.0", "draft" => false}} =
             ReleaseClient.update_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               %{name: "Version 1.0", draft: false},
               client_opts(update_stub)
             )
  end

  test "binds a successful create response to the exact requested unique tag" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(release_json(41, tag_name: "release/other"))
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             ReleaseClient.create_release(
               "installation_token",
               "acme",
               "widgets",
               %{tag_name: "release/v1.0", target_commitish: "main"},
               client_opts(stub)
             )
  end

  test "deletes with the exact empty-body status" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/repos/acme/widgets/releases/41"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok =
             ReleaseClient.delete_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               client_opts(stub)
             )

    unexpected = stub_name()
    Req.Test.expect(unexpected, &Plug.Conn.send_resp(&1, 200, ""))

    assert {:error, %Error{kind: :unexpected_status}} =
             ReleaseClient.delete_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               client_opts(unexpected)
             )
  end

  test "rejects response identity substitution and malformed required fields" do
    invalid_releases = [
      put_in(release_json(41), ["url"], "https://api.github.com/repos/other/widgets/releases/41"),
      put_in(release_json(41), ["url"], "https://api.github.com/repos/acme/widgets/releases/42"),
      Map.put(release_json(41), "id", 42),
      Map.delete(release_json(41), "node_id"),
      Map.put(release_json(41), "node_id", ""),
      Map.put(release_json(41), "tag_name", ""),
      Map.put(release_json(41), "name", String.duplicate("n", 256)),
      Map.put(release_json(41), "body", String.duplicate("🙂", 65_537)),
      Map.put(release_json(41), "draft", "false"),
      Map.put(release_json(41), "prerelease", nil),
      Map.put(release_json(41), "target_commitish", ""),
      Map.put(release_json(41), "published_at", nil),
      Map.put(release_json(41), "created_at", "not-a-time"),
      Map.put(release_json(41), "updated_at", nil),
      put_in(release_json(41), ["author", "id"], 0),
      put_in(release_json(41), ["author", "login"], "bad login")
    ]

    for release <- invalid_releases do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, release))

      assert {:error, %Error{kind: :invalid_response}} =
               ReleaseClient.get_release(
                 "installation_token",
                 "acme",
                 "widgets",
                 41,
                 client_opts(stub)
               )
    end
  end

  test "accepts coherent draft publication state and rejects incoherent state" do
    draft = release_json(41, draft: true, published_at: nil)
    accepted = stub_name()
    Req.Test.expect(accepted, &Req.Test.json(&1, draft))

    assert {:ok, %{"draft" => true, "published_at" => nil}} =
             ReleaseClient.get_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               client_opts(accepted)
             )

    invalid = stub_name()
    Req.Test.expect(invalid, &Req.Test.json(&1, release_json(41, draft: true)))

    assert {:error, %Error{kind: :invalid_response}} =
             ReleaseClient.get_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               client_opts(invalid)
             )
  end

  test "rejects oversized, malformed, or ambiguous pages instead of truncating" do
    responses = [
      Enum.map(1..101, &release_json(&1)),
      [release_json(41), release_json(41)],
      [release_json(41), release_json(42, node_id: "RE_41")],
      [release_json(41), release_json(42, tag_name: "release/v1.0")],
      [Map.put(release_json(41), "assets", List.duplicate(%{}, 513))],
      %{}
    ]

    for response <- responses do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, response))

      assert {:error, %Error{kind: :invalid_response}} =
               ReleaseClient.list_releases_page(
                 "installation_token",
                 "acme",
                 "widgets",
                 nil,
                 client_opts(stub)
               )
    end
  end

  test "rejects pagination changes and invalid page requests before continuing" do
    for url <- [
          "https://api.github.com/repos/acme/other/releases?page=2&per_page=100",
          "https://evil.example/repos/acme/widgets/releases?page=2&per_page=100",
          "https://api.github.com/repos/acme/widgets/releases?page=2&per_page=99",
          "https://api.github.com/repos/acme/widgets/releases?page=1&per_page=100",
          "https://api.github.com/repos/acme/widgets/releases?page=3&per_page=100",
          "https://api.github.com/repos/acme/widgets/releases?page=2&page=2&per_page=100"
        ] do
      stub = stub_name()

      Req.Test.expect(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("link", "<#{url}>; rel=\"next\"")
        |> Req.Test.json([])
      end)

      assert {:error, %Error{kind: :invalid_pagination}} =
               ReleaseClient.list_releases_page(
                 "installation_token",
                 "acme",
                 "widgets",
                 nil,
                 client_opts(stub)
               )
    end

    for cursor <- [0, -1, "2", 2_147_483_648] do
      assert {:error, %Error{kind: :invalid_request}} =
               ReleaseClient.list_releases_page(
                 "installation_token",
                 "acme",
                 "widgets",
                 cursor,
                 client_opts(stub_name())
               )
    end
  end

  test "accepts bounded installation and one-time import gates" do
    read_stub = stub_name()

    Req.Test.expect(read_stub, fn conn -> Req.Test.json(conn, release_json(41)) end)

    assert {:ok, %{"id" => 41}} =
             ReleaseClient.get_release(
               "import_token",
               "acme",
               "widgets",
               41,
               client_opts(read_stub, {:one_time_run, 7})
             )

    page_stub = stub_name()
    Req.Test.expect(page_stub, fn conn -> Req.Test.json(conn, [release_json(41)]) end)

    assert {:ok, %{releases: [%{"id" => 41}], next_cursor: nil}} =
             ReleaseClient.list_releases_page(
               "import_token",
               "acme",
               "widgets",
               nil,
               client_opts(page_stub, {:one_time_run, 7})
             )

    assert {:error, %Error{kind: :invalid_request}} =
             ReleaseClient.create_release(
               "import_token",
               "acme",
               "widgets",
               %{tag_name: "v1", target_commitish: "main"},
               client_opts(stub_name(), {:one_time_run, 7})
             )

    assert {:error, %Error{kind: :invalid_request}} =
             ReleaseClient.update_release(
               "import_token",
               "acme",
               "widgets",
               41,
               %{name: "forbidden"},
               client_opts(stub_name(), {:one_time_run, 7})
             )

    assert {:error, %Error{kind: :invalid_request}} =
             ReleaseClient.delete_release(
               "import_token",
               "acme",
               "widgets",
               41,
               client_opts(stub_name(), {:one_time_run, 7})
             )
  end

  test "rejects unsupported payload fields and unsupported gates without transport" do
    for attrs <- [
          %{},
          %{tag_name: "v1"},
          %{tag_name: "v1", target_commitish: "main", assets: []},
          %{tag_name: "refs/tags/v1", target_commitish: "main"},
          %{tag_name: "", target_commitish: "main"},
          %{tag_name: "v1", target_commitish: ""},
          %{tag_name: "v1", target_commitish: "main", body: String.duplicate("🙂", 65_537)}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               ReleaseClient.create_release(
                 "installation_token",
                 "acme",
                 "widgets",
                 attrs,
                 client_opts(stub_name())
               )
    end

    assert {:error, %Error{kind: :invalid_request}} =
             ReleaseClient.update_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               %{},
               client_opts(stub_name())
             )

    for gate_key <- [nil, {:saved_credential, 1}, {:github_app, 1}, {:github_installation, 0}] do
      assert {:error, %Error{kind: :invalid_request}} =
               ReleaseClient.get_release(
                 "installation_token",
                 "acme",
                 "widgets",
                 41,
                 client_opts(stub_name(), gate_key)
               )
    end
  end

  test "rejects credential echoes in every retained provider-controlled string" do
    for field <- [
          "node_id",
          "tag_name",
          "name",
          "body",
          "target_commitish",
          "published_at",
          "created_at",
          "updated_at"
        ] do
      release = release_json(41)
      token = release[field]
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, release))

      assert {:error, %Error{kind: :invalid_response}} =
               ReleaseClient.get_release(token, "acme", "widgets", 41, client_opts(stub))
    end
  end

  test "rejects provider tags under the reserved refs namespace" do
    stub = stub_name()
    Req.Test.expect(stub, &Req.Test.json(&1, release_json(41, tag_name: "refs/tags/v1")))

    assert {:error, %Error{kind: :invalid_response}} =
             ReleaseClient.get_release(
               "installation_token",
               "acme",
               "widgets",
               41,
               client_opts(stub)
             )
  end

  test "release body profile does not widen other response strings" do
    for release <- [
          Map.put(release_json(41), "unexpected", String.duplicate("x", 16_385)),
          Map.put(release_json(41), "tag_name", String.duplicate("x", 16_385))
        ] do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, release))

      assert {:error, %Error{kind: :invalid_response}} =
               ReleaseClient.get_release(
                 "installation_token",
                 "acme",
                 "widgets",
                 41,
                 client_opts(stub)
               )
    end
  end

  test "low-level release profile rejects noncanonical routes, queries, and status contracts" do
    opts = client_opts(stub_name())

    for path <- [
          "/repos/acme/widgets/releases",
          "/repos/acme/widgets/releases?page=1",
          "/repos/acme/widgets/releases?page=01&per_page=100",
          "/repos/acme/widgets/releases?page=1&per_page=99",
          "/repos/acme/widgets/releases?page=1&page=2&per_page=100",
          "/repos/acme/widgets/releases?page=1&per_page=100&extra=yes",
          "/repos/acme/widgets/releases/tags/release/v1.0",
          "/repos/acme/widgets/releases/tags/release%252Fv1.0",
          "/repos/acme/widgets/releases/41?extra=yes",
          "/repos/acme/widgets/releases/041",
          "/repos/acme/widgets/releases/0"
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               Client.release_metadata_page("installation_token", path, opts)
    end

    for {method, path, status} <- [
          {:get, "/repos/acme/widgets/releases/41", 201},
          {:post, "/repos/acme/widgets/releases", 200},
          {:patch, "/repos/acme/widgets/releases/41", 201},
          {:delete, "/repos/acme/widgets/releases/41", 200},
          {:put, "/repos/acme/widgets/releases/41", 200},
          {:get, "/repos/acme/widgets/releases/tags/release%2Fv1.0", 201}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               Client.release_metadata_request(
                 "installation_token",
                 method,
                 path,
                 status,
                 opts
               )
    end
  end

  defp canonical_release(id, overrides) do
    Map.merge(
      %{
        "id" => id,
        "node_id" => "RE_#{id}",
        "tag_name" => "release/v1.0",
        "name" => "Version 1.0",
        "body" => "Release notes",
        "draft" => false,
        "prerelease" => false,
        "target_commitish" => "main",
        "published_at" => "2030-01-02T00:00:00Z",
        "created_at" => "2030-01-01T00:00:00Z",
        "updated_at" => "2030-01-03T00:00:00Z",
        "author" => %{"id" => 99, "node_id" => "U_99", "login" => "octocat"},
        "asset_count" => 0,
        "unsupported_fields" => ~w(assets_url html_url tarball_url upload_url zipball_url)
      },
      Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
    )
  end

  defp release_json(id, overrides \\ []) do
    overrides = Map.new(overrides)
    assets = Map.get(overrides, :assets, [])
    extra = Map.get(overrides, :extra, %{})

    Map.merge(
      %{
        "id" => id,
        "node_id" => Map.get(overrides, :node_id, "RE_#{id}"),
        "url" => "https://api.github.com/repos/acme/widgets/releases/#{id}",
        "tag_name" => Map.get(overrides, :tag_name, "release/v1.0"),
        "name" => Map.get(overrides, :name, "Version 1.0"),
        "body" => Map.get(overrides, :body, "Release notes"),
        "draft" => Map.get(overrides, :draft, false),
        "prerelease" => Map.get(overrides, :prerelease, false),
        "target_commitish" => Map.get(overrides, :target_commitish, "main"),
        "published_at" => Map.get(overrides, :published_at, "2030-01-02T00:00:00Z"),
        "created_at" => "2030-01-01T00:00:00Z",
        "updated_at" => "2030-01-03T00:00:00Z",
        "author" => %{"id" => 99, "node_id" => "U_99", "login" => "octocat"},
        "assets" => assets,
        "assets_url" => "https://api.github.com/repos/acme/widgets/releases/#{id}/assets",
        "html_url" => "https://github.com/acme/widgets/releases/tag/release/v1.0",
        "tarball_url" => "https://api.github.com/repos/acme/widgets/tarball/release/v1.0",
        "zipball_url" => "https://api.github.com/repos/acme/widgets/zipball/release/v1.0"
      },
      extra
    )
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
