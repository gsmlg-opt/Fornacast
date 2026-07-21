defmodule FornacastAPI.MetaController do
  use FornacastAPI, :controller

  def versions(conn, _params) do
    FornacastAPI.Response.json(conn, 200, ["2022-11-28", "2026-03-10"])
  end

  def rate_limit(conn, _params) do
    bucket = Map.fetch!(conn.assigns, :rate_limit_bucket)
    body = FornacastAPI.Serializer.render(conn.assigns.api_version, :rate_limit, bucket)

    FornacastAPI.Response.json(conn, 200, body)
  end
end
