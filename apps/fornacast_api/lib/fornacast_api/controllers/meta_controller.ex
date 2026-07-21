defmodule FornacastAPI.MetaController do
  use FornacastAPI, :controller

  def versions(conn, _params) do
    FornacastAPI.Response.json(conn, 200, ["2022-11-28", "2026-03-10"])
  end

  def rate_limit(conn, _params) do
    bucket = Map.fetch!(conn.assigns, :rate_limit_bucket)

    resources = %{
      core: %{
        limit: bucket.limit,
        remaining: bucket.remaining,
        reset: bucket.reset,
        used: bucket.used,
        resource: bucket.resource
      }
    }

    body =
      case conn.assigns.api_version do
        "2022-11-28" -> %{resources: resources, rate: resources.core}
        "2026-03-10" -> %{resources: resources}
      end

    FornacastAPI.Response.json(conn, 200, body)
  end
end
