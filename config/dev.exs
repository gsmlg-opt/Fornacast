import Config

config :fornacast_web, FornacastWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "fornacast-development-secret-key-base-for-local-use-only-and-long-enough-for-cookie-signing",
  server: true

config :phoenix, :stacktrace_depth, 20
