import Config

config :git_core, :limits,
  scan_concurrency: 4,
  scan_deadline_ms: 30_000,
  commit_visits: 50_000,
  tree_entry_visits: 100_000,
  changed_path_visits: 10_000,
  patch_bytes: 20_971_520,
  blob_concurrency: 8,
  blob_reserved_bytes: 134_217_728,
  blob_bytes: 104_857_600,
  repository_writer_concurrency: 2,
  body_memory_bytes: 536_870_912,
  contents_reservation_bytes: 251_658_240,
  contents_json_bytes: 146_800_640,
  ref_deadline_ms: 10_000,
  content_deadline_ms: 60_000,
  receive_pack_bytes: 104_857_600,
  body_total_timeout_ms: 120_000,
  body_idle_timeout_ms: 15_000,
  reconcile_interval_ms: 30_000

test_root = Path.expand("..", __DIR__)

database_adapter =
  System.get_env("FORNACAST_DATABASE_ADAPTER", "turso")
  |> String.downcase()

repo_config =
  case database_adapter do
    value when value in ["libsql", "turso"] ->
      [
        database:
          System.get_env("FORNACAST_TEST_DATABASE_PATH", "fornacast_test.db")
          |> Path.expand(test_root)
      ]

    value when value in ["postgres", "postgresql"] ->
      username =
        System.get_env("PGUSER") ||
          System.get_env("POSTGRES_USER") ||
          System.get_env("USER", "postgres")

      password =
        case System.get_env("PGPASSWORD") || System.get_env("POSTGRES_PASSWORD") do
          value when value in [nil, ""] -> nil
          value -> value
        end

      host = System.get_env("PGHOST") || System.get_env("POSTGRES_HOST", "localhost")

      port =
        System.get_env("PGPORT") ||
          System.get_env("POSTGRES_PORT", "5432")

      port = String.to_integer(port)

      connection =
        if Path.type(host) == :absolute do
          [hostname: nil, port: port, socket_dir: host]
        else
          [hostname: host, port: port, socket_dir: nil]
        end

      credentials =
        [
          username: username,
          password: password,
          database: System.get_env("POSTGRES_TEST_DB", "fornacast_test")
        ]

      credentials ++ connection
  end

config :fornacast, Fornacast.Repo, [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10] ++ repo_config

config :fornacast,
  auto_migrate: false,
  repo_storage_root: "tmp/test/repos",
  ssh_bind_ip: "127.0.0.1",
  ssh_port: 0,
  ssh_system_dir: "tmp/test/ssh",
  ssh_enabled: false

config :concord,
  cluster_enabled: false,
  turso: [
    enabled: true,
    database:
      System.get_env("FORNACAST_TEST_CONFIG_DATABASE_PATH", "fornacast_config_test.db")
      |> Path.expand(test_root),
    pool_size: 1
  ]

config :fornacast_web, FornacastWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "fornacast-test-secret-key-base-for-test-use-only-and-long-enough-for-cookie-signing",
  server: false

config :fornacast_api, FornacastAPI.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4891],
  server: false

config :fornacast_api,
  trusted_proxy_cidrs: [],
  anonymous_rate_limit: 60,
  authenticated_rate_limit: 5_000

config :logger, level: :warning
