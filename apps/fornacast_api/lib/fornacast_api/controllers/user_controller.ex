defmodule FornacastAPI.UserController do
  use FornacastAPI, :controller

  alias FornacastAPI.{Authentication, Error, Response, Serializer}

  @authenticated_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/users/users#get-the-authenticated-user"
  @public_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/users/users#get-a-user"

  def authenticated(
        %Plug.Conn{
          assigns: %{
            api_auth: %Authentication{actor: actor, api_key: api_key},
            api_version: version
          }
        } = conn,
        _params
      ) do
    case ForgeAccounts.APIScope.authorize(api_key, :identity_read, nil) do
      :ok ->
        body = version |> Serializer.render(:private_user, ForgeRepos.account_view(actor, actor))
        Response.json(conn, 200, body, accepted_scopes: [])

      {:error, reason} ->
        render_error(conn, reason, @authenticated_documentation_url)
    end
  end

  def authenticated(conn, _params) do
    render_error(conn, :invalid_credentials, @authenticated_documentation_url)
  end

  def show(conn, %{"username" => username}) do
    with {:ok, user} <- ForgeAccounts.get_public_user(username) do
      actor = optional_actor(conn.assigns[:api_auth])
      view = ForgeRepos.account_view(actor, user)
      body = Serializer.render(conn.assigns.api_version, :public_user, view)
      Response.json(conn, 200, body, accepted_scopes: [])
    else
      {:error, reason} -> render_error(conn, reason, @public_documentation_url)
    end
  end

  defp optional_actor(%Authentication{actor: actor}), do: actor
  defp optional_actor(_api_auth), do: nil

  defp render_error(conn, reason, documentation_url) do
    error = %{Error.from_domain(reason, documentation_url) | accepted_scopes: []}
    Response.error(conn, error)
  end
end
