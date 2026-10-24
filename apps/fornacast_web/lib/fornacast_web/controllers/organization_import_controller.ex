defmodule FornacastWeb.OrganizationImportController do
  use FornacastWeb, :controller

  alias ForgeAccounts.{Organization, User}
  alias ForgeImports.{RunView, SafeValue}
  alias FornacastWeb.{ImportHTML, RequestMetadata}

  plug :require_active_user
  plug :put_private_no_store

  @max_id 9_223_372_036_854_775_807
  @github_login ~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?\z/

  def index(conn, _params) do
    render_page(
      conn,
      "Import organization from GitHub",
      ImportHTML.organization(%{error: nil, __changed__: nil})
    )
  end

  def public(conn, params), do: render_source(conn, :public, params)
  def app(conn, params), do: render_source(conn, :app, params)

  def discover(conn, params) do
    actor = conn.assigns.current_user

    with {:ok, attrs} <- source_params(params, :public),
         :ok <- validate_source(attrs["organization"]),
         {:ok, destination} <- destination(actor, attrs),
         {:ok, %RunView{id: id, actor_user_id: actor_id}} <-
           imports(conn).create_organization_discovery(
             actor,
             %{
               organization: attrs["organization"],
               credential_source: "public",
               destination_organization: destination
             },
             RequestMetadata.from_conn(conn)
           ),
         true <- actor_id == actor.id and is_integer(id) and id in 1..@max_id do
      conn |> put_status(:see_other) |> redirect(to: "/imports/#{id}")
    else
      {:error, reason} -> source_error(conn, :public, params, reason)
      _ -> source_error(conn, :public, params, :unavailable)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  def connect(conn, params) do
    actor = conn.assigns.current_user

    with {:ok, attrs} <- source_params(params, :app),
         {:ok, destination} <- destination(actor, attrs),
         {:ok, organization} <- app_destination(actor, destination) do
      conn
      |> put_status(:see_other)
      |> redirect(to: "/organizations/#{organization.username}/settings/github/connection")
    else
      {:error, reason} -> source_error(conn, :app, params, reason)
    end
  rescue
    DBConnection.ConnectionError -> unavailable(conn)
  end

  defp source_params(%{"import" => attrs}, mode) when is_map(attrs) do
    fields = if mode == :public, do: ["organization"], else: []

    destination_fields =
      case attrs["destination_action"] do
        "new" -> ["destination_action", "destination_slug"]
        "existing" -> ["destination_action", "destination_organization_id"]
        _ -> []
      end

    if destination_fields != [] and
         Enum.sort(Map.keys(attrs)) == Enum.sort(fields ++ destination_fields),
       do: {:ok, attrs},
       else: {:error, :invalid_request}
  end

  defp source_params(_, _), do: {:error, :invalid_request}

  defp validate_source(login) when is_binary(login) and byte_size(login) <= 39 do
    if Regex.match?(@github_login, login), do: :ok, else: {:error, :invalid_source}
  end

  defp validate_source(_), do: {:error, :invalid_source}

  defp destination(_actor, %{"destination_action" => "new", "destination_slug" => slug})
       when is_binary(slug) and byte_size(slug) in 1..255 do
    if String.valid?(slug) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, slug),
      do: {:ok, %{action: "new", slug: slug}},
      else: {:error, :invalid_destination}
  end

  defp destination(actor, %{
         "destination_action" => "existing",
         "destination_organization_id" => raw_id
       }) do
    with {:ok, id} <- canonical_id(raw_id),
         {:ok, _organization} <- ForgeAccounts.fetch_manageable_organization(actor, id) do
      {:ok, %{action: "existing", id: id}}
    else
      {:error, :invalid_request} -> {:error, :invalid_destination}
      _ -> {:error, :not_found}
    end
  end

  defp destination(_, _), do: {:error, :invalid_destination}

  defp app_destination(actor, %{action: "existing", id: id}),
    do: ForgeAccounts.fetch_manageable_organization(actor, id)

  defp app_destination(actor, %{action: "new", slug: slug}),
    do: ForgeAccounts.create_organization(actor, %{username: slug})

  defp canonical_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id in 1..@max_id ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp canonical_id(_), do: {:error, :invalid_request}

  defp render_source(conn, mode, params, error \\ nil) do
    organizations =
      ForgeAccounts.list_repository_owners(conn.assigns.current_user)
      |> Enum.filter(&match?(%Organization{state: :active}, &1))

    attrs = if is_map(params["import"]), do: params["import"], else: %{}
    action = params["destination"] || attrs["destination_action"]

    rendered =
      ImportHTML.organization_source(%{
        mode: mode,
        organizations: organizations,
        destination_action: if(action == "existing", do: "existing", else: "new"),
        values:
          Map.new(~w(organization destination_slug destination_organization_id), fn key ->
            value = attrs[key]

            {key,
             if(
               is_binary(value) and byte_size(value) <= 255 and
                 SafeValue.github_source_text?(value, 255),
               do: value,
               else: ""
             )}
          end),
        error: error,
        __changed__: nil
      })

    render_page(
      conn,
      if(mode == :public,
        do: "Synchronize public repositories",
        else: "Connect organization with GitHub App"
      ),
      rendered
    )
  end

  defp source_error(conn, mode, params, %{kind: kind}), do: source_error(conn, mode, params, kind)

  defp source_error(conn, _mode, _params, reason) when reason in [:not_found, :forbidden] do
    conn |> put_status(:not_found) |> page("Import organization", "Organization not found.")
  end

  defp source_error(conn, mode, params, reason) do
    status =
      cond do
        reason == :unavailable ->
          :service_unavailable

        reason in [:rate_limited, :primary_rate_limit, :secondary_rate_limit] ->
          :too_many_requests

        true ->
          :unprocessable_entity
      end

    conn
    |> put_status(status)
    |> render_source(mode, params, message(reason))
  end

  defp message(:invalid_source), do: "Enter a valid GitHub organization login."

  defp message(:invalid_destination),
    do: "Choose an owned organization or enter a valid new organization slug."

  defp message(:invalid_request), do: "Choose one local destination and submit only its fields."
  defp message(%Ecto.Changeset{}), do: "Choose an available local organization slug."
  defp message(:unavailable), do: "Organization discovery is temporarily unavailable. Try again."

  defp message(reason) when reason in [:rate_limited, :primary_rate_limit, :secondary_rate_limit],
    do:
      "GitHub's anonymous API rate limit was reached. Try again after the limit resets, or connect the GitHub App."

  defp message(_), do: "Could not prepare this organization. Check the source and destination."

  defp render_page(conn, title, rendered),
    do: page(conn, title, rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary())

  defp imports(conn), do: conn.private[:forge_imports] || ForgeImports

  defp unavailable(conn),
    do:
      conn
      |> assign(:current_user, nil)
      |> put_status(:service_unavailable)
      |> page("Import organization", message(:unavailable))

  defp put_private_no_store(conn, _opts),
    do: put_resp_header(conn, "cache-control", "private, no-store")

  defp require_active_user(
         %Plug.Conn{assigns: %{current_user: %User{kind: :user, state: :active}}} = conn,
         _opts
       ),
       do: conn

  defp require_active_user(conn, _opts),
    do: conn |> delete_session(:user_id) |> redirect(to: "/login") |> halt()
end
