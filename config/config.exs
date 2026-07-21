import Config

database_adapter =
  System.get_env("FORNACAST_DATABASE_ADAPTER", "turso")
  |> String.downcase()

repo_adapter =
  case database_adapter do
    value when value in ["libsql", "turso"] -> Ecto.Adapters.Turso
    value when value in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
    value -> raise "unsupported FORNACAST_DATABASE_ADAPTER=#{inspect(value)}"
  end

config :fornacast, ecto_repos: [Fornacast.Repo]
config :fornacast, :database_adapter, database_adapter
config :fornacast, :repo_adapter, repo_adapter
config :fornacast, :auto_migrate, true

repo_config =
  case database_adapter do
    value when value in ["libsql", "turso"] ->
      [
        database: System.get_env("FORNACAST_DATABASE_PATH", "fornacast_dev.db"),
        remote_url: System.get_env("TURSO_DATABASE_URL"),
        auth_token: System.get_env("TURSO_AUTH_TOKEN")
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    value when value in ["postgres", "postgresql"] ->
      [
        username: System.get_env("POSTGRES_USER", "postgres"),
        password: System.get_env("POSTGRES_PASSWORD", "postgres"),
        hostname: System.get_env("POSTGRES_HOST", "localhost"),
        database: System.get_env("POSTGRES_DB", "fornacast_dev")
      ]
  end

config :fornacast,
       Fornacast.Repo,
       [
         stacktrace: true,
         show_sensitive_data_on_connection_error: true,
         pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
       ] ++ repo_config

config_store_enabled =
  System.get_env("FORNACAST_CONFIG_STORE_ENABLED", "true")
  |> String.downcase()
  |> Kernel.!=("false")

config :concord,
  cluster_enabled: false,
  turso: [
    enabled: config_store_enabled,
    database: System.get_env("FORNACAST_CONFIG_DATABASE_PATH", "fornacast_config_dev.db"),
    pool_size: String.to_integer(System.get_env("FORNACAST_CONFIG_POOL_SIZE", "1")),
    remote_url:
      System.get_env("FORNACAST_CONFIG_TURSO_DATABASE_URL") ||
        System.get_env("CONCORD_TURSO_REMOTE_URL"),
    auth_token:
      System.get_env("FORNACAST_CONFIG_TURSO_AUTH_TOKEN") ||
        System.get_env("CONCORD_TURSO_AUTH_TOKEN")
  ]

config :fornacast,
  base_url: System.get_env("FORNACAST_BASE_URL", "http://localhost:4890"),
  repo_storage_root: System.get_env("FORNACAST_REPO_STORAGE_ROOT", "tmp/repos"),
  ssh_host: System.get_env("FORNACAST_SSH_HOST", "localhost"),
  ssh_bind_ip: System.get_env("FORNACAST_SSH_BIND_IP", "0.0.0.0"),
  ssh_port: String.to_integer(System.get_env("FORNACAST_SSH_PORT", "2222")),
  ssh_system_dir: System.get_env("FORNACAST_SSH_SYSTEM_DIR", "tmp/ssh"),
  ssh_enabled: System.get_env("FORNACAST_SSH_ENABLED", "true") != "false"

config :fornacast_web, FornacastWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FornacastWeb.ErrorHTML, json: FornacastWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fornacast.PubSub,
  live_view: [signing_salt: "fornacast-development"]

config :fornacast_api, FornacastAPI.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter

config :fornacast_api,
  anonymous_rate_limit: 60,
  authenticated_rate_limit: 5_000,
  rate_window_seconds: 3_600,
  trusted_proxy_cidrs: [],
  request_target_max_bytes: 8_192,
  ordinary_json_max_bytes: 1_048_576,
  ordinary_body_total_timeout_ms: 15_000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :repo, :user_id]

config :phoenix, :json_library, JSON

config :bun, version: "1.3.4"

fornacast_web_path = Path.expand("../apps/fornacast_web", __DIR__)

config :duskmoon_bundler, :fornacast_web,
  entry: Path.join(fornacast_web_path, "assets/js/app.js"),
  outdir: Path.join(fornacast_web_path, "priv/static/assets"),
  root: Path.join(fornacast_web_path, "assets"),
  format: :esm,
  target: :es2020,
  sourcemap: :hidden,
  resolve_dirs: [Path.expand("../deps", __DIR__)],
  tailwind: [
    css: Path.join(fornacast_web_path, "assets/css/app.css"),
    sources: [
      %{base: Path.join(fornacast_web_path, "lib"), pattern: "**/*.{ex,heex,eex}"},
      %{base: Path.join(fornacast_web_path, "assets"), pattern: "**/*.{js,ts,jsx,tsx}"}
    ]
  ],
  server: [
    watch_dirs: [
      Path.join(fornacast_web_path, "lib"),
      Path.join(fornacast_web_path, "assets")
    ]
  ]

import_config "#{config_env()}.exs"
