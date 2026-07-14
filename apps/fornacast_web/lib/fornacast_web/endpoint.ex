defmodule FornacastWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fornacast_web

  @session_options [
    store: :cookie,
    key: "_fornacast_key",
    signing_salt: "fornacast-session"
  ]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Static,
    at: "/assets/css",
    from: {:fornacast_web, "priv/static/assets/css"},
    gzip: false

  if code_reloading? do
    plug DuskmoonBundler.DevServer, profile: :fornacast_web
  end

  plug Plug.Static,
    at: "/",
    from: :fornacast_web,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FornacastWeb.Router
end
