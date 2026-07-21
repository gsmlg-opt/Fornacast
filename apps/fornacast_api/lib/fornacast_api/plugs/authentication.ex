defmodule FornacastAPI.Plugs.Authentication do
  import Plug.Conn

  alias FornacastAPI.{Authentication, Error, Response}

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/authentication/authenticating-to-the-rest-api"
  @authorization ~r/^(?:bearer|token)[ \t]+(\S+)\z/i

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      [] -> conn
      [authorization] -> authenticate(conn, authorization)
      _headers -> bad_credentials(conn)
    end
  end

  defp authenticate(conn, authorization) do
    with [secret] <- Regex.run(@authorization, authorization, capture: :all_but_first),
         {:ok, actor, api_key} <- ForgeAccounts.authenticate_api_key(secret) do
      assign(conn, :api_auth, %Authentication{actor: actor, api_key: api_key})
    else
      _invalid -> bad_credentials(conn)
    end
  end

  defp bad_credentials(conn) do
    conn
    |> Response.error(Error.from_domain(:invalid_credentials, @documentation_url))
    |> halt()
  end
end
