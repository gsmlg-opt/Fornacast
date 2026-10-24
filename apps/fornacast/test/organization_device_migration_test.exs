defmodule Fornacast.OrganizationDeviceMigrationRepo do
  use Ecto.Repo, otp_app: :fornacast, adapter: Ecto.Adapters.Postgres
end

defmodule Fornacast.OrganizationDeviceMigrationTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Fornacast.OrganizationDeviceMigrationRepo, as: MigrationRepo

  @version 20_261_022_000_400
  @migration_dir Path.expand("../priv/repo/migrations", __DIR__)
  @tables ~w(organization_pat_configurations organization_pat_sync_runs github_import_runs organization_mirrors)

  setup do
    schema = "org_device_migration_#{System.unique_integer([:positive])}"

    config =
      Fornacast.Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.update(
        :parameters,
        [search_path: schema],
        &Keyword.put(&1, :search_path, schema)
      )

    start_supervised!({MigrationRepo, config})
    query("CREATE SCHEMA #{schema}")

    on_exit(fn ->
      {:ok, pid} = MigrationRepo.start_link(config)

      try do
        query("DROP SCHEMA #{schema} CASCADE")
      after
        GenServer.stop(pid)
      end
    end)

    for table <-
          ~w(users organization_github_credentials organization_github_connections repository_mirrors) do
      query("CREATE TABLE #{table} (id bigint PRIMARY KEY)")
    end

    for table <- ~w(organization_pat_configurations organization_pat_sync_runs) do
      nullability = if table == "organization_pat_sync_runs", do: "NOT NULL", else: ""

      query(
        "CREATE TABLE #{table} (id bigint PRIMARY KEY, owner_user_id bigint #{nullability}, github_identity_id bigint #{nullability})"
      )
    end

    query("""
    CREATE TABLE github_import_runs (id bigint PRIMARY KEY, credential_source text,
      github_identity_id bigint NOT NULL, github_credential_id bigint, state text,
      credential_ciphertext bytea, credential_nonce bytea, credential_tag bytea, credential_key_id text,
      destination_organization_id bigint, destination_organization_action text, source_owner_github_id bigint,
      CONSTRAINT github_import_runs_credential_source_check CHECK (true),
      CONSTRAINT github_import_runs_credential_consistency_check CHECK (true))
    """)

    query(
      "CREATE TABLE organization_mirrors (id bigint PRIMARY KEY, github_installation_id bigint, github_account_id bigint)"
    )

    migrate(
      :up,
      20_260_905_000_300,
      "20260905000300_add_github_app_import_credentials.exs",
      Fornacast.Repo.Migrations.AddGitHubAppImportCredentials
    )

    migrate(
      :up,
      20_261_019_000_100,
      "20261019000100_add_pat_git_mirror_authority.exs",
      Fornacast.Repo.Migrations.AddPatGitMirrorAuthority
    )

    baseline = schema_snapshot()
    %{baseline: baseline}
  end

  test "empty schema rolls back to the exact legacy columns and constraints", c do
    assert :ok = up()
    assert :ok = down()
    assert schema_snapshot() == c.baseline
  end

  test "legacy authority and jobs survive an up down up round trip", c do
    seed_legacy()
    assert :ok = up()
    assert :ok = down()
    assert schema_snapshot() == c.baseline
    for table <- @tables, do: assert(query("SELECT id FROM #{table}").rows == [[1]])
    assert :ok = up()

    assert query("SELECT credential_source FROM organization_pat_sync_runs").rows == [
             ["personal"]
           ]
  end

  for table <- @tables do
    @table table
    test "rollback refuses before DDL when #{@table} contains organization authority" do
      seed_legacy()
      assert :ok = up()

      for table <- ~w(users organization_github_credentials organization_github_connections),
          do: query("INSERT INTO #{table} (id) VALUES (1)")

      common =
        "organization_connection_id=1, organization_connection_version=1, organization_credential_id=1, organization_credential_version=1, github_installation_id=1"

      extra =
        case @table do
          "organization_pat_configurations" ->
            ", owner_user_id=NULL, github_identity_id=NULL, configured_by_user_id=1"

          "organization_pat_sync_runs" ->
            ", owner_user_id=NULL, github_identity_id=NULL, requested_by_user_id=1, github_organization_id=1"

          "github_import_runs" ->
            ", github_identity_id=NULL, github_credential_id=NULL, organization_sync_run_id=1, destination_organization_id=1, destination_organization_action='existing', source_owner_github_id=1"

          "organization_mirrors" ->
            ", pat_configuration_id=1, pat_configuration_version=1, github_account_id=1"
        end

      query(
        "UPDATE #{@table} SET credential_source='organization_device', #{common}#{extra} WHERE id=1"
      )

      before = schema_snapshot()
      assert_raise Postgrex.Error, ~r/recorded organization authority exists/, &down/0
      assert schema_snapshot() == before

      assert query("SELECT credential_source FROM #{@table} WHERE id=1").rows == [
               ["organization_device"]
             ]

      assert @version in Ecto.Migrator.migrated_versions(MigrationRepo)
    end
  end

  defp seed_legacy do
    for table <- ~w(organization_pat_configurations organization_pat_sync_runs),
        do: query("INSERT INTO #{table} (id, owner_user_id, github_identity_id) VALUES (1, 1, 1)")

    query(
      "INSERT INTO github_import_runs (id, credential_source, github_identity_id, github_credential_id, state) VALUES (1, 'saved', 1, 1, 'queued')"
    )

    query("INSERT INTO organization_mirrors (id) VALUES (1)")
  end

  defp up,
    do:
      migrate(
        :up,
        @version,
        "20261022000400_add_organization_device_sync_source.exs",
        Fornacast.Repo.Migrations.AddOrganizationDeviceSyncSource
      )

  defp down,
    do:
      Ecto.Migrator.down(
        MigrationRepo,
        @version,
        Fornacast.Repo.Migrations.AddOrganizationDeviceSyncSource,
        log: false
      )

  defp migrate(direction, version, file, module) do
    unless Code.ensure_loaded?(module), do: Code.require_file(Path.join(@migration_dir, file))
    apply(Ecto.Migrator, direction, [MigrationRepo, version, module, [log: false]])
  end

  defp schema_snapshot do
    columns =
      query(
        "SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema=current_schema() AND table_name=ANY($1) ORDER BY table_name, ordinal_position",
        [@tables]
      ).rows

    constraints =
      query(
        "SELECT c.relname, con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=current_schema() AND c.relname=ANY($1) ORDER BY c.relname, con.conname",
        [@tables]
      ).rows

    {columns, constraints}
  end

  defp query(sql, params \\ []), do: SQL.query!(MigrationRepo, sql, params)
end
