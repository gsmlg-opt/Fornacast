defmodule Fornacast.Repo.Migrations.CreateGitHubImportDomain do
  use Ecto.Migration

  @run_states ~w(discovering awaiting_resolution ready running awaiting_credential cancel_requested completed completed_with_warnings canceled failed)
  @item_states ~w(queued awaiting_resolution staging_git git_staged staging_metadata ready_to_publish publishing published completed awaiting_credential cancel_requested skipped canceled failed)

  def up do
    create_runs()
    create_repository_items()
    create_attempts()
    create_object_mappings()
    create_page_checkpoints()
    create_report_entries()
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop(table(:github_import_report_entries))
    drop(table(:github_import_page_checkpoints))
    drop(table(:github_import_object_mappings))
    drop(table(:github_import_attempts))
    drop(table(:github_import_repository_items))
    drop(table(:github_import_runs))
  end

  defp create_runs do
    create table(:github_import_runs) do
      add(:actor_user_id, references(:users, on_delete: :restrict), null: false)

      add(:predecessor_run_id, references(:github_import_runs, on_delete: :nilify_all))

      add(
        :source_kind,
        :string,
        column_options(
          [null: false],
          :github_import_runs_source_kind_check,
          "source_kind in ('repository', 'organization')"
        )
      )

      add(:github_identity_id, references(:github_identities, on_delete: :restrict), null: false)

      add(
        :credential_source,
        :string,
        column_options(
          [null: false],
          :github_import_runs_credential_source_check,
          "credential_source in ('saved', 'one_time')"
        )
      )

      add(:github_credential_id, references(:github_credentials, on_delete: :nilify_all))

      add(
        :source_owner_github_id,
        :bigint,
        column_options(
          [null: false],
          :github_import_runs_source_owner_id_positive_check,
          "source_owner_github_id > 0"
        )
      )

      add(:source_owner_login, :string, null: false)

      add(
        :source_repository_github_id,
        :bigint,
        column_options(
          [],
          :github_import_runs_source_repository_id_positive_check,
          "source_repository_github_id is null or source_repository_github_id > 0"
        )
      )

      add(:source_repository_full_name, :string)

      add(
        :destination_organization_action,
        :string,
        column_options(
          [],
          :github_import_runs_destination_action_check,
          "destination_organization_action is null or destination_organization_action in ('new', 'existing')"
        )
      )

      add(:destination_organization_slug, :string)
      add(:destination_organization_id, references(:users, on_delete: :restrict))

      add(
        :state,
        :string,
        column_options(
          [null: false, default: "discovering"],
          :github_import_runs_state_check,
          enum_check("state", @run_states)
        )
      )

      add(
        :resume_state,
        :string,
        column_options(
          [],
          :github_import_runs_resume_state_check,
          "resume_state is null or #{enum_check("resume_state", @run_states)}"
        )
      )

      add(
        :wait_reason,
        :string,
        column_options(
          [],
          :github_import_runs_resume_state_coherence_check,
          run_resume_state_check()
        )
      )

      add(:next_attempt_at, :utc_datetime)
      add(:cancellation_requested_at, :utc_datetime)

      add(
        :terminal_at,
        :utc_datetime,
        column_options([], :github_import_runs_terminal_at_check, run_terminal_at_check())
      )

      add(:report_finalized_at, :utc_datetime)
      add(:failure_kind, :string)
      add(:failure_detail, :text)

      for field <- [
            :selected_count,
            :published_count,
            :skipped_count,
            :warning_count,
            :failure_count
          ] do
        add(
          field,
          :integer,
          column_options(
            [null: false, default: 0],
            count_check_name(:runs, field),
            "#{field} >= 0"
          )
        )
      end

      add(:request_metadata, :map, null: false, default: %{})

      add(
        :credential_ciphertext,
        :binary,
        column_options(
          [],
          :github_import_runs_credential_consistency_check,
          credential_consistency_check()
        )
      )

      add(
        :credential_nonce,
        :binary,
        column_options(
          [],
          :github_import_runs_terminal_envelope_check,
          terminal_envelope_check()
        )
      )

      add(:credential_tag, :binary)
      add(:credential_key_id, :string)

      add(
        :lease_owner,
        :string,
        column_options([], :github_import_runs_terminal_lease_check, run_terminal_lease_check())
      )

      add(:lease_expires_at, :utc_datetime)

      add(
        :lock_version,
        :integer,
        column_options(
          [null: false, default: 1],
          :github_import_runs_lock_version_check,
          "lock_version > 0"
        )
      )

      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_runs,
      :github_import_runs_credential_consistency_check,
      credential_consistency_check()
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_terminal_envelope_check,
      terminal_envelope_check()
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_source_kind_check,
      "source_kind in ('repository', 'organization')"
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_credential_source_check,
      "credential_source in ('saved', 'one_time')"
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_source_owner_id_positive_check,
      "source_owner_github_id > 0"
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_source_repository_id_positive_check,
      "source_repository_github_id is null or source_repository_github_id > 0"
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_destination_action_check,
      "destination_organization_action is null or destination_organization_action in ('new', 'existing')"
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_state_check,
      enum_check("state", @run_states)
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_resume_state_check,
      "resume_state is null or #{enum_check("resume_state", @run_states)}"
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_resume_state_coherence_check,
      run_resume_state_check()
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_terminal_at_check,
      run_terminal_at_check()
    )

    postgres_check(
      :github_import_runs,
      :github_import_runs_terminal_lease_check,
      run_terminal_lease_check()
    )

    for field <- [
          :selected_count,
          :published_count,
          :skipped_count,
          :warning_count,
          :failure_count
        ] do
      postgres_check(
        :github_import_runs,
        count_check_name(:runs, field),
        "#{field} >= 0"
      )
    end

    postgres_check(
      :github_import_runs,
      :github_import_runs_lock_version_check,
      "lock_version > 0"
    )

    create(index(:github_import_runs, [:actor_user_id, :inserted_at]))

    create(
      index(:github_import_runs, [:state, :next_attempt_at, :lease_expires_at, :id],
        name: :github_import_runs_recovery_index
      )
    )

    create(index(:github_import_runs, [:github_credential_id]))
    create(index(:github_import_runs, [:predecessor_run_id]))
  end

  defp create_repository_items do
    create table(:github_import_repository_items) do
      add(:import_run_id, references(:github_import_runs, on_delete: :delete_all), null: false)

      add(
        :predecessor_item_id,
        references(:github_import_repository_items, on_delete: :nilify_all)
      )

      add(
        :github_repository_id,
        :bigint,
        column_options(
          [null: false],
          :github_import_items_repository_id_positive_check,
          "github_repository_id > 0"
        )
      )

      add(:source_full_name, :string, null: false)
      add(:source_name, :string, null: false)
      add(:source_metadata, :map, null: false, default: %{})
      add(:source_observed_at, :utc_datetime, null: false)
      add(:selected, :boolean, null: false, default: true)
      add(:destination_owner_id, references(:users, on_delete: :restrict))
      add(:destination_slug, :string)

      add(
        :destination_visibility,
        :string,
        column_options(
          [],
          :github_import_items_destination_visibility_check,
          "destination_visibility is null or destination_visibility in ('private', 'public')"
        )
      )

      add(
        :conflict_action,
        :string,
        column_options(
          [],
          :github_import_items_conflict_action_check,
          "conflict_action is null or conflict_action in ('skip', 'rename', 'replace')"
        )
      )

      add(:replacement_repository_id, :bigint)
      add(:replacement_owner_id, :bigint)
      add(:replacement_storage_path, :string)
      add(:replacement_generation, :integer)
      add(:replacement_updated_at, :utc_datetime)
      add(:replacement_last_pushed_at, :utc_datetime)
      add(:hidden_repository_id, references(:repositories, on_delete: :restrict))
      add(:staged_storage_path, :string)

      add(
        :state,
        :string,
        column_options(
          [null: false, default: "queued"],
          :github_import_items_state_check,
          enum_check("state", @item_states)
        )
      )

      add(
        :resume_state,
        :string,
        column_options(
          [],
          :github_import_items_resume_state_check,
          "resume_state is null or #{enum_check("resume_state", @item_states)}"
        )
      )

      add(
        :wait_reason,
        :string,
        column_options(
          [],
          :github_import_items_resume_state_coherence_check,
          item_resume_state_check()
        )
      )

      add(:next_attempt_at, :utc_datetime)

      add(
        :lease_owner,
        :string,
        column_options(
          [],
          :github_import_items_terminal_lease_check,
          item_terminal_lease_check()
        )
      )

      add(:lease_expires_at, :utc_datetime)

      add(
        :lock_version,
        :integer,
        column_options(
          [null: false, default: 1],
          :github_import_items_lock_version_check,
          "lock_version > 0"
        )
      )

      add(
        :attempt_count,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_items_attempt_count_check,
          "attempt_count >= 0"
        )
      )

      add(:failure_kind, :string)
      add(:failure_detail, :text)
      add(:checkpoint, :map, null: false, default: %{})
      add(:source_git, :map, null: false, default: %{})
      add(:publication_evidence, :map, null: false, default: %{})

      for field <- [:imported_count, :skipped_count, :warning_count, :failure_count] do
        add(
          field,
          :integer,
          column_options(
            [null: false, default: 0],
            count_check_name(:items, field),
            "#{field} >= 0"
          )
        )
      end

      add(:cleanup_state, :string)
      add(:cleanup_eligible_at, :utc_datetime)

      add(
        :cleanup_attempt_count,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_items_cleanup_attempt_count_check,
          "cleanup_attempt_count >= 0"
        )
      )

      add(:cleanup_error, :text)
      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_repository_items,
      :github_import_items_repository_id_positive_check,
      "github_repository_id > 0"
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_destination_visibility_check,
      "destination_visibility is null or destination_visibility in ('private', 'public')"
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_conflict_action_check,
      "conflict_action is null or conflict_action in ('skip', 'rename', 'replace')"
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_state_check,
      enum_check("state", @item_states)
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_resume_state_check,
      "resume_state is null or #{enum_check("resume_state", @item_states)}"
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_resume_state_coherence_check,
      item_resume_state_check()
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_terminal_lease_check,
      item_terminal_lease_check()
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_lock_version_check,
      "lock_version > 0"
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_attempt_count_check,
      "attempt_count >= 0"
    )

    postgres_check(
      :github_import_repository_items,
      :github_import_items_cleanup_attempt_count_check,
      "cleanup_attempt_count >= 0"
    )

    for field <- [:imported_count, :skipped_count, :warning_count, :failure_count] do
      postgres_check(
        :github_import_repository_items,
        count_check_name(:items, field),
        "#{field} >= 0"
      )
    end

    create(
      unique_index(:github_import_repository_items, [:import_run_id, :github_repository_id],
        name: :github_import_items_run_repository_index
      )
    )

    create(
      unique_index(:github_import_repository_items, [:id, :import_run_id],
        name: :github_import_items_id_run_index
      )
    )

    create(
      index(
        :github_import_repository_items,
        [:state, :next_attempt_at, :lease_expires_at, :id],
        name: :github_import_items_recovery_index
      )
    )

    create(index(:github_import_repository_items, [:hidden_repository_id]))
    create(index(:github_import_repository_items, [:predecessor_item_id]))
  end

  defp create_attempts do
    create table(:github_import_attempts) do
      add(
        :repository_item_id,
        references(:github_import_repository_items, on_delete: :delete_all),
        null: false
      )

      add(
        :attempt_number,
        :integer,
        column_options(
          [null: false],
          :github_import_attempts_number_positive_check,
          "attempt_number > 0"
        )
      )

      add(
        :state,
        :string,
        column_options(
          [null: false],
          :github_import_attempts_state_check,
          "state in ('running', 'completed', 'failed', 'canceled', 'destination_changed')"
        )
      )

      add(:decision, :map, null: false, default: %{})
      add(:started_at, :utc_datetime, null: false)

      add(
        :terminal_at,
        :utc_datetime,
        column_options(
          [],
          :github_import_attempts_terminal_at_check,
          attempt_terminal_at_check()
        )
      )

      add(:failure_kind, :string)
      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_attempts,
      :github_import_attempts_number_positive_check,
      "attempt_number > 0"
    )

    postgres_check(
      :github_import_attempts,
      :github_import_attempts_state_check,
      "state in ('running', 'completed', 'failed', 'canceled', 'destination_changed')"
    )

    postgres_check(
      :github_import_attempts,
      :github_import_attempts_terminal_at_check,
      attempt_terminal_at_check()
    )

    create(
      unique_index(:github_import_attempts, [:repository_item_id, :attempt_number],
        name: :github_import_attempts_item_number_index
      )
    )
  end

  defp create_object_mappings do
    create table(:github_import_object_mappings) do
      add(
        :repository_item_id,
        references(:github_import_repository_items, on_delete: :delete_all),
        null: false
      )

      add(:hidden_repository_id, references(:repositories, on_delete: :restrict), null: false)

      add(
        :github_repository_id,
        :bigint,
        column_options(
          [null: false],
          :github_import_mappings_repository_id_positive_check,
          "github_repository_id > 0"
        )
      )

      add(:object_kind, :string, null: false)

      add(
        :github_object_id,
        :bigint,
        column_options(
          [null: false],
          :github_import_mappings_object_id_positive_check,
          "github_object_id > 0"
        )
      )

      add(:local_resource_type, :string, null: false)
      add(:local_resource_id, :bigint, null: false)
      add(:source_url, :text)
      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_object_mappings,
      :github_import_mappings_repository_id_positive_check,
      "github_repository_id > 0"
    )

    postgres_check(
      :github_import_object_mappings,
      :github_import_mappings_object_id_positive_check,
      "github_object_id > 0"
    )

    create(
      unique_index(
        :github_import_object_mappings,
        [:hidden_repository_id, :github_repository_id, :object_kind, :github_object_id],
        name: :github_import_mappings_source_object_index
      )
    )

    create(index(:github_import_object_mappings, [:repository_item_id]))
  end

  defp create_page_checkpoints do
    create table(:github_import_page_checkpoints) do
      add(
        :repository_item_id,
        references(:github_import_repository_items, on_delete: :delete_all),
        null: false
      )

      add(:resource_kind, :string, null: false)
      add(:page_key, :string, null: false)
      add(:etag, :string)
      add(:observed_at, :utc_datetime)

      add(
        :item_count,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_checkpoints_item_count_check,
          "item_count >= 0"
        )
      )

      add(:cursor_metadata, :map, null: false, default: %{})
      add(:committed_at, :utc_datetime, null: false)
      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_page_checkpoints,
      :github_import_checkpoints_item_count_check,
      "item_count >= 0"
    )

    create(
      unique_index(
        :github_import_page_checkpoints,
        [:repository_item_id, :resource_kind, :page_key],
        name: :github_import_checkpoints_item_resource_page_index
      )
    )
  end

  defp create_report_entries do
    create table(:github_import_report_entries) do
      add(:import_run_id, references(:github_import_runs, on_delete: :delete_all), null: false)

      add(
        :repository_item_id,
        references(:github_import_repository_items,
          on_delete: :delete_all,
          with: [import_run_id: :import_run_id],
          name: :github_import_reports_item_run_fkey
        )
      )

      add(:idempotency_key, :string, null: false)

      add(
        :scope,
        :string,
        column_options(
          [null: false],
          :github_import_reports_scope_check,
          "scope in ('run', 'repository', 'object')"
        )
      )

      add(:object_kind, :string)

      add(
        :source_object_id,
        :bigint,
        column_options(
          [],
          :github_import_reports_source_object_id_positive_check,
          "source_object_id is null or source_object_id > 0"
        )
      )

      add(
        :outcome,
        :string,
        column_options(
          [null: false],
          :github_import_reports_outcome_check,
          "outcome in ('imported', 'skipped', 'warning', 'failed', 'canceled', 'not_selected')"
        )
      )

      add(:classification, :string, null: false)
      add(:summary, :text, null: false)
      add(:metadata, :map, null: false, default: %{})

      add(
        :source_count,
        :integer,
        column_options(
          [null: false, default: 0],
          :github_import_reports_source_count_check,
          "source_count >= 0"
        )
      )

      timestamps(type: :utc_datetime)
    end

    postgres_check(
      :github_import_report_entries,
      :github_import_reports_scope_check,
      "scope in ('run', 'repository', 'object')"
    )

    postgres_check(
      :github_import_report_entries,
      :github_import_reports_source_object_id_positive_check,
      "source_object_id is null or source_object_id > 0"
    )

    postgres_check(
      :github_import_report_entries,
      :github_import_reports_outcome_check,
      "outcome in ('imported', 'skipped', 'warning', 'failed', 'canceled', 'not_selected')"
    )

    postgres_check(
      :github_import_report_entries,
      :github_import_reports_source_count_check,
      "source_count >= 0"
    )

    create(
      unique_index(:github_import_report_entries, [:import_run_id, :idempotency_key],
        name: :github_import_reports_run_idempotency_index
      )
    )

    create(index(:github_import_report_entries, [:repository_item_id]))
  end

  defp column_options(options, name, expression) do
    if turso?(),
      do: Keyword.put(options, :check, name: to_string(name), expr: expression),
      else: options
  end

  defp postgres_check(table, name, expression) do
    unless turso?(), do: create(constraint(table, name, check: expression))
  end

  defp enum_check(field, values) do
    encoded = values |> Enum.map_join(", ", &"'#{&1}'")
    "#{field} in (#{encoded})"
  end

  defp credential_consistency_check do
    "(credential_source = 'saved' and (github_credential_id is not null or state in ('awaiting_credential', 'completed', 'completed_with_warnings', 'canceled', 'failed')) and credential_ciphertext is null and credential_nonce is null and credential_tag is null and credential_key_id is null) or " <>
      "(credential_source = 'one_time' and github_credential_id is null and ((credential_ciphertext is null and credential_nonce is null and credential_tag is null and credential_key_id is null) or " <>
      "(credential_ciphertext is not null and credential_nonce is not null and credential_tag is not null and credential_key_id is not null)))"
  end

  defp terminal_envelope_check do
    "state not in ('completed', 'completed_with_warnings', 'canceled', 'failed') or " <>
      "(credential_ciphertext is null and credential_nonce is null and credential_tag is null and credential_key_id is null)"
  end

  defp run_terminal_at_check do
    "(state in ('completed', 'completed_with_warnings', 'canceled', 'failed') and terminal_at is not null) or " <>
      "(state not in ('completed', 'completed_with_warnings', 'canceled', 'failed') and terminal_at is null)"
  end

  defp run_terminal_lease_check do
    "state not in ('completed', 'completed_with_warnings', 'canceled', 'failed') or " <>
      "(lease_owner is null and lease_expires_at is null)"
  end

  defp run_resume_state_check do
    "(state = 'awaiting_credential' and resume_state is not null and resume_state in ('awaiting_resolution', 'ready', 'running')) or " <>
      "(state != 'awaiting_credential' and resume_state is null)"
  end

  defp item_terminal_lease_check do
    "state not in ('completed', 'skipped', 'canceled', 'failed') or " <>
      "(lease_owner is null and lease_expires_at is null)"
  end

  defp item_resume_state_check do
    "(state = 'awaiting_credential' and resume_state is not null and resume_state in ('queued', 'awaiting_resolution', 'staging_git', 'git_staged', 'staging_metadata', 'ready_to_publish', 'publishing')) or " <>
      "(state != 'awaiting_credential' and resume_state is null)"
  end

  defp attempt_terminal_at_check do
    "(state = 'running' and terminal_at is null) or " <>
      "(state in ('completed', 'failed', 'canceled', 'destination_changed') and terminal_at is not null)"
  end

  defp count_check_name(:runs, field), do: String.to_atom("github_import_runs_#{field}_check")
  defp count_check_name(:items, field), do: String.to_atom("github_import_items_#{field}_check")

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
