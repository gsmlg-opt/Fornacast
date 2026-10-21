defmodule ForgeAccounts.GitHubDeviceToken do
  @moduledoc false

  @fields [:client_id, :access_token, :refresh_token, :expires_at, :refresh_expires_at]

  def normalize(value, now \\ DateTime.utc_now(:second))

  def normalize(value, now) when is_map(value) do
    with %{
           client_id: client,
           access_token: access,
           refresh_token: refresh,
           expires_at: %DateTime{} = expires,
           refresh_expires_at: %DateTime{} = refresh_expires
         } <-
           Map.take(value, @fields),
         true <- is_binary(client) and byte_size(client) in 1..255,
         true <- String.valid?(client) and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, client),
         true <- valid_secret?(access) and valid_secret?(refresh),
         true <- expires.utc_offset == 0 and expires.std_offset == 0,
         true <- refresh_expires.utc_offset == 0 and refresh_expires.std_offset == 0,
         :gt <- DateTime.compare(expires, now),
         :gt <- DateTime.compare(refresh_expires, now) do
      {:ok,
       %{
         client_id: client,
         access_token: access,
         refresh_token: refresh,
         expires_at: DateTime.truncate(expires, :second),
         refresh_expires_at: DateTime.truncate(refresh_expires, :second)
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def normalize(_value, _now), do: {:error, :invalid_response}

  defp valid_secret?(value), do: is_binary(value) and byte_size(value) in 1..4_096
end
