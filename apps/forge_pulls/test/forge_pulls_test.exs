defmodule ForgePullsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest}
  alias Fornacast.Repo

  @states ~w(prepared merge_written ref_advanced completed failed)

  @expected_contract %{
    "pull_requests" => %{
      columns: %{
        "id" => %{type: :bigint, nullable: false, default: :generated},
        "issue_id" => %{type: :bigint, nullable: false, default: nil},
        "repository_id" => %{type: :bigint, nullable: false, default: nil},
        "head_ref" => %{type: :text, nullable: false, default: nil},
        "base_ref" => %{type: :text, nullable: false, default: nil},
        "head_sha" => %{type: :text, nullable: false, default: nil},
        "base_sha" => %{type: :text, nullable: false, default: nil},
        "mergeable" => %{type: :boolean, nullable: true, default: nil},
        "mergeable_state" => %{type: :text, nullable: true, default: nil},
        "merged_at" => %{type: :timestamp, nullable: true, default: nil, utc: true},
        "merged_by_user_id" => %{type: :bigint, nullable: true, default: nil},
        "merge_commit_sha" => %{type: :text, nullable: true, default: nil},
        "inserted_at" => %{type: :timestamp, nullable: false, default: nil, utc: true},
        "updated_at" => %{type: :timestamp, nullable: false, default: nil, utc: true}
      },
      foreign_keys:
        MapSet.new([
          {"issue_id", "issues", "id", :cascade},
          {"repository_id", "repositories", "id", :cascade},
          {"merged_by_user_id", "users", "id", :nilify}
        ]),
      indexes:
        MapSet.new([
          {false, ["repository_id"]},
          {false, ["repository_id", "base_ref"]},
          {true, ["issue_id"]}
        ]),
      checks: %{}
    },
    "pull_merge_operations" => %{
      columns: %{
        "id" => %{type: :bigint, nullable: false, default: :generated},
        "pull_request_id" => %{type: :bigint, nullable: false, default: nil},
        "repository_id" => %{type: :bigint, nullable: false, default: nil},
        "actor_user_id" => %{type: :bigint, nullable: true, default: nil},
        "request_id" => %{type: :text, nullable: false, default: nil},
        "base_ref" => %{type: :text, nullable: false, default: nil},
        "head_ref" => %{type: :text, nullable: false, default: nil},
        "expected_base_oid" => %{type: :text, nullable: false, default: nil},
        "expected_head_oid" => %{type: :text, nullable: false, default: nil},
        "merge_oid" => %{type: :text, nullable: true, default: nil},
        "state" => %{type: :text, nullable: false, default: nil},
        "lease_owner" => %{type: :text, nullable: true, default: nil},
        "lease_expires_at" => %{
          type: :timestamp,
          nullable: true,
          default: nil,
          utc: true
        },
        "failure_reason" => %{type: :text, nullable: true, default: nil},
        "lock_version" => %{type: :integer, nullable: false, default: 0},
        "inserted_at" => %{type: :timestamp, nullable: false, default: nil, utc: true},
        "updated_at" => %{type: :timestamp, nullable: false, default: nil, utc: true}
      },
      foreign_keys:
        MapSet.new([
          {"pull_request_id", "pull_requests", "id", :cascade},
          {"repository_id", "repositories", "id", :cascade},
          {"actor_user_id", "users", "id", :nilify}
        ]),
      indexes:
        MapSet.new([
          {false, ["repository_id", "state"]},
          {false, ["pull_request_id", "state"]},
          {false, ["lease_expires_at"]}
        ]),
      checks: %{"state" => MapSet.new(@states)}
    }
  }

  setup do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    :ok
  end

  test "pull request creation accepts the documented Task 2 constructor" do
    attrs = %{
      issue_id: 1,
      repository_id: 10,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40)
    }

    changeset = PullRequest.create_changeset(%PullRequest{}, attrs)

    assert changeset.valid?

    assert %PullRequest{
             issue_id: 1,
             repository_id: 10,
             head_ref: "refs/heads/feature",
             base_ref: "refs/heads/main",
             head_sha: head_sha,
             base_sha: base_sha
           } = Ecto.Changeset.apply_changes(changeset)

    assert head_sha == String.duplicate("a", 40)
    assert base_sha == String.duplicate("b", 40)
  end

  test "a reader opens a pull with a canonical shared issue identity and may update its shared fields" do
    suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    owner = user_fixture("pull-owner-#{suffix}")
    reader = user_fixture("pull-reader-#{suffix}")
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    create_branch!(repository, "main")
    create_branch!(repository, "feature/x")

    assert {:error, :invalid_head} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing", base: "main"},
               %{}
             )

    assert {:error, :invalid_base} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing", head: "feature/x"},
               %{}
             )

    assert {:error, :head_equals_base} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "same", head: "main", base: "main"},
               %{}
             )

    assert {:error, :cross_repository_head} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "foreign", head: "other:feature/x", base: "main"},
               %{}
             )

    assert {:error, :invalid_head} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing ref", head: "missing", base: "main"},
               %{}
             )

    assert {:error, :invalid_base} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing ref", head: "feature/x", base: "missing"},
               %{}
             )

    attrs = %{
      title: "Add feature",
      body: "description",
      head: "#{owner.username}:feature/x",
      base: "main"
    }

    assert {:ok, pull} = ForgePulls.create_pull_request(repository, reader, attrs, %{})
    assert pull.head_ref == "refs/heads/feature/x"
    assert pull.base_ref == "refs/heads/main"

    assert %Issue{number: 1, kind: :pull_request, title: "Add feature"} =
             Repo.get!(Issue, pull.issue_id)

    assert {:ok, updated} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               reader,
               %{title: "Renamed", state: :closed},
               %{}
             )

    assert updated.id == pull.id
    assert %Issue{title: "Renamed", state: :closed} = Repo.get!(Issue, pull.issue_id)

    assert {:ok, %{entries: [listed], total: 1}} =
             ForgePulls.list_pull_requests(repository, reader, %{
               state: :closed,
               sort: :number,
               direction: :asc
             })

    assert listed.id == pull.id

    assert {:ok, %{entries: [^listed]}} =
             ForgePulls.list_pull_requests(repository, reader, %{
               state: "closed",
               head: "#{String.upcase(owner.username)}:feature/x",
               base: "main"
             })

    issue_id = pull.issue_id

    assert {:ok, %{^issue_id => %{merged_at: nil}}} =
             ForgePulls.pull_links_for_issue_ids(repository, [issue_id], reader)
  end

  test "pull requests require distinct canonical branch refs and immutable repository identity" do
    pull = %PullRequest{repository_id: 10}

    changeset =
      PullRequest.create_changeset(pull, %{
        issue_id: 1,
        repository_id: 11,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{repository_id: ["is immutable"]} = errors_on(changeset)

    invalid_ref =
      PullRequest.create_changeset(%PullRequest{repository_id: 10}, %{
        issue_id: 1,
        head_ref: "feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(invalid_ref)

    equal_refs =
      PullRequest.create_changeset(%PullRequest{repository_id: 10}, %{
        issue_id: 1,
        head_ref: "refs/heads/main",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{base_ref: ["must differ from head ref"]} = errors_on(equal_refs)
  end

  test "pull requests accept valid Unicode nested branches and reject Git-invalid ref forms" do
    valid_refs = ["refs/heads/feature/東京", "refs/heads/release/v1", "refs/heads/feature-v1"]

    for ref <- valid_refs do
      changeset =
        PullRequest.create_changeset(
          %PullRequest{repository_id: 10},
          valid_pull_attrs(%{head_ref: ref})
        )

      refute Map.has_key?(errors_on(changeset), :head_ref)
    end

    invalid_refs = [
      "refs/heads/..",
      "refs/heads/feature..next",
      "refs/heads/feature name",
      "refs/heads/feature\nnext",
      "refs/heads/feature~next",
      "refs/heads/feature^next",
      "refs/heads/feature:next",
      "refs/heads/feature?next",
      "refs/heads/feature*next",
      "refs/heads/feature[next",
      "refs/heads/feature\\next",
      "refs/heads/feature@{next",
      "refs/heads//feature",
      "refs/heads/feature/",
      "refs/heads/./feature",
      "refs/heads/feature/../next",
      "refs/heads/.hidden",
      "refs/heads/feature/.hidden",
      "refs/heads/feature.",
      "refs/heads/feature.lock"
    ]

    for ref <- invalid_refs do
      changeset =
        PullRequest.create_changeset(
          %PullRequest{repository_id: 10},
          valid_pull_attrs(%{head_ref: ref})
        )

      assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(changeset)
    end
  end

  test "pull request creation rejects persisted structs without applying mutable snapshots" do
    pull = %PullRequest{
      id: 42,
      issue_id: 1,
      repository_id: 10,
      head_ref: "refs/heads/original",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40)
    }

    changeset =
      PullRequest.create_changeset(
        pull,
        valid_pull_attrs(%{
          issue_id: 2,
          repository_id: 11,
          head_ref: "refs/heads/replacement",
          base_ref: "refs/heads/release",
          head_sha: String.duplicate("c", 40),
          base_sha: String.duplicate("d", 40)
        })
      )

    assert %{base: ["cannot create a persisted pull request"]} = errors_on(changeset)
    assert changeset.changes == %{}
  end

  test "merge operations only move through durable next states and redact failure reasons" do
    operation = %MergeOperation{state: :prepared, failure_reason: "private git error"}

    assert %{state: ["is not a valid transition"]} =
             operation |> MergeOperation.transition_changeset(:completed) |> errors_on()

    assert %{state: :merge_written} =
             operation
             |> MergeOperation.transition_changeset(:merge_written)
             |> Ecto.Changeset.apply_changes()

    assert %{failure_reason: nil} = MergeOperation.public(operation)
  end

  test "merge operation preparation only accepts the prepared state" do
    attrs = %{
      pull_request_id: 1,
      repository_id: 1,
      request_id: "request-1",
      base_ref: "refs/heads/main",
      head_ref: "refs/heads/feature",
      expected_base_oid: String.duplicate("a", 40),
      expected_head_oid: String.duplicate("b", 40),
      state: :merge_written
    }

    assert %{state: ["is invalid"]} =
             %MergeOperation{} |> MergeOperation.prepare_changeset(attrs) |> errors_on()
  end

  test "merge transitions expose only the sequential graph and sanitized pre-CAS failure" do
    sources = [:prepared, :merge_written, :ref_advanced, :completed, :failed]

    sequential =
      MapSet.new(prepared: :merge_written, merge_written: :ref_advanced, ref_advanced: :completed)

    for source <- sources, target <- sources do
      changeset = MergeOperation.transition_changeset(%MergeOperation{state: source}, target)

      if MapSet.member?(sequential, {source, target}) do
        assert %{state: ^target} = Ecto.Changeset.apply_changes(changeset)
      else
        assert %{state: ["is not a valid transition"]} = errors_on(changeset)
      end
    end

    for {transition, expected_source, target} <- [
          {:merge_written_changeset, :prepared, :merge_written},
          {:ref_advanced_changeset, :merge_written, :ref_advanced},
          {:completed_changeset, :ref_advanced, :completed}
        ],
        source <- sources do
      changeset = apply(MergeOperation, transition, [%MergeOperation{state: source}])

      if source == expected_source do
        assert %{state: ^target} = Ecto.Changeset.apply_changes(changeset)
      else
        assert %{state: ["is not a valid transition"]} = errors_on(changeset)
      end
    end

    for {source, reason, sanitized_reason} <- [
          {:prepared, "prepared\n\u0000failure", "prepared failure"},
          {:merge_written, "merge-written\u0000\n failure", "merge-written failure"}
        ] do
      assert %{state: :failed, failure_reason: ^sanitized_reason} =
               %MergeOperation{state: source}
               |> MergeOperation.failed_changeset(reason)
               |> Ecto.Changeset.apply_changes()
    end

    for source <- [:ref_advanced, :completed, :failed] do
      assert %{state: ["is not a valid transition"]} =
               %MergeOperation{state: source}
               |> MergeOperation.failed_changeset("failure")
               |> errors_on()
    end

    for source <- [:prepared, :merge_written], reason <- [nil, "", " \n\u0000\t "] do
      assert %{failure_reason: ["can't be blank"]} =
               %MergeOperation{state: source}
               |> MergeOperation.failed_changeset(reason)
               |> errors_on()
    end

    bounded_reason = String.duplicate("x", 600)

    assert %{state: :failed, failure_reason: sanitized_reason} =
             %MergeOperation{state: :prepared}
             |> MergeOperation.failed_changeset(bounded_reason)
             |> Ecto.Changeset.apply_changes()

    assert String.length(sanitized_reason) == 512
  end

  test "the active adapter enforces the exact durable pull database contract" do
    assert database_contract() == @expected_contract

    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)

    for state <- @states do
      assert {:ok, %{num_rows: 1}} =
               insert_merge_operation(fixture, state, "allowed-#{state}")
    end

    assert_constraint_rejected(fn ->
      insert_merge_operation(fixture, "not-a-pull-state", "invalid-state")
    end)

    assert_constraint_rejected(fn -> insert_pull(fixture.issue_id, fixture.repository_id) end)
    assert_constraint_rejected(fn -> insert_pull(-1, fixture.repository_id) end)
    assert_constraint_rejected(fn -> insert_pull(fixture.spare_issue_ids.issue_2, -1) end)

    assert_constraint_rejected(fn ->
      insert_pull(fixture.spare_issue_ids.issue_3, fixture.repository_id, -1)
    end)

    assert_constraint_rejected(fn ->
      insert_merge_operation(%{fixture | pull_request_id: -1}, "prepared", "missing-pull")
    end)

    assert_constraint_rejected(fn ->
      insert_merge_operation(%{fixture | repository_id: -1}, "prepared", "missing-repo")
    end)

    assert_constraint_rejected(fn ->
      insert_merge_operation(fixture, "prepared", "missing-actor", -1)
    end)
  end

  test "deleting a repository cascades through issues, pulls, and merge operations" do
    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)
    assert {:ok, %{num_rows: 1}} = insert_merge_operation(fixture, "prepared", "repo-cascade")

    assert %{num_rows: 1} = delete_by_id("repositories", fixture.repository_id)
    assert count_by_id("repositories", fixture.repository_id) == 0
    assert count_by_foreign_key("issues", "repository_id", fixture.repository_id) == 0
    assert count_by_foreign_key("pull_requests", "repository_id", fixture.repository_id) == 0

    assert count_by_foreign_key(
             "pull_merge_operations",
             "repository_id",
             fixture.repository_id
           ) == 0

    assert count_by_id("users", fixture.user_id) == 1
  end

  test "deleting an issue cascades through its pull and operation but retains the repository" do
    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)
    assert {:ok, %{num_rows: 1}} = insert_merge_operation(fixture, "prepared", "issue-cascade")

    assert %{num_rows: 1} = delete_by_id("issues", fixture.issue_id)
    assert count_by_id("issues", fixture.issue_id) == 0
    assert count_by_id("pull_requests", fixture.pull_request_id) == 0

    assert count_by_foreign_key(
             "pull_merge_operations",
             "pull_request_id",
             fixture.pull_request_id
           ) == 0

    assert count_by_id("repositories", fixture.repository_id) == 1
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        replacement = if is_list(value), do: inspect(value), else: to_string(value)
        String.replace(acc, "%{#{key}}", replacement)
      end)
    end)
  end

  defp valid_pull_attrs(overrides) do
    Map.merge(
      %{
        issue_id: 1,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      },
      overrides
    )
  end

  defp database_contract do
    case database_adapter() do
      :turso -> turso_database_contract()
      :postgres -> postgres_database_contract()
    end
  end

  defp turso_database_contract do
    Map.new(Map.keys(@expected_contract), fn table ->
      table_sql = turso_table_sql(table)

      {table,
       %{
         columns: turso_columns(table),
         foreign_keys: turso_foreign_keys(table, table_sql),
         indexes: turso_indexes(table),
         checks: turso_checks(table_sql)
       }}
    end)
  end

  defp turso_columns(table) do
    %{rows: rows} = SQL.query!(Repo, "PRAGMA table_info('#{table}')", [])

    Map.new(rows, fn [_cid, name, declared_type, not_null, default, primary_key] ->
      type = turso_semantic_type(name, declared_type)

      metadata = %{
        type: type,
        nullable: not_null == 0 and primary_key == 0,
        default: normalize_default(name, default, primary_key == 1)
      }

      {name, maybe_mark_utc(metadata)}
    end)
  end

  defp turso_semantic_type(name, "INTEGER")
       when name in [
              "id",
              "issue_id",
              "repository_id",
              "merged_by_user_id",
              "pull_request_id",
              "actor_user_id"
            ],
       do: :bigint

  defp turso_semantic_type("mergeable", "INTEGER"), do: :boolean
  defp turso_semantic_type("lock_version", "INTEGER"), do: :integer

  defp turso_semantic_type(name, "TEXT")
       when name in ["merged_at", "lease_expires_at", "inserted_at", "updated_at"],
       do: :timestamp

  defp turso_semantic_type(_name, "TEXT"), do: :text

  defp turso_foreign_keys(table, table_sql) do
    case SQL.query(Repo, "PRAGMA foreign_key_list('#{table}')", []) do
      {:ok, %{rows: rows}} ->
        MapSet.new(rows, fn [_id, _seq, target, source, target_column, _update, delete, _match] ->
          {source, target, target_column, normalize_delete_action(delete)}
        end)

      {:error, _unsupported_by_exturso} ->
        sqlite_master_foreign_keys(table_sql)
    end
  end

  defp sqlite_master_foreign_keys(table_sql) do
    ~r/[\(,]\s*"([^"]+)"\s+INTEGER\b[^,]*?CONSTRAINT\s+"[^"]+"\s+REFERENCES\s+"([^"]+)"\s+\("([^"]+)"\)\s+ON DELETE\s+(CASCADE|RESTRICT|NO ACTION|SET NULL)/
    |> Regex.scan(table_sql, capture: :all_but_first)
    |> MapSet.new(fn [source, target, target_column, delete] ->
      {source, target, target_column, normalize_delete_action(delete)}
    end)
  end

  defp turso_indexes(table) do
    %{rows: rows} = SQL.query!(Repo, "PRAGMA index_list('#{table}')", [])

    MapSet.new(rows, fn [_sequence, index_name, unique, _origin, _partial] ->
      %{rows: column_rows} = SQL.query!(Repo, "PRAGMA index_info('#{index_name}')", [])
      {unique == 1, Enum.map(column_rows, fn [_sequence, _column_id, name] -> name end)}
    end)
  end

  defp turso_table_sql(table) do
    %{rows: [[sql]]} =
      SQL.query!(Repo, "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?", [
        "table",
        table
      ])

    sql
  end

  defp turso_checks(table_sql) do
    allowed_states =
      ~r/'([^']+)'/
      |> Regex.scan(table_sql, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    if MapSet.size(allowed_states) == 0,
      do: %{},
      else: %{"state" => allowed_states}
  end

  defp postgres_database_contract do
    columns = postgres_columns()
    foreign_keys = postgres_foreign_keys()
    indexes = postgres_indexes()
    checks = postgres_checks()

    Map.new(Map.keys(@expected_contract), fn table ->
      {table,
       %{
         columns: Map.fetch!(columns, table),
         foreign_keys: Map.get(foreign_keys, table, MapSet.new()),
         indexes: Map.get(indexes, table, MapSet.new()),
         checks: Map.get(checks, table, %{})
       }}
    end)
  end

  defp postgres_columns do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT table_name, column_name, data_type, udt_name, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name IN ('pull_requests', 'pull_merge_operations')
      ORDER BY table_name, ordinal_position
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {table, table_rows} ->
      columns =
        Map.new(table_rows, fn [_table, name, data_type, udt_name, nullable, default] ->
          type = postgres_semantic_type(data_type, udt_name)

          metadata = %{
            type: type,
            nullable: nullable == "YES",
            default: normalize_default(name, default, name == "id")
          }

          {name, maybe_mark_utc(metadata)}
        end)

      {table, columns}
    end)
  end

  defp postgres_semantic_type("bigint", "int8"), do: :bigint
  defp postgres_semantic_type("integer", "int4"), do: :integer
  defp postgres_semantic_type("boolean", "bool"), do: :boolean
  defp postgres_semantic_type("character varying", "varchar"), do: :text
  defp postgres_semantic_type("text", "text"), do: :text
  defp postgres_semantic_type("timestamp without time zone", "timestamp"), do: :timestamp

  defp postgres_foreign_keys do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT tc.table_name, kcu.column_name, ccu.table_name, ccu.column_name,
             rc.delete_rule
      FROM information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu
        ON kcu.constraint_schema = tc.constraint_schema
       AND kcu.constraint_name = tc.constraint_name
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_schema = tc.constraint_schema
       AND ccu.constraint_name = tc.constraint_name
      JOIN information_schema.referential_constraints AS rc
        ON rc.constraint_schema = tc.constraint_schema
       AND rc.constraint_name = tc.constraint_name
      WHERE tc.table_schema = 'public'
        AND tc.constraint_type = 'FOREIGN KEY'
        AND tc.table_name IN ('pull_requests', 'pull_merge_operations')
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {table, table_rows} ->
      values =
        MapSet.new(table_rows, fn [_table, source, target, target_column, delete] ->
          {source, target, target_column, normalize_delete_action(delete)}
        end)

      {table, values}
    end)
  end

  defp postgres_indexes do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT tablename, indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename IN ('pull_requests', 'pull_merge_operations')
        AND indexname NOT LIKE '%\\_pkey' ESCAPE '\\'
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {table, table_rows} ->
      values =
        MapSet.new(table_rows, fn [_table, _index_name, definition] ->
          [columns] = Regex.run(~r/\(([^()]+)\)$/, definition, capture: :all_but_first)

          {String.starts_with?(definition, "CREATE UNIQUE INDEX"),
           columns |> String.split(",") |> Enum.map(&String.trim/1)}
        end)

      {table, values}
    end)
  end

  defp postgres_checks do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT table_name, pg_get_constraintdef(pg_constraint.oid)
      FROM pg_constraint
      JOIN information_schema.table_constraints
        ON constraint_name = conname
       AND constraint_schema = 'public'
      WHERE conname = 'pull_merge_operations_state_check'
      """)

    Map.new(rows, fn [table, definition] ->
      states =
        ~r/'([^']+)'/
        |> Regex.scan(definition, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      {table, %{"state" => states}}
    end)
  end

  defp normalize_default(_name, _default, true), do: :generated
  defp normalize_default("lock_version", default, false) when default in [0, "0"], do: 0
  defp normalize_default(_name, nil, false), do: nil

  defp maybe_mark_utc(%{type: :timestamp} = metadata), do: Map.put(metadata, :utc, true)
  defp maybe_mark_utc(metadata), do: metadata

  defp normalize_delete_action(action) when action in ["RESTRICT", "NO ACTION"], do: :restrict
  defp normalize_delete_action("CASCADE"), do: :cascade
  defp normalize_delete_action("SET NULL"), do: :nilify

  defp insert_contract_fixture(key) do
    user_id =
      insert_id(
        """
        INSERT INTO users
          (username, email, password_hash, role, state, inserted_at, updated_at)
        VALUES (?, ?, 'hash', 'user', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        """
        INSERT INTO users
          (username, email, password_hash, role, state, inserted_at, updated_at)
        VALUES ($1, $2, 'hash', 'user', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        [key, "#{key}@example.test"]
      )

    repository_id =
      insert_id(
        """
        INSERT INTO repositories
          (owner_user_id, slug, name, visibility, storage_path, default_branch,
           inserted_at, updated_at)
        VALUES (?, ?, ?, 'private', ?, 'main', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        """
        INSERT INTO repositories
          (owner_user_id, slug, name, visibility, storage_path, default_branch,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, 'private', $4, 'main', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        [user_id, key, key, "/tmp/#{key}.git"]
      )

    issue_ids =
      Map.new(1..3, fn number ->
        issue_id =
          insert_id(
            """
            INSERT INTO issues
              (repository_id, number, kind, title, state, author_user_id,
               inserted_at, updated_at)
            VALUES (?, ?, 'pull_request', ?, 'open', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING id
            """,
            """
            INSERT INTO issues
              (repository_id, number, kind, title, state, author_user_id,
               inserted_at, updated_at)
            VALUES ($1, $2, 'pull_request', $3, 'open', $4,
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING id
            """,
            [repository_id, number, "#{key}-#{number}", user_id]
          )

        {String.to_atom("issue_#{number}"), issue_id}
      end)

    issue_id = issue_ids.issue_1
    pull_request_id = insert_pull!(issue_id, repository_id)

    %{
      key: key,
      user_id: user_id,
      repository_id: repository_id,
      issue_id: issue_id,
      spare_issue_ids: issue_ids,
      pull_request_id: pull_request_id
    }
  end

  defp contract_fixture_key do
    "pull-contract-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_pull(issue_id, repository_id, merged_by_user_id \\ nil) do
    sql(
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         merged_by_user_id, inserted_at, updated_at)
      VALUES (?, ?, 'refs/heads/feature', 'refs/heads/main', ?, ?, ?,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         merged_by_user_id, inserted_at, updated_at)
      VALUES ($1, $2, 'refs/heads/feature', 'refs/heads/main', $3, $4, $5,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        issue_id,
        repository_id,
        String.duplicate("a", 40),
        String.duplicate("b", 40),
        merged_by_user_id
      ]
    )
  end

  defp insert_pull!(issue_id, repository_id) do
    insert_id(
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         inserted_at, updated_at)
      VALUES (?, ?, 'refs/heads/feature', 'refs/heads/main', ?, ?,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
      """,
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         inserted_at, updated_at)
      VALUES ($1, $2, 'refs/heads/feature', 'refs/heads/main', $3, $4,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
      """,
      [issue_id, repository_id, String.duplicate("a", 40), String.duplicate("b", 40)]
    )
  end

  defp insert_merge_operation(fixture, state, request_id, actor_user_id \\ nil) do
    sql(
      """
      INSERT INTO pull_merge_operations
        (pull_request_id, repository_id, actor_user_id, request_id, base_ref, head_ref,
         expected_base_oid, expected_head_oid, state, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, 'refs/heads/main', 'refs/heads/feature', ?, ?, ?,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      """
      INSERT INTO pull_merge_operations
        (pull_request_id, repository_id, actor_user_id, request_id, base_ref, head_ref,
         expected_base_oid, expected_head_oid, state, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'refs/heads/main', 'refs/heads/feature', $5, $6, $7,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        fixture.pull_request_id,
        fixture.repository_id,
        actor_user_id,
        request_id,
        String.duplicate("a", 40),
        String.duplicate("b", 40),
        state
      ]
    )
  end

  defp assert_constraint_rejected(fun) do
    assert {:error, {:constraint, _error}} =
             Repo.transaction(fn ->
               case fun.() do
                 {:ok, _result} -> Repo.rollback(:constraint_not_enforced)
                 {:error, error} -> Repo.rollback({:constraint, error})
               end
             end)
  end

  defp delete_contract_fixture(key) do
    sql!(
      "DELETE FROM pull_merge_operations WHERE pull_request_id IN (SELECT id FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE ?))",
      "DELETE FROM pull_merge_operations WHERE pull_request_id IN (SELECT id FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE $1))",
      ["#{key}%"]
    )

    sql!(
      "DELETE FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE ?)",
      "DELETE FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE $1)",
      ["#{key}%"]
    )

    sql!("DELETE FROM issues WHERE title LIKE ?", "DELETE FROM issues WHERE title LIKE $1", [
      "#{key}%"
    ])

    sql!("DELETE FROM repositories WHERE slug = ?", "DELETE FROM repositories WHERE slug = $1", [
      key
    ])

    sql!("DELETE FROM users WHERE username = ?", "DELETE FROM users WHERE username = $1", [key])
  end

  defp cleanup_contract_fixture(key) do
    if database_adapter() == :turso, do: on_exit(fn -> delete_contract_fixture(key) end)
  end

  defp delete_by_id(table, id) do
    sql!("DELETE FROM #{table} WHERE id = ?", "DELETE FROM #{table} WHERE id = $1", [id])
  end

  defp count_by_id(table, id), do: count_by_foreign_key(table, "id", id)

  defp count_by_foreign_key(table, column, id) do
    %{rows: [[count]]} =
      sql!(
        "SELECT count(*) FROM #{table} WHERE #{column} = ?",
        "SELECT count(*) FROM #{table} WHERE #{column} = $1",
        [id]
      )

    count
  end

  defp insert_id(turso_sql, postgres_sql, params) do
    %{rows: [[id]]} = sql!(turso_sql, postgres_sql, params)
    id
  end

  defp sql(turso_sql, postgres_sql, params) do
    SQL.query(Repo, adapter_sql(turso_sql, postgres_sql), params)
  end

  defp sql!(turso_sql, postgres_sql, params) do
    SQL.query!(Repo, adapter_sql(turso_sql, postgres_sql), params)
  end

  defp adapter_sql(turso_sql, postgres_sql) do
    case database_adapter() do
      :turso -> turso_sql
      :postgres -> postgres_sql
    end
  end

  defp database_adapter do
    case Application.fetch_env!(:fornacast, :database_adapter) do
      value when value in ["turso", "libsql"] -> :turso
      value when value in ["postgres", "postgresql"] -> :postgres
    end
  end

  defp grant_reader!(repository, user) do
    %ForgeRepos.Collaborator{}
    |> ForgeRepos.Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: :read
    })
    |> Repo.insert!()
  end

  defp user_fixture(username) do
    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp repository_fixture(owner) do
    slug = "pull-#{System.unique_integer([:positive])}"

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{name: slug, slug: slug, visibility: :private})

    repository
  end

  defp create_branch!(repository, branch) do
    path = ForgeRepos.absolute_storage_path(repository)

    empty_tree =
      Path.join(System.tmp_dir!(), "pull-empty-tree-#{System.unique_integer([:positive])}")

    File.write!(empty_tree, "")
    on_exit(fn -> File.rm(empty_tree) end)

    {tree, 0} =
      System.cmd("git", ["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", empty_tree])

    {commit, 0} =
      System.cmd("git", ["--git-dir=#{path}", "commit-tree", String.trim(tree), "-m", branch],
        env: [
          {"GIT_AUTHOR_NAME", "Test"},
          {"GIT_AUTHOR_EMAIL", "test@example.test"},
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@example.test"}
        ]
      )

    {_, 0} =
      System.cmd("git", [
        "--git-dir=#{path}",
        "update-ref",
        "refs/heads/#{branch}",
        String.trim(commit)
      ])
  end
end
