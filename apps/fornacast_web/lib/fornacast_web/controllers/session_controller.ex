defmodule FornacastWeb.SessionController do
  use FornacastWeb, :controller

  alias FornacastWeb.{SessionHTML, UserSession}

  def new(conn, _params) do
    render_login(conn, nil, "")
  end

  def create(conn, %{"session" => %{"username" => username, "password" => password}}) do
    case ForgeAccounts.authenticate_password(username, password) do
      {:ok, user} ->
        case UserSession.log_in(conn, user) do
          {:ok, conn} -> redirect(conn, to: "/")
          {:error, _reason} -> send_resp(conn, 503, "Session temporarily unavailable.")
        end

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> render_login("Invalid username or password.", username)
    end
  end

  def create(conn, _params), do: new(conn, %{})

  def delete(conn, _params) do
    case UserSession.log_out(conn) do
      {:ok, conn} -> conn |> configure_session(drop: true) |> redirect(to: "/login")
      {:error, _reason} -> send_resp(conn, 503, "Session temporarily unavailable.")
    end
  end

  defp render_login(conn, error, username) do
    rendered =
      SessionHTML.new(%{
        error: error,
        username: username,
        __changed__: nil
      })

    page(conn, "Login", rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary())
  end
end
