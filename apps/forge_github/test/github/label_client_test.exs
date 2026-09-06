defmodule ForgeGitHub.LabelClientTest do
  use ExUnit.Case, async: true
  alias ForgeGitHub.{Error, LabelClient}
  setup {Req.Test, :verify_on_exit!}

  test "creates a label with bounded metadata and returns immutable provider identity" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/repo/labels"
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"name" => "bug", "color" => "aabbcc", "description" => "Fix"}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(label())
    end)

    assert {:ok, %{"id" => 42, "node_id" => "L_42"}} =
             LabelClient.create_label(
               "token",
               "acme",
               "repo",
               %{name: "bug", color: "aabbcc", description: "Fix"},
               opts(stub)
             )
  end

  test "label names are encoded as a single path segment" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/repo/labels/bug%2Ffix%20%23%3F"
      Req.Test.json(conn, Map.put(label(), "name", "bug/fix #?"))
    end)

    assert {:ok, _} = LabelClient.get_label("token", "acme", "repo", "bug/fix #?", opts(stub))
  end

  test "invalid attributes and missing installation gate fail without requests" do
    for attrs <- [
          %{name: "bug", color: "#aabbcc"},
          %{name: "bug", color: "aabbcc", extra: true},
          %{name: "bug", color: "aabbcc", description: String.duplicate("e\u0301", 51)}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               LabelClient.create_label("token", "acme", "repo", attrs, opts(stub()))
    end

    assert {:error, %Error{kind: :invalid_request}} =
             LabelClient.get_label("token", "acme", "repo", "bug", [])
  end

  test "malformed responses and provider failures are not successful mappings" do
    stub = stub()
    Req.Test.expect(stub, &Req.Test.json(&1, Map.put(label(), "id", 0)))

    assert {:error, %Error{kind: :invalid_response}} =
             LabelClient.get_label("token", "acme", "repo", "bug", opts(stub))

    stub = stub()
    Req.Test.expect(stub, &Plug.Conn.send_resp(&1, 404, ""))

    assert {:error, %Error{kind: :not_found}} =
             LabelClient.get_label("token", "acme", "repo", "bug", opts(stub))
  end

  defp label,
    do: %{
      "id" => 42,
      "node_id" => "L_42",
      "name" => "bug",
      "color" => "aabbcc",
      "description" => "Fix"
    }

  defp stub, do: {__MODULE__, System.unique_integer([:positive])}

  defp opts(stub),
    do: [
      plug: {Req.Test, stub},
      gate_key: {:github_installation, System.unique_integer([:positive])},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
end
