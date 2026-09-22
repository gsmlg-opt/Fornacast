defmodule FornacastWeb.OrganizationSettingsController do
  use FornacastWeb, :controller

  alias FornacastWeb.{OrganizationSettingsHTML, RequestMetadata}

  plug :fetch_flash

  def index(
        %Plug.Conn{assigns: %{current_user: actor}} = conn,
        %{"organization" => organization_slug}
      ) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization_by_slug(actor, organization_slug) do
      render_settings(conn, organization)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def update(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, organization} <- manageable_organization(actor, params),
         {:ok, attrs} <- organization_params(params),
         result <-
           ForgeAccounts.update_organization(
             actor,
             organization,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      handle_update_result(conn, organization, attrs, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp handle_update_result(conn, organization, _attrs, {:ok, _updated}) do
    conn
    |> put_flash(:info, "Organization settings saved.")
    |> put_status(:see_other)
    |> redirect(to: settings_path(organization))
  end

  defp handle_update_result(conn, organization, attrs, {:error, {:validation, errors}})
       when is_list(errors) do
    if unavailable_errors?(errors) do
      render_error(conn, :unavailable)
    else
      render_validation_error(conn, organization, attrs, errors)
    end
  end

  defp handle_update_result(conn, _organization, _attrs, {:error, reason}),
    do: render_error(conn, reason)

  defp render_validation_error(conn, organization, attrs, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_settings(organization, attrs, errors)
  end

  defp render_settings(conn, organization, form \\ nil, errors \\ []) do
    form =
      form || %{"name" => organization.display_name, "description" => organization.description}

    rendered =
      OrganizationSettingsHTML.index(%{
        organization: organization,
        form: form,
        errors: errors,
        flash: Phoenix.Flash.get(conn.assigns.flash, :info),
        __changed__: nil
      })

    page(
      conn,
      "#{organization.display_name || organization.username} settings",
      rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp render_error(conn, reason) when reason in [:not_found, :forbidden] do
    conn
    |> put_status(:not_found)
    |> page("Organization settings", error_panel("Organization settings not found."))
  end

  defp render_error(conn, :invalid_request) do
    conn
    |> put_status(:bad_request)
    |> page("Organization settings", error_panel("Organization settings request is invalid."))
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:service_unavailable)
    |> page(
      "Organization settings",
      error_panel("Organization settings are temporarily unavailable.")
    )
  end

  defp manageable_organization(actor, %{"organization_slug" => slug}) when is_binary(slug),
    do: ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug)

  defp manageable_organization(_actor, _params), do: {:error, :not_found}

  defp organization_params(%{"organization" => attrs}) when is_map(attrs),
    do: {:ok, Map.take(attrs, ["name", "description"])}

  defp organization_params(_params), do: {:error, :invalid_request}

  defp settings_path(organization), do: "/organizations/#{organization.username}/settings"

  defp unavailable_errors?(errors) do
    Enum.any?(errors, fn
      %{resource: "Organization", field: "base", code: :unprocessable} -> true
      _error -> false
    end)
  end
end
