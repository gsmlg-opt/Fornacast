defmodule Fornacast.Repo.Migrations.CreateGitWriteOperations do
  use Ecto.Migration

  def up do
    create table(:git_write_operations) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:actor_user_id, references(:users, on_delete: :nilify_all))
      add(:request_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:state, :string, null: false)
      add(:target_ref, :string, null: false)
      add(:expected_oid, :string)
      add(:proposed_oid, :string, null: false)
      add(:result_blob_oid, :string)
      add(:failure_reason, :string)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime)
    end

    create_postgres_check(
      :git_write_operations,
      :git_write_operations_kind_check,
      "kind in ('ref_create', 'ref_update', 'content_create', 'content_update', 'content_delete', 'receive_pack')"
    )

    create_postgres_check(
      :git_write_operations,
      :git_write_operations_state_check,
      "state in ('prepared', 'object_written', 'ref_advanced', 'bookkeeping_complete', 'failed')"
    )

    create_postgres_check(
      :git_write_operations,
      :git_write_operations_expected_oid_check,
      "expected_oid is null or expected_oid ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'"
    )

    create_postgres_check(
      :git_write_operations,
      :git_write_operations_proposed_oid_check,
      "proposed_oid ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'"
    )

    create_postgres_check(
      :git_write_operations,
      :git_write_operations_result_blob_oid_check,
      "result_blob_oid is null or result_blob_oid ~ '^[0-9a-f]{40}([0-9a-f]{24})?$'"
    )

    create_postgres_check(
      :git_write_operations,
      :git_write_operations_lock_version_check,
      "lock_version >= 0"
    )

    create(
      index(:git_write_operations, [:repository_id, :state, :id],
        name: :git_write_operations_recovery_index
      )
    )

    create(
      index(:git_write_operations, [:lease_expires_at], name: :git_write_operations_lease_index)
    )

    create(
      unique_index(:git_write_operations, [:request_id, :kind, :target_ref],
        name: :git_write_operations_request_ref_index
      )
    )

    alter table(:audit_events) do
      add(:request_id, :string)
      add(:operation_id, :string)
    end

    create(
      unique_index(:audit_events, [:operation_id, :action],
        name: :audit_events_operation_action_index
      )
    )
  end

  def down do
    drop(table(:git_write_operations))

    if turso?() do
      # WORKAROUND(upstream): gsmlg-dev/concord#68
      rebuild_turso_audit_events()
    else
      drop(
        index(:audit_events, [:operation_id, :action], name: :audit_events_operation_action_index)
      )

      alter table(:audit_events) do
        remove(:operation_id)
        remove(:request_id)
      end
    end
  end

  defp rebuild_turso_audit_events do
    execute("""
    create table audit_events_without_operation_columns (
      id integer primary key,
      actor_user_id integer,
      action text not null,
      target_type text not null,
      target_id text,
      metadata text not null default ('{}'),
      ip_address text,
      user_agent text,
      inserted_at text not null,
      foreign key (actor_user_id) references users(id) on delete set null
    )
    """)

    execute("""
    insert into audit_events_without_operation_columns
      (id, actor_user_id, action, target_type, target_id, metadata, ip_address, user_agent, inserted_at)
    select id, actor_user_id, action, target_type, target_id, metadata, ip_address, user_agent, inserted_at
    from audit_events
    """)

    execute("drop table audit_events")
    execute("alter table audit_events_without_operation_columns rename to audit_events")
    execute("create index audit_events_actor_user_id_index on audit_events (actor_user_id)")
    execute("create index audit_events_action_index on audit_events (action)")

    execute(
      "create index audit_events_target_type_target_id_index on audit_events (target_type, target_id)"
    )
  end

  defp create_postgres_check(table, name, expr) do
    unless turso?() do
      create(constraint(table, name, check: expr))
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
