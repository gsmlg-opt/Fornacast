defmodule ForgeGitHub.DeviceFlow do
  @moduledoc """
  GitHub App Device Flow authorization and refresh using a public client ID.

  Requests run once against fixed GitHub endpoints. Callers own authorization
  polling schedules and must retain the returned client binding when refreshing.
  """

  alias __MODULE__.Transport

  @default_client_id "Iv23lizCVE3E24s7fCA0"
  @grant_type "urn:ietf:params:oauth:grant-type:device_code"
  @max_token_ttl 31_536_000
  @errors ~w(authorization_pending access_denied device_flow_disabled expired_token bad_refresh_token incorrect_client_credentials incorrect_device_code unsupported_grant_type)a

  defmodule Authorization do
    @moduledoc "Server-side authorization data. Never send the device code to the browser."
    @derive {Inspect, only: [:user_code, :verification_uri, :expires_in, :interval]}
    defstruct [:device_code, :user_code, :verification_uri, :expires_in, :interval]
  end

  defmodule Token do
    @moduledoc "Client-bound, expiring credentials for encrypted storage."
    @derive {Inspect, only: [:client_id, :expires_at, :refresh_expires_at]}
    defstruct [:client_id, :access_token, :refresh_token, :expires_at, :refresh_expires_at]
  end

  @doc "Returns the configured public GitHub App client ID."
  def client_id, do: Application.get_env(:forge_github, :device_client_id, @default_client_id)

  @doc "Starts authorization with offline access for refreshable credentials."
  def start(opts \\ []) do
    with {:ok, client} <- request_client(opts),
         {:ok, json} <-
           Transport.post(
             "/login/device/code",
             [client_id: client, scope: "offline_access"],
             opts
           ),
         {:ok, json} <- provider_result(json) do
      authorization(json)
    end
  end

  @doc "Exchanges a device code once; pending and slow-down responses are returned to the caller."
  def poll(device_code, opts \\ []) do
    exchange([device_code: device_code, grant_type: @grant_type], device_code, opts)
  end

  @doc "Renews Device Flow credentials without a client secret."
  def refresh(refresh_token, opts \\ []) do
    exchange([refresh_token: refresh_token, grant_type: "refresh_token"], refresh_token, opts)
  end

  defp exchange(form, secret, opts) do
    with true <- valid_text?(secret, 4096),
         {:ok, client} <- request_client(opts),
         {:ok, json} <-
           Transport.post("/login/oauth/access_token", [{:client_id, client} | form], opts),
         {:ok, json} <- provider_result(json) do
      token(json, client)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp request_client(opts) do
    client = Keyword.get(opts, :client_id, client_id())
    if valid_text?(client, 256), do: {:ok, client}, else: {:error, :invalid_request}
  end

  defp provider_result(%{"error" => "slow_down", "interval" => interval})
       when is_integer(interval) and interval in 1..86_400,
       do: {:error, {:slow_down, interval}}

  defp provider_result(%{"error" => reason}) do
    case Enum.find(@errors, &(Atom.to_string(&1) == reason)) do
      nil -> {:error, :invalid_response}
      error -> {:error, error}
    end
  end

  defp provider_result(json) when is_map(json), do: {:ok, json}
  defp provider_result(_json), do: {:error, :invalid_response}

  defp authorization(%{
         "device_code" => device_code,
         "user_code" => user_code,
         "verification_uri" => "https://github.com/login/device",
         "expires_in" => expires_in,
         "interval" => interval
       })
       when is_integer(expires_in) and expires_in in 1..86_400 and
              is_integer(interval) and interval >= 1 and interval <= expires_in do
    if valid_text?(device_code, 4096) and valid_text?(user_code, 256) do
      {:ok,
       %Authorization{
         device_code: device_code,
         user_code: user_code,
         verification_uri: "https://github.com/login/device",
         expires_in: expires_in,
         interval: interval
       }}
    else
      {:error, :invalid_response}
    end
  end

  defp authorization(_json), do: {:error, :invalid_response}

  defp token(
         %{
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "token_type" => "bearer",
           "expires_in" => expires_in,
           "refresh_token_expires_in" => refresh_expires_in
         },
         client
       )
       when is_integer(expires_in) and expires_in in 1..@max_token_ttl and
              is_integer(refresh_expires_in) and refresh_expires_in in 1..@max_token_ttl and
              refresh_expires_in >= expires_in do
    if valid_text?(access_token, 4096) and valid_text?(refresh_token, 4096) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok,
       %Token{
         client_id: client,
         access_token: access_token,
         refresh_token: refresh_token,
         expires_at: DateTime.add(now, expires_in),
         refresh_expires_at: DateTime.add(now, refresh_expires_in)
       }}
    else
      {:error, :invalid_response}
    end
  end

  defp token(_json, _client), do: {:error, :invalid_response}

  defp valid_text?(value, limit)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= limit do
    String.valid?(value) and String.trim(value) != "" and
      not String.contains?(value, [<<0>>, "\r", "\n"])
  end

  defp valid_text?(_value, _limit), do: false
end
