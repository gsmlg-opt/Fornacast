defmodule FornacastWeb.SessionController do
  use FornacastWeb, :controller

  def new(conn, _params) do
    page(conn, "Login", """
    <form action="/login" method="post">
      #{csrf_input()}
      <label>Username <input name="session[username]" autocomplete="username"></label>
      <label>Password <input name="session[password]" type="password" autocomplete="current-password"></label>
      <button type="submit">Login</button>
    </form>
    """)
  end

  def create(conn, %{"session" => %{"username" => username, "password" => password}}) do
    case ForgeAccounts.authenticate_password(username, password) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> redirect(to: "/")

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> page("Login", ~s(<p class="error">Invalid username or password.</p>))
    end
  end

  def create(conn, _params), do: new(conn, %{})

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end
end
