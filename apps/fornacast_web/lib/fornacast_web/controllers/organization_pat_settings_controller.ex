defmodule FornacastWeb.OrganizationPATSettingsController do
  use FornacastWeb, :controller
  alias ForgeImports.PatSyncQueries
  alias ForgeMirrors.PatSettings
  alias FornacastWeb.{OrganizationPATSettingsHTML, RequestMetadata}
  plug :fetch_flash

  def index(conn, params), do: show(conn, params, :index)
  def repositories(conn, params), do: show(conn, params, :repositories)

  def runs(conn, %{"organization" => slug}) do
    actor = conn.assigns.current_user

    with {:ok, organization} <- ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug),
         {:ok, runs} <- PatSyncQueries.list_runs(actor, organization.id) do
      render_task_page(conn, organization, :runs, %{runs: runs})
    else
      _ -> not_found(conn)
    end
  end

  def run(conn, %{"organization" => slug, "run_id" => id}) do
    actor = conn.assigns.current_user

    with {:ok, organization} <- ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug),
         {:ok, run} <- PatSyncQueries.get_run(actor, organization.id, id) do
      render_task_page(conn, organization, :run, %{run: run})
    else
      _ -> not_found(conn)
    end
  end

  def run_status(conn, %{"organization" => slug, "run_id" => id}) do
    actor = conn.assigns.current_user

    if is_nil(actor) do
      conn |> put_status(:unauthorized) |> json(%{error: "login_required"})
    else
      with {:ok, organization} <- ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug),
           {:ok, run} <- PatSyncQueries.get_run(actor, organization.id, id) do
        json(conn, %{run: run, html: task_html(organization, run)})
      else
        _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      end
    end
  end

  defp render_task_page(conn, organization, template, data) do
    assigns = Map.merge(data, %{organization: organization, __changed__: nil})
    html = apply(OrganizationPATSettingsHTML, template, [assigns])

    page(
      conn,
      "#{organization.username} synchronization",
      html |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp task_html(organization, run) do
    OrganizationPATSettingsHTML.task_report(%{
      organization: organization,
      run: run,
      __changed__: nil
    })
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  def save(conn, params), do: mutate(conn, params, :save)
  def selection(conn, params), do: mutate(conn, params, :selection)
  def refresh(conn, params), do: mutate(conn, params, :refresh)
  def git_mirror(conn, params), do: mutate(conn, params, :git_mirror)
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
            :git_mirror ->
              enroll_git_mirrors(actor, organization.id, attrs, metadata)

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
              ForgeImports.OrganizationPatSettings.sync(
                actor,
                organization.id,
                attrs["lock_version"],
                metadata
              )

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
          conn
          |> put_session(:pat_check_result, %{organization_id: organization.id, report: report})
          |> put_status(:see_other)
          |> redirect(to: OrganizationPATSettingsHTML.base(organization))

        {:ok, run} when action == :sync_now ->
          conn
          |> put_status(:see_other)
          |> redirect(to: OrganizationPATSettingsHTML.base(organization) <> "/runs/#{run.id}")

        {:ok, _} ->
          success(conn, organization, action)

        {:error, reason} when action == :check ->
          conn
          |> put_session(:pat_check_result, %{
            organization_id: organization.id,
            error: check_error_message(reason)
          })
          |> put_status(:see_other)
          |> redirect(to: OrganizationPATSettingsHTML.base(organization))

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
            if(action == :check,
              do: check_error_message(reason),
              else: error_message(reason, action)
            )
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
        :git_mirror ->
          "Selected repositories enrolled for bidirectional Git and LFS synchronization."

        :refresh ->
          "Repository list refreshed."

        :sync_now ->
          "Synchronization of all credential-visible organization repositories queued."

        :pause ->
          "Synchronization configuration paused. Active work pauses at its next authorization checkpoint; tasks are not canceled."

        :resume ->
          "Synchronization configuration resumed."

        _ ->
          "GitHub synchronization configuration saved."
      end

    conn
    |> put_flash(:info, message)
    |> put_status(:see_other)
    |> redirect(to: "/organizations/#{organization.username}/settings/github#{suffix}")
  end

  defp render_view(conn, organization, view, template, error, check_result \\ nil) do
    {:ok, runs} = PatSyncQueries.list_runs(conn.assigns.current_user, organization.id)

    {:ok, pat_mirror} =
      ForgeMirrors.pat_git_enrollment_view(conn.assigns.current_user, organization.id)

    latest_run =
      case List.first(runs) do
        nil ->
          nil

        run ->
          {:ok, detail} =
            PatSyncQueries.get_run(conn.assigns.current_user, organization.id, run["id"])

          detail
      end

    feedback = get_session(conn, :pat_check_result)
    feedback = if feedback && feedback.organization_id == organization.id, do: feedback, else: %{}
    conn = delete_session(conn, :pat_check_result)

    html =
      apply(OrganizationPATSettingsHTML, template, [
        %{
          organization: organization,
          view: view,
          pat_mirror: pat_mirror,
          error: error || feedback[:error],
          check_result: check_result || feedback[:report],
          latest_run: latest_run,
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

  defp enroll_git_mirrors(actor, organization_id, attrs, metadata) do
    with true <- Enum.sort(Map.keys(attrs)) == ["lock_version", "repository_ids"],
         {:ok, version} <- positive_id(attrs["lock_version"]),
         values when is_list(values) and length(values) <= 101 <- attrs["repository_ids"],
         {:ok, ids} <- repository_ids(Enum.reject(values, &(&1 == ""))),
         true <- ids != [] do
      ForgeMirrors.enroll_pat_git_repositories(actor, organization_id, version, ids, metadata)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp repository_ids(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case positive_id(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> {:error, :invalid_request}
    end
  end

  defp positive_id(_), do: {:error, :invalid_request}

  defp error_message(:stale), do: "The configuration changed. Refresh and try again."

  defp error_message(:invalid_request),
    do: "Check the source organization, owner, credential and repository selection."

  defp error_message(:credential_unavailable),
    do: "Select a valid saved credential belonging to an active organization owner."

  defp error_message(:paused), do: "Synchronization is paused. Resume it before syncing."

  defp error_message(:legacy_sync_active),
    do:
      "Wait for the active synchronization task to finish before enabling bidirectional Git and LFS."

  defp error_message(:unverified_import),
    do:
      "Select repositories imported into this organization with the configured saved credential."

  defp error_message(:already_bound),
    do: "A selected repository or organization already has a different mirror connection."

  defp error_message(:not_enabled), do: "Enable the GitHub mirror before syncing."

  defp error_message(:reauthorization_required),
    do: "Reconnect the saved account in Settings → GitHub, then try again."

  defp error_message(:refresh_in_progress),
    do: "The GitHub credential is being renewed. Try again shortly."

  defp error_message(:invalid_credential),
    do: "GitHub rejected this credential. Reconnect GitHub or replace the saved credential."

  defp error_message(:credential_invalid),
    do: "The saved credential is invalid or expired. Re-verify or replace it."

  defp error_message(:forbidden),
    do:
      "This credential cannot access the GitHub organization. Check owner permissions and organization access."

  defp error_message(:not_found),
    do: "GitHub organization was not found for this credential. Check the organization name."

  defp error_message(:host_unavailable),
    do: "The GitHub API host could not be resolved. Check network access."

  defp error_message(:transport),
    do: "The GitHub API request could not be completed. Check network access."

  defp error_message(:timeout), do: "The GitHub API request timed out. Try again."

  defp error_message(:credential_service_unavailable),
    do:
      "The saved credential could not be opened. The credential service is unavailable; try again."

  defp error_message(:request_gate_busy),
    do: "The saved credential is already being checked by another request. Try again."

  defp error_message(:invalid_response),
    do: "GitHub returned an invalid response while checking this organization."

  defp error_message(:unsafe_credential_result),
    do:
      "The saved credential service returned an unsafe result. Reconnect GitHub or re-save the PAT and try again."

  defp error_message(:unavailable),
    do:
      "The credential or GitHub check service is unavailable. Verify the saved credential and try again."

  defp error_message(reason) when reason in [:repository_sync_failed, :import_failed],
    do:
      "Could not synchronize repositories. Check the saved credential and GitHub access, then try again."

  defp error_message(_), do: nil

  defp error_message(reason, action) do
    error_message(reason) ||
      if action == :sync_now do
        "Could not start synchronization. Check the owner’s credential and GitHub access, then try again."
      else
        "Could not refresh the repository list. Check the owner’s credential and GitHub access, then try again."
      end
  end

  defp check_error_message(reason) when is_atom(reason),
    do: "Configuration check failed (#{reason})."
end
