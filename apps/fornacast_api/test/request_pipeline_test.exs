defmodule FornacastAPI.RequestPipelineTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint FornacastAPI.Endpoint
  @user_agent {"user-agent", "fornacast-contract-test/1.0"}

  defp put_req_header(conn, {name, value}), do: put_req_header(conn, name, value)

  test "missing version selects 2022 and returns common headers" do
    conn = build_conn() |> put_req_header(@user_agent) |> get("/api/v3/versions")

    assert json_response(conn, 200) == ["2022-11-28", "2026-03-10"]
    assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
    assert get_resp_header(conn, "x-github-media-type") == ["github.v3; format=json"]
    assert [request_id] = get_resp_header(conn, "x-github-request-id")
    assert request_id != ""
  end

  test "request metadata preserves only the assigned effective client IP" do
    ip_address = {203, 0, 113, 9}

    assigned_metadata =
      build_conn()
      |> assign(:effective_client_ip, ip_address)
      |> FornacastAPI.Plugs.RequestContext.metadata()

    assert %{ip_address: ^ip_address} = assigned_metadata
    refute Map.has_key?(assigned_metadata, :client_ip)

    unassigned_conn = %{build_conn() | remote_ip: {198, 51, 100, 7}}
    assert %{ip_address: nil} = FornacastAPI.Plugs.RequestContext.metadata(unassigned_conn)
  end

  test "explicit supported version is selected" do
    conn =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("x-github-api-version", "2026-03-10")
      |> get("/api/v3/versions")

    assert json_response(conn, 200) == ["2022-11-28", "2026-03-10"]
    assert get_resp_header(conn, "x-github-api-version-selected") == ["2026-03-10"]
  end

  test "unsupported version is a GitHub-shaped 400" do
    conn =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("x-github-api-version", "2099-01-01")
      |> get("/api/v3/versions")

    assert %{"message" => "Bad Request", "documentation_url" => documentation_url} =
             json_response(conn, 400)

    assert documentation_url =~ "/rest/about-the-rest-api/api-versions"
  end

  test "missing and blank User-Agent are rejected" do
    for headers <- [[], [{"user-agent", "   "}]] do
      conn =
        Enum.reduce(headers, build_conn(), fn {name, value}, acc ->
          put_req_header(acc, name, value)
        end)

      conn = get(conn, "/api/v3/versions")
      assert json_response(conn, 403)["message"] == "User agent required"
    end
  end

  test "Accept negotiation allows GitHub and JSON media and rejects diff" do
    for media <- ["application/vnd.github+json", "application/json", "*/*"] do
      conn =
        build_conn()
        |> put_req_header(@user_agent)
        |> put_req_header("accept", media)
        |> get("/api/v3/versions")

      assert response(conn, 200)
    end

    rejected =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("accept", "application/vnd.github.diff")
      |> get("/api/v3/versions")

    assert json_response(rejected, 406)["message"] == "Not Acceptable"
  end

  test "Accept exact exclusions override a positive wildcard" do
    conn =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header(
        "accept",
        "application/json;q=0, application/vnd.github+json;q=0, */*;q=1"
      )
      |> get("/api/v3/versions")

    assert json_response(conn, 406)["message"] == "Not Acceptable"
    assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
  end

  test "unknown API and upload paths use the same sanitized 404" do
    for path <- ["/api/v3/not-a-resource", "/api/uploads/not-a-resource"] do
      conn = build_conn() |> put_req_header(@user_agent) |> get(path)
      assert json_response(conn, 404)["message"] == "Not Found"
      assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
    end
  end

  test "bodyless DELETE reaches the sanitized fallback without a content type" do
    conn =
      build_conn()
      |> put_req_header(@user_agent)
      |> delete("/api/v3/repos/octo/example/issues/comments/1")

    assert json_response(conn, 404)["message"] == "Not Found"
    assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
  end

  test "DELETE with declared body metadata requires a supported JSON content type" do
    path = "/api/v3/repos/octo/example/contents/README.md"

    for {header, value} <- [
          {"content-length", "2"},
          {"transfer-encoding", "chunked"}
        ] do
      conn =
        build_conn()
        |> put_req_header(@user_agent)
        |> put_req_header(header, value)
        |> delete(path)

      assert json_response(conn, 415)["message"] == "Unsupported Media Type"
      assert get_resp_header(conn, "x-github-api-version-selected") == ["2022-11-28"]
    end

    accepted =
      build_conn()
      |> put_req_header(@user_agent)
      |> put_req_header("content-length", "2")
      |> put_req_header("content-type", "application/json")
      |> delete(path)

    assert json_response(accepted, 404)["message"] == "Not Found"
  end

  test "duplicate keys and malformed JSON are rejected" do
    for {body, reason} <- [
          {~s({"name":"one","name":"two"}), :duplicate_key},
          {~s({"name":), :malformed_json}
        ] do
      conn = Plug.Test.conn("POST", "/", body)
      conn = put_req_header(conn, "content-type", "application/json")

      assert {:error, %FornacastAPI.Error{status: 400}, ^reason, _conn} =
               FornacastAPI.RequestBody.read_json(conn, :ordinary, [])
    end
  end

  test "oversized Content-Length is rejected before body read" do
    conn =
      Plug.Test.conn("POST", "/", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-length", "1048577")

    assert {:error, %FornacastAPI.Error{status: 413}, :request_too_large, _conn} =
             FornacastAPI.RequestBody.read_json(conn, :ordinary, [])
  end

  test "request target over 8 KiB is rejected" do
    path = "/api/v3/" <> String.duplicate("a", 8_193)
    conn = build_conn() |> put_req_header(@user_agent) |> get(path)
    assert json_response(conn, 414)["message"] == "URI Too Long"
  end
end
