defmodule FornacastWeb.OrganizationPATSettingsController do
  use FornacastWeb, :controller
  alias ForgeMirrors.PatSettings
  alias FornacastWeb.{OrganizationPATSettingsHTML, RequestMetadata}
  plug :fetch_flash

  def index(conn, params), do: show(conn, params, :index)
  def repositories(conn, params), do: show(conn, params, :repositories)

  def save(conn, params), do: mutate(conn, params, :save)
  def selection(conn, params), do: mutate(conn, params, :selection)
  def refresh(conn, params), do: mutate(conn, params, :refresh)
  def sync_now(conn, params), do: mutate(conn, params, :sync_now)
  def check(conn, params), do: mutate(conn, params, :check)
  def pause(conn, params), do: mutate(conn, params, :pause)
  def resume(conn, params), do: mutate(conn, params, :resume)

  defp show(conn, %{"organization" => slug}, template) do
    actor = conn.assigns.current_user

    with {:ok, organization} <- ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug),
         {:ok, view} <- PatSettings.view(actor, organization.id) do
      render_view(conn, organization, view, template, nil)
    else
      {:error, _} -> not_found(conn)
    end
  end

  defp mutate(conn, %{"organization" => slug} = params, action) do
    actor = conn.assigns.current_user

    with {:ok, organization} <- ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug) do
      attrs = params["pat_sync"] || %{}

      result =
        if is_map(attrs) do
          metadata = RequestMetadata.from_conn(conn)

          case action do
            :save ->
              PatSettings.save(actor, organization.id, attrs, metadata)

            :selection ->
              PatSettings.select_repositories(actor, organization.id, attrs, metadata)

            :refresh ->
              ForgeImports.OrganizationPatSettings.refresh(
                actor,
                organization.id,
                attrs["lock_version"],
                metadata
              )

            :sync_now ->
              with {:ok, %{config: config}} <- PatSettings.view(actor, organization.id),
                   false <- config.paused,
                   true <- config.enabled,
                   {:ok, _} <- PatSettings.mark_sync(actor, organization.id, "running", metadata),
                   result <-
                     ForgeImports.OrganizationPatSettings.refresh(
                       actor,
                       organization.id,
                       attrs["lock_version"],
                       metadata
                     ),
                   {:ok, _} <-
                     PatSettings.mark_sync(
                       actor,
                       organization.id,
                       if(result == :ok, do: "succeeded", else: "failed"),
                       metadata
                     ) do
                result
              else
                true -> {:error, :paused}
                false -> {:error, :not_enabled}
                {:error, reason} -> {:error, reason}
              end

            :check ->
              ForgeImports.OrganizationPatSettings.check(actor, organization.id)

            :pause ->
              PatSettings.set_paused(actor, organization.id, true, metadata)

            :resume ->
              PatSettings.set_paused(actor, organization.id, false, metadata)
          end
        else
          {:error, :invalid_request}
        end

      case result do
        :ok ->
          success(conn, organization, action)

        {:ok, report} when action == :check ->
          {:ok, view} = PatSettings.view(actor, organization.id)
          render_view(conn, organization, view, :index, nil, report)

        {:ok, _} ->
          success(conn, organization, action)

        {:error, reason} ->
          {:ok, view} = PatSettings.view(actor, organization.id)
          status = if reason == :stale, do: :conflict, else: :unprocessable_entity

          template =
            if action in [:save, :pause, :resume, :check], do: :index, else: :repositories

          conn
          |> put_status(status)
          |> render_view(
            organization,
            view,
            template,
            if(action == :check, do: check_error_message(reason), else: error_message(reason))
          )
      end
    else
      {:error, _} -> not_found(conn)
    end
  end

  defp success(conn, organization, action) do
    suffix = if action in [:save, :pause, :resume], do: "", else: "/repositories"

    message =
      case action do
        :refresh -> "Repository list refreshed."
        :sync_now -> "Synchronization completed."
        :pause -> "Synchronization paused."
        :resume -> "Synchronization resumed."
        _ -> "PAT synchronization configuration saved."
      end

    conn
    |> put_flash(:info, message)
    |> put_status(:see_other)
    |> redirect(to: "/organizations/#{organization.username}/settings/github#{suffix}")
  end

  defp render_view(conn, organization, view, template, error, check_result \\ nil) do
    html =
      apply(OrganizationPATSettingsHTML, template, [
        %{
          organization: organization,
          view: view,
          error: error,
          check_result: check_result,
          flash: Phoenix.Flash.get(conn.assigns.flash, :info),
          __changed__: nil
        }
      ])

    page(
      conn,
      "#{organization.username} GitHub settings",
      html |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp not_found(conn),
    do:
      conn
      |> put_status(:not_found)
      |> page("GitHub settings", "Organization settings not found.")

  defp error_message(:stale), do: "The configuration changed. Refresh and try again."

  defp error_message(:invalid_request),
    do: "Check the source organization, owner, PAT and repository selection."

  defp error_message(:credential_unavailable),
    do: "Select a valid saved PAT belonging to an active organization owner."

  defp error_message(:paused), do: "Synchronization is paused. Resume it before syncing."
  defp error_message(:not_enabled), do: "Enable the GitHub mirror before syncing."

  defp error_message(:invalid_credential),
    do: "GitHub rejected this PAT. Re-verify or replace the saved PAT."

  defp error_message(:credential_invalid),
    do: "The saved PAT is invalid or expired. Re-verify or replace it."

  defp error_message(:forbidden),
    do:
      "This PAT cannot access the GitHub organization. Check owner permissions and organization access."

  defp error_message(:not_found),
    do: "GitHub organization was not found for this PAT. Check the organization name."

  defp error_message(:host_unavailable),
    do: "The GitHub API host could not be resolved. Check network access."

  defp error_message(:transport),
    do: "The GitHub API request could not be completed. Check network access."

  defp error_message(:timeout), do: "The GitHub API request timed out. Try again."

  defp error_message(:credential_service_unavailable),
    do: "The saved PAT could not be opened. The credential service is unavailable; try again."

  defp error_message(:request_gate_busy),
    do: "The saved PAT is already being checked by another request. Try again."

  defp error_message(:invalid_response),
    do: "GitHub returned an invalid response while checking this organization."

  defp error_message(:unsafe_credential_result),
    do:
      "The saved PAT credential service returned an unsafe result. Re-save the PAT and try again."

  defp error_message(:unavailable),
    do: "The PAT or GitHub check service is unavailable. Verify the saved PAT and try again."

  defp error_message(_),
    do:
      "Could not refresh the repository list. Check the owner’s PAT and GitHub access, then try again."

  defp check_error_message(reason) when is_atom(reason),
    do: "Configuration check failed (#{reason})."
end
