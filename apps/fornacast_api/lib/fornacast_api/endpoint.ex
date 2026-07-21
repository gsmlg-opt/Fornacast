defmodule FornacastAPI.Endpoint do
  use Phoenix.Endpoint, otp_app: :fornacast_api

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug FornacastAPI.Router
end
