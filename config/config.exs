import Config

release_asset_default_root =
  case config_env() do
    :prod -> "/data/release-assets"
    :test -> "tmp/test/release-assets"
    _ -> "tmp/release-assets"
  end

release_asset_root =
  System.get_env("FORNACAST_RELEASE_ASSET_STORAGE_ROOT", release_asset_default_root)
  |> Path.expand()

parse_positive_integer! = fn name, default, minimum, maximum ->
  raw = System.get_env(name, Integer.to_string(default))

  case Integer.parse(raw) do
    {value, ""} when value >= minimum -> min(value, maximum)
    _ -> raise "#{name} must be a decimal integer >= #{minimum}"
  end
end

release_asset_max_bytes =
  parse_positive_integer!.(
    "FORNACAST_RELEASE_ASSET_MAX_BYTES",
    2_147_483_648,
    1,
    2_147_483_648
  )

release_asset_gc_grace_seconds =
  parse_positive_integer!.(
    "FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS",
    86_400,
    3_600,
    2_147_483_647
  )

database_adapter =
  System.get_env("FORNACAST_DATABASE_ADAPTER", "turso")
  |> String.downcase()

repo_adapter =
  case database_adapter do
    value when value in ["libsql", "turso"] -> Ecto.Adapters.Turso
    value when value in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
    value -> raise "unsupported FORNACAST_DATABASE_ADAPTER=#{inspect(value)}"
  end

github_credential_keyring =
  if config_env() == :prod do
    :unavailable
  else
    with keys_json when is_binary(keys_json) and keys_json != "" <-
           System.get_env("FORNACAST_GITHUB_CREDENTIAL_KEYS"),
         active when is_binary(active) and byte_size(active) in 1..255 <-
           System.get_env("FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID"),
         {:ok, encoded_keys} when is_map(encoded_keys) and map_size(encoded_keys) > 0 <-
           JSON.decode(keys_json),
         {:ok, keys} <-
           Enum.reduce_while(encoded_keys, {:ok, %{}}, fn
             {key_id, encoded_key}, {:ok, decoded}
             when is_binary(key_id) and byte_size(key_id) in 1..255 and
                    is_binary(encoded_key) ->
               case Base.decode64(encoded_key) do
                 {:ok, key} when byte_size(key) == 32 ->
                   {:cont, {:ok, Map.put(decoded, key_id, key)}}

                 _ ->
                   {:halt, :error}
               end

             _, _decoded ->
               {:halt, :error}
           end),
         {:ok, _active_key} <- Map.fetch(keys, active) do
      %{active: active, keys: keys}
    else
      _ -> :unavailable
    end
  end

config :fornacast, ecto_repos: [Fornacast.Repo]
config :fornacast, :database_adapter, database_adapter
config :fornacast, :repo_adapter, repo_adapter
config :fornacast, :auto_migrate, true
config :fornacast, :github_credential_keyring, github_credential_keyring

config :fornacast,
  release_asset_storage_root: release_asset_root,
  release_asset_max_bytes: release_asset_max_bytes,
  release_asset_gc_grace_seconds: release_asset_gc_grace_seconds

config :forge_repos,
  repository_write_reconcilers: [
    {100, :git_writes, ForgeRepos.GitWriteRecovery},
    {200, :pull_merges, ForgePulls.MergeRecovery}
  ]

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
  # Future bounded API ingestion; GitTransport retains its independent 4 GiB/nil policy.
  receive_pack_bytes: 104_857_600,
  body_total_timeout_ms: 120_000,
  body_idle_timeout_ms: 15_000,
  reconcile_interval_ms: 30_000

repo_config =
  case database_adapter do
    value when value in ["libsql", "turso"] ->
      [
        database: System.get_env("FORNACAST_DATABASE_PATH", "fornacast_dev.db"),
        remote_url: System.get_env("TURSO_DATABASE_URL"),
        auth_token: System.get_env("TURSO_AUTH_TOKEN"),
        # TODO(upstream): gsmlg-dev/concord#67
        # WORKAROUND(upstream): gsmlg-dev/concord#67
        after_connect:
          {Ecto.Adapters.Turso.Connection, :query, ["PRAGMA foreign_keys = ON", [], []]}
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
  cluster_enabled: true,
  data_dir: Path.join(release_asset_root, "concord"),
  vsr: [
    group_id: :ex_storage_service_metadata,
    replica_id: node(),
    members: [%{id: node(), endpoint: node()}],
    storage: :file,
    bootstrap: false
  ],
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

config :ex_storage_service,
  data_root: release_asset_root,
  blob_root: Path.join(release_asset_root, "cas"),
  tmp_root: Path.join(release_asset_root, "tmp"),
  ra_root: Path.join(release_asset_root, "ra"),
  metadata_root: Path.join(release_asset_root, "concord"),
  instance_config: [
    instance: :fornacast_release_assets,
    mode: :standalone,
    node_role: :data,
    auto_start: false,
    web_enabled: false,
    public_s3_enabled: false,
    cluster_data_plane_enabled: false,
    workers: %{
      multipart_gc: false,
      content_gc: false,
      cas_gc: false,
      packer: false,
      lifecycle: false,
      cross_cluster_replication: false,
      repair: false,
      scrub: false
    }
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
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: FornacastAPI.ErrorJSON], layout: false]

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

config :phoenix, :filter_parameters, {:keep, []}

fornacast_web_path = Path.expand("../apps/fornacast_web", __DIR__)

config :duskmoon_bundler, :fornacast_web,
  entry: Path.join(fornacast_web_path, "assets/js/app.js"),
  outdir: Path.join(fornacast_web_path, "priv/static/assets"),
  root: Path.join(fornacast_web_path, "assets"),
  format: :esm,
  target: :es2020,
  sourcemap: :hidden,
  # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#118
  resolve_dirs: [
    Path.expand("../node_modules", __DIR__),
    Path.expand("../deps", __DIR__)
  ],
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
