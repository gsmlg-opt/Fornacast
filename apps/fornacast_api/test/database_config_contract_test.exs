defmodule FornacastAPI.DatabaseConfigContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @config Path.join(@root, "config/config.exs")
  @runtime_config Path.join(@root, "config/runtime.exs")
  @config_marker "FORNACAST_CONFIG_TERM:"

  @database_env ~w(
    RELEASE_COMMAND FORNACAST_DATABASE_ADAPTER DATABASE_URL
    PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
    POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT POSTGRES_DB
    FORNACAST_DATABASE_PATH TURSO_DATABASE_URL TURSO_AUTH_TOKEN
    FORNACAST_CONFIG_TURSO_AUTH_TOKEN CONCORD_TURSO_AUTH_TOKEN
    FORNACAST_GITHUB_CREDENTIAL_KEYS FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID
  )

  @fixed_build_connection [
    hostname: "127.0.0.1",
    socket_dir: nil,
    port: 5432,
    database: "fornacast_build"
  ]

  @sentinel_url "ecto://sentinel:secret@prod.example/sentinel_db"
  @sentinel_username "sentinel_user"
  @sentinel_password "sentinel_password"
  @sentinel_host "prod.example"
  @sentinel_database "sentinel_db"

  @turso_sentinel_database "sentinel_turso_build.db"
  @turso_sentinel_url "libsql://sentinel-turso.example"
  @turso_sentinel_token "sentinel_turso_auth_token"

  @component_host "db.sentinel.invalid"
  @component_database "sentinel_runtime_database"
  @component_username "sentinel_runtime_user"
  @component_password "sentinel_runtime_password"

  test "omitted adapter selects PostgreSQL with a non-sensitive dev config" do
    {output, 0} = read_config(:dev, [])
    assert output =~ ~s(adapter="postgres")
    assert output =~ "repo_adapter=Ecto.Adapters.Postgres"
    assert output =~ ~s(database="fornacast_dev")
  end

  test "development prefers PG variables and recognizes Unix sockets" do
    {output, 0} =
      read_config(:dev,
        PGUSER: "socket_user",
        PGPASSWORD: "socket_password",
        PGHOST: "/tmp/fornacast-pg",
        PGPORT: "55432",
        PGDATABASE: "socket_db",
        POSTGRES_USER: "ignored_user",
        POSTGRES_PASSWORD: "ignored_password",
        POSTGRES_HOST: "ignored.example",
        POSTGRES_PORT: "5433",
        POSTGRES_DB: "ignored_db"
      )

    assert output =~ ~s(username="socket_user")
    assert output =~ ~s(database="socket_db")
    assert output =~ ~s(socket_dir="/tmp/fornacast-pg")
    assert output =~ "hostname=nil"
    assert output =~ "port=55432"
    assert output =~ "password_matches_pg=true"
    refute output =~ "socket_password"
    refute output =~ "ignored"
  end

  test "development falls back to the local Unix user" do
    {output, 0} = read_config(:dev, USER: "local_fornacast_user")
    assert output =~ ~s(username="local_fornacast_user")
  end

  test "explicit adapter aliases remain compile-selectable" do
    for adapter <- ["postgres", "postgresql"] do
      {output, 0} = read_config(:dev, FORNACAST_DATABASE_ADAPTER: adapter)
      assert output =~ "repo_adapter=Ecto.Adapters.Postgres"
    end

    for adapter <- ["turso", "libsql"] do
      {output, 0} = read_config(:dev, FORNACAST_DATABASE_ADAPTER: adapter)
      assert output =~ "repo_adapter=Ecto.Adapters.Turso"
    end

    {output, status} = read_config(:dev, FORNACAST_DATABASE_ADAPTER: "unsupported")
    assert status != 0
    assert output =~ "unsupported FORNACAST_DATABASE_ADAPTER"
  end

  test "development accepts TCP and rejects invalid ports" do
    {tcp, 0} = read_config(:dev, PGHOST: "127.0.0.1", PGPORT: "5433")
    assert tcp =~ ~s(hostname="127.0.0.1")
    assert tcp =~ "socket_dir=nil"
    assert tcp =~ "port=5433"

    for port <- ["5432x", "0", "65536"] do
      {invalid, status} = read_config(:dev, PGPORT: port)
      assert status != 0

      assert invalid =~
               "PGPORT/POSTGRES_PORT must be a decimal integer from 1 through 65535"
    end
  end

  test "development rejects an invalid host without echoing it" do
    invalid_host = "invalid\nhost"
    {output, status} = read_config(:dev, PGHOST: invalid_host)

    assert status != 0
    assert output =~ "PGHOST/POSTGRES_HOST must be a printable nonempty host or socket path"
    refute output =~ invalid_host
  end

  test "production build config and no-Repo runtime evaluation exclude connection credentials" do
    overrides =
      build_sentinel_overrides() ++
        [FORNACAST_DATABASE_ADAPTER: "postgres"]

    {compile_output, 0} =
      read_build_config_term(@config, :prod, overrides)

    compile_config = decode_config!(compile_output)
    compile_repo = assert_safe_build_config(compile_config)

    for release_command <- [nil, ""] do
      {runtime_output, 0} =
        read_build_config_term(
          @runtime_config,
          :prod,
          Keyword.put(overrides, :RELEASE_COMMAND, release_command)
        )

      runtime_config = decode_config!(runtime_output)
      runtime_repo = assert_safe_build_config(runtime_config)

      assert connection_literals(compile_repo) == connection_literals(runtime_repo)

      compile_config
      |> Config.Reader.merge(runtime_config)
      |> assert_safe_build_config()
    end
  end

  test "explicit Turso production builds exclude operator connection credentials" do
    overrides = [
      FORNACAST_DATABASE_ADAPTER: "turso",
      FORNACAST_DATABASE_PATH: @turso_sentinel_database,
      TURSO_DATABASE_URL: @turso_sentinel_url,
      TURSO_AUTH_TOKEN: @turso_sentinel_token
    ]

    {compile_output, 0} = read_build_config_term(@config, :prod, overrides)
    compile_config = decode_config!(compile_output)
    compile_repo = assert_safe_turso_build_config(compile_config)

    assert compile_repo[:database] == "fornacast_build.db"

    assert compile_repo[:after_connect] ==
             {Ecto.Adapters.Turso.Connection, :query, ["PRAGMA foreign_keys = ON", [], []]}

    for release_command <- [nil, ""] do
      {runtime_output, 0} =
        read_build_config_term(
          @runtime_config,
          :prod,
          Keyword.put(overrides, :RELEASE_COMMAND, release_command)
        )

      compile_config
      |> Config.Reader.merge(decode_config!(runtime_output))
      |> assert_safe_turso_build_config()
    end
  end

  test "effective URL config does not inherit absent credentials from build config" do
    build_config = production_build_config()

    {without_userinfo_output, 0} =
      read_runtime_config(Ecto.Adapters.Postgres,
        DATABASE_URL: "ecto://db.example/fornacast"
      )

    without_userinfo =
      build_config
      |> Config.Reader.merge(decode_config!(without_userinfo_output))
      |> effective_repo_config()

    assert without_userinfo[:hostname] == "db.example"
    assert without_userinfo[:database] == "fornacast"
    refute Keyword.has_key?(without_userinfo, :username)
    refute Keyword.has_key?(without_userinfo, :password)

    {complete_output, 0} =
      read_runtime_config(Ecto.Adapters.Postgres,
        DATABASE_URL: "ecto://url_user:url_password@url.example:5544/url_database"
      )

    complete =
      build_config
      |> Config.Reader.merge(decode_config!(complete_output))
      |> effective_repo_config()

    assert complete[:hostname] == "url.example"
    assert complete[:port] == 5544
    assert complete[:database] == "url_database"
    assert complete[:username] == "url_user"
    assert complete[:password] == "url_password"
  end

  test "actual release accepts URL and complete component PostgreSQL modes" do
    database_url = "ecto://user:pass@db.example/fornacast"
    {url_output, 0} = read_runtime_config(Ecto.Adapters.Postgres, DATABASE_URL: database_url)
    url_repo = url_output |> decode_config!() |> repo_config()

    assert url_repo[:url] == database_url
    assert url_repo[:show_sensitive_data_on_connection_error] == false
    refute Keyword.has_key?(url_repo, :username)
    refute Keyword.has_key?(url_repo, :password)

    component_password = "p@ss:/#?[]"

    {component_output, 0} =
      read_runtime_config(Ecto.Adapters.Postgres,
        POSTGRES_HOST: "db",
        POSTGRES_DB: "fornacast_prod",
        POSTGRES_USER: "fornacast",
        POSTGRES_PASSWORD: component_password,
        POSTGRES_PORT: "5432"
      )

    component_config = decode_config!(component_output)
    component_repo = repo_config(component_config)

    assert get_in(component_config, [:fornacast, :database_adapter]) == "postgres"
    assert component_repo[:hostname] == "db"
    assert component_repo[:database] == "fornacast_prod"
    assert component_repo[:username] == "fornacast"
    assert component_repo[:port] == 5432

    assert :crypto.hash(:sha256, component_repo[:password]) ==
             :crypto.hash(:sha256, component_password)

    refute Keyword.has_key?(component_repo, :url)
    assert component_repo[:show_sensitive_data_on_connection_error] == false
  end

  test "URL mode rejects operator control of sensitive connection diagnostics" do
    for setting <- ["true", "false"] do
      query = "show_sensitive_data_on_connection_error=#{setting}"

      database_url =
        "ecto://sentinel_reserved_user:sentinel_reserved_password@db.example/fornacast?#{query}"

      assert Ecto.Repo.Supervisor.parse_url(database_url)[
               :show_sensitive_data_on_connection_error
             ] == setting

      assert_runtime_failure(
        [DATABASE_URL: database_url],
        "DATABASE_URL is invalid",
        [
          database_url,
          "sentinel_reserved_user",
          "sentinel_reserved_password",
          query
        ]
      )
    end
  end

  test "component mode defaults an absent port to 5432" do
    {output, 0} =
      read_runtime_config(
        Ecto.Adapters.Postgres,
        Keyword.delete(component_overrides(), :POSTGRES_PORT)
      )

    assert output |> decode_config!() |> repo_config() |> Keyword.fetch!(:port) == 5432
  end

  test "actual release requires exactly one PostgreSQL connection mode" do
    assert_runtime_failure(
      [],
      "configure exactly one PostgreSQL connection mode",
      []
    )

    assert_runtime_failure(
      [DATABASE_URL: ""],
      "DATABASE_URL is invalid",
      []
    )

    malformed_url = "not-a-url-sentinel"

    assert_runtime_failure(
      [DATABASE_URL: malformed_url],
      "DATABASE_URL is invalid",
      [malformed_url]
    )

    malformed_query_url =
      "ecto://sentinel_query_user:sentinel_query_password@db.example/fornacast?pool_size=sentinel_query_value"

    assert_runtime_failure(
      [DATABASE_URL: malformed_query_url],
      "DATABASE_URL is invalid",
      [
        malformed_query_url,
        "sentinel_query_user",
        "sentinel_query_password",
        "sentinel_query_value"
      ]
    )

    conflict_url =
      "ecto://sentinel_conflict_user:sentinel_conflict_password@conflict.example/conflict_db"

    for component <- ~w(POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)a,
        component_value <- ["", "sentinel_conflict_component"] do
      assert_runtime_failure(
        [{:DATABASE_URL, conflict_url}, {component, component_value}],
        "configure exactly one PostgreSQL connection mode",
        [
          conflict_url,
          "sentinel_conflict_user",
          "sentinel_conflict_password",
          component_value
        ]
        |> Enum.reject(&(&1 == ""))
      )
    end
  end

  test "component mode rejects each missing or blank required value without disclosure" do
    for component <- ~w(POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)a,
        overrides <- [
          Keyword.delete(component_overrides(), component),
          Keyword.put(component_overrides(), component, "")
        ] do
      assert_runtime_failure(
        overrides,
        "PostgreSQL component mode requires host, database, user, and password",
        component_sentinels(overrides)
      )
    end
  end

  test "component mode strictly validates each present port" do
    for port <- ["", "0", "65536", "-1", "not-decimal", "5432trailing"] do
      overrides = Keyword.put(component_overrides(), :POSTGRES_PORT, port)

      assert_runtime_failure(
        overrides,
        "POSTGRES_PORT must be a decimal integer from 1 through 65535",
        component_sentinels(overrides)
      )
    end
  end

  test "runtime adapter assertion is checked against the compiled Repo adapter" do
    mismatch_url =
      "ecto://sentinel_mismatch_user:sentinel_mismatch_password@db.example/fornacast?pool_size=sentinel_mismatch_query"

    assert_runtime_failure(
      [FORNACAST_DATABASE_ADAPTER: "turso", DATABASE_URL: mismatch_url],
      "runtime database adapter does not match compiled adapter",
      [mismatch_url, "sentinel_mismatch_user", "sentinel_mismatch_password"],
      Ecto.Adapters.Postgres
    )

    assert_runtime_failure(
      [FORNACAST_DATABASE_ADAPTER: "postgres", DATABASE_URL: mismatch_url],
      "runtime database adapter does not match compiled adapter",
      [mismatch_url, "sentinel_mismatch_user", "sentinel_mismatch_password"],
      Ecto.Adapters.Turso
    )

    {postgres_output, 0} =
      read_runtime_config(
        Ecto.Adapters.Postgres,
        [FORNACAST_DATABASE_ADAPTER: "postgresql"] ++ component_overrides()
      )

    assert get_in(decode_config!(postgres_output), [:fornacast, :database_adapter]) == "postgres"

    {turso_output, 0} =
      read_runtime_config(Ecto.Adapters.Turso, FORNACAST_DATABASE_ADAPTER: "libsql")

    turso_config = decode_config!(turso_output)
    assert get_in(turso_config, [:fornacast, :database_adapter]) == "turso"
    assert repo_config(turso_config)[:database] == "/data/fornacast.db"

    assert_runtime_failure(
      [],
      "compiled database adapter is unsupported",
      [],
      Unsupported.DatabaseAdapter
    )
  end

  defp read_config(env, overrides) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    script = """
    config = Config.Reader.read!(#{inspect(@config)}, env: #{inspect(env)})
    values = Keyword.fetch!(config, :fornacast)
    repo = Keyword.fetch!(values, Fornacast.Repo)
    IO.puts("adapter=\#{inspect(values[:database_adapter])}")
    IO.puts("repo_adapter=\#{inspect(values[:repo_adapter])}")
    IO.puts("password_matches_pg=\#{repo[:password] == System.get_env("PGPASSWORD")}")
    for key <- [:username, :database, :hostname, :socket_dir, :port] do
      IO.puts("\#{key}=\#{inspect(repo[key])}")
    end
    """

    env =
      @database_env
      |> Map.new(&{&1, nil})
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
      |> Map.to_list()

    System.cmd(elixir, ["-e", script], cd: @root, env: env, stderr_to_stdout: true)
  end

  defp production_build_config do
    {output, 0} =
      read_build_config_term(@config, :prod, FORNACAST_DATABASE_ADAPTER: "postgres")

    decode_config!(output)
  end

  defp read_runtime_config(compiled_adapter, overrides) do
    read_actual_runtime_config_term(
      compiled_adapter,
      [
        RELEASE_COMMAND: "start",
        SECRET_KEY_BASE: String.duplicate("s", 64),
        FORNACAST_BASE_URL: "http://localhost:4890",
        FORNACAST_REPO_STORAGE_ROOT: "/tmp/fornacast-database-contract-repos",
        FORNACAST_SSH_HOST: "localhost",
        FORNACAST_SSH_PORT: "2222",
        FORNACAST_SSH_SYSTEM_DIR: "/tmp/fornacast-database-contract-ssh"
      ] ++ overrides
    )
  end

  defp read_build_config_term(path, env, overrides) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    empty_environment_variables =
      for {key, ""} <- overrides, do: to_string(key)

    script = """
    Enum.each(#{inspect(empty_environment_variables)}, &System.put_env(&1, ""))
    :non_existing = :code.which(Fornacast.Repo)

    config = Config.Reader.read!(#{inspect(path)}, env: #{inspect(env)}, target: :host)
    :non_existing = :code.which(Fornacast.Repo)
    IO.write(#{inspect(@config_marker)} <> Base.encode64(:erlang.term_to_binary(config, [:deterministic])))
    """

    System.cmd(elixir, ["-e", script],
      cd: @root,
      env: config_reader_env(overrides),
      stderr_to_stdout: true
    )
  end

  defp read_actual_runtime_config_term(compiled_adapter, overrides) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    ecto_ebin = Ecto.Repo.Supervisor |> :code.which() |> to_string() |> Path.dirname()

    empty_environment_variables =
      for {key, ""} <- overrides, do: to_string(key)

    script = """
    Enum.each(#{inspect(empty_environment_variables)}, &System.put_env(&1, ""))

    defmodule Fornacast.Repo do
      def __adapter__, do: #{inspect(compiled_adapter)}
    end

    config = Config.Reader.read!(#{inspect(@runtime_config)}, env: :prod, target: :host)
    IO.write(#{inspect(@config_marker)} <> Base.encode64(:erlang.term_to_binary(config, [:deterministic])))
    """

    System.cmd(elixir, ["-pa", ecto_ebin, "-e", script],
      cd: @root,
      env: config_reader_env(overrides),
      stderr_to_stdout: true
    )
  end

  defp config_reader_env(overrides) do
    @database_env
    |> Map.new(&{&1, nil})
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
    |> Map.to_list()
  end

  defp decode_config!(output) do
    case String.split(output, @config_marker, parts: 2) do
      [_prefix, encoded] ->
        encoded
        |> String.trim()
        |> Base.decode64!()
        |> :erlang.binary_to_term([:safe])

      _ ->
        flunk("runtime config subprocess did not return a serialized config")
    end
  end

  defp assert_safe_build_config(config) do
    repo = repo_config(config)

    assert connection_literals(repo) == @fixed_build_connection
    refute Keyword.has_key?(repo, :url)
    refute Keyword.has_key?(repo, :username)
    refute Keyword.has_key?(repo, :password)
    assert repo[:show_sensitive_data_on_connection_error] == false

    serialized = :erlang.term_to_binary(config, [:deterministic])

    for sentinel <- [
          @sentinel_url,
          @sentinel_username,
          @sentinel_password,
          @sentinel_host,
          @sentinel_database
        ] do
      assert :binary.match(serialized, sentinel) == :nomatch
    end

    repo
  end

  defp assert_safe_turso_build_config(config) do
    repo = repo_config(config)

    refute Keyword.has_key?(repo, :remote_url)
    refute Keyword.has_key?(repo, :auth_token)
    assert repo[:show_sensitive_data_on_connection_error] == false

    serialized = :erlang.term_to_binary(config, [:deterministic])

    for sentinel <- [
          @turso_sentinel_database,
          @turso_sentinel_url,
          @turso_sentinel_token
        ] do
      assert :binary.match(serialized, sentinel) == :nomatch
    end

    repo
  end

  defp effective_repo_config(config) do
    {url, repo} = config |> repo_config() |> Keyword.pop(:url)
    Keyword.merge(repo, Ecto.Repo.Supervisor.parse_url(url))
  end

  defp repo_config(config), do: get_in(config, [:fornacast, Fornacast.Repo])

  defp connection_literals(repo) do
    Enum.map([:hostname, :socket_dir, :port, :database], &{&1, repo[&1]})
  end

  defp build_sentinel_overrides do
    [
      DATABASE_URL: @sentinel_url,
      PGUSER: @sentinel_username,
      PGPASSWORD: @sentinel_password,
      PGHOST: @sentinel_host,
      PGPORT: "6543",
      PGDATABASE: @sentinel_database,
      POSTGRES_USER: @sentinel_username,
      POSTGRES_PASSWORD: @sentinel_password,
      POSTGRES_HOST: @sentinel_host,
      POSTGRES_PORT: "6543",
      POSTGRES_DB: @sentinel_database
    ]
  end

  defp component_overrides do
    [
      POSTGRES_HOST: @component_host,
      POSTGRES_PORT: "5432",
      POSTGRES_DB: @component_database,
      POSTGRES_USER: @component_username,
      POSTGRES_PASSWORD: @component_password
    ]
  end

  defp component_sentinels(overrides) do
    for key <- ~w(POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)a,
        value = Keyword.get(overrides, key),
        is_binary(value) and value != "",
        do: value
  end

  defp assert_runtime_failure(
         overrides,
         expected_message,
         sentinels,
         compiled_adapter \\ Ecto.Adapters.Postgres
       ) do
    {output, status} = read_runtime_config(compiled_adapter, overrides)

    assert status != 0
    assert output =~ expected_message

    for sentinel <- sentinels do
      refute output =~ sentinel
    end
  end
end
