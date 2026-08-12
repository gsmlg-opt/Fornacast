defmodule ForgeIssues.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :forge_issues,
    adapter: Ecto.Adapters.Turso
end

defmodule ForgeIssues.IssueDomainMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeIssues.MigrationTestRepo

  @migrations_path Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @migration_path Path.join(@migrations_path, "20260721000300_create_issue_domain.exs")

  @postgres_checks MapSet.new([
                     {:repository_number_sequences, :number_sequence_positive, "next_number > 0"},
                     {:issues, :issues_kind_check, "kind in ('issue', 'pull_request')"},
                     {:issues, :issues_state_check, "state in ('open', 'closed')"},
                     {:issues, :issues_state_reason_check,
                      "state_reason is null or state_reason in ('completed', 'not_planned', 'reopened')"}
                   ])

  @tag :tmp_dir
  test "fresh Turso migration creates the issue tables and portable constraints", %{
    tmp_dir: tmp_dir
  } do
    database_path = Path.join(tmp_dir, "issue-domain.db")
    start_supervised!({MigrationTestRepo, database: database_path, pool_size: 1})

    Ecto.Migrator.run(MigrationTestRepo, @migrations_path, :up, all: true)

    expected_tables =
      MapSet.new(~w(
        repository_number_sequences
        issues
        issue_comments
        repository_labels
        issue_labels
        issue_assignees
      ))

    assert MapSet.subset?(expected_tables, table_names())

    sequence_sql = table_sql("repository_number_sequences")
    issues_sql = table_sql("issues")

    assert sequence_sql =~
             ~r/CONSTRAINT number_sequence_positive CHECK \(next_number > 0\)/

    assert sequence_sql =~
             ~r/REFERENCES "repositories" \("id"\) ON DELETE CASCADE/

    assert issues_sql =~
             ~r/CONSTRAINT issues_kind_check CHECK \(kind IN \('issue', 'pull_request'\)\)/

    assert issues_sql =~
             ~r/CONSTRAINT issues_state_check CHECK \(state IN \('open', 'closed'\)\)/

    assert issues_sql =~
             ~r/CONSTRAINT issues_state_reason_check CHECK \(state_reason IS NULL OR state_reason IN \('completed', 'not_planned', 'reopened'\)\)/

    assert issues_sql =~
             ~r/REFERENCES "repositories" \("id"\) ON DELETE CASCADE/

    assert issues_sql =~
             ~r/REFERENCES "users" \("id"\) ON DELETE RESTRICT/

    assert_indexes("issues", ~w(
      issues_repository_id_number_index
      issues_repository_id_state_updated_at_id_index
      issues_author_user_id_index
    ))

    assert_indexes("repository_labels", ~w(
      repository_labels_repository_id_normalized_name_index
      repository_labels_repository_id_name_index
    ))

    assert_indexes(
      "issue_labels",
      ~w(issue_labels_issue_id_label_id_index issue_labels_label_id_index)
    )

    assert_indexes(
      "issue_assignees",
      ~w(issue_assignees_issue_id_user_id_index issue_assignees_user_id_index)
    )

    assert_unique_index("issues", "issues_repository_id_number_index")

    assert_unique_index(
      "repository_labels",
      "repository_labels_repository_id_normalized_name_index"
    )

    assert_unique_index("issue_labels", "issue_labels_issue_id_label_id_index")
    assert_unique_index("issue_assignees", "issue_assignees_issue_id_user_id_index")
  end

  test "migration constructs the four explicit PostgreSQL check constraints" do
    {:ok, migration_ast} = @migration_path |> File.read!() |> Code.string_to_quoted()

    {_ast, checks} =
      Macro.prewalk(migration_ast, MapSet.new(), fn
        {:create_postgres_check, _meta, [table, name, expression]} = node, checks
        when is_atom(table) and is_atom(name) and is_binary(expression) ->
          {node, MapSet.put(checks, {table, name, expression})}

        node, checks ->
          {node, checks}
      end)

    assert checks == @postgres_checks
  end

  defp table_names do
    %{rows: rows} =
      SQL.query!(
        MigrationTestRepo,
        "select name from sqlite_master where type = 'table'",
        []
      )

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
    assert expected_names |> MapSet.new() |> MapSet.subset?(index_names(table))
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
