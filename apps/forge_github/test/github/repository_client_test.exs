defmodule ForgeGitHub.RepositoryClientTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, Repository, RepositoryClient}

  setup {Req.Test, :verify_on_exit!}

  test "creates an organization repository through an installation-gated POST" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/orgs/acme/repos"
      assert conn.query_string == ""
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(body) == %{
               "description" => "Canonical widgets",
               "name" => "widgets",
               "visibility" => "private"
             }

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(repository_json(description: "Canonical widgets"))
    end)

    assert {:ok, %Repository{id: 41, node_id: "R_kgDOAAAoAQ", name: "widgets"}} =
             RepositoryClient.create_organization_repository(
               "installation-token",
               "acme",
               %{name: "widgets", description: "Canonical widgets", visibility: :private},
               client_opts(stub)
             )
  end

  test "omits a nil create description and requires the exact canonical full name" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"name" => "widgets", "visibility" => "private"}

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(
        repository_json([])
        |> Map.put("full_name", "other/widgets")
      )
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             RepositoryClient.create_organization_repository(
               "installation-token",
               "acme",
               %{name: "widgets", description: nil, visibility: :private},
               client_opts(stub)
             )
  end

  test "rejects unsafe organization-create inputs before a request" do
    for {owner, attrs} <- [
          {"acme/other", %{name: "widgets", visibility: :private}},
          {"acme", %{visibility: :private}},
          {"acme", %{name: "widgets", visibility: :internal}},
          {"acme", %{name: "widgets", visibility: :private, archived: false}},
          {"acme", %{name: "widgets", visibility: :private, default_branch: "main"}},
          {"acme", %{name: "widgets?x=1", visibility: :private}},
          {"acme",
           %{name: "widgets", description: String.duplicate("x", 1_001), visibility: :private}}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               RepositoryClient.create_organization_repository(
                 "installation-token",
                 owner,
                 attrs,
                 client_opts(stub_name())
               )
    end

    assert {:error, %Error{kind: :invalid_request}} =
             RepositoryClient.create_organization_repository(
               "installation-token",
               "acme",
               %{name: "widgets", visibility: :private},
               client_opts(stub_name(), json: %{"name" => "override"})
             )
  end

  test "requires exactly 201 for organization repository creation" do
    stub = stub_name()
    Req.Test.expect(stub, fn conn -> Req.Test.json(conn, repository_json([])) end)

    assert {:error, %Error{kind: :unexpected_status}} =
             RepositoryClient.create_organization_repository(
               "installation-token",
               "acme",
               %{name: "widgets", visibility: :private},
               client_opts(stub)
             )
  end

  test "classifies an organization repository name collision separately from validation failures" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"message" => "name already exists on this account"})
    end)

    assert {:error, %Error{kind: :unprocessable_entity}} =
             RepositoryClient.create_organization_repository(
               "installation-token",
               "acme",
               %{name: "widgets", visibility: :private},
               client_opts(stub)
             )
  end

  test "updates representable repository metadata through an installation-gated PATCH" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/widgets"
      assert conn.query_string == ""
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(body) == %{
               "archived" => true,
               "default_branch" => "trunk",
               "description" => "Canonical widgets",
               "name" => "widgets-next",
               "visibility" => "private"
             }

      Req.Test.json(conn, repository_json(name: "widgets-next", description: "Canonical widgets"))
    end)

    assert {:ok, %Repository{name: "widgets-next", visibility: :private}} =
             RepositoryClient.update_repository(
               "installation-token",
               "acme",
               "widgets",
               %{
                 name: "widgets-next",
                 description: "Canonical widgets",
                 visibility: :private,
                 default_branch: "trunk",
                 archived: true
               },
               client_opts(stub)
             )
  end

  test "allows clearing a repository description" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"description" => ""}
      Req.Test.json(conn, repository_json(description: ""))
    end)

    assert {:ok, %Repository{description: ""}} =
             RepositoryClient.update_repository(
               "installation-token",
               "acme",
               "widgets",
               %{description: ""},
               client_opts(stub)
             )
  end

  test "rejects unsafe targets, internal visibility, empty or unknown fields before a request" do
    for {owner, repository, attrs} <- [
          {"acme/other", "widgets", %{archived: true}},
          {"acme", "widgets?x=1", %{archived: true}},
          {"acme", "widgets", %{visibility: :internal}},
          {"acme", "widgets", %{}},
          {"acme", "widgets", %{unknown: true}},
          {"acme", "widgets", %{description: String.duplicate("x", 1_001)}},
          {"acme", "widgets", %{default_branch: ""}},
          {"acme", "widgets", %{archived: "true"}},
          {"acme", "widgets", %{name: String.duplicate("x", 101)}}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               RepositoryClient.update_repository(
                 "installation-token",
                 owner,
                 repository,
                 attrs,
                 client_opts(stub_name())
               )
    end
  end

  test "requires an installation gate and exact successful canonical response" do
    assert {:error, %Error{kind: :invalid_request}} =
             RepositoryClient.update_repository(
               "installation-token",
               "acme",
               "widgets",
               %{archived: true},
               []
             )

    assert {:error, %Error{kind: :invalid_request}} =
             RepositoryClient.update_repository(
               "installation-token",
               "acme",
               "widgets",
               %{archived: true},
               client_opts(stub_name(), json: %{"token" => "installation-token"})
             )

    for response <- [
          fn conn -> Plug.Conn.send_resp(conn, 201, "{}") end,
          fn conn -> Plug.Conn.send_resp(conn, 302, "") end,
          fn conn -> Req.Test.json(conn, %{"token" => "installation-token"}) end
        ] do
      stub = stub_name()
      Req.Test.expect(stub, response)

      result =
        RepositoryClient.update_repository(
          "installation-token",
          "acme",
          "widgets",
          %{archived: true},
          client_opts(stub)
        )

      assert {:error, %Error{kind: kind}} = result

      assert kind in [:unexpected_status, :invalid_response]
      refute inspect(result) =~ "installation-token"
    end
  end

  defp client_opts(stub, extra \\ []),
    do: [plug: {Req.Test, stub}, gate_key: {:github_installation, 9}] ++ extra

  defp stub_name, do: String.to_atom("repository-client-#{System.unique_integer([:positive])}")

  defp repository_json(overrides) do
    %{
      "id" => 41,
      "node_id" => "R_kgDOAAAoAQ",
      "owner" => %{"id" => 7, "login" => "acme"},
      "name" => "widgets",
      "full_name" => "acme/widgets",
      "description" => nil,
      "visibility" => "private",
      "default_branch" => "main",
      "has_issues" => true,
      "allow_merge_commit" => true,
      "fork" => false,
      "archived" => false,
      "html_url" => "https://github.com/acme/widgets",
      "updated_at" => "2026-09-14T05:00:00Z",
      "pushed_at" => "2026-09-14T05:00:00Z"
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn repository ->
      Map.put(repository, "full_name", "acme/#{repository["name"]}")
      |> Map.put("html_url", "https://github.com/acme/#{repository["name"]}")
    end)
  end
end
