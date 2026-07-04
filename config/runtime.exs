import Config

if System.get_env("MIX_BUN_PATH") do
  config :bun, path: System.get_env("MIX_BUN_PATH")
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end

if config_env() == :prod do
  database_adapter =
    System.get_env("FORNACAST_DATABASE_ADAPTER", "turso")
    |> String.downcase()

  turso_auth_token =
    case System.get_env("TURSO_AUTH_TOKEN") do
      value when value in [nil, ""] ->
        nil

      _value ->
        fn -> System.fetch_env!("TURSO_AUTH_TOKEN") end
    end

  repo_config =
    case database_adapter do
      value when value in ["libsql", "turso"] ->
        [
          database: System.get_env("FORNACAST_DATABASE_PATH", "/data/fornacast.db"),
          remote_url: System.get_env("TURSO_DATABASE_URL"),
          auth_token: turso_auth_token
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

      value when value in ["postgres", "postgresql"] ->
        database_url =
          System.get_env("DATABASE_URL") ||
            raise "environment variable DATABASE_URL is missing for PostgreSQL"

        [url: database_url]

      value ->
        raise "unsupported FORNACAST_DATABASE_ADAPTER=#{inspect(value)}"
    end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  config :fornacast, :database_adapter, database_adapter

  config :fornacast,
         Fornacast.Repo,
         [pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")] ++ repo_config

  config_store_enabled =
    System.get_env("FORNACAST_CONFIG_STORE_ENABLED", "true")
    |> String.downcase()
    |> Kernel.!=("false")

  config_store_auth_token =
    case System.get_env("FORNACAST_CONFIG_TURSO_AUTH_TOKEN") ||
           System.get_env("CONCORD_TURSO_AUTH_TOKEN") do
      value when value in [nil, ""] ->
        nil

      _value ->
        fn ->
          System.get_env("FORNACAST_CONFIG_TURSO_AUTH_TOKEN") ||
            System.fetch_env!("CONCORD_TURSO_AUTH_TOKEN")
        end
    end

  config :concord,
    cluster_enabled: false,
    turso: [
      enabled: config_store_enabled,
      database: System.get_env("FORNACAST_CONFIG_DATABASE_PATH", "/data/fornacast_config.db"),
      pool_size: String.to_integer(System.get_env("FORNACAST_CONFIG_POOL_SIZE") || "1"),
      remote_url:
        System.get_env("FORNACAST_CONFIG_TURSO_DATABASE_URL") ||
          System.get_env("CONCORD_TURSO_REMOTE_URL"),
      auth_token: config_store_auth_token
    ]

  config :fornacast,
    base_url: System.fetch_env!("FORNACAST_BASE_URL"),
    repo_storage_root: System.fetch_env!("FORNACAST_REPO_STORAGE_ROOT"),
    ssh_host: System.fetch_env!("FORNACAST_SSH_HOST"),
    ssh_port: String.to_integer(System.fetch_env!("FORNACAST_SSH_PORT")),
    ssh_system_dir: System.fetch_env!("FORNACAST_SSH_SYSTEM_DIR")

  config :fornacast_web, FornacastWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: secret_key_base
end
