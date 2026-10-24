defmodule ForgeGitHub.UserInstallationTest do
  use ExUnit.Case, async: true
  alias ForgeGitHub.{Client, Error, UserInstallation}
  setup {Req.Test, :verify_on_exit!}

  test "normalizes App identity separately from organization installation facts" do
    assert {:ok,
            %UserInstallation{
              app_id: 5_412_311,
              app_slug: "fornacast",
              installation: installation
            }} =
             UserInstallation.from_json(installation_json())

    assert installation.account_id == 91
    assert installation.account_type == :organization
    assert installation.state == :active

    assert {:error, :invalid_response} =
             UserInstallation.from_json(Map.delete(installation_json(), "app_id"))
  end

  test "installation listing preserves legitimate admin permissions alongside operation permissions" do
    permissions = %{
      "contents" => "read",
      "issues" => "write",
      "pull_requests" => "read",
      "organization_custom_properties" => "admin",
      "organization_projects" => "admin",
      "repository_projects" => "admin"
    }

    json = Map.put(installation_json(), "permissions", permissions)
    assert {:ok, normalized} = UserInstallation.from_json(json)
    assert normalized.installation.permissions == permissions

    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/user/installations"
      Req.Test.json(conn, %{"total_count" => 1, "installations" => [json]})
    end)

    assert {:ok, [listed]} = Client.user_installations("installation-user-token", options(stub))
    assert listed.installation.permissions == permissions
  end

  test "admin normalization retains bounded keys and rejects unsupported permission values" do
    for permissions <- [
          %{"organization_projects" => "owner"},
          %{"organization_projects" => "Admin"},
          %{"organization_projects" => true},
          %{String.duplicate("x", 129) => "admin"},
          Map.new(1..129, &{"permission_#{&1}", "admin"})
        ] do
      assert {:error, :invalid_response} =
               UserInstallation.from_json(
                 Map.put(installation_json(), "permissions", permissions)
               )
    end
  end

  test "installation listing follows exact sequential pages and preserves App identity" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, 2, fn conn ->
      assert conn.request_path == "/user/installations"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer installation-user-token"]

      if URI.decode_query(conn.query_string)["page"] == "1" do
        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<https://api.github.com/user/installations?per_page=100&page=2>; rel="next")
        )
        |> Req.Test.json(%{"total_count" => 2, "installations" => [installation_json()]})
      else
        Req.Test.json(conn, %{
          "total_count" => 2,
          "installations" => [Map.put(installation_json(), "id", 45)]
        })
      end
    end)

    assert {:ok, [first, second]} =
             Client.user_installations("installation-user-token", options(stub))

    assert [first.installation.id, second.installation.id] == [44, 45]
  end

  test "a missing next page cannot establish full installation visibility" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(
      stub,
      &Req.Test.json(&1, %{"total_count" => 2, "installations" => [installation_json()]})
    )

    assert {:error, %Error{kind: :invalid_response}} =
             Client.user_installations("installation-user-token", options(stub))
  end

  test "pagination cannot substitute another installation or endpoint" do
    for path <- [
          "/user/installations/45/repositories",
          "/orgs/example/repos",
          "/user/installations/44/repositories?page=1"
        ] do
      stub = {__MODULE__, make_ref()}

      Req.Test.expect(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "link",
          ~s(<https://api.github.com#{path}?per_page=100&page=2>; rel="next")
        )
        |> Req.Test.json(%{"total_count" => 2, "repositories" => [repository_json()]})
      end)

      assert {:error, %Error{kind: :invalid_pagination}} =
               Client.user_installation_repositories("installation-user-token", 44, options(stub))
    end
  end

  test "installation repository endpoint returns full normalized repository DTOs" do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/user/installations/44/repositories"
      Req.Test.json(conn, %{"total_count" => 1, "repositories" => [repository_json()]})
    end)

    assert {:ok, [%ForgeGitHub.Repository{id: 501, owner_id: 91, full_name: "example/project"}]} =
             Client.user_installation_repositories("installation-user-token", 44, options(stub))
  end

  test "duplicate repository IDs and inconsistent totals fail closed" do
    for json <- [
          %{"total_count" => 2, "repositories" => [repository_json(), repository_json()]},
          %{"total_count" => 0, "repositories" => [repository_json()]},
          %{"total_count" => 10_001, "repositories" => []}
        ] do
      stub = {__MODULE__, make_ref()}
      Req.Test.expect(stub, &Req.Test.json(&1, json))

      assert {:error, %Error{kind: :invalid_response}} =
               Client.user_installation_repositories("installation-user-token", 44, options(stub))
    end
  end

  defp options(stub),
    do: [
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
      gate_key: {:account_setup, System.unique_integer([:positive])}
    ]

  defp installation_json,
    do: %{
      "id" => 44,
      "app_id" => 5_412_311,
      "app_slug" => "fornacast",
      "account" => %{"id" => 91, "login" => "example", "type" => "Organization"},
      "repository_selection" => "selected",
      "permissions" => %{"contents" => "read", "issues" => "read", "pull_requests" => "read"}
    }

  defp repository_json,
    do: %{
      "id" => 501,
      "node_id" => "R_501",
      "name" => "project",
      "full_name" => "example/project",
      "owner" => %{"id" => 91, "login" => "example"},
      "visibility" => "private",
      "default_branch" => "main",
      "has_issues" => true,
      "fork" => false,
      "archived" => false
    }
end
