defmodule FornacastAPI.WellKnownController do
  use FornacastAPI, :controller

  alias FornacastAPI.URL

  def fornacast(conn, _params) do
    json(conn, %{
      version: 1,
      base_url: Fornacast.Config.base_url(),
      api_v3: URL.api_v3(),
      api_graphql: URL.graphql(),
      api_uploads: URL.uploads()
    })
  end
end
