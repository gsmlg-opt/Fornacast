defmodule Fornacast.Repo.Migrations.CreateMirrorDomain do
  use Ecto.Migration

  @organization_states ~w(pending_installation ready_to_bootstrap bootstrapping catching_up active paused degraded conflicted revoked)
  @repository_states ~w(discovered active orphaned revoked tombstoned)
  @operation_states ~w(pending processing effect_pending completed failed)

  def up do
    create_organization_mirrors()
    create_repository_mirrors()
    create_ref_states()
    create_resource_states()
    create_operations()
    create_webhook_deliveries()
    create_conflicts()
  end

  def down do
    drop(table(:mirror_conflicts))
    drop(table(:mirror_webhook_deliveries))
    drop(table(:mirror_operations))
    drop(table(:mirror_resource_states))
    drop(table(:mirror_ref_states))
    drop(table(:repository_mirrors))
    drop(table(:organization_mirrors))
  end

  defp create_organization_mirrors do
    create table(:organization_mirrors) do
      add(:organization_id, references(:users, on_delete: :restrict), null: false)
      add(:provider, :string, null: false)
      add(:github_installation_id, :bigint)
      add(:github_account_id, :bigint)
      add(:github_account_login, :string)
      add(:state, :string, null: false, default: "pending_installation")
      add(:resume_state, :string)
      add(:capabilities, :map, null: false, default: %{})
      add(:policy, :map, null: false, default: %{})

      add(
        :bootstrap_import_run_id,
        references(:github_import_runs, on_delete: :nilify_all)
      )

      add(:last_webhook_at, :utc_datetime)
      add(:last_reconciled_at, :utc_datetime)
      add(:next_reconcile_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:organization_mirrors, [:organization_id, :provider],
        name: :organization_mirrors_active_organization_provider_index,
        where: "state <> 'revoked'"
      )
    )

    create(
      unique_index(:organization_mirrors, [:provider, :github_installation_id],
        name: :organization_mirrors_active_installation_index,
        where: "github_installation_id is not null and state <> 'revoked'"
      )
    )

    create(
      unique_index(:organization_mirrors, [:provider, :github_account_id],
        name: :organization_mirrors_active_account_index,
        where: "github_account_id is not null and state <> 'revoked'"
      )
    )

    create(index(:organization_mirrors, [:state, :next_reconcile_at, :id]))
    bounded_string(:organization_mirrors, :provider, false)
    bounded_string(:organization_mirrors, :github_account_login, true)
    positive_optional(:organization_mirrors, :github_installation_id)
    positive_optional(:organization_mirrors, :github_account_id)
    json_object(:organization_mirrors, :capabilities)
    json_object(:organization_mirrors, :policy)
    enum_constraint(:organization_mirrors, :state, @organization_states)

    check(
      :organization_mirrors,
      :organization_mirrors_resume_state_check,
      "(state = 'paused' and resume_state in ('ready_to_bootstrap', 'bootstrapping', 'catching_up', 'active', 'degraded', 'conflicted')) or " <>
        "(state <> 'paused' and resume_state is null)"
    )

    check(:organization_mirrors, :organization_mirrors_lock_version_check, "lock_version > 0")
  end

  defp create_repository_mirrors do
    create table(:repository_mirrors) do
      add(
        :organization_mirror_id,
        references(:organization_mirrors, on_delete: :delete_all),
        null: false
      )

      add(:repository_id, references(:repositories, on_delete: :restrict))
      add(:github_repository_id, :bigint)
      add(:github_node_id, :string)
      add(:github_full_name, :string)
      add(:state, :string, null: false, default: "discovered")

      add(
        :bootstrap_repository_item_id,
        references(:github_import_repository_items, on_delete: :nilify_all)
      )

      add(:last_inventory_at, :utc_datetime)
      add(:last_synced_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:repository_mirrors, [:repository_id],
        name: :repository_mirrors_active_local_repository_index,
        where: "repository_id is not null and state <> 'tombstoned'"
      )
    )

    create(
      unique_index(:repository_mirrors, [:github_repository_id],
        name: :repository_mirrors_active_github_repository_index,
        where: "github_repository_id is not null and state <> 'tombstoned'"
      )
    )

    create(index(:repository_mirrors, [:organization_mirror_id, :state, :id]))
    positive_optional(:repository_mirrors, :github_repository_id)
    bounded_string(:repository_mirrors, :github_node_id, true)
    bounded_string(:repository_mirrors, :github_full_name, true)
    enum_constraint(:repository_mirrors, :state, @repository_states)

    check(
      :repository_mirrors,
      :repository_mirrors_identity_check,
      "repository_id is not null or github_repository_id is not null"
    )

    check(
      :repository_mirrors,
      :repository_mirrors_active_identity_check,
      "state <> 'active' or (repository_id is not null and github_repository_id is not null)"
    )

    check(:repository_mirrors, :repository_mirrors_lock_version_check, "lock_version > 0")
  end

  defp create_ref_states do
    create table(:mirror_ref_states) do
      add(
        :repository_mirror_id,
        references(:repository_mirrors, on_delete: :delete_all),
        null: false
      )

      add(:ref_name, :string, null: false)
      add(:ref_kind, :string, null: false)
      add(:confirmed_oid, :string)
      add(:last_local_oid, :string)
      add(:last_remote_oid, :string)
      add(:state, :string, null: false, default: "pending")
      add(:last_confirmed_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:mirror_ref_states, [:repository_mirror_id, :ref_name]))
    create(index(:mirror_ref_states, [:repository_mirror_id, :state]))
    bounded_string(:mirror_ref_states, :ref_name, false, 1_024)
    enum_constraint(:mirror_ref_states, :ref_kind, ~w(branch tag))
    enum_constraint(:mirror_ref_states, :state, ~w(pending confirmed conflicted deleted degraded))

    for field <- [:confirmed_oid, :last_local_oid, :last_remote_oid] do
      check(
        :mirror_ref_states,
        String.to_atom("mirror_ref_states_#{field}_check"),
        "#{field} is null or #{field} ~ '^[0-9a-f]{40,64}$'"
      )
    end

    check(:mirror_ref_states, :mirror_ref_states_lock_version_check, "lock_version > 0")
  end

  defp create_resource_states do
    create table(:mirror_resource_states) do
      add(
        :repository_mirror_id,
        references(:repository_mirrors, on_delete: :delete_all),
        null: false
      )

      add(:resource_kind, :string, null: false)
      add(:local_resource_type, :string)
      add(:local_resource_id, :bigint)
      add(:github_object_id, :bigint)
      add(:github_node_id, :string)
      add(:github_number, :bigint)
      add(:confirmed_local_version, :bigint)
      add(:confirmed_remote_updated_at, :utc_datetime)
      add(:confirmed_fingerprint, :string)
      add(:state, :string, null: false, default: "pending")
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(
        :mirror_resource_states,
        [:repository_mirror_id, :resource_kind, :local_resource_type, :local_resource_id],
        name: :mirror_resource_states_local_identity_index,
        where: "local_resource_id is not null"
      )
    )

    create(
      unique_index(
        :mirror_resource_states,
        [:repository_mirror_id, :resource_kind, :github_object_id],
        name: :mirror_resource_states_github_identity_index,
        where: "github_object_id is not null"
      )
    )

    create(index(:mirror_resource_states, [:repository_mirror_id, :resource_kind, :state]))

    enum_constraint(
      :mirror_resource_states,
      :resource_kind,
      ~w(repository issue issue_comment pull release)
    )

    enum_constraint(
      :mirror_resource_states,
      :state,
      ~w(pending confirmed conflicted deleted unsupported)
    )

    bounded_string(:mirror_resource_states, :local_resource_type, true)
    bounded_string(:mirror_resource_states, :github_node_id, true)
    bounded_string(:mirror_resource_states, :confirmed_fingerprint, true, 512)

    check(
      :mirror_resource_states,
      :mirror_resource_states_identity_check,
      "local_resource_id is not null or github_object_id is not null or github_node_id is not null or github_number is not null"
    )

    for field <- [:local_resource_id, :github_object_id, :github_number, :confirmed_local_version] do
      positive_optional(:mirror_resource_states, field)
    end

    check(:mirror_resource_states, :mirror_resource_states_lock_version_check, "lock_version > 0")
  end

  defp create_operations do
    create table(:mirror_operations) do
      add(
        :organization_mirror_id,
        references(:organization_mirrors, on_delete: :delete_all),
        null: false
      )

      add(
        :repository_mirror_id,
        references(:repository_mirrors, on_delete: :delete_all)
      )

      add(:kind, :string, null: false)
      add(:dedupe_key, :string, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:cursor, :map, null: false, default: %{})
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime, null: false)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:failure_class, :string)
      add(:failure_detail, :string)
      add(:external_effect_marker, :map)
      add(:effect_marked_at, :utc_datetime)
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:mirror_operations, [:dedupe_key]))

    create(
      unique_index(:mirror_operations, [:repository_mirror_id],
        name: :mirror_operations_one_active_repository_index,
        where: "repository_mirror_id is not null and state in ('processing', 'effect_pending')"
      )
    )

    create(
      unique_index(:mirror_operations, [:organization_mirror_id],
        name: :mirror_operations_one_active_organization_index,
        where: "repository_mirror_id is null and state in ('processing', 'effect_pending')"
      )
    )

    create(
      index(:mirror_operations, [:state, :next_attempt_at, :lease_expires_at, :id],
        name: :mirror_operations_claim_index,
        where: "state in ('pending', 'processing', 'effect_pending')"
      )
    )

    create(index(:mirror_operations, [:repository_mirror_id, :state, :id]))
    create(index(:mirror_operations, [:organization_mirror_id, :state, :id]))
    bounded_string(:mirror_operations, :kind, false)
    bounded_string(:mirror_operations, :dedupe_key, false, 512)
    bounded_string(:mirror_operations, :lease_owner, true)
    bounded_string(:mirror_operations, :failure_class, true)
    bounded_string(:mirror_operations, :failure_detail, true, 2_048)
    enum_constraint(:mirror_operations, :state, @operation_states)
    json_object(:mirror_operations, :cursor)
    json_optional_object(:mirror_operations, :external_effect_marker)
    check(:mirror_operations, :mirror_operations_attempt_count_check, "attempt_count >= 0")
    check(:mirror_operations, :mirror_operations_lock_version_check, "lock_version > 0")

    check(
      :mirror_operations,
      :mirror_operations_lease_check,
      "(state = 'processing' and lease_owner is not null and lease_expires_at is not null) or " <>
        "(state = 'effect_pending' and ((lease_owner is null and lease_expires_at is null) or (lease_owner is not null and lease_expires_at is not null))) or " <>
        "(state not in ('processing', 'effect_pending') and lease_owner is null and lease_expires_at is null)"
    )

    check(
      :mirror_operations,
      :mirror_operations_effect_marker_check,
      "(state = 'effect_pending' and external_effect_marker is not null and effect_marked_at is not null) or " <>
        "(state <> 'effect_pending' and external_effect_marker is null and effect_marked_at is null)"
    )

    check(
      :mirror_operations,
      :mirror_operations_completed_at_check,
      "(state = 'completed' and completed_at is not null) or (state <> 'completed' and completed_at is null)"
    )
  end

  defp create_webhook_deliveries do
    create table(:mirror_webhook_deliveries) do
      add(
        :organization_mirror_id,
        references(:organization_mirrors, on_delete: :delete_all),
        null: false
      )

      add(:delivery_guid, :string, null: false)
      add(:hook_id, :bigint)
      add(:event, :string, null: false)
      add(:action, :string)
      add(:installation_id, :bigint, null: false)
      add(:github_repository_id, :bigint)
      add(:signature_version, :string, null: false)
      add(:raw_payload, :map, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime, null: false)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:received_at, :utc_datetime, null: false)
      add(:processed_at, :utc_datetime)
      add(:failure_class, :string)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:mirror_webhook_deliveries, [:delivery_guid]))

    create(
      index(:mirror_webhook_deliveries, [:state, :next_attempt_at, :lease_expires_at, :id],
        name: :mirror_webhook_deliveries_claim_index,
        where: "state in ('pending', 'processing')"
      )
    )

    for field <- [
          :delivery_guid,
          :event,
          :action,
          :signature_version,
          :lease_owner,
          :failure_class
        ] do
      bounded_string(
        :mirror_webhook_deliveries,
        field,
        field in [:action, :lease_owner, :failure_class]
      )
    end

    positive_optional(:mirror_webhook_deliveries, :hook_id)
    positive_optional(:mirror_webhook_deliveries, :github_repository_id)

    check(
      :mirror_webhook_deliveries,
      :mirror_webhook_deliveries_installation_id_check,
      "installation_id > 0"
    )

    enum_constraint(:mirror_webhook_deliveries, :state, ~w(pending processing completed failed))
    json_object(:mirror_webhook_deliveries, :raw_payload)

    check(
      :mirror_webhook_deliveries,
      :mirror_webhook_deliveries_attempt_count_check,
      "attempt_count >= 0"
    )

    check(
      :mirror_webhook_deliveries,
      :mirror_webhook_deliveries_lock_version_check,
      "lock_version > 0"
    )

    check(
      :mirror_webhook_deliveries,
      :mirror_webhook_deliveries_lease_check,
      "(state = 'processing' and lease_owner is not null and lease_expires_at is not null) or " <>
        "(state <> 'processing' and lease_owner is null and lease_expires_at is null)"
    )

    check(
      :mirror_webhook_deliveries,
      :mirror_webhook_deliveries_processed_at_check,
      "(state = 'completed' and processed_at is not null) or (state <> 'completed' and processed_at is null)"
    )
  end

  defp create_conflicts do
    create table(:mirror_conflicts) do
      add(
        :organization_mirror_id,
        references(:organization_mirrors, on_delete: :delete_all),
        null: false
      )

      add(
        :repository_mirror_id,
        references(:repository_mirrors, on_delete: :delete_all)
      )

      add(:resource_kind, :string, null: false)
      add(:resource_identity, :string, null: false)
      add(:conflict_kind, :string, null: false)
      add(:baseline_snapshot, :map, null: false, default: %{})
      add(:local_snapshot, :map, null: false, default: %{})
      add(:remote_snapshot, :map, null: false, default: %{})
      add(:state, :string, null: false, default: "open")
      add(:resolution, :map)
      add(:resolved_by_user_id, references(:users, on_delete: :nilify_all))
      add(:resolved_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(
        :mirror_conflicts,
        [
          :organization_mirror_id,
          "coalesce(repository_mirror_id, 0)",
          :resource_kind,
          :resource_identity
        ],
        name: :mirror_conflicts_one_open_identity_index,
        where: "state = 'open'"
      )
    )

    create(index(:mirror_conflicts, [:organization_mirror_id, :state, :id]))
    create(index(:mirror_conflicts, [:repository_mirror_id, :state, :id]))

    for field <- [:resource_kind, :resource_identity, :conflict_kind] do
      bounded_string(:mirror_conflicts, field, false, 512)
    end

    for field <- [:baseline_snapshot, :local_snapshot, :remote_snapshot] do
      json_object(:mirror_conflicts, field)
    end

    json_optional_object(:mirror_conflicts, :resolution)
    enum_constraint(:mirror_conflicts, :state, ~w(open resolved))
    check(:mirror_conflicts, :mirror_conflicts_lock_version_check, "lock_version > 0")

    check(
      :mirror_conflicts,
      :mirror_conflicts_resolution_coherence_check,
      "(state = 'open' and resolution is null and resolved_by_user_id is null and resolved_at is null) or " <>
        "(state = 'resolved' and resolution is not null and resolved_at is not null)"
    )
  end

  defp enum_constraint(table, field, values) do
    quoted = Enum.map_join(values, ", ", &"'#{&1}'")
    check(table, String.to_atom("#{table}_#{field}_check"), "#{field} in (#{quoted})")
  end

  defp bounded_string(table, field, optional, max \\ 255) do
    prefix = if optional, do: "#{field} is null or ", else: ""

    check(
      table,
      String.to_atom("#{table}_#{field}_bounds_check"),
      "#{prefix}(octet_length(#{field}) between 1 and #{max} and #{field} = btrim(#{field}))"
    )
  end

  defp positive_optional(table, field) do
    check(table, String.to_atom("#{table}_#{field}_check"), "#{field} is null or #{field} > 0")
  end

  defp json_object(table, field) do
    check(
      table,
      String.to_atom("#{table}_#{field}_check"),
      "jsonb_typeof(#{field}) = 'object' and pg_column_size(#{field}) <= 65536"
    )
  end

  defp json_optional_object(table, field) do
    check(
      table,
      String.to_atom("#{table}_#{field}_check"),
      "#{field} is null or (jsonb_typeof(#{field}) = 'object' and pg_column_size(#{field}) <= 65536)"
    )
  end

  defp check(table, name, expression) do
    unless turso?(), do: create(constraint(table, name, check: expression))
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
