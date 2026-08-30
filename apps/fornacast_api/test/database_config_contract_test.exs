defmodule FornacastAPI.DatabaseConfigContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @config Path.join(@root, "config/config.exs")

  @database_env ~w(
    FORNACAST_DATABASE_ADAPTER DATABASE_URL
    PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
    POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT POSTGRES_DB
  )

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
end
