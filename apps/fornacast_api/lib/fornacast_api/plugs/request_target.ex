defmodule FornacastAPI.Plugs.RequestTarget do
  import Plug.Conn

  alias FornacastAPI.{Error, Response}

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api"

  def init(opts), do: opts

  def call(conn, _opts) do
    maximum_bytes =
      Application.get_env(:fornacast_api, :request_target_max_bytes, 8_192)

    if api_path?(conn.request_path) and target_size(conn) > maximum_bytes do
      conn
      |> Response.error(Error.new(414, "URI Too Long", @documentation_url))
      |> halt()
    else
      conn
    end
  end

  defp target_size(%{request_path: request_path, query_string: ""}) do
    byte_size(request_path)
  end

  defp target_size(%{request_path: request_path, query_string: query_string}) do
    byte_size(request_path) + 1 + byte_size(query_string)
  end

  defp api_path?(path) do
    path == "/api/v3" or String.starts_with?(path, "/api/v3/") or
      path == "/api/uploads" or String.starts_with?(path, "/api/uploads/")
  end
end
