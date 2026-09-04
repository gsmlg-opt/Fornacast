defmodule ForgeGitHub.InventoryClientTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Client, Error, Repository}

  setup {Req.Test, :verify_on_exit!}

  test "fetches one bounded installation repository page and returns a safe resume cursor" do
    stub = stub_name()
    parent = self()

    Req.Test.expect(stub, fn conn ->
      send(parent, {:request, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/installation/repositories?per_page=100&page=2>; rel="next")
      )
      |> Req.Test.json(%{
        "total_count" => 2,
        "repositories" => [repository_json(12_345, "one")]
      })
    end)

    assert {:ok,
            %{
              repositories: [%Repository{id: 12_345, node_id: "R_kgDOAAAwOQ"}],
              next_cursor: 2
            }} =
             Client.installation_repositories_page(
               "installation_token",
               nil,
               client_opts(stub)
             )

    assert_received {:request, "/installation/repositories", query}
    assert URI.decode_query(query) == %{"page" => "1", "per_page" => "100"}
  end

  test "rejects unsafe caller cursors and malformed next links without following them" do
    for cursor <- [0, 101, "2", %{"page" => 2}] do
      assert {:error, %Error{kind: :invalid_request}} =
               Client.installation_repositories_page(
                 "installation_token",
                 cursor,
                 client_opts(stub_name())
               )
    end

    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/installation/repositories?per_page=50&page=2>; rel="next")
      )
      |> Req.Test.json(%{"total_count" => 1, "repositories" => [repository_json(1, "one")]})
    end)

    assert {:error, %Error{kind: :invalid_pagination}} =
             Client.installation_repositories_page(
               "installation_token",
               nil,
               client_opts(stub)
             )
  end

  test "requires immutable node identities in installation inventory responses" do
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      repository = Map.delete(repository_json(1, "one"), "node_id")
      Req.Test.json(conn, %{"total_count" => 1, "repositories" => [repository]})
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             Client.installation_repositories_page(
               "installation_token",
               nil,
               client_opts(stub)
             )
  end

  defp client_opts(stub) do
    [
      plug: {Req.Test, stub},
      gate_key: {:github_installation, System.unique_integer([:positive])},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defp repository_json(id, name) do
    %{
      "id" => id,
      "node_id" => "R_kgDOAAAwOQ",
      "name" => name,
      "full_name" => "github/#{name}",
      "owner" => %{"id" => 99, "login" => "github"},
      "description" => "A repository",
      "visibility" => "private",
      "default_branch" => "main",
      "has_issues" => true,
      "fork" => false,
      "archived" => false,
      "html_url" => "https://github.com/github/#{name}",
      "updated_at" => "2030-01-01T00:00:00Z",
      "pushed_at" => "2030-01-01T00:00:00Z"
    }
  end
end
