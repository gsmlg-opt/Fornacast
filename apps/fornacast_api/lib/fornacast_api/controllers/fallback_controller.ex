defmodule FornacastAPI.FallbackController do
  use FornacastAPI, :controller

  alias FornacastAPI.{Error, Response}

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api"

  def not_found(conn, _params) do
    Response.error(conn, Error.from_domain(:not_found, @documentation_url))
  end
end
