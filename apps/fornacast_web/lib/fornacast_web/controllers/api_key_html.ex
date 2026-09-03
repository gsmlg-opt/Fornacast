defmodule FornacastWeb.APIKeyHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "api_key_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  def classic_scopes, do: ForgeAccounts.APIKey.classic_scopes()

  def scope_checked?(scopes, scope) when is_map(scopes) do
    Map.get(scopes, scope) in ["true", "on", true]
  end

  def scope_checked?(_scopes, _scope), do: false

  def format_scopes(scopes) when is_map(scopes) do
    scopes
    |> Enum.filter(fn {_scope, enabled} -> enabled end)
    |> Enum.map_join(", ", fn {scope, _enabled} -> scope end)
  end

  def format_scopes(_scopes), do: ""

  def format_datetime(nil, fallback), do: fallback
  def format_datetime(%DateTime{} = datetime, _fallback), do: DateTime.to_string(datetime)
  def format_datetime(datetime, _fallback), do: to_string(datetime)

  def key_status(%{revoked_at: revoked_at}) when not is_nil(revoked_at), do: "Revoked"

  def key_status(%{expires_at: expires_at}) when not is_nil(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now(:second)) in [:lt, :eq],
      do: "Expired",
      else: "Active"
  end

  def key_status(_key), do: "Active"
end
