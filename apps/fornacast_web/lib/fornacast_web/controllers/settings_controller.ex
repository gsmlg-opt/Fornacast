defmodule FornacastWeb.SettingsController do
  use FornacastWeb, :controller

  alias FornacastWeb.{SettingsHTML, UserSession}

  plug :fetch_flash

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    rendered =
      SettingsHTML.index(%{
        user: user,
        __changed__: nil
      })

    profile = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    page(conn, "Settings", settings_layout(:profile, profile))
  end

  def appearance(conn, _params), do: render_appearance(conn)

  def update_appearance(conn, params) do
    attrs =
      case params do
        %{"appearance" => attrs} when is_map(attrs) -> attrs
        _params -> %{}
      end

    case UserSession.save_appearance(conn, attrs) do
      {:ok, conn} ->
        conn
        |> put_flash(:info, "Appearance settings saved.")
        |> put_status(:see_other)
        |> redirect(to: "/settings/appearance")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_appearance(["Choose Auto, Sunshine, or Moonlight."])

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> page("Appearance", error_panel("Appearance settings cannot be updated."))

      {:error, _reason} ->
        appearance_unavailable(conn)
    end
  end

  defp render_appearance(conn, errors \\ []) do
    rendered =
      SettingsHTML.appearance(%{
        theme_preference: conn.assigns.current_user.theme_preference,
        errors: errors,
        flash: Phoenix.Flash.get(conn.assigns.flash, :info),
        csrf_token: Plug.CSRFProtection.get_csrf_token(),
        __changed__: nil
      })

    content = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    page(conn, "Appearance", settings_layout(:appearance, content))
  end

  defp appearance_unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> page("Appearance", error_panel("Appearance settings are temporarily unavailable."))
  end
end
