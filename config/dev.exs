import Config

config :fornacast, :development_admin,
  username: "admin",
  email: "admin@fornacast.invalid",
  password: "admin"

config :fornacast_web, FornacastWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4890"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "fornacast-development-secret-key-base-for-local-use-only-and-long-enough-for-cookie-signing",
  server: true,
  watchers: [
    duskmoon_bundler: {Mix.Tasks.DuskmoonBundler.Dev, :run, [~w(fornacast_web --tailwind)]}
  ]

config :phoenix, :stacktrace_depth, 20
