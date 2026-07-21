defmodule FornacastAPI.Plugs.RequestContext do
  import Plug.Conn

  @default_version "2022-11-28"
  @default_media_type "application/vnd.github+json"

  def init(opts), do: opts

  def call(conn, _opts) do
    if api_path?(conn.request_path) do
      conn
      |> assign(:api_version, @default_version)
      |> assign(:response_media_type, @default_media_type)
      |> assign(:accepted_scopes, [])
      |> assign(:api_auth, nil)
      |> register_before_send(&put_common_headers/1)
    else
      conn
    end
  end

  def metadata(conn) do
    %{
      request_id: request_id(conn),
      api_version: conn.assigns[:api_version],
      ip_address: conn.assigns[:effective_client_ip],
      user_agent: List.first(get_req_header(conn, "user-agent")),
      token_id: token_id(conn.assigns[:api_auth])
    }
  end

  defp put_common_headers(conn) do
    conn
    |> put_resp_header(
      "x-github-api-version-selected",
      conn.assigns[:api_version] || @default_version
    )
    |> put_resp_header("x-github-media-type", "github.v3; format=json")
    |> put_resp_header("x-github-request-id", request_id(conn))
    |> put_resp_header("x-oauth-scopes", oauth_scopes(conn.assigns[:api_auth]))
    |> put_resp_header(
      "x-accepted-oauth-scopes",
      join_scopes(conn.assigns[:accepted_scopes])
    )
  end

  defp request_id(conn) do
    case conn.assigns[:request_id] do
      request_id when is_binary(request_id) and request_id != "" ->
        request_id

      _unassigned ->
        conn
        |> get_resp_header("x-request-id")
        |> Enum.find("unassigned", &(&1 != ""))
    end
  end

  defp oauth_scopes(%{api_key: %{scopes: scopes}}) when is_map(scopes) do
    scopes
    |> Enum.flat_map(fn
      {scope, true} when is_binary(scope) -> [scope]
      {_scope, _disabled} -> []
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp oauth_scopes(_api_auth), do: ""

  defp join_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp join_scopes(_scopes), do: ""

  defp token_id(%{api_key: %{id: id}}), do: id
  defp token_id(_api_auth), do: nil

  defp api_path?(path) do
    path == "/api/v3" or String.starts_with?(path, "/api/v3/") or
      path == "/api/uploads" or String.starts_with?(path, "/api/uploads/")
  end
end
