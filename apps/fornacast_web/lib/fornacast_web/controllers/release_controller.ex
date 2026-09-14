defmodule FornacastWeb.ReleaseController do
  use FornacastWeb, :controller

  alias FornacastWeb.{
    ReleaseHTML,
    RepositoryCollaborationPage,
    RepositoryPage,
    RepositoryWeb,
    RequestMetadata
  }

  @authenticated_actions [:new, :create, :edit, :update, :delete]
  @release_fields ~w(tag_name name body target_commitish draft prerelease)

  plug :redirect_unauthenticated_with_return when action in @authenticated_actions
  plug FornacastWeb.Plugs.RequireUser when action in @authenticated_actions

  def index(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, page} <- positive_integer(Map.get(params, "page", "1")),
         {:ok, result} <-
           collaboration_page(conn).releases(
             context.repository,
             context.owner,
             context.viewer,
             %{page: page, per_page: 30},
             []
           ) do
      RepositoryWeb.render(conn, result, html_module(conn), :index)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def show(conn, %{"owner" => owner_slug, "repo" => repository_slug, "id" => id}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, id} <- positive_integer(id),
         {:ok, result} <-
           collaboration_page(conn).release(
             context.repository,
             context.owner,
             context.viewer,
             id,
             []
           ) do
      RepositoryWeb.render(conn, result, html_module(conn), :show)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def show_tag(conn, %{"owner" => owner_slug, "repo" => repository_slug, "tag" => tag}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, result} <-
           collaboration_page(conn).release_by_tag(
             context.repository,
             context.owner,
             context.viewer,
             tag,
             []
           ) do
      RepositoryWeb.render(conn, result, html_module(conn), :show)
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def new(conn, %{"owner" => owner_slug, "repo" => repository_slug}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug) do
      render_form(conn, context, :new, %{}, [], :ok)
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def create(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, attrs} <- release_attrs(params),
         {:ok, release} <-
           releases(conn).create(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      private_redirect(conn, ReleaseHTML.release_path(path_chrome(context), release.id))
    else
      {:error, {:validation, errors}} ->
        render_create_error(conn, owner_slug, repository_slug, params, errors)

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  def edit(conn, %{"owner" => owner_slug, "repo" => repository_slug, "id" => id}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, id} <- positive_integer(id) do
      render_form(conn, context, {:edit, id}, %{}, [], :ok)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def update(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "id" => id} = params
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, id} <- positive_integer(id),
         {:ok, attrs} <- release_attrs(params),
         {:ok, release} <-
           releases(conn).update(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             id,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      private_redirect(conn, ReleaseHTML.release_path(path_chrome(context), release.id))
    else
      {:error, {:validation, errors}} ->
        render_update_error(conn, owner_slug, repository_slug, id, params, errors)

      {:error, :invalid_integer} ->
        RepositoryWeb.error(conn, nil, :not_found)

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  def delete(conn, %{"owner" => owner_slug, "repo" => repository_slug, "id" => id}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, id} <- positive_integer(id),
         :ok <-
           releases(conn).delete(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             id,
             RequestMetadata.from_conn(conn)
           ) do
      private_redirect(conn, ReleaseHTML.releases_path(path_chrome(context)))
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp render_create_error(conn, owner_slug, repository_slug, params, errors) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug) do
      render_form(
        conn,
        context,
        :new,
        retained_release_values(params),
        errors,
        :unprocessable_entity
      )
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp render_update_error(conn, owner_slug, repository_slug, id, params, errors) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, id} <- positive_integer(id) do
      render_form(
        conn,
        context,
        {:edit, id},
        retained_release_values(params),
        errors,
        :unprocessable_entity
      )
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp render_form(conn, context, mode, values, errors, status) do
    with {:ok, result} <-
           collaboration_page(conn).release_form(
             context.repository,
             context.owner,
             context.viewer,
             mode,
             values,
             errors,
             []
           ) do
      template = if mode == :new, do: :new, else: :edit

      conn
      |> put_status(status)
      |> RepositoryWeb.render(result, html_module(conn), template)
    else
      {:error, reason} -> RepositoryWeb.error(conn, context.repository, reason)
    end
  end

  defp release_attrs(%{"release" => attrs}) when is_map(attrs) do
    attrs = Map.take(attrs, @release_fields)

    Enum.reduce_while(["draft", "prerelease"], {:ok, attrs}, fn field, {:ok, normalized} ->
      case Map.fetch(normalized, field) do
        {:ok, value} ->
          case boolean(value) do
            {:ok, value} -> {:cont, {:ok, Map.put(normalized, field, value)}}
            :error -> {:halt, invalid_attrs(field)}
          end

        :error ->
          {:cont, {:ok, normalized}}
      end
    end)
  end

  defp release_attrs(_params), do: invalid_attrs("base")

  defp retained_release_values(%{"release" => attrs}) when is_map(attrs),
    do: Map.take(attrs, @release_fields)

  defp retained_release_values(_params), do: %{}

  defp boolean(value) when value in [true, "true", "1", "on"], do: {:ok, true}
  defp boolean(value) when value in [false, "false", "0", "off"], do: {:ok, false}
  defp boolean(_value), do: :error

  defp invalid_attrs(field),
    do: {:error, {:validation, [%{resource: "Release", field: field, code: :invalid}]}}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, :invalid_integer}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_integer}

  defp redirect_unauthenticated_with_return(
         %Plug.Conn{assigns: %{current_user: nil}} = conn,
         _opts
       ) do
    target = safe_return_target(conn)

    conn
    |> redirect(to: "/login?return_to=#{URI.encode_www_form(target)}")
    |> halt()
  end

  defp redirect_unauthenticated_with_return(conn, _opts), do: conn

  defp safe_return_target(conn) do
    owner = encode_path_segment(conn.path_params["owner"])
    repository = encode_path_segment(conn.path_params["repo"])
    id = encode_path_segment(conn.path_params["id"])
    base = "/#{owner}/#{repository}/releases"

    case conn.private[:phoenix_action] do
      :new -> base <> "/new"
      :edit -> base <> "/#{id}/edit"
      :create -> base
      action when action in [:update, :delete] -> base <> "/#{id}"
    end
  end

  defp encode_path_segment(nil), do: ""
  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp path_chrome(context) do
    %RepositoryPage.Chrome{
      owner: context.owner,
      repository: context.repository,
      viewer: context.viewer,
      ref_summary: nil,
      clone: nil
    }
  end

  defp private_redirect(conn, path) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
    |> redirect(to: path)
  end

  defp collaboration_page(conn),
    do: conn.private[:repository_collaboration_page] || RepositoryCollaborationPage

  defp releases(conn), do: conn.private[:forge_releases] || ForgeReleases
  defp html_module(conn), do: conn.private[:release_html] || ReleaseHTML
end
