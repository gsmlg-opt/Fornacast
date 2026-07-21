defmodule FornacastAPI.Response do
  import Plug.Conn

  @default_version "2022-11-28"

  def json(conn, status, body, opts \\ []) do
    conn
    |> put_assign_options(opts)
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  def error(conn, %FornacastAPI.Error{} = error) do
    version = conn.assigns[:api_version] || @default_version
    body = FornacastAPI.Serializer.render(version, :error, error)

    json(conn, error.status, body, accepted_scopes: error.accepted_scopes)
  end

  def no_content(conn, opts \\ []) do
    conn
    |> put_assign_options(opts)
    |> send_resp(204, "")
  end

  def paginated(conn, status, body, page, opts \\ [])
      when is_struct(page, Fornacast.Page) do
    conn
    |> then(
      &apply(FornacastAPI.Pagination, :put_link_header, [
        &1,
        page,
        Keyword.fetch!(opts, :url)
      ])
    )
    |> json(status, body, opts)
  end

  defp put_assign_options(conn, opts) do
    conn
    |> assign(
      :accepted_scopes,
      Keyword.get(opts, :accepted_scopes, conn.assigns[:accepted_scopes] || [])
    )
    |> assign(
      :response_media_type,
      Keyword.get(opts, :media_type, conn.assigns[:response_media_type])
    )
  end
end
