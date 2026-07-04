import Config

config :fornacast_web, FornacastWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4890"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "fornacast-development-secret-key-base-for-local-use-only-and-long-enough-for-cookie-signing",
  server: true,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:fornacast_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:fornacast_web, ~w(--sourcemap=inline --watch)]}
  ]

config :phoenix, :stacktrace_depth, 20
