defmodule FornacastWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fornacast_web

  @session_options [
    store: :cookie,
    key: "_fornacast_key",
    signing_salt: "fornacast-session"
  ]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FornacastWeb.Router
end
