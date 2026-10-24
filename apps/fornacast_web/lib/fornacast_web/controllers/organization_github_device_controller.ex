defmodule FornacastWeb.OrganizationGitHubDeviceController do
  use FornacastWeb, :controller

  alias FornacastWeb.{
    OrganizationGitHubDeviceSession,
    OrganizationGitHubConnectionHTML,
    RequestMetadata
  }

  plug :fetch_flash

  def index(conn, params), do: show(conn, params, :index)
  def connection(conn, params), do: show(conn, params, :connection)

  def create(conn, params) do
    with {:ok, organization} <- organization(conn, params),
         {:ok, expected} <- service(conn).reference(conn.assigns.current_user, organization.id),
         {:ok, id} <- OrganizationGitHubDeviceSession.run(conn, organization.id, :begin) do
      result =
        with {:ok, grant} <- provider(conn).start(client_id: provider(conn).client_id()) do
          references = %{
            actor_id: conn.assigns.current_user.id,
            organization_id: organization.id,
            expected: expected
          }

          OrganizationGitHubDeviceSession.run(
            conn,
            organization.id,
            {:authorize, id, grant, provider(conn).client_id(), references}
          )
        end

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          OrganizationGitHubDeviceSession.run(
            conn,
            organization.id,
            {:fail, id, safe_reason(reason)}
          )
      end

      redirect_connection(conn, organization)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def poll(conn, %{"attempt_id" => id} = params) do
    result =
      with {:ok, organization} <- organization(conn, params) do
        case OrganizationGitHubDeviceSession.run(conn, organization.id, {:claim, id}) do
          {:ok, claim} -> exchange(conn, organization, id, claim)
          {:wait, interval} -> {:ok, %{status: "pending", interval: interval}}
          {:done, :complete} -> {:ok, complete(organization)}
          {:error, reason} -> {:error, reason}
        end
      end

    case result do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{status: "failed", message: OrganizationGitHubConnectionHTML.message(reason)})
    end
  end

  def cancel(conn, %{"attempt_id" => id} = params) do
    with {:ok, organization} <- organization(conn, params) do
      OrganizationGitHubDeviceSession.run(conn, organization.id, {:cancel, id})
      redirect_connection(conn, organization)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def bind(conn, params), do: mutate(conn, params, :bind)
  def disconnect(conn, params), do: mutate(conn, params, :disconnect)
  def activate(conn, params), do: mutate(conn, params, :activate)

  defp mutate(conn, params, action) do
    with {:ok, organization} <- organization(conn, params),
         {:ok, attrs} <- action_attrs(params, action),
         {:ok, version} <- integer(attrs["connection_version"], true) do
      actor = conn.assigns.current_user
      metadata = RequestMetadata.from_conn(conn)

      result =
        case action do
          :bind ->
            with {:ok, installation_id} <- integer(attrs["installation_id"], false) do
              service(conn).bind(
                actor,
                organization.id,
                installation_id,
                version,
                metadata,
                service_options(conn)
              )
            end

          :disconnect ->
            service(conn).disconnect(actor, organization.id, version, metadata)

          :activate ->
            with {:ok, view} <- service(conn).view(actor, organization.id),
                 true <- view.state == :ready and view.connection_version == version,
                 {:ok, config_version} <- integer(attrs["config_version"], false),
                 {:ok, scope} <- service(conn).scope(view.connection.id),
                 true <- scope.connection_version == version do
              settings(conn).activate_organization_connection(
                actor,
                organization.id,
                scope,
                config_version,
                metadata
              )
            else
              false -> {:error, :stale}
              error -> error
            end
        end

      case result do
        {:ok, _} ->
          conn |> put_flash(:info, success_message(action)) |> redirect_connection(organization)

        {:error, reason} ->
          error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp show(conn, params, template) do
    with {:ok, organization} <- organization(conn, params),
         {:ok, view} <- service(conn).view(conn.assigns.current_user, organization.id),
         {:ok, sync} <- settings(conn).view(conn.assigns.current_user, organization.id) do
      {installations, listing_error} =
        if template == :connection and view.credential.status == :valid do
          case service(conn).installations(
                 conn.assigns.current_user,
                 organization.id,
                 service_options(conn)
               ) do
            {:ok, installations} -> {installations, nil}
            {:error, reason} -> {[], OrganizationGitHubConnectionHTML.message(reason)}
          end
        else
          {[], nil}
        end

      rendered =
        apply(OrganizationGitHubConnectionHTML, template, [
          %{
            organization: organization,
            view: view,
            config: sync.config,
            installations: installations,
            error: listing_error,
            flash: Phoenix.Flash.get(conn.assigns.flash, :info),
            device_flow: OrganizationGitHubDeviceSession.view(conn, organization.id),
            __changed__: nil
          }
        ])

      page(
        conn,
        "#{organization.username} GitHub connection",
        rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      )
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp exchange(conn, organization, id, claim) do
    with {:ok, %{expected: expected}} <-
           OrganizationGitHubDeviceSession.run(conn, organization.id, {:check, id, claim.id}),
         {:ok, current} <- service(conn).reference(conn.assigns.current_user, organization.id),
         true <- same_reference?(current, expected) do
      case provider(conn).poll(claim.device_code, client_id: claim.client_id) do
        {:ok, token} ->
          finish(conn, organization, id, claim.id, token)

        {:error, :authorization_pending} ->
          pending(conn, organization, id, claim.id, 0)

        {:error, {:slow_down, interval}} ->
          pending(conn, organization, id, claim.id, interval)

        {:error, reason} ->
          OrganizationGitHubDeviceSession.run(
            conn,
            organization.id,
            {:fail, id, safe_reason(reason)}
          )

          {:error, reason}
      end
    else
      _ ->
        OrganizationGitHubDeviceSession.run(conn, organization.id, {:fail, id, :stale})
        {:error, :stale}
    end
  end

  defp pending(conn, organization, id, claim, requested) do
    case OrganizationGitHubDeviceSession.view(conn, organization.id) do
      %{interval: current_interval} ->
        interval =
          if requested > 0, do: max(requested, current_interval + 5), else: current_interval

        with :ok <-
               OrganizationGitHubDeviceSession.run(
                 conn,
                 organization.id,
                 {:pending, id, claim, interval}
               ),
             do: {:ok, %{status: "pending", interval: interval}}

      _ ->
        {:error, :stale}
    end
  end

  defp finish(conn, organization, id, claim, token) do
    OrganizationGitHubDeviceSession.transaction(conn, organization.id, fn dispatch ->
      actor = conn.assigns.current_user

      with {:ok, %{actor_id: actor_id, organization_id: organization_id, expected: expected}} <-
             dispatch.({:check, id, claim}),
           true <- actor_id == actor.id and organization_id == organization.id,
           {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization.id),
           {:ok, _} <-
             service(conn).connect(
               actor,
               organization.id,
               token,
               expected,
               RequestMetadata.from_conn(conn),
               Keyword.put(service_options(conn), :before_save, fn ->
                 dispatch.({:prepare_save, id, claim})
               end)
             ),
           :ok <- dispatch.({:complete, id, claim}) do
        {:ok, complete(organization)}
      else
        false ->
          dispatch.({:fail, id, :stale})
          {:error, :stale}

        {:error, reason} ->
          dispatch.({:fail, id, safe_reason(reason)})
          {:error, reason}
      end
    end)
  end

  defp organization(
         %{assigns: %{current_user: %ForgeAccounts.User{state: :active, kind: :user} = actor}},
         %{"organization" => slug}
       ),
       do: ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug)

  defp organization(_, _), do: {:error, :not_found}

  defp service(conn),
    do: conn.private[:organization_github_connection] || ForgeImports.OrganizationGitHubConnection

  defp provider(conn), do: conn.private[:github_device_provider] || ForgeGitHub.DeviceFlow

  defp settings(conn),
    do: conn.private[:organization_github_sync_settings] || ForgeMirrors.PatSettings

  defp service_options(conn), do: conn.private[:organization_github_connection_options] || []

  defp complete(organization),
    do: %{
      status: "complete",
      redirect: OrganizationGitHubConnectionHTML.base(organization) <> "/connection"
    }

  defp same_reference?(current, expected) do
    keys = [:organization_id, :credential_id, :verification_version, :status]

    current.organization_id == expected.organization_id and
      current.connection_version == expected.connection_version and
      Map.take(current.credential, keys) == Map.take(expected.credential, keys)
  end

  defp redirect_connection(conn, organization),
    do:
      conn
      |> put_status(:see_other)
      |> redirect(to: OrganizationGitHubConnectionHTML.base(organization) <> "/connection")

  defp action_attrs(%{"connection" => attrs}, action) when is_map(attrs) do
    keys =
      case action do
        :bind -> ~w(connection_version installation_id)
        :disconnect -> ~w(connection_version)
        :activate -> ~w(connection_version config_version)
      end

    if Enum.sort(Map.keys(attrs)) == Enum.sort(keys),
      do: {:ok, attrs},
      else: {:error, :invalid_request}
  end

  defp action_attrs(_, _), do: {:error, :invalid_request}

  defp integer(value, zero?) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and number <= 9_223_372_036_854_775_807 ->
        if to_string(number) == value and (zero? or number > 0),
          do: {:ok, number},
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp integer(_, _), do: {:error, :invalid_request}

  defp error(conn, reason),
    do:
      conn
      |> put_status(error_status(reason))
      |> page("Organization GitHub connection", OrganizationGitHubConnectionHTML.message(reason))

  defp error_status(reason) when reason in [:not_found, :forbidden, :stale], do: :not_found
  defp error_status(reason) when reason in [:busy, :leased, :conflict], do: :conflict
  defp error_status(:expired_token), do: :gone
  defp error_status(_), do: :unprocessable_entity

  defp safe_reason(reason)
       when reason in [
              :device_flow_disabled,
              :access_denied,
              :expired_token,
              :incorrect_client_credentials,
              :stale,
              :credential_service_unavailable,
              :authorization_unavailable,
              :primary_rate_limit,
              :secondary_rate_limit
            ],
       do: reason

  defp safe_reason(_), do: :authorization_unavailable

  defp success_message(:activate),
    do: "Organization connection enabled for synchronization. Use Sync now to start a task."

  defp success_message(:bind),
    do: "GitHub installation checked. Review its connection status below."

  defp success_message(:disconnect), do: "Organization GitHub connection disconnected."
end
