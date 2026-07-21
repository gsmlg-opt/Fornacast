defmodule FornacastAPI.EndpointTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastAPI.Endpoint

  test "health is served without browser state or GitHub policy" do
    conn = get(build_conn(), "/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
    assert Plug.Conn.get_resp_header(conn, "x-github-api-version-selected") == []
    assert Plug.Conn.get_resp_header(conn, "x-ratelimit-limit") == []
  end

  test "health reports degraded when the database is unavailable" do
    conn =
      try do
        assert :ok = Supervisor.terminate_child(Fornacast.Supervisor, Fornacast.Repo)
        get(build_conn(), "/health")
      after
        assert {:ok, _pid} = Supervisor.restart_child(Fornacast.Supervisor, Fornacast.Repo)
      end

    assert %{"status" => "degraded", "checks" => %{"database" => "error"}} =
             json_response(conn, 503)
  end

  test "API application has no web or transport dependency" do
    dependencies =
      :fornacast_api
      |> Application.spec(:applications)
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([:fornacast, :forge_accounts, :forge_repos, :git_core]),
             dependencies
           )

    refute MapSet.member?(dependencies, :fornacast_web)
    refute MapSet.member?(dependencies, :git_transport)
  end

  test "web application does not depend on API" do
    dependencies = :fornacast_web |> Application.spec(:applications) |> MapSet.new()
    refute MapSet.member?(dependencies, :fornacast_api)
  end
end
