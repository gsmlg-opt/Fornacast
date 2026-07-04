defmodule FornacastWeb.SetupController do
  use FornacastWeb, :controller

  def new(conn, _params) do
    if Fornacast.Setup.initialized?() do
      already_initialized(conn)
    else
      page(conn, "Set up Fornacast", form_body())
    end
  end

  def create(conn, %{"admin" => attrs}) do
    if Fornacast.Setup.initialized?() do
      already_initialized(conn)
    else
      case ForgeAccounts.create_first_admin(sanitize(attrs)) do
        {:ok, user} ->
          Fornacast.Setup.mark_initialized!(user)
          redirect(conn, to: "/login")

        {:error, :admin_exists} ->
          Fornacast.Setup.mark_initialized!(%{id: nil})
          already_initialized(conn)

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> page("Set up Fornacast", error_body(changeset))
      end
    end
  end

  def create(conn, _params), do: new(conn, %{})

  defp sanitize(attrs) do
    %{
      username: Map.get(attrs, "username"),
      email: Map.get(attrs, "email"),
      password: Map.get(attrs, "password")
    }
  end

  defp already_initialized(conn) do
    conn
    |> put_status(:not_found)
    |> page("Not found", ~s(<p class="error">Fornacast is already set up.</p>))
  end

  defp form_body do
    """
    <p class="muted">Create the first administrator account to finish setting up this Fornacast instance.</p>
    <form action="/setup" method="post">
      #{csrf_input()}
      <label>Username <input name="admin[username]" autocomplete="username"></label>
      <label>Email <input name="admin[email]" type="email" autocomplete="email"></label>
      <label>Password <input name="admin[password]" type="password" autocomplete="new-password"></label>
      <button type="submit">Create admin</button>
    </form>
    """
  end

  defp error_body(changeset) do
    form_body() <> ~s(<p class="error">#{escape(inspect(changeset.errors))}</p>)
  end
end
