defmodule FornacastWeb.SettingsController do
  use FornacastWeb, :controller

  alias FornacastWeb.SettingsHTML

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    rendered =
      SettingsHTML.index(%{
        user: user,
        __changed__: nil
      })

    profile = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    page(conn, "Settings", settings_layout(:profile, profile))
  end
end
