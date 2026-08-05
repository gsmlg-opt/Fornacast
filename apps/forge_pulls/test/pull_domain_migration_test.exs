defmodule ForgePulls.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :forge_pulls,
    adapter: Ecto.Adapters.Turso
end

defmodule ForgePulls.PullDomainMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgePulls.MigrationTestRepo

  @migrations_path Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @migration_path Path.join(@migrations_path, "20260721000400_create_pull_domain.exs")
  @state_check {
    :pull_merge_operations,
    :pull_merge_operations_state_check,
    "state in ('prepared', 'merge_written', 'ref_advanced', 'completed', 'failed')"
  }

  @tag :tmp_dir
  test "fresh Turso migration creates pull tables, foreign keys, indexes, and state constraint", %{
    tmp_dir: tmp_dir
  } do
    database_path = Path.join(tmp_dir, "pull-domain.db")
    start_supervised!({MigrationTestRepo, database: database_path, pool_size: 1})

    Ecto.Migrator.run(MigrationTestRepo, @migrations_path, :up, all: true)

    assert MapSet.subset?(MapSet.new(~w(pull_requests pull_merge_operations)), table_names())

    pull_sql = table_sql("pull_requests")
    operation_sql = table_sql("pull_merge_operations")

    assert pull_sql =~ ~r/REFERENCES "issues" \("id"\) ON DELETE CASCADE/
    assert pull_sql =~ ~r/REFERENCES "repositories" \("id"\) ON DELETE RESTRICT/
    assert operation_sql =~ ~r/REFERENCES "pull_requests" \("id"\) ON DELETE RESTRICT/
    assert operation_sql =~ ~r/REFERENCES "repositories" \("id"\) ON DELETE RESTRICT/
    assert operation_sql =~ ~r/REFERENCES "users" \("id"\) ON DELETE SET NULL/

    assert operation_sql =~
             ~r/CONSTRAINT pull_merge_operations_state_check CHECK \(state IN \('prepared', 'merge_written', 'ref_advanced', 'completed', 'failed'\)\)/

    assert_indexes("pull_requests", ~w(
      pull_requests_issue_id_index
      pull_requests_repository_id_index
      pull_requests_repository_id_base_ref_index
    ))

    assert_indexes("pull_merge_operations", ~w(
      pull_merge_operations_repository_id_state_index
      pull_merge_operations_pull_request_id_state_index
      pull_merge_operations_lease_expires_at_index
    ))

    assert_unique_index("pull_requests", "pull_requests_issue_id_index")
  end

  test "migration constructs the PostgreSQL state check through the adapter helper" do
    {:ok, migration_ast} = @migration_path |> File.read!() |> Code.string_to_quoted()

    {_ast, checks} =
      Macro.prewalk(migration_ast, MapSet.new(), fn
        {:create_postgres_check, _meta, [table, name, expression]} = node, checks
        when is_atom(table) and is_atom(name) and is_binary(expression) ->
          {node, MapSet.put(checks, {table, name, expression})}

        node, checks ->
          {node, checks}
      end)

    assert checks == MapSet.new([@state_check])
  end

  defp table_names do
    %{rows: rows} =
      SQL.query!(MigrationTestRepo, "select name from sqlite_master where type = 'table'", [])

    MapSet.new(rows, fn [name] -> name end)
  end

  defp table_sql(table) do
    %{rows: [[sql]]} =
      SQL.query!(
        MigrationTestRepo,
        "select sql from sqlite_master where type = 'table' and name = ?",
        [table]
      )

    sql
  end

  defp index_names(table) do
    %{rows: rows} =
      SQL.query!(
        MigrationTestRepo,
        "select name from sqlite_master where type = 'index' and tbl_name = ?",
        [table]
      )

    MapSet.new(rows, fn [name] -> name end)
  end

  defp assert_indexes(table, expected_names) do
    assert MapSet.subset?(MapSet.new(expected_names), index_names(table))
  end

  defp assert_unique_index(table, index_name) do
    %{rows: rows} =
      SQL.query!(
        MigrationTestRepo,
        ~s|select name from pragma_index_list(?) where "unique" = 1|,
        [table]
      )

    assert [index_name] in rows
  end
end
