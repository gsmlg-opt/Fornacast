defmodule Fornacast.Repo.Migrations.AllowProvisionalGitHubImportSources do
  use Ecto.Migration

  @disable_ddl_transaction true

  @verified_source_check "(source_owner_github_id is null or source_owner_github_id > 0) and " <>
                           "(state in ('discovering', 'failed') or " <>
                           "(source_owner_github_id is not null and " <>
                           "(source_kind = 'organization' or source_repository_github_id is not null)))"

  def up do
    if turso?() do
      # WORKAROUND(upstream): gsmlg-dev/concord#82
      rebuild_turso_runs()
    else
      alter table(:github_import_runs) do
        modify(:source_owner_github_id, :bigint, null: true)
        add(:source_metadata, :map, null: false, default: %{})
      end

      create(
        constraint(:github_import_runs, :github_import_runs_verified_source_check,
          check: @verified_source_check
        )
      )
    end

    create(
      index(:github_import_repository_items, [:import_run_id, :id],
        name: :github_import_items_run_id_index
      )
    )

    create(
      index(:github_import_report_entries, [:import_run_id, :id],
        name: :github_import_reports_run_id_index
      )
    )
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop(
      index(:github_import_report_entries, [:import_run_id, :id],
        name: :github_import_reports_run_id_index
      )
    )

    drop(
      index(:github_import_repository_items, [:import_run_id, :id],
        name: :github_import_items_run_id_index
      )
    )

    drop(constraint(:github_import_runs, :github_import_runs_verified_source_check))

    alter table(:github_import_runs) do
      remove(:source_metadata)
      modify(:source_owner_github_id, :bigint, null: false)
    end
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso

  defp rebuild_turso_runs do
    migration_repo = repo()

    migration_repo.checkout(
      fn ->
        query!(migration_repo, "PRAGMA foreign_keys = OFF")

        try do
          Enum.each(turso_rebuild_statements(), &query!(migration_repo, &1))
        after
          query!(migration_repo, "PRAGMA foreign_keys = ON")
        end
      end,
      timeout: :infinity
    )
  end

  defp turso_rebuild_statements do
    [
      """
      CREATE TABLE github_import_runs_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_user_id INTEGER NOT NULL
          CONSTRAINT github_import_runs_actor_user_id_fkey
          REFERENCES users (id) ON DELETE RESTRICT,
        predecessor_run_id INTEGER
          CONSTRAINT github_import_runs_predecessor_run_id_fkey
          REFERENCES github_import_runs_new (id) ON DELETE SET NULL,
        source_kind TEXT NOT NULL CONSTRAINT github_import_runs_source_kind_check
          CHECK (source_kind IN ('repository', 'organization')),
        github_identity_id INTEGER NOT NULL
          CONSTRAINT github_import_runs_github_identity_id_fkey
          REFERENCES github_identities (id) ON DELETE RESTRICT,
        credential_source TEXT NOT NULL CONSTRAINT github_import_runs_credential_source_check
          CHECK (credential_source IN ('saved', 'one_time')),
        github_credential_id INTEGER
          CONSTRAINT github_import_runs_github_credential_id_fkey
          REFERENCES github_credentials (id) ON DELETE SET NULL,
        source_owner_github_id INTEGER CONSTRAINT github_import_runs_verified_source_check
          CHECK (#{@verified_source_check}),
        source_owner_login TEXT NOT NULL,
        source_repository_github_id INTEGER
          CONSTRAINT github_import_runs_source_repository_id_positive_check
          CHECK (source_repository_github_id IS NULL OR source_repository_github_id > 0),
        source_repository_full_name TEXT,
        source_metadata TEXT DEFAULT ('{}') NOT NULL,
        destination_organization_action TEXT CONSTRAINT github_import_runs_destination_action_check
          CHECK (destination_organization_action IS NULL OR destination_organization_action IN ('new', 'existing')),
        destination_organization_slug TEXT,
        destination_organization_id INTEGER
          CONSTRAINT github_import_runs_destination_organization_id_fkey
          REFERENCES users (id) ON DELETE RESTRICT,
        state TEXT DEFAULT 'discovering' NOT NULL CONSTRAINT github_import_runs_state_check
          CHECK (state IN ('discovering', 'awaiting_resolution', 'ready', 'running', 'awaiting_credential', 'cancel_requested', 'completed', 'completed_with_warnings', 'canceled', 'failed')),
        resume_state TEXT CONSTRAINT github_import_runs_resume_state_check
          CHECK (resume_state IS NULL OR resume_state IN ('discovering', 'awaiting_resolution', 'ready', 'running', 'awaiting_credential', 'cancel_requested', 'completed', 'completed_with_warnings', 'canceled', 'failed')),
        wait_reason TEXT CONSTRAINT github_import_runs_resume_state_coherence_check
          CHECK ((state = 'awaiting_credential' AND resume_state IS NOT NULL AND resume_state IN ('awaiting_resolution', 'ready', 'running')) OR (state != 'awaiting_credential' AND resume_state IS NULL)),
        next_attempt_at TEXT,
        cancellation_requested_at TEXT,
        terminal_at TEXT CONSTRAINT github_import_runs_terminal_at_check
          CHECK ((state IN ('completed', 'completed_with_warnings', 'canceled', 'failed') AND terminal_at IS NOT NULL) OR (state NOT IN ('completed', 'completed_with_warnings', 'canceled', 'failed') AND terminal_at IS NULL)),
        report_finalized_at TEXT,
        failure_kind TEXT,
        failure_detail TEXT,
        selected_count INTEGER DEFAULT 0 NOT NULL CONSTRAINT github_import_runs_selected_count_check CHECK (selected_count >= 0),
        published_count INTEGER DEFAULT 0 NOT NULL CONSTRAINT github_import_runs_published_count_check CHECK (published_count >= 0),
        skipped_count INTEGER DEFAULT 0 NOT NULL CONSTRAINT github_import_runs_skipped_count_check CHECK (skipped_count >= 0),
        warning_count INTEGER DEFAULT 0 NOT NULL CONSTRAINT github_import_runs_warning_count_check CHECK (warning_count >= 0),
        failure_count INTEGER DEFAULT 0 NOT NULL CONSTRAINT github_import_runs_failure_count_check CHECK (failure_count >= 0),
        request_metadata TEXT DEFAULT ('{}') NOT NULL,
        credential_ciphertext BLOB CONSTRAINT github_import_runs_credential_consistency_check
          CHECK ((credential_source = 'saved' AND (github_credential_id IS NOT NULL OR state IN ('awaiting_credential', 'completed', 'completed_with_warnings', 'canceled', 'failed')) AND credential_ciphertext IS NULL AND credential_nonce IS NULL AND credential_tag IS NULL AND credential_key_id IS NULL) OR (credential_source = 'one_time' AND github_credential_id IS NULL AND ((credential_ciphertext IS NULL AND credential_nonce IS NULL AND credential_tag IS NULL AND credential_key_id IS NULL) OR (credential_ciphertext IS NOT NULL AND credential_nonce IS NOT NULL AND credential_tag IS NOT NULL AND credential_key_id IS NOT NULL)))),
        credential_nonce BLOB CONSTRAINT github_import_runs_terminal_envelope_check
          CHECK (state NOT IN ('completed', 'completed_with_warnings', 'canceled', 'failed') OR (credential_ciphertext IS NULL AND credential_nonce IS NULL AND credential_tag IS NULL AND credential_key_id IS NULL)),
        credential_tag BLOB,
        credential_key_id TEXT,
        lease_owner TEXT CONSTRAINT github_import_runs_terminal_lease_check
          CHECK (state NOT IN ('completed', 'completed_with_warnings', 'canceled', 'failed') OR (lease_owner IS NULL AND lease_expires_at IS NULL)),
        lease_expires_at TEXT,
        lock_version INTEGER DEFAULT 1 NOT NULL CONSTRAINT github_import_runs_lock_version_check CHECK (lock_version > 0),
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      INSERT INTO github_import_runs_new (
        id, actor_user_id, predecessor_run_id, source_kind, github_identity_id,
        credential_source, github_credential_id, source_owner_github_id, source_owner_login,
        source_repository_github_id, source_repository_full_name, source_metadata,
        destination_organization_action, destination_organization_slug,
        destination_organization_id, state, resume_state, wait_reason, next_attempt_at,
        cancellation_requested_at, terminal_at, report_finalized_at, failure_kind,
        failure_detail, selected_count, published_count, skipped_count, warning_count,
        failure_count, request_metadata, credential_ciphertext, credential_nonce,
        credential_tag, credential_key_id, lease_owner, lease_expires_at, lock_version,
        inserted_at, updated_at
      )
      SELECT
        id, actor_user_id, predecessor_run_id, source_kind, github_identity_id,
        credential_source, github_credential_id, source_owner_github_id, source_owner_login,
        source_repository_github_id, source_repository_full_name, '{}',
        destination_organization_action, destination_organization_slug,
        destination_organization_id, state, resume_state, wait_reason, next_attempt_at,
        cancellation_requested_at, terminal_at, report_finalized_at, failure_kind,
        failure_detail, selected_count, published_count, skipped_count, warning_count,
        failure_count, request_metadata, credential_ciphertext, credential_nonce,
        credential_tag, credential_key_id, lease_owner, lease_expires_at, lock_version,
        inserted_at, updated_at
      FROM github_import_runs
      """,
      "DROP TABLE github_import_runs",
      "ALTER TABLE github_import_runs_new RENAME TO github_import_runs",
      "CREATE INDEX github_import_runs_actor_user_id_inserted_at_index ON github_import_runs (actor_user_id, inserted_at)",
      "CREATE INDEX github_import_runs_recovery_index ON github_import_runs (state, next_attempt_at, lease_expires_at, id)",
      "CREATE INDEX github_import_runs_github_credential_id_index ON github_import_runs (github_credential_id)",
      "CREATE INDEX github_import_runs_predecessor_run_id_index ON github_import_runs (predecessor_run_id)"
    ]
  end

  defp query!(migration_repo, sql),
    do: Ecto.Adapters.SQL.query!(migration_repo, sql, [], log: false)
end
