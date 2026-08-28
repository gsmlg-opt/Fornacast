defmodule Fornacast.Repo.Migrations.AddImportCleanupRecovery do
  use Ecto.Migration

  @disable_ddl_transaction true

  @kind_check "kind in ('remote_quarantine', 'unpublished_shadow', 'replacement_tombstone')"
  @state_check "state in ('cleanup_pending', 'cleanup_blocked', 'cleanup_complete')"
  @identity_check "repository_id > 0 and repository_item_id > 0 and source_lock_version > 0"
  @attempt_check "attempt_count >= 0"
  @version_check "lock_version >= 0"
  @lease_pair_check "(lease_owner is null and lease_expires_at is null) or " <>
                      "(lease_owner is not null and length(trim(lease_owner)) > 0 and lease_expires_at is not null)"
  @effect_order_check "(effect_finished_at is null or " <>
                        "(effect_started_at is not null and effect_started_at <= effect_finished_at))"
  @lifecycle_check "(" <>
                     "state = 'cleanup_pending' and next_attempt_at is not null and completed_at is null" <>
                     ") or (" <>
                     "state = 'cleanup_blocked' and last_error is not null and length(trim(last_error)) between 1 and 120 and " <>
                     "lease_owner is null and lease_expires_at is null and next_attempt_at is null and completed_at is null" <>
                     ") or (" <>
                     "state = 'cleanup_complete' and lease_owner is null and lease_expires_at is null and " <>
                     "next_attempt_at is null and last_error is null and effect_started_at is not null and " <>
                     "effect_finished_at is not null and completed_at is not null and " <>
                     "effect_started_at <= effect_finished_at and effect_finished_at <= completed_at" <>
                     ")"
  @operation_id_check "operation_id = 'github-import-cleanup:' || kind || ':' || " <>
                        "repository_id || ':' || repository_item_id || ':' || source_lock_version"
  @git_pair_check "(lease_owner is null and lease_expires_at is null) or " <>
                    "(lease_owner is not null and lease_expires_at is not null)"
  @git_terminal_check "state not in ('bookkeeping_complete', 'failed') or " <>
                        "(lease_owner is null and lease_expires_at is null)"
  @merge_terminal_check "state not in ('completed', 'failed') or " <>
                          "(lease_owner is null and lease_expires_at is null)"
  @replacement_keys ~w(version kind repository_id repository_generation repository_write_version repository_storage_path repository_deleted_at repository_updated_at item_id item_lock_version attempt_number attempt_decision attempt_fingerprint publication_operation_id publication_marker new_repository_id new_repository_generation publication_audit_id)
  @unpublished_keys ~w(version kind repository_id repository_generation repository_write_version repository_storage_path repository_updated_at item_id item_lock_version item_state run_id run_state attempt_number attempt_state attempt_decision attempt_fingerprint publication_evidence predecessor_item_id successor_item_id adopter_item_id)
  @remote_keys ~w(version kind repository_id repository_generation repository_storage_path item_id item_lock_version requested_path quarantine_path mode major_device minor_device inode remote_failure_kind)

  def up do
    create_cleanup_table()

    if turso?() do
      rebuild_turso_operation_tables()
    else
      add_postgres_operation_checks()
    end
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    execute(
      "ALTER TABLE pull_merge_operations DROP CONSTRAINT pull_merge_operations_terminal_lease_check"
    )

    execute(
      "ALTER TABLE pull_merge_operations DROP CONSTRAINT pull_merge_operations_lease_pair_check"
    )

    execute(
      "ALTER TABLE git_write_operations DROP CONSTRAINT git_write_operations_terminal_lease_check"
    )

    execute(
      "ALTER TABLE git_write_operations DROP CONSTRAINT git_write_operations_lease_pair_check"
    )

    drop(table(:github_import_repository_cleanups))
  end

  defp create_cleanup_table do
    create table(:github_import_repository_cleanups) do
      add(
        :repository_id,
        references(:repositories, on_delete: :restrict),
        column_options(
          [null: false],
          :github_import_cleanups_positive_identity_check,
          @identity_check
        )
      )

      add(
        :repository_item_id,
        references(:github_import_repository_items, on_delete: :restrict),
        null: false
      )

      add(:source_lock_version, :bigint, null: false)

      add(
        :kind,
        :string,
        column_options([null: false], :github_import_cleanups_kind_check, @kind_check)
      )

      add(
        :state,
        :string,
        column_options(
          [null: false, default: "cleanup_pending"],
          :github_import_cleanups_state_check,
          @state_check
        )
      )

      add(
        :operation_id,
        :string,
        column_options(
          [null: false],
          :github_import_cleanups_operation_id_check,
          @operation_id_check
        )
      )

      add(
        :evidence,
        :map,
        column_options(
          [null: false],
          :github_import_cleanups_evidence_check,
          evidence_check()
        )
      )

      add(:eligible_at, :utc_datetime, null: false)

      add(
        :next_attempt_at,
        :utc_datetime,
        column_options([], :github_import_cleanups_lifecycle_check, @lifecycle_check)
      )

      add(
        :attempt_count,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_cleanups_attempt_count_check,
          @attempt_check
        )
      )

      add(:last_error, :string)
      add(:effect_started_at, :utc_datetime)

      add(
        :effect_finished_at,
        :utc_datetime,
        column_options([], :github_import_cleanups_effect_order_check, @effect_order_check)
      )

      add(:completed_at, :utc_datetime)

      add(
        :lease_owner,
        :string,
        column_options([], :github_import_cleanups_lease_pair_check, @lease_pair_check)
      )

      add(:lease_expires_at, :utc_datetime)

      add(
        :lock_version,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_cleanups_lock_version_check,
          @version_check
        )
      )

      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_kind_check,
      @kind_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_state_check,
      @state_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_positive_identity_check,
      @identity_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_attempt_count_check,
      @attempt_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_lock_version_check,
      @version_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_lease_pair_check,
      @lease_pair_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_effect_order_check,
      @effect_order_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_lifecycle_check,
      @lifecycle_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_operation_id_check,
      @operation_id_check
    )

    postgres_check(
      :github_import_repository_cleanups,
      :github_import_cleanups_evidence_check,
      evidence_check()
    )

    create(
      unique_index(:github_import_repository_cleanups, [:operation_id],
        name: :github_import_repository_cleanups_operation_id_index
      )
    )

    create(
      unique_index(
        :github_import_repository_cleanups,
        [:repository_item_id, :kind, :source_lock_version],
        name: :github_import_cleanups_item_kind_version_index
      )
    )

    create(
      index(
        :github_import_repository_cleanups,
        [:state, :next_attempt_at, :eligible_at, :id],
        name: :github_import_repository_cleanups_recovery_index
      )
    )
  end

  defp evidence_check do
    if turso?() do
      "json_valid(evidence) and json_type(evidence) = 'object' and " <>
        "json_extract(evidence, '$.version') = 1 and " <>
        "json_extract(evidence, '$.kind') = kind and " <>
        "json_extract(evidence, '$.repository_id') = repository_id and " <>
        "json_extract(evidence, '$.item_id') = repository_item_id and " <>
        "json_extract(evidence, '$.item_lock_version') = source_lock_version and " <>
        exact_kind_keys_check(:turso) <> " and " <> anchor_check(:turso)
    else
      "jsonb_typeof(evidence) = 'object' and evidence @> jsonb_build_object(" <>
        "'version', 1, 'kind', kind, 'repository_id', repository_id, " <>
        "'item_id', repository_item_id, 'item_lock_version', source_lock_version) and " <>
        exact_kind_keys_check(:postgres) <> " and " <> anchor_check(:postgres)
    end
  end

  defp anchor_check(:turso) do
    root = "json_type(evidence, '$.root_identity') is not null"
    target = "json_type(evidence, '$.anchored_identity') is not null"
    absence = "json_type(evidence, '$.anchored_absence') is not null"

    "((effect_started_at is null and not (#{root}) and not (#{target}) and not (#{absence})) or " <>
      "(effect_started_at is not null and (((#{root}) and (#{target}) and not (#{absence}) and " <>
      identity_check(:turso, "$.root_identity") <>
      " and " <>
      identity_check(:turso, "$.anchored_identity") <>
      ") or " <>
      "(not (#{root}) and not (#{target}) and (#{absence}) and effect_finished_at is not null and " <>
      absence_check(:turso) <> "))))"
  end

  defp anchor_check(:postgres) do
    root = "evidence ? 'root_identity'"
    target = "evidence ? 'anchored_identity'"
    absence = "evidence ? 'anchored_absence'"

    "((effect_started_at is null and not (#{root}) and not (#{target}) and not (#{absence})) or " <>
      "(effect_started_at is not null and (((#{root}) and (#{target}) and not (#{absence}) and " <>
      identity_check(:postgres, "evidence->'root_identity'") <>
      " and " <>
      identity_check(:postgres, "evidence->'anchored_identity'") <>
      ") or " <>
      "(not (#{root}) and not (#{target}) and (#{absence}) and effect_finished_at is not null and " <>
      absence_check(:postgres) <> "))))"
  end

  defp exact_kind_keys_check(adapter) do
    [
      {"replacement_tombstone", @replacement_keys},
      {"unpublished_shadow", @unpublished_keys},
      {"remote_quarantine", @remote_keys}
    ]
    |> Enum.map_join(" or ", fn {kind, keys} ->
      all_keys = keys ++ ~w(root_identity anchored_identity anchored_absence)

      required =
        case adapter do
          :turso ->
            Enum.map_join(keys, " and ", &"json_type(evidence, '$.#{&1}') is not null")

          :postgres ->
            encoded = Enum.map_join(keys, ", ", &"'#{&1}'")
            "evidence ?& array[#{encoded}]"
        end

      no_unknown =
        case adapter do
          :turso ->
            paths = Enum.map_join(all_keys, ", ", &"'$.#{&1}'")
            "json_remove(evidence, #{paths}) = '{}'"

          :postgres ->
            encoded = Enum.map_join(all_keys, ", ", &"'#{&1}'")
            "(evidence - array[#{encoded}]::text[]) = '{}'::jsonb"
        end

      "(kind = '#{kind}' and #{required} and #{no_unknown})"
    end)
    |> then(&"(#{&1})")
  end

  defp identity_check(:turso, path) do
    "json_type(evidence, '#{path}') = 'object' and " <>
      "json_type(evidence, '#{path}.mode') = 'integer' and json_extract(evidence, '#{path}.mode') >= 0 and " <>
      "json_type(evidence, '#{path}.major_device') = 'integer' and json_extract(evidence, '#{path}.major_device') >= 0 and " <>
      "json_type(evidence, '#{path}.minor_device') = 'integer' and json_extract(evidence, '#{path}.minor_device') >= 0 and " <>
      "json_type(evidence, '#{path}.inode') = 'integer' and json_extract(evidence, '#{path}.inode') > 0 and " <>
      "json_remove(json_extract(evidence, '#{path}'), '$.mode', '$.major_device', '$.minor_device', '$.inode') = '{}'"
  end

  defp identity_check(:postgres, expression) do
    expression = "(#{expression})"

    "jsonb_typeof(#{expression}) = 'object' and " <>
      "jsonb_typeof(#{expression}->'mode') = 'number' and (#{expression}->>'mode')::numeric >= 0 and mod((#{expression}->>'mode')::numeric, 1) = 0 and " <>
      "jsonb_typeof(#{expression}->'major_device') = 'number' and (#{expression}->>'major_device')::numeric >= 0 and mod((#{expression}->>'major_device')::numeric, 1) = 0 and " <>
      "jsonb_typeof(#{expression}->'minor_device') = 'number' and (#{expression}->>'minor_device')::numeric >= 0 and mod((#{expression}->>'minor_device')::numeric, 1) = 0 and " <>
      "jsonb_typeof(#{expression}->'inode') = 'number' and (#{expression}->>'inode')::numeric > 0 and mod((#{expression}->>'inode')::numeric, 1) = 0 and " <>
      "(#{expression} - array['mode','major_device','minor_device','inode']::text[]) = '{}'::jsonb"
  end

  defp absence_check(:turso) do
    path = "$.anchored_absence"

    "json_type(evidence, '#{path}') = 'object' and json_extract(evidence, '#{path}.version') = 1 and " <>
      "json_type(evidence, '#{path}.observed_at') = 'text' and " <>
      identity_check(:turso, "#{path}.root_identity") <>
      " and " <>
      projection_check(:turso, "#{path}.root_projection") <>
      " and " <>
      projection_check(:turso, "#{path}.path_projection") <>
      " and " <>
      "json_remove(json_extract(evidence, '#{path}'), '$.version', '$.observed_at', '$.root_identity', '$.root_projection', '$.path_projection') = '{}'"
  end

  defp absence_check(:postgres) do
    expression = "evidence->'anchored_absence'"
    nested = "(#{expression})"

    "jsonb_typeof(#{nested}) = 'object' and #{nested}->'version' = '1'::jsonb and " <>
      "jsonb_typeof(#{nested}->'observed_at') = 'string' and " <>
      identity_check(:postgres, "#{nested}->'root_identity'") <>
      " and " <>
      projection_check(:postgres, "#{nested}->>'root_projection'") <>
      " and " <>
      projection_check(:postgres, "#{nested}->>'path_projection'") <>
      " and " <>
      "(#{nested} - array['version','observed_at','root_identity','root_projection','path_projection']::text[]) = '{}'::jsonb"
  end

  defp projection_check(:turso, path) do
    "json_type(evidence, '#{path}') = 'text' and length(json_extract(evidence, '#{path}')) = 64 and " <>
      "json_extract(evidence, '#{path}') not glob '*[^0-9a-f]*'"
  end

  defp projection_check(:postgres, expression) do
    "#{expression} ~ '^[0-9a-f]{64}$'"
  end

  defp add_postgres_operation_checks do
    execute(
      "ALTER TABLE git_write_operations ADD CONSTRAINT git_write_operations_lease_pair_check CHECK (#{@git_pair_check})"
    )

    execute(
      "ALTER TABLE git_write_operations ADD CONSTRAINT git_write_operations_terminal_lease_check CHECK (#{@git_terminal_check})"
    )

    execute(
      "ALTER TABLE pull_merge_operations ADD CONSTRAINT pull_merge_operations_lease_pair_check CHECK (#{@git_pair_check})"
    )

    execute(
      "ALTER TABLE pull_merge_operations ADD CONSTRAINT pull_merge_operations_terminal_lease_check CHECK (#{@merge_terminal_check})"
    )
  end

  defp rebuild_turso_operation_tables do
    migration_repo = repo()

    migration_repo.checkout(
      fn ->
        query!(migration_repo, "PRAGMA foreign_keys = OFF")

        try do
          Enum.each(turso_git_write_statements(), &query!(migration_repo, &1))
          Enum.each(turso_pull_merge_statements(), &query!(migration_repo, &1))
        after
          query!(migration_repo, "PRAGMA foreign_keys = ON")
        end
      end,
      timeout: :infinity
    )
  end

  defp turso_git_write_statements do
    [
      """
      CREATE TABLE git_write_operations_with_cleanup_recovery (
        id INTEGER PRIMARY KEY,
        repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        actor_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        request_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        target_ref TEXT NOT NULL,
        expected_oid TEXT,
        proposed_oid TEXT NOT NULL,
        result_blob_oid TEXT,
        failure_reason TEXT,
        lease_owner TEXT,
        lease_expires_at TEXT,
        lock_version INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT git_write_operations_lease_pair_check CHECK (#{@git_pair_check}),
        CONSTRAINT git_write_operations_terminal_lease_check CHECK (#{@git_terminal_check})
      )
      """,
      """
      INSERT INTO git_write_operations_with_cleanup_recovery
        (id, repository_id, actor_user_id, request_id, kind, state, target_ref,
         expected_oid, proposed_oid, result_blob_oid, failure_reason, lease_owner,
         lease_expires_at, lock_version, inserted_at, updated_at)
      SELECT id, repository_id, actor_user_id, request_id, kind, state, target_ref,
             expected_oid, proposed_oid, result_blob_oid, failure_reason, lease_owner,
             lease_expires_at, lock_version, inserted_at, updated_at
      FROM git_write_operations
      """,
      "DROP TABLE git_write_operations",
      "ALTER TABLE git_write_operations_with_cleanup_recovery RENAME TO git_write_operations",
      "CREATE INDEX git_write_operations_recovery_index ON git_write_operations (repository_id, state, id)",
      "CREATE INDEX git_write_operations_lease_index ON git_write_operations (lease_expires_at)",
      "CREATE UNIQUE INDEX git_write_operations_request_ref_index ON git_write_operations (request_id, kind, target_ref)"
    ]
  end

  defp turso_pull_merge_statements do
    [
      """
      CREATE TABLE pull_merge_operations_with_cleanup_recovery (
        id INTEGER PRIMARY KEY,
        pull_request_id INTEGER NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
        repository_id INTEGER NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        actor_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        request_id TEXT NOT NULL,
        api_version TEXT,
        ip_address TEXT,
        user_agent TEXT,
        token_id TEXT,
        base_ref TEXT NOT NULL,
        head_ref TEXT NOT NULL,
        expected_base_oid TEXT NOT NULL,
        expected_head_oid TEXT NOT NULL,
        merge_oid TEXT,
        state TEXT NOT NULL CONSTRAINT pull_merge_operations_state_check
          CHECK (state IN ('prepared', 'merge_written', 'ref_advanced', 'completed', 'failed')),
        lease_owner TEXT,
        lease_expires_at TEXT,
        failure_reason TEXT,
        lock_version INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT pull_merge_operations_lease_pair_check CHECK (#{@git_pair_check}),
        CONSTRAINT pull_merge_operations_terminal_lease_check CHECK (#{@merge_terminal_check})
      )
      """,
      """
      INSERT INTO pull_merge_operations_with_cleanup_recovery
        (id, pull_request_id, repository_id, actor_user_id, request_id, api_version,
         ip_address, user_agent, token_id, base_ref, head_ref, expected_base_oid,
         expected_head_oid, merge_oid, state, lease_owner, lease_expires_at,
         failure_reason, lock_version, inserted_at, updated_at)
      SELECT id, pull_request_id, repository_id, actor_user_id, request_id, api_version,
             ip_address, user_agent, token_id, base_ref, head_ref, expected_base_oid,
             expected_head_oid, merge_oid, state, lease_owner, lease_expires_at,
             failure_reason, lock_version, inserted_at, updated_at
      FROM pull_merge_operations
      """,
      "DROP TABLE pull_merge_operations",
      "ALTER TABLE pull_merge_operations_with_cleanup_recovery RENAME TO pull_merge_operations",
      "CREATE INDEX pull_merge_operations_repository_id_state_index ON pull_merge_operations (repository_id, state)",
      "CREATE INDEX pull_merge_operations_pull_request_id_state_index ON pull_merge_operations (pull_request_id, state)",
      "CREATE INDEX pull_merge_operations_lease_expires_at_index ON pull_merge_operations (lease_expires_at)"
    ]
  end

  defp column_options(options, name, expression) do
    if turso?(),
      do: Keyword.put(options, :check, name: to_string(name), expr: expression),
      else: options
  end

  defp postgres_check(table, name, expression) do
    unless turso?(), do: create(constraint(table, name, check: expression))
  end

  defp query!(migration_repo, sql),
    do: Ecto.Adapters.SQL.query!(migration_repo, sql, [], log: false)

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
