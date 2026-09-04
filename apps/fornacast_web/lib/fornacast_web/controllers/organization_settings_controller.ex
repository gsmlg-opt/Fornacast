defmodule FornacastWeb.OrganizationSettingsController do
  use FornacastWeb, :controller

  alias FornacastWeb.OrganizationSettingsHTML

  def index(
        %Plug.Conn{assigns: %{current_user: actor}} = conn,
        %{"organization" => organization_slug}
      ) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization_by_slug(actor, organization_slug),
         {:ok, %{} = view} <- organization_sync(conn).get_settings(actor, organization) do
      rendered =
        OrganizationSettingsHTML.index(%{
          organization: organization,
          view: Map.put(view, :organization, organization),
          __changed__: nil
        })

      page(
        conn,
        "#{organization.display_name || organization.username} settings",
        rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      )
    else
      {:error, reason} -> render_error(conn, reason)
      _unexpected -> render_error(conn, :unavailable)
    end
  end

  defp render_error(conn, reason) when reason in [:not_found, :forbidden] do
    conn
    |> put_status(:not_found)
    |> page("Organization settings", error_panel("Organization settings not found."))
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:service_unavailable)
    |> page(
      "Organization settings",
      error_panel("Organization settings are temporarily unavailable.")
    )
  end

  defp organization_sync(conn),
    do: conn.private[:github_organization_sync] || ForgeImports.OrganizationSync
end
