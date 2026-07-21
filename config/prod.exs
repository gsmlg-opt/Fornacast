import Config

config :fornacast_web, FornacastWeb.Endpoint,
  url: [host: System.get_env("FORNACAST_HOST", "localhost"), port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :fornacast_api, FornacastAPI.Endpoint, server: true
