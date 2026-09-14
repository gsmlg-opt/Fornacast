defmodule ForgeGitHub.RepositoryClientTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, Repository, RepositoryClient}

  setup {Req.Test, :verify_on_exit!}

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
