defmodule FornacastWeb.OrganizationGitHubSettingsController do
  use FornacastWeb, :controller

  alias FornacastWeb.{
    OrganizationGitHubSettingsHTML,
    OrganizationSettingsComponents,
    RequestMetadata
  }

  @callback_session_key :github_organization_installation
  @canonical_id ~r/\A[1-9][0-9]*\z/
  @callback_state ~r/\A[A-Za-z0-9_-]{43}\z/
  @max_id 9_223_372_036_854_775_807
  @max_install_url_bytes 2_048

  def index(conn, params), do: render_settings(conn, params, :index)

  def conflicts(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    case manageable_organization(actor, params) do
      {:ok, organization} ->
        case organization_sync(conn).get_conflicts(
               actor,
               organization,
               Map.take(params, ["repository", "resource", "type"])
             ) do
          {:ok, %{} = view} ->
            case OrganizationGitHubSettingsHTML.normalize_view(organization, view) do
              {:ok, view} ->
                rendered =
                  OrganizationGitHubSettingsHTML.conflicts(%{
                    organization: organization,
                    view: view,
                    __changed__: nil
                  })

                page(
                  conn,
                  "#{organization.display_name || organization.username} GitHub settings",
                  rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
                )

              {:error, reason} ->
                render_authorized_error(conn, organization, reason)
            end

          {:error, reason} ->
            render_authorized_error(conn, organization, reason)

          _unexpected ->
            render_authorized_error(conn, organization, :unavailable)
        end

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def resolve_pull_merge_conflict(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, organization} <- manageable_organization(actor, params),
         {:ok, attrs} <- pull_merge_conflict_params(params),
         result <-
           organization_sync(conn).resolve_pull_merge_conflict(
             actor,
             organization,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      handle_conflict_action_result(conn, organization, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def resolve_repository_metadata_conflict(
        %Plug.Conn{assigns: %{current_user: actor}} = conn,
        params
      ) do
    with {:ok, organization} <- manageable_organization(actor, params),
         {:ok, attrs} <- repository_metadata_conflict_params(params),
         result <-
           organization_sync(conn).resolve_repository_metadata_conflict(
             actor,
             organization,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      handle_conflict_action_result(conn, organization, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def install(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, organization} <- manageable_organization(actor, params),
         state = installation_state(),
         {:ok, result} <-
           organization_sync(conn).begin_installation(
             actor,
             organization,
             state,
             RequestMetadata.from_conn(conn)
           ),
         {:ok, url} <- github_install_url(result) do
      correlation = %{
        "actor_id" => actor.id,
        "organization_id" => organization.id,
        "state" => state
      }

      conn
      |> put_session(@callback_session_key, correlation)
      |> put_status(:see_other)
      |> redirect(external: url)
    else
      {:error, reason} -> render_error(conn, reason)
      _unexpected -> render_error(conn, :unavailable)
    end
  end

  def callback(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    correlation = get_session(conn, @callback_session_key)
    conn = delete_session(conn, @callback_session_key)

    with {:ok, organization} <- manageable_organization(actor, params),
         {:ok, callback_attrs} <- callback_params(params),
         :ok <- validate_correlation(correlation, actor, organization, callback_attrs.state),
         result <-
           organization_sync(conn).complete_installation(
             actor,
             organization,
             callback_attrs,
             RequestMetadata.from_conn(conn)
           ) do
      handle_action_result(conn, organization, result)
    else
      {:error, :invalid_callback} -> render_error(conn, :invalid_callback)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def update(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, organization} <- manageable_organization(actor, params),
         {:ok, attrs} <- nested_params(params, "github"),
         result <-
           organization_sync(conn).update_settings(
             actor,
             organization,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      handle_action_result(conn, organization, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def bootstrap(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, organization} <- manageable_organization(actor, params),
         {:ok, attrs} <- nested_params(params, "bootstrap"),
         result <-
           organization_sync(conn).bootstrap(
             actor,
             organization,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      handle_action_result(conn, organization, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def reconcile(conn, params), do: simple_action(conn, params, :reconcile)
  def pause(conn, params), do: simple_action(conn, params, :pause)
  def resume(conn, params), do: simple_action(conn, params, :resume)
  def delete(conn, params), do: simple_action(conn, params, :disconnect)

  defp render_settings(
         %Plug.Conn{assigns: %{current_user: actor}} = conn,
         params,
         template
       ) do
    case manageable_organization(actor, params) do
      {:ok, organization} ->
        case organization_sync(conn).get_settings(actor, organization) do
          {:ok, %{} = view} ->
            case OrganizationGitHubSettingsHTML.normalize_view(organization, view) do
              {:ok, view} ->
                rendered =
                  apply(OrganizationGitHubSettingsHTML, template, [
                    %{organization: organization, view: view, __changed__: nil}
                  ])

                page(
                  conn,
                  "#{organization.display_name || organization.username} GitHub settings",
                  rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
                )

              {:error, reason} ->
                render_authorized_error(conn, organization, reason)
            end

          {:error, reason} ->
            render_authorized_error(conn, organization, reason)

          _unexpected ->
            render_authorized_error(conn, organization, :unavailable)
        end

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp simple_action(
         %Plug.Conn{assigns: %{current_user: actor}} = conn,
         params,
         action
       ) do
    with {:ok, organization} <- manageable_organization(actor, params),
         result <-
           apply(organization_sync(conn), action, [
             actor,
             organization,
             RequestMetadata.from_conn(conn)
           ]) do
      handle_action_result(conn, organization, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp handle_action_result(conn, organization, {:ok, _result}) do
    conn
    |> put_status(:see_other)
    |> redirect(to: settings_path(organization) <> "/app")
  end

  defp handle_action_result(conn, _organization, {:error, reason}),
    do: render_error(conn, reason)

  defp handle_action_result(conn, _organization, _unexpected),
    do: render_error(conn, :unavailable)

  defp handle_conflict_action_result(conn, organization, {:ok, _result}) do
    conn
    |> put_status(:see_other)
    |> redirect(to: conflicts_path(organization))
  end

  defp handle_conflict_action_result(conn, _organization, {:error, reason}),
    do: render_error(conn, reason)

  defp handle_conflict_action_result(conn, _organization, _unexpected),
    do: render_error(conn, :unavailable)

  defp manageable_organization(actor, %{"organization" => slug}) when is_binary(slug),
    do: ForgeAccounts.fetch_manageable_organization_by_slug(actor, slug)

  defp manageable_organization(_actor, _params), do: {:error, :not_found}

  defp nested_params(params, key) do
    case Map.get(params, key, %{}) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _invalid -> {:error, :invalid_request}
    end
  end

  defp pull_merge_conflict_params(%{
         "conflict_id" => conflict_id,
         "conflict" => %{"lock_version" => lock_version, "action" => "external_recheck"} = attrs
       })
       when map_size(attrs) == 2 do
    with {:ok, conflict_id} <- canonical_positive_id(conflict_id),
         {:ok, lock_version} <- canonical_positive_id(lock_version) do
      {:ok, %{conflict_id: conflict_id, lock_version: lock_version, action: "external_recheck"}}
    end
  end

  defp pull_merge_conflict_params(_params), do: {:error, :invalid_request}

  defp repository_metadata_conflict_params(%{
         "conflict_id" => conflict_id,
         "conflict" => %{"lock_version" => lock_version, "action" => action} = attrs
       })
       when map_size(attrs) == 2 and
              action in ["accept_github", "keep_fornacast", "external_recheck"] do
    with {:ok, conflict_id} <- canonical_positive_id(conflict_id),
         {:ok, lock_version} <- canonical_positive_id(lock_version) do
      {:ok, %{conflict_id: conflict_id, lock_version: lock_version, action: action}}
    end
  end

  defp repository_metadata_conflict_params(_params), do: {:error, :invalid_request}

  defp canonical_positive_id(value) when is_binary(value) and byte_size(value) <= 19 do
    with true <- Regex.match?(@canonical_id, value),
         {id, ""} when id <= @max_id <- Integer.parse(value) do
      {:ok, id}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp canonical_positive_id(_value), do: {:error, :invalid_request}

  defp callback_params(%{
         "installation_id" => installation_id,
         "setup_action" => setup_action,
         "state" => state
       }) do
    with {:ok, installation_id} <- canonical_id(installation_id),
         {:ok, setup_action} <- setup_action(setup_action),
         true <- valid_callback_state?(state) do
      {:ok, %{installation_id: installation_id, setup_action: setup_action, state: state}}
    else
      _invalid -> {:error, :invalid_callback}
    end
  end

  defp callback_params(_params), do: {:error, :invalid_callback}

  defp canonical_id(value) when is_binary(value) and byte_size(value) <= 19 do
    with true <- Regex.match?(@canonical_id, value),
         {id, ""} when id <= @max_id <- Integer.parse(value) do
      {:ok, id}
    else
      _invalid -> {:error, :invalid_callback}
    end
  end

  defp canonical_id(_value), do: {:error, :invalid_callback}

  defp setup_action("install"), do: {:ok, :install}
  defp setup_action("update"), do: {:ok, :update}
  defp setup_action(_action), do: {:error, :invalid_callback}

  defp valid_callback_state?(state) when is_binary(state),
    do: Regex.match?(@callback_state, state)

  defp valid_callback_state?(_state), do: false

  defp validate_correlation(
         %{
           "actor_id" => actor_id,
           "organization_id" => organization_id,
           "state" => expected_state
         },
         %{id: actor_id},
         %{id: organization_id},
         state
       )
       when is_binary(expected_state) and byte_size(expected_state) == 43 do
    if Plug.Crypto.secure_compare(expected_state, state),
      do: :ok,
      else: {:error, :invalid_callback}
  end

  defp validate_correlation(_correlation, _actor, _organization, _state),
    do: {:error, :invalid_callback}

  defp github_install_url(%{url: url})
       when is_binary(url) and byte_size(url) <= @max_install_url_bytes do
    with true <- String.valid?(url),
         false <- String.contains?(url, ["\\", "\r", "\n"]),
         %URI{
           scheme: "https",
           host: "github.com",
           port: port,
           userinfo: nil,
           fragment: nil,
           path: path
         } <- URI.parse(url),
         true <- port in [nil, 443],
         true <- is_binary(path) and String.starts_with?(path, "/") do
      {:ok, url}
    else
      _unsafe -> {:error, :unsafe_install_url}
    end
  end

  defp github_install_url(_result), do: {:error, :unsafe_install_url}

  defp installation_state do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp settings_path(organization),
    do: "/organizations/#{organization.username}/settings/github"

  defp conflicts_path(organization), do: settings_path(organization) <> "/conflicts"

  defp render_authorized_error(conn, _organization, :invalid_callback),
    do: render_error(conn, :invalid_callback)

  defp render_authorized_error(conn, _organization, reason)
       when reason in [:not_found, :forbidden],
       do: render_error(conn, reason)

  defp render_authorized_error(conn, organization, :invalid_request),
    do:
      render_layout_error(
        conn,
        organization,
        :unprocessable_entity,
        "GitHub organization settings parameters are invalid."
      )

  defp render_authorized_error(conn, organization, reason)
       when reason in [:busy, :leased, :stale, :conflict],
       do:
         render_layout_error(
           conn,
           organization,
           :conflict,
           "GitHub organization sync changed or is busy. Refresh and try again."
         )

  defp render_authorized_error(conn, organization, :missing_permissions),
    do:
      render_layout_error(
        conn,
        organization,
        :unprocessable_entity,
        "GitHub App permissions are insufficient for the requested capabilities."
      )

  defp render_authorized_error(conn, organization, _reason),
    do:
      render_layout_error(
        conn,
        organization,
        :service_unavailable,
        "GitHub organization sync is temporarily unavailable."
      )

  defp render_layout_error(conn, organization, status, message) do
    rendered =
      OrganizationSettingsComponents.organization_settings_layout(%{
        organization: organization,
        active: :github,
        inner_block: [
          %{inner_block: fn _changed, _argument -> Phoenix.HTML.raw(error_panel(message)) end}
        ],
        __changed__: nil
      })

    conn
    |> put_status(status)
    |> page(
      "#{organization.display_name || organization.username} GitHub settings",
      rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp render_error(conn, :invalid_callback) do
    conn
    |> put_status(:bad_request)
    |> page(
      "GitHub organization settings",
      error_panel("The GitHub installation callback is invalid or expired.")
    )
  end

  defp render_error(conn, reason) when reason in [:not_found, :forbidden] do
    conn
    |> put_status(:not_found)
    |> page("GitHub organization settings", error_panel("Organization settings not found."))
  end

  defp render_error(conn, :invalid_request) do
    conn
    |> put_status(:unprocessable_entity)
    |> page(
      "GitHub organization settings",
      error_panel("GitHub organization settings parameters are invalid.")
    )
  end

  defp render_error(conn, reason) when reason in [:busy, :leased, :stale, :conflict] do
    conn
    |> put_status(:conflict)
    |> page(
      "GitHub organization settings",
      error_panel("GitHub organization sync changed or is busy. Refresh and try again.")
    )
  end

  defp render_error(conn, :missing_permissions) do
    conn
    |> put_status(:unprocessable_entity)
    |> page(
      "GitHub organization settings",
      error_panel("GitHub App permissions are insufficient for the requested capabilities.")
    )
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:service_unavailable)
    |> page(
      "GitHub organization settings",
      error_panel("GitHub organization sync is temporarily unavailable.")
    )
  end

  defp organization_sync(conn),
    do: conn.private[:github_organization_sync] || ForgeImports.OrganizationSync
end
