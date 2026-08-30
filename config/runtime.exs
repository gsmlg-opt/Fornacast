import Config

if config_env() == :prod do
  # Mix evaluates runtime.exs for prod build tasks; require these only in releases.
  release_command = System.get_env("RELEASE_COMMAND")
  require_runtime_env? = is_binary(release_command) and release_command != ""

  fetch_runtime_env! = fn name, build_default ->
    System.get_env(name) ||
      if require_runtime_env? do
        raise "environment variable #{name} is missing"
      else
        build_default
      end
  end

  fixed_postgres_build_config = [
    hostname: "127.0.0.1",
    socket_dir: nil,
    port: 5432,
    database: "fornacast_build"
  ]

  compiled_database_adapter =
    if require_runtime_env? do
      case Fornacast.Repo.__adapter__() do
        Ecto.Adapters.Postgres -> "postgres"
        Ecto.Adapters.Turso -> "turso"
        _other -> raise "compiled database adapter is unsupported"
      end
    end

  canonical_runtime_adapter = fn
    value when is_binary(value) ->
      case String.downcase(value) do
        value when value in ["postgres", "postgresql"] -> "postgres"
        value when value in ["turso", "libsql"] -> "turso"
        _other -> :unsupported
      end
  end

  database_adapter =
    if require_runtime_env? do
      runtime_database_adapter =
        case System.get_env("FORNACAST_DATABASE_ADAPTER") do
          nil -> compiled_database_adapter
          value -> canonical_runtime_adapter.(value)
        end

      if runtime_database_adapter != compiled_database_adapter do
        raise "runtime database adapter does not match compiled adapter"
      end

      compiled_database_adapter
    end

  postgres_runtime_config = fn ->
    database_url = System.get_env("DATABASE_URL")

    components = [
      hostname: System.get_env("POSTGRES_HOST"),
      port: System.get_env("POSTGRES_PORT"),
      database: System.get_env("POSTGRES_DB"),
      username: System.get_env("POSTGRES_USER"),
      password: System.get_env("POSTGRES_PASSWORD")
    ]

    url_mode? = not is_nil(database_url)
    component_mode? = Enum.any?(components, fn {_key, value} -> not is_nil(value) end)

    case {url_mode?, component_mode?} do
      {true, false} ->
        if database_url == "" do
          raise "DATABASE_URL is invalid"
        end

        parsed_url =
          try do
            Ecto.Repo.Supervisor.parse_url(database_url)
          rescue
            _error -> raise "DATABASE_URL is invalid"
          end

        if Keyword.has_key?(parsed_url, :show_sensitive_data_on_connection_error) do
          raise "DATABASE_URL is invalid"
        end

        [url: database_url]

      {false, true} ->
        required = Keyword.take(components, [:hostname, :database, :username, :password])

        unless Enum.all?(required, fn {_key, value} -> is_binary(value) and value != "" end) do
          raise "PostgreSQL component mode requires host, database, user, and password"
        end

        port =
          case components[:port] do
            nil ->
              5432

            raw_port ->
              case Integer.parse(raw_port) do
                {parsed_port, ""} when parsed_port in 1..65_535 ->
                  parsed_port

                _invalid ->
                  raise "POSTGRES_PORT must be a decimal integer from 1 through 65535"
              end
          end

        [
          hostname: components[:hostname],
          port: port,
          database: components[:database],
          username: components[:username],
          password: components[:password]
        ]

      _neither_or_both ->
        raise "configure exactly one PostgreSQL connection mode"
    end
  end

  turso_runtime_config = fn ->
    turso_auth_token =
      case System.get_env("TURSO_AUTH_TOKEN") do
        value when value in [nil, ""] ->
          nil

        _value ->
          fn -> System.fetch_env!("TURSO_AUTH_TOKEN") end
      end

    [
      database: System.get_env("FORNACAST_DATABASE_PATH", "/data/fornacast.db"),
      remote_url: System.get_env("TURSO_DATABASE_URL"),
      auth_token: turso_auth_token
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  repo_config =
    if require_runtime_env? do
      case compiled_database_adapter do
        "postgres" -> postgres_runtime_config.()
        "turso" -> turso_runtime_config.()
      end
    else
      fixed_postgres_build_config
    end

  secret_key_base =
    fetch_runtime_env!.("SECRET_KEY_BASE", String.duplicate("0", 64))

  if byte_size(secret_key_base) < 64 do
    raise "environment variable SECRET_KEY_BASE must be at least 64 bytes"
  end

  github_credential_keyring =
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

  config :fornacast, :github_credential_keyring, github_credential_keyring

  api_bind = System.get_env("FORNACAST_API_BIND_IP", "127.0.0.1")

  api_ip =
    case :inet.parse_address(String.to_charlist(api_bind)) do
      {:ok, address} -> address
      {:error, reason} -> raise "invalid FORNACAST_API_BIND_IP: #{inspect(reason)}"
    end

  api_port =
    System.get_env("FORNACAST_API_PORT", "4891")
    |> String.to_integer()

  trusted_proxy_cidrs =
    System.get_env("FORNACAST_API_TRUSTED_PROXIES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  release_asset_root =
    System.get_env("FORNACAST_RELEASE_ASSET_STORAGE_ROOT", "/data/release-assets")
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

  if require_runtime_env? do
    config :fornacast, :database_adapter, database_adapter
  end

  config :fornacast,
         Fornacast.Repo,
         [
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           show_sensitive_data_on_connection_error: false
         ] ++ repo_config

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

  fornacast_config_store_options = [
    enabled: config_store_enabled,
    database: System.get_env("FORNACAST_CONFIG_DATABASE_PATH", "/data/fornacast_config.db"),
    pool_size: String.to_integer(System.get_env("FORNACAST_CONFIG_POOL_SIZE") || "1"),
    remote_url:
      System.get_env("FORNACAST_CONFIG_TURSO_DATABASE_URL") ||
        System.get_env("CONCORD_TURSO_REMOTE_URL"),
    auth_token: config_store_auth_token
  ]

  config :fornacast,
    release_asset_storage_root: release_asset_root,
    release_asset_max_bytes: release_asset_max_bytes,
    release_asset_gc_grace_seconds: release_asset_gc_grace_seconds

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
    turso: fornacast_config_store_options

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
    base_url: fetch_runtime_env!.("FORNACAST_BASE_URL", "http://localhost:4890"),
    repo_storage_root: fetch_runtime_env!.("FORNACAST_REPO_STORAGE_ROOT", "/data/repos"),
    ssh_host: fetch_runtime_env!.("FORNACAST_SSH_HOST", "localhost"),
    ssh_port: String.to_integer(fetch_runtime_env!.("FORNACAST_SSH_PORT", "2222")),
    ssh_system_dir: fetch_runtime_env!.("FORNACAST_SSH_SYSTEM_DIR", "/data/ssh")

  config :fornacast_web, FornacastWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4890")],
    secret_key_base: secret_key_base

  config :fornacast_api, :trusted_proxy_cidrs, trusted_proxy_cidrs

  config :fornacast_api, FornacastAPI.Endpoint,
    http: [ip: api_ip, port: api_port],
    secret_key_base: secret_key_base
end
