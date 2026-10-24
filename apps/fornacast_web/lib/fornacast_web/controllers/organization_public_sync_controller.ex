defmodule FornacastWeb.OrganizationPublicSyncController do
  use FornacastWeb, :controller
  alias FornacastWeb.{OrganizationPublicSyncHTML, RequestMetadata}
  plug :fetch_flash
  plug :put_private_no_store

  def index(conn, params) do
    with {:ok, organization} <- organization(conn, params),
         {:ok, view} <- service(conn).view(conn.assigns.current_user, organization.id) do
      render_view(conn, organization, view, nil)
    else
      _ -> not_found(conn)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  def save(conn, params), do: mutate(conn, params, :save)
  def sync(conn, params), do: mutate(conn, params, :sync)

  defp mutate(conn, params, action) do
    with {:ok, organization} <- organization(conn, params) do
      attrs = params["public_sync"]

      fields =
        if action == :save, do: ~w(github_organization lock_version), else: ~w(lock_version)

      result =
        if is_map(attrs) and Enum.sort(Map.keys(attrs)) == fields do
          metadata = RequestMetadata.from_conn(conn)

          case action do
            :save ->
              service(conn).configure(conn.assigns.current_user, organization.id, attrs, metadata)

            :sync ->
              service(conn).sync(
                conn.assigns.current_user,
                organization.id,
                attrs["lock_version"],
                metadata
              )
          end
        else
          {:error, :invalid_request}
        end

      case result do
        {:ok, %{id: id}} when action == :sync and is_integer(id) and id > 0 ->
          conn
          |> put_status(:see_other)
          |> redirect(to: "/organizations/#{organization.username}/settings/github/runs/#{id}")

        {:ok, _} when action == :save ->
          conn
          |> put_flash(:info, "Public synchronization configuration saved.")
          |> put_status(:see_other)
          |> redirect(to: OrganizationPublicSyncHTML.base(organization))

        {:error, reason} ->
          with {:ok, view} <- service(conn).view(conn.assigns.current_user, organization.id) do
            conn
            |> put_status(error_status(reason))
            |> render_view(organization, view, message(reason))
          else
            _ -> not_found(conn)
          end

        _ ->
          unavailable(conn)
      end
    else
      _ -> not_found(conn)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  defp organization(conn, %{"organization" => slug}),
    do: ForgeAccounts.fetch_manageable_organization_by_slug(conn.assigns.current_user, slug)

  defp organization(_, _), do: {:error, :not_found}

  defp render_view(conn, organization, view, error) do
    html =
      OrganizationPublicSyncHTML.index(%{
        organization: organization,
        config: view.config,
        error: error,
        flash: Phoenix.Flash.get(conn.assigns.flash, :info),
        __changed__: nil
      })

    page(
      conn,
      "#{organization.username} public synchronization",
      html |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp service(conn),
    do: conn.private[:organization_public_sync] || ForgeImports.OrganizationPublicSync

  defp not_found(conn),
    do:
      conn
      |> put_status(:not_found)
      |> page("Public synchronization", "Organization settings not found.")

  defp message(:stale), do: "The configuration changed. Refresh and try again."

  defp message(reason) when reason in [:busy, :legacy_sync_active],
    do: "Wait for the active synchronization to finish before changing its source."

  defp message(reason) when reason in [:rate_limited, :primary_rate_limit, :secondary_rate_limit],
    do:
      "GitHub's anonymous API rate limit was reached. Try again after the limit resets, or connect the GitHub App."

  defp message(:paused), do: "Synchronization is paused. Resume it before synchronizing."
  defp message(:not_found), do: "The public GitHub organization was not found."

  defp message(_),
    do: "Could not update public synchronization. Check the organization and try again."

  defp error_status(reason) when reason in [:stale, :busy, :legacy_sync_active], do: :conflict

  defp error_status(reason)
       when reason in [:rate_limited, :primary_rate_limit, :secondary_rate_limit],
       do: :too_many_requests

  defp error_status(_), do: :unprocessable_entity

  defp put_private_no_store(conn, _opts),
    do: put_resp_header(conn, "cache-control", "private, no-store")

  defp unavailable(conn),
    do:
      conn
      |> assign(:current_user, nil)
      |> put_status(:service_unavailable)
      |> page(
        "Public synchronization",
        "Public synchronization is temporarily unavailable. Try again."
      )
end
