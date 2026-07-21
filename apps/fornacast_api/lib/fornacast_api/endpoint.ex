defmodule FornacastAPI.Endpoint do
  use Phoenix.Endpoint, otp_app: :fornacast_api

  plug Plug.RequestId
  plug FornacastAPI.Plugs.EndpointTelemetry, event_prefix: [:phoenix, :endpoint]
  plug FornacastAPI.Plugs.RequestContext
  plug FornacastAPI.Plugs.RequestTarget
  plug FornacastAPI.Router
end
