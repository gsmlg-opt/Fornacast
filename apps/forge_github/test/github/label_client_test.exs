defmodule ForgeGitHub.LabelClientTest do
  use ExUnit.Case, async: true
  alias ForgeGitHub.{Error, LabelClient}
  setup {Req.Test, :verify_on_exit!}

  test "page projects only canonical fields without imposing profile name byte limits" do
    stub = stub()
    canonical = Map.put(label(), "name", String.duplicate("😀", 255))
    Req.Test.expect(stub, &Req.Test.json(&1, [Map.put(canonical, "unchecked", "token")]))

    assert {:ok, %{labels: [^canonical]}} =
             LabelClient.list_labels_page("token", "acme", "repo", nil, opts(stub))
  end

  test "page rejects credential echoes and noncanonical or oversized node identities" do
    for {field, value} <- [
          {"name", "token"},
          {"description", "ghp_secret"},
          {"node_id", "token"},
          {"node_id", " L_42"},
          {"node_id", String.duplicate("😀", 129)}
        ] do
      stub = stub()
      Req.Test.expect(stub, &Req.Test.json(&1, [Map.put(label(), field, value)]))

      assert {:error, %Error{kind: :invalid_response}} =
               LabelClient.list_labels_page("token", "acme", "repo", nil, opts(stub))
    end
  end

  test "low-level page leaf rejects malformed queries before transport" do
    for query <- [
          "",
          "page=0&per_page=100",
          "page=2147483648&per_page=100",
          "page=1&per_page=101",
          "page=1&page=2&per_page=100",
          "page=1&per_page=100&extra=yes",
          "page=01&per_page=100"
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               ForgeGitHub.Client.label_metadata_page(
                 "token",
                 "/repos/acme/repo/labels?#{query}",
                 opts(stub())
               )
    end
  end

  test "single label reads and creates reject credential echoes before returning evidence" do
    for action <- [:get, :create],
        {field, value} <- [{"name", "token"}, {"description", "ghp_secret"}, {"node_id", "token"}] do
      stub = stub()
      Req.Test.expect(stub, &Req.Test.json(&1, Map.put(label(), field, value)))

      result =
        if action == :get,
          do: LabelClient.get_label("token", "acme", "repo", "bug", opts(stub)),
          else:
            LabelClient.create_label(
              "token",
              "acme",
              "repo",
              %{name: "bug", color: "aabbcc"},
              opts(stub)
            )

      assert {:error, %Error{kind: :invalid_response}} = result
    end
  end

  test "single label responses retain only canonical evidence fields" do
    stub = stub()
    Req.Test.expect(stub, &Req.Test.json(&1, Map.put(label(), "unchecked", "token")))
    assert {:ok, result} = LabelClient.get_label("token", "acme", "repo", "bug", opts(stub))
    assert result == label()
  end

  test "single label evidence cannot hide archived or malformed archive state" do
    for archived <- [true, "false", nil] do
      stub = stub()
      Req.Test.expect(stub, &Req.Test.json(&1, Map.put(label(), "archived", archived)))

      assert {:error, %Error{kind: :invalid_response}} =
               LabelClient.get_label("token", "acme", "repo", "bug", opts(stub))
    end
  end

  test "lists exactly one bounded page and preserves numeric and node identity" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/repos/acme/repo/labels"
      assert URI.decode_query(conn.query_string) == %{"page" => "1", "per_page" => "100"}

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        "<https://api.github.com/repos/acme/repo/labels?page=2&per_page=100>; rel=\"next\""
      )
      |> Req.Test.json([label()])
    end)

    assert {:ok, %{labels: [%{"id" => 42, "node_id" => "L_42"}], next_cursor: 2}} =
             LabelClient.list_labels_page("token", "acme", "repo", nil, opts(stub))
  end

  test "resumes a page and returns exhaustion without another request" do
    stub = stub()

    Req.Test.expect(stub, fn conn ->
      assert URI.decode_query(conn.query_string)["page"] == "3"
      Req.Test.json(conn, [])
    end)

    assert {:ok, %{labels: [], next_cursor: nil}} =
             LabelClient.list_labels_page("token", "acme", "repo", 3, opts(stub))
  end

  test "rejects pagination that changes route, origin, size, or page progression" do
    for url <- [
          "https://api.github.com/repos/acme/other/labels?page=2&per_page=100",
          "https://evil.example/repos/acme/repo/labels?page=2&per_page=100",
          "https://api.github.com/repos/acme/repo/labels?page=2&per_page=101",
          "https://api.github.com/repos/acme/repo/labels?page=1&per_page=100",
          "https://api.github.com/repos/acme/repo/labels?page=3&per_page=100",
          "https://api.github.com/repos/acme/repo/labels?page=2&page=2&per_page=100"
        ] do
      stub = stub()

      Req.Test.expect(stub, fn conn ->
        conn |> Plug.Conn.put_resp_header("link", "<#{url}>; rel=\"next\"") |> Req.Test.json([])
      end)

      assert {:error, %Error{kind: :invalid_pagination}} =
               LabelClient.list_labels_page("token", "acme", "repo", nil, opts(stub))
    end
  end

  test "rejects oversized malformed and ambiguous identity pages" do
    for response <- [
          Enum.map(1..101, &Map.merge(label(), %{"id" => &1, "node_id" => "L_#{&1}"})),
          [Map.delete(label(), "node_id")],
          [label(), label()],
          [label(), Map.put(label(), "id", 43)],
          %{}
        ] do
      stub = stub()
      Req.Test.expect(stub, &Req.Test.json(&1, response))

      assert {:error, %Error{kind: :invalid_response}} =
               LabelClient.list_labels_page("token", "acme", "repo", nil, opts(stub))
    end
  end

  test "page request validation and provider errors stay typed" do
    for cursor <- [0, -1, "2", 2_147_483_648] do
      assert {:error, %Error{kind: :invalid_request}} =
               LabelClient.list_labels_page("token", "acme", "repo", cursor, opts(stub()))
    end

    assert {:error, %Error{kind: :invalid_request}} =
             LabelClient.list_labels_page("token", "acme", "repo", nil, [])

    assert {:error, %Error{kind: :invalid_request}} =
             LabelClient.list_labels_page("token", "acme", "../repo", nil, opts(stub()))

    stub = stub()
    Req.Test.expect(stub, &Plug.Conn.send_resp(&1, 404, ""))

    assert {:error, %Error{kind: :not_found}} =
             LabelClient.list_labels_page("token", "acme", "repo", nil, opts(stub))
  end

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
