defmodule FornacastAPI.Plugs.UserAgent do
  import Plug.Conn

  alias FornacastAPI.{Error, Response}

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api#user-agent-required"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "user-agent") do
      [user_agent] when is_binary(user_agent) ->
        if String.trim(user_agent) == "", do: reject(conn), else: conn

      _missing_or_multiple ->
        reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> Response.error(Error.new(403, "User agent required", @documentation_url))
    |> halt()
  end
end
