import Config

database_adapter =
  System.get_env("FORNACAST_DATABASE_ADAPTER", "turso")
  |> String.downcase()

repo_config =
  case database_adapter do
    value when value in ["libsql", "turso"] ->
      [
        database: System.get_env("FORNACAST_TEST_DATABASE_PATH", "fornacast_test.db")
      ]

    value when value in ["postgres", "postgresql"] ->
      [
        username: System.get_env("POSTGRES_USER", "postgres"),
        password: System.get_env("POSTGRES_PASSWORD", "postgres"),
        hostname: System.get_env("POSTGRES_HOST", "localhost"),
        database: System.get_env("POSTGRES_TEST_DB", "fornacast_test")
      ]
  end

config :fornacast, Fornacast.Repo, [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 10] ++ repo_config

config :fornacast,
  repo_storage_root: "tmp/test/repos",
  ssh_bind_ip: "127.0.0.1",
  ssh_port: 0,
  ssh_system_dir: "tmp/test/ssh",
  ssh_enabled: false

config :concord,
  cluster_enabled: false,
  turso: [
    enabled: true,
    database: System.get_env("FORNACAST_TEST_CONFIG_DATABASE_PATH", "fornacast_config_test.db"),
    pool_size: 1
  ]

config :fornacast_web, FornacastWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "fornacast-test-secret-key-base-for-test-use-only-and-long-enough-for-cookie-signing",
  server: false

config :logger, level: :warning
