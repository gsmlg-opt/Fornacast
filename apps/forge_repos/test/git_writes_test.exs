defmodule ForgeRepos.GitWritesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeRepos.GitWriteOperation
  alias Fornacast.{Audit, AuditEvent, Repo}

  @moduletag :persistence
  @oid40 String.duplicate("A", 40)
  @oid64 String.duplicate("B", 64)

  setup do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      Repo.delete_all(AuditEvent)
    end

    :ok
  end

  test "prepare changeset enforces and normalizes the durable operation contract" do
    attrs = valid_attrs()
    changeset = GitWriteOperation.changeset(%GitWriteOperation{}, attrs)

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :expected_oid) == String.downcase(@oid40)
    assert Ecto.Changeset.get_change(changeset, :proposed_oid) == String.downcase(@oid64)

    assert %{constraint: constraint, type: :unique} =
             Enum.find(changeset.constraints, &(&1.type == :unique))

    assert Regex.match?(constraint, "git_write_operations_request_ref_index")

    assert Regex.match?(
             constraint,
             "git_write_operations_(request_id_kind_target_ref) (19)_index"
           )

    assert GitWriteOperation.changeset(%GitWriteOperation{}, Map.put(attrs, :expected_oid, nil)).valid?

    for field <- ~w(repository_id request_id kind state target_ref proposed_oid)a do
      refute GitWriteOperation.changeset(%GitWriteOperation{}, Map.delete(attrs, field)).valid?
    end
  end

  test "changeset rejects unknown enums, noncanonical refs, unsafe reasons, OIDs, and versions" do
    invalid = [
      {:kind, :unknown},
      {:state, :unknown},
      {:target_ref, "main"},
      {:target_ref, "refs/heads/main.lock"},
      {:target_ref, "refs/heads/.hidden"},
      {:target_ref, "refs/heads/../main"},
      {:failure_reason, "native panic: /srv/repos/private.git token=secret"},
      {:expected_oid, "ABCDEF"},
      {:proposed_oid, String.duplicate("g", 40)},
      {:result_blob_oid, String.duplicate("a", 39)},
      {:lock_version, -1}
    ]

    for {field, value} <- invalid do
      changeset =
        GitWriteOperation.changeset(%GitWriteOperation{}, Map.put(valid_attrs(), field, value))

      refute changeset.valid?, "expected #{field}=#{inspect(value)} to be rejected"
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "changeset enforces lifecycle and evidence coupling on direct persistence" do
    oid = String.duplicate("C", 40)

    invalid = [
      %{state: :object_written, result_blob_oid: nil},
      %{state: :ref_advanced, result_blob_oid: nil},
      %{state: :prepared, result_blob_oid: oid},
      %{state: :failed, failure_reason: nil},
      %{state: :failed, failure_reason: "unexpected_ref"},
      %{state: :prepared, failure_reason: "effect_not_started"},
      %{state: :bookkeeping_complete, failure_reason: "unexpected_ref"},
      %{kind: :ref_update, state: :object_written, result_blob_oid: oid}
    ]

    for overrides <- invalid do
      changeset =
        GitWriteOperation.changeset(%GitWriteOperation{}, Map.merge(valid_attrs(), overrides))

      refute changeset.valid?, "expected #{inspect(overrides)} to be rejected"
      assert {:error, %Ecto.Changeset{}} = Repo.insert(changeset)
    end

    valid =
      GitWriteOperation.changeset(
        %GitWriteOperation{},
        Map.merge(valid_attrs(), %{state: :object_written, result_blob_oid: oid})
      )

    assert valid.valid?
    assert Ecto.Changeset.get_change(valid, :result_blob_oid) == String.downcase(oid)
  end

  test "audit options override normalized request metadata and operation actions deduplicate" do
    operation_id = "git_write:42"

    opts = [
      request_metadata: %{
        "operation_id" => "metadata-operation",
        "ip_address" => "192.0.2.1",
        request_id: "metadata-request",
        user_agent: "metadata-agent"
      },
      request_id: "explicit-request",
      operation_id: operation_id,
      ip_address: "127.0.0.1",
      user_agent: "test"
    ]

    for _ <- 1..2 do
      multi =
        Multi.new()
        |> Audit.record_multi(
          :audit,
          nil,
          "git.ref.created",
          "repository",
          fn _changes -> 7 end,
          fn _changes ->
            %{
              "ref" => "refs/heads/feature/x",
              "result" => "success",
              "nested" => %{"token" => "secret", "kept" => true}
            }
          end,
          opts
        )

      assert {:ok, %{audit: %AuditEvent{}}} = Repo.transaction(multi)
    end

    assert [%AuditEvent{} = event] =
             Repo.all(from e in AuditEvent, where: e.operation_id == ^operation_id)

    assert event.target_id == "7"
    assert event.request_id == "explicit-request"
    assert event.ip_address == "127.0.0.1"
    assert event.user_agent == "test"
    assert event.metadata["ref"] == "refs/heads/feature/x"
    assert event.metadata["nested"] == %{"kept" => true}

    assert {:ok, first} =
             Audit.record(nil, "git.ref.updated", "repository", 7, %{},
               operation_id: "git-write:returned"
             )

    assert {:ok, duplicate} =
             Audit.record(nil, "git.ref.updated", "repository", 7, %{},
               operation_id: "git-write:returned"
             )

    assert is_integer(first.id)
    assert duplicate.id == first.id

    multi =
      Multi.new()
      |> Audit.record_multi(
        :deduplicated_audit,
        nil,
        "git.ref.updated",
        "repository",
        7,
        %{},
        operation_id: "git-write:returned"
      )
      |> Multi.run(:downstream, fn _repo, %{deduplicated_audit: audit} ->
        {:ok, audit.id}
      end)

    assert {:ok, %{deduplicated_audit: duplicate, downstream: id}} = Repo.transaction(multi)
    assert duplicate.id == first.id
    assert id == first.id

    for _ <- 1..2 do
      assert {:ok, _event} =
               Audit.record(nil, "ordinary.repeat", "repository", 7, %{}, operation_id: nil)
    end

    assert Repo.aggregate(
             from(e in AuditEvent, where: e.action == "ordinary.repeat"),
             :count,
             :id
           ) == 2
  end

  defp valid_attrs do
    %{
      repository_id: 1,
      actor_user_id: nil,
      request_id: "request-1",
      kind: :content_create,
      state: :prepared,
      target_ref: "refs/heads/main",
      expected_oid: @oid40,
      proposed_oid: @oid64,
      result_blob_oid: nil,
      failure_reason: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      lock_version: 0
    }
  end
end

defmodule ForgeRepos.GitWriteOperationMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :forge_repos,
    adapter: Ecto.Adapters.Turso
end

defmodule ForgeRepos.GitWriteOperationMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeRepos.GitWriteOperationMigrationTestRepo, as: MigrationRepo

  @moduletag :persistence
  @migrations_path Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @migration_path Path.join(@migrations_path, "20260721000200_create_git_write_operations.exs")

  @tag :tmp_dir
  test "fresh Turso migration creates exact durable indexes and rolls back", %{tmp_dir: tmp_dir} do
    database_path = Path.join(tmp_dir, "git-write-operations.db")
    start_supervised!({MigrationRepo, database: database_path, pool_size: 1})

    Ecto.Migrator.run(MigrationRepo, @migrations_path, :up, to: 20_260_721_000_200)

    assert MapSet.subset?(
             MapSet.new(~w(
               git_write_operations_recovery_index
               git_write_operations_lease_index
               git_write_operations_request_ref_index
             )),
             index_names("git_write_operations")
           )

    assert MapSet.subset?(
             MapSet.new(~w(audit_events_operation_action_index)),
             index_names("audit_events")
           )

    assert MapSet.subset?(
             MapSet.new(~w(request_id operation_id)),
             column_names("audit_events")
           )

    SQL.query!(
      MigrationRepo,
      "insert into audit_events (action, target_type, metadata, inserted_at, request_id) values (?, ?, ?, ?, ?)",
      ["rollback.preserved", "test", "{}", "2026-07-21T00:00:00Z", "request-1"]
    )

    # WORKAROUND(upstream): gsmlg-dev/concord#69
    MigrationRepo.transaction(fn ->
      Ecto.Migration.Runner.run(
        MigrationRepo,
        MigrationRepo.config(),
        20_260_721_000_200,
        Fornacast.Repo.Migrations.CreateGitWriteOperations,
        :forward,
        :down,
        :down,
        log: false
      )
    end)

    refute "git_write_operations" in table_names()
    refute "operation_id" in column_names("audit_events")
    refute "request_id" in column_names("audit_events")

    assert %{rows: [["rollback.preserved"]]} =
             SQL.query!(MigrationRepo, "select action from audit_events", [])
  end

  test "migration declares every PostgreSQL check constraint" do
    {:ok, migration_ast} = @migration_path |> File.read!() |> Code.string_to_quoted()

    {_ast, checks} =
      Macro.prewalk(migration_ast, MapSet.new(), fn
        {:create_postgres_check, _meta, [table, name, expression]} = node, checks
        when is_atom(table) and is_atom(name) and is_binary(expression) ->
          {node, MapSet.put(checks, {table, name, expression})}

        node, checks ->
          {node, checks}
      end)

    assert MapSet.new([
             :git_write_operations_kind_check,
             :git_write_operations_state_check,
             :git_write_operations_expected_oid_check,
             :git_write_operations_proposed_oid_check,
             :git_write_operations_result_blob_oid_check,
             :git_write_operations_lock_version_check
           ]) == MapSet.new(checks, fn {_table, name, _expression} -> name end)
  end

  defp table_names do
    %{rows: rows} =
      SQL.query!(MigrationRepo, "select name from sqlite_master where type = 'table'", [])

    MapSet.new(rows, fn [name] -> name end)
  end

  defp index_names(table) do
    %{rows: rows} =
      SQL.query!(
        MigrationRepo,
        "select name from sqlite_master where type = 'index' and tbl_name = ?",
        [table]
      )

    MapSet.new(rows, fn [name] -> name end)
  end

  defp column_names(table) do
    %{rows: rows} = SQL.query!(MigrationRepo, "select name from pragma_table_info(?)", [table])
    MapSet.new(rows, fn [name] -> name end)
  end
end
