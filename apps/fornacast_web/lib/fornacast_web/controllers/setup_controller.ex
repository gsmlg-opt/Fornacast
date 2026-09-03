defmodule FornacastWeb.SetupController do
  use FornacastWeb, :controller

  alias FornacastWeb.SetupHTML

  def new(conn, _params) do
    if Fornacast.Setup.initialized?() do
      already_initialized(conn)
    else
      render_setup(conn, %{}, nil)
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
          |> render_setup(attrs, inspect(changeset.errors))
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
    |> page("Not found", error_panel("Fornacast is already set up."))
  end

  defp render_setup(conn, admin, error) do
    rendered =
      SetupHTML.new(%{
        admin: admin,
        error: error,
        __changed__: nil
      })

    page(
      conn,
      "Set up Fornacast",
      rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end
end
