defmodule ForgeGitHub.IdentityClientTest do
  use ExUnit.Case, async: true
  alias ForgeGitHub.{Error, IdentityClient, User}

  test "reads a renamed user by numeric identity and retains the opaque node ID" do
    stub = stub()

    Req.Test.stub(stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/user/42"
      Req.Test.json(conn, %{"id" => 42, "node_id" => "U_opaque", "login" => "renamed-user"})
    end)

    assert {:ok, %User{id: 42, node_id: "U_opaque", login: "renamed-user"}} =
             IdentityClient.get_user("fixture-token", 42, options(stub))
  end

  test "rejects substituted IDs and missing or invalid node identity" do
    for profile <- [
          %{"id" => 43, "node_id" => "U_other", "login" => "user"},
          %{"id" => 42, "login" => "user"},
          %{"id" => 42, "node_id" => " ", "login" => "user"}
        ] do
      stub = stub()
      Req.Test.stub(stub, &Req.Test.json(&1, profile))

      assert {:error, %Error{kind: :invalid_response}} =
               IdentityClient.get_user("fixture-token", 42, options(stub))
    end
  end

  test "invalid IDs and missing installation scope make no request" do
    stub = stub()
    Req.Test.stub(stub, fn _ -> flunk("invalid request reached provider") end)

    for id <- [nil, 0, -1, "42", 9_223_372_036_854_775_808] do
      assert {:error, %Error{kind: :invalid_request}} =
               IdentityClient.get_user("fixture-token", id, options(stub))
    end

    assert {:error, %Error{kind: :invalid_request}} =
             IdentityClient.get_user(
               "fixture-token",
               42,
               Keyword.delete(options(stub), :gate_key)
             )
  end

  test "retains a provider not-found error for a missing immutable identity" do
    stub = stub()
    Req.Test.stub(stub, &Plug.Conn.send_resp(&1, 404, "{}"))

    assert {:error, %Error{kind: :not_found}} =
             IdentityClient.get_user("fixture-token", 42, options(stub))
  end

  test "does not return a credential echoed in retained profile fields" do
    for field <- ["node_id", "login", "name"] do
      stub = stub()

      raw =
        Map.put(%{"id" => 42, "node_id" => "U_opaque", "login" => "user"}, field, "fixture-token")

      Req.Test.stub(stub, &Req.Test.json(&1, raw))

      assert {:error, %Error{kind: :invalid_response}} =
               IdentityClient.get_user("fixture-token", 42, options(stub))
    end
  end

  defp stub, do: {__MODULE__, System.unique_integer([:positive])}

  defp options(stub),
    do: [
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
      gate_key: {:github_installation, System.unique_integer([:positive])}
    ]
end
