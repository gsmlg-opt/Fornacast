defmodule FornacastAPI.Plugs.APIVersion do
  import Plug.Conn

  alias FornacastAPI.{Error, Response}

  @supported_versions ["2022-11-28", "2026-03-10"]
  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/about-the-rest-api/api-versions"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "x-github-api-version") do
      [] ->
        conn

      [version] when version in @supported_versions ->
        assign(conn, :api_version, version)

      _unsupported_or_multiple ->
        conn
        |> Response.error(Error.new(400, "Bad Request", @documentation_url))
        |> halt()
    end
  end
end
