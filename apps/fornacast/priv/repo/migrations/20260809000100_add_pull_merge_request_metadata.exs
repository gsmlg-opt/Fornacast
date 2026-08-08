defmodule Fornacast.Repo.Migrations.AddPullMergeRequestMetadata do
  use Ecto.Migration

  def up do
    if turso?() do
      # WORKAROUND(upstream): gsmlg-dev/concord#71
      rebuild_turso_operations(:with_request_metadata)
    else
      alter table(:pull_merge_operations) do
        add(:api_version, :text)
        add(:ip_address, :text)
        add(:user_agent, :text)
        add(:token_id, :text)
      end
    end
  end

  def down do
    if turso?() do
      # WORKAROUND(upstream): gsmlg-dev/concord#71
      rebuild_turso_operations(:without_request_metadata)
    else
      alter table(:pull_merge_operations) do
        remove(:token_id)
        remove(:user_agent)
        remove(:ip_address)
        remove(:api_version)
      end
    end
  end

  defp rebuild_turso_operations(:with_request_metadata) do
    execute(create_turso_table("pull_merge_operations_with_request_metadata", metadata_columns()))

    execute("""
    INSERT INTO pull_merge_operations_with_request_metadata
      (id, pull_request_id, repository_id, actor_user_id, request_id,
       base_ref, head_ref, expected_base_oid, expected_head_oid, merge_oid,
       state, lease_owner, lease_expires_at, failure_reason, lock_version,
       inserted_at, updated_at)
    SELECT id, pull_request_id, repository_id, actor_user_id, request_id,
           base_ref, head_ref, expected_base_oid, expected_head_oid, merge_oid,
           state, lease_owner, lease_expires_at, failure_reason, lock_version,
           inserted_at, updated_at
    FROM pull_merge_operations
    """)

    replace_turso_table("pull_merge_operations_with_request_metadata")
  end

  defp rebuild_turso_operations(:without_request_metadata) do
    execute(create_turso_table("pull_merge_operations_without_request_metadata", ""))

    execute("""
    INSERT INTO pull_merge_operations_without_request_metadata
      (id, pull_request_id, repository_id, actor_user_id, request_id,
       base_ref, head_ref, expected_base_oid, expected_head_oid, merge_oid,
       state, lease_owner, lease_expires_at, failure_reason, lock_version,
       inserted_at, updated_at)
    SELECT id, pull_request_id, repository_id, actor_user_id, request_id,
           base_ref, head_ref, expected_base_oid, expected_head_oid, merge_oid,
           state, lease_owner, lease_expires_at, failure_reason, lock_version,
           inserted_at, updated_at
    FROM pull_merge_operations
    """)

    replace_turso_table("pull_merge_operations_without_request_metadata")
  end

  defp create_turso_table(name, metadata_columns) do
    """
    CREATE TABLE #{name} (
      id INTEGER PRIMARY KEY,
      "pull_request_id" INTEGER NOT NULL
        CONSTRAINT "pull_merge_operations_pull_request_id_fkey"
        REFERENCES "pull_requests" ("id") ON DELETE CASCADE,
      "repository_id" INTEGER NOT NULL
        CONSTRAINT "pull_merge_operations_repository_id_fkey"
        REFERENCES "repositories" ("id") ON DELETE CASCADE,
      "actor_user_id" INTEGER
        CONSTRAINT "pull_merge_operations_actor_user_id_fkey"
        REFERENCES "users" ("id") ON DELETE SET NULL,
      request_id TEXT NOT NULL,
      #{metadata_columns}
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
      updated_at TEXT NOT NULL
    )
    """
  end

  defp metadata_columns do
    """
    api_version TEXT,
    ip_address TEXT,
    user_agent TEXT,
    token_id TEXT,
    """
  end

  defp replace_turso_table(replacement) do
    execute("DROP TABLE pull_merge_operations")
    execute("ALTER TABLE #{replacement} RENAME TO pull_merge_operations")

    execute(
      "CREATE INDEX pull_merge_operations_repository_id_state_index " <>
        "ON pull_merge_operations (repository_id, state)"
    )

    execute(
      "CREATE INDEX pull_merge_operations_pull_request_id_state_index " <>
        "ON pull_merge_operations (pull_request_id, state)"
    )

    execute(
      "CREATE INDEX pull_merge_operations_lease_expires_at_index " <>
        "ON pull_merge_operations (lease_expires_at)"
    )
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
