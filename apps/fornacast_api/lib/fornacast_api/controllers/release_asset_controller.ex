defmodule FornacastAPI.ReleaseAssetController do
  use FornacastAPI, :controller

  alias ForgeAccounts.APIScope

  alias FornacastAPI.{
    Authentication,
    Error,
    Pagination,
    RequestBody,
    RequestValidator,
    Response,
    URL
  }

  alias FornacastAPI.Plugs.RequestContext

  @docs "https://docs.github.com/en/enterprise-server@3.21/rest/releases/assets"

  def index(conn, %{"owner" => owner, "repo" => repo, "release_id" => id}) do
    conn = fetch_query_params(conn)

    with_authorization(conn, owner, repo, :repository_read, fn conn, actor ->
      with {:ok, id} <- positive_id(id),
           {:ok, pagination} <- Pagination.parse(conn.query_params),
           {:ok, page} <- ForgeReleases.list_assets(actor, owner, repo, id, Map.new(pagination)) do
        Response.paginated(
          conn,
          200,
          Enum.map(page.entries, &render_asset(conn, &1, owner, repo)),
          page,
          url: URL.release_assets(owner, repo, id)
        )
      else
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  def show(conn, params), do: read_asset(conn, params, false)
  def download(conn, params), do: read_asset(conn, params, true)

  defp read_asset(conn, %{"owner" => owner, "repo" => repo, "asset_id" => id}, force_binary?) do
    with_authorization(conn, owner, repo, :repository_read, fn conn, actor ->
      with {:ok, id} <- positive_id(id),
           {:ok, asset} <- ForgeReleases.get_asset(actor, owner, repo, id) do
        if force_binary? or FornacastAPI.Plugs.MediaType.binary_asset_request?(conn),
          do: FornacastAPI.ReleaseDownload.asset(conn, actor, owner, repo, asset),
          else: Response.json(conn, 200, render_asset(conn, asset, owner, repo))
      else
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  def create(conn, %{"owner" => owner, "repo" => repo, "release_id" => id}) do
    conn = fetch_query_params(conn)

    with_authorization(conn, owner, repo, :repository_mutation, fn conn, actor ->
      with {:ok, id} <- positive_id(id),
           {:ok, _release} <- ForgeReleases.get(actor, owner, repo, id),
           {:ok, content_type} <- content_type(conn),
           {:ok, attrs} <- upload_attrs(conn.query_params, content_type),
           {:ok, asset, conn} <-
             ForgeReleases.upload_asset(
               actor,
               owner,
               repo,
               id,
               attrs,
               &Plug.Conn.read_body/2,
               conn,
               request_metadata: RequestContext.metadata(conn)
             ) do
        conn
        |> put_resp_header("location", URL.release_asset(owner, repo, asset.id))
        |> Response.json(201, render_asset(conn, asset, owner, repo))
      else
        {:error, reason, conn} -> error(conn, reason)
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "asset_id" => id}) do
    with_authorization(conn, owner, repo, :repository_mutation, fn conn, actor ->
      with {:ok, id} <- positive_id(id),
           {:ok, _asset} <- ForgeReleases.get_asset(actor, owner, repo, id),
           {:ok, attrs, conn} <- RequestBody.read_json(conn, :ordinary, []),
           {:ok, attrs} <-
             RequestValidator.validate_fields(
               attrs,
               "ReleaseAsset",
               %{
                 "name" => &is_binary/1,
                 "label" => &(is_nil(&1) or is_binary(&1))
               },
               []
             ),
           {:ok, asset} <-
             ForgeReleases.update_asset(
               actor,
               owner,
               repo,
               id,
               attrs,
               RequestContext.metadata(conn)
             ) do
        Response.json(conn, 200, render_asset(conn, asset, owner, repo))
      else
        {:error, %Error{} = failure, _reason, conn} ->
          Response.error(conn, %{failure | accepted_scopes: conn.assigns[:accepted_scopes] || []})

        {:error, reason} ->
          error(conn, reason)
      end
    end)
  end

  def delete(conn, %{"owner" => owner, "repo" => repo, "asset_id" => id}) do
    with_authorization(conn, owner, repo, :repository_mutation, fn conn, actor ->
      with {:ok, id} <- positive_id(id),
           :ok <-
             ForgeReleases.delete_asset(actor, owner, repo, id, RequestContext.metadata(conn)) do
        Response.no_content(conn)
      else
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  def archive(conn, %{"owner" => owner, "repo" => repo, "release_id" => id, "format" => format}) do
    with_authorization(conn, owner, repo, :repository_read, fn conn, actor ->
      with {:ok, id} <- positive_id(id),
           {:ok, archive} <- ForgeReleases.Archives.prepare(actor, owner, repo, id, format) do
        try do
          conn
          |> put_resp_header("cache-control", "private, no-store")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header(
            "content-disposition",
            FornacastAPI.ReleaseDownload.disposition(archive.filename)
          )
          |> put_resp_content_type(archive.content_type)
          |> send_file(200, archive.path)
        after
          ForgeReleases.Archives.cleanup(archive)
        end
      else
        {:error, reason} -> error(conn, reason)
      end
    end)
  end

  defp with_authorization(conn, owner, repo, action, callback) do
    case authorize(conn, owner, repo, action) do
      {:ok, actor, conn} -> callback.(conn, actor)
      {:error, reason, conn} -> error(conn, reason)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp authorize(conn, owner, repo, action) do
    authentication = conn.assigns[:api_auth]

    actor =
      case authentication do
        %Authentication{actor: actor} -> actor
        _ -> nil
      end

    with :ok <- require_actor(actor, action),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
         {:ok, scopes} <- scopes(authentication, action, repository.visibility) do
      conn = assign(conn, :accepted_scopes, scopes)

      case write_permission(actor, owner, repo, action) do
        :ok -> {:ok, actor, conn}
        {:error, reason} -> {:error, reason, conn}
      end
    end
  end

  defp require_actor(nil, :repository_mutation), do: {:error, :requires_authentication}
  defp require_actor(_actor, _action), do: :ok

  defp write_permission(actor, owner, repo, :repository_mutation) do
    case ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_write) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_permission(_actor, _owner, _repo, _action), do: :ok
  defp scopes(nil, :repository_read, :public), do: {:ok, []}

  defp scopes(%Authentication{api_key: key}, action, visibility) do
    accepted = APIScope.accepted_scopes(action, visibility)

    case APIScope.authorize(key, action, visibility) do
      :ok -> {:ok, accepted}
      _ -> {:error, {:insufficient_scope, accepted}}
    end
  end

  defp scopes(_authentication, _action, _visibility), do: {:error, :requires_authentication}

  defp upload_attrs(params, content_type) do
    with {:ok, attrs} <-
           RequestValidator.validate_fields(
             Map.take(params, ["name", "label"]),
             "ReleaseAsset",
             %{
               "name" => &(is_binary(&1) and &1 != ""),
               "label" => &(is_nil(&1) or is_binary(&1))
             },
             ["name"]
           ) do
      {:ok, Map.put(attrs, "content_type", content_type)}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        {:ok, value |> String.split(";", parts: 2) |> hd() |> String.trim()}

      _ ->
        {:error,
         {:validation, [%{resource: "ReleaseAsset", field: "content_type", code: :missing_field}]}}
    end
  end

  defp positive_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp render_asset(conn, asset, owner, repo),
    do:
      FornacastAPI.Serializers.ReleaseAsset.render(
        asset,
        [owner: owner, repo: repo],
        conn.assigns.api_version
      )

  defp error(conn, reason) do
    failure = Error.from_domain(reason, @docs)

    Response.error(conn, %{
      failure
      | accepted_scopes:
          Enum.uniq(failure.accepted_scopes ++ (conn.assigns[:accepted_scopes] || []))
    })
  end
end
