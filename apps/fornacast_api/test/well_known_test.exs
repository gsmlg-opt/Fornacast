defmodule FornacastAPI.WellKnownTest do
  use FornacastAPI.ConnCase, async: false

  test "GET /.well-known/fornacast is public and returns configured absolute URLs" do
    conn = get(build_conn(), "/.well-known/fornacast")
    body = json_response(conn, 200)

    base = Fornacast.Config.base_url()

    assert body == %{
             "version" => 1,
             "base_url" => base,
             "api_v3" => base <> "/api/v3",
             "api_graphql" => base <> "/api/graphql",
             "api_uploads" => base <> "/api/uploads"
           }

    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
  end

  test "discovery URLs ignore the request Host header" do
    conn =
      %{build_conn() | host: "evil.example"}
      |> get("/.well-known/fornacast")

    body = json_response(conn, 200)
    refute body["base_url"] =~ "evil.example"
    assert body["api_graphql"] == FornacastAPI.URL.graphql()
  end
end
