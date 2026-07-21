defmodule FornacastAPI.UserController do
  use FornacastAPI, :controller

  alias FornacastAPI.{Authentication, Error, Response}

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/users/users#get-the-authenticated-user"

  def authenticated(
        %Plug.Conn{assigns: %{api_auth: %Authentication{actor: actor}}} = conn,
        _params
      ) do
    Response.json(conn, 200, %{login: actor.username})
  end

  def authenticated(conn, _params) do
    Response.error(conn, Error.from_domain(:invalid_credentials, @documentation_url))
  end
end
