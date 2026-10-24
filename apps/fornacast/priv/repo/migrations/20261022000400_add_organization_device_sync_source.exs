defmodule Fornacast.Repo.Migrations.AddOrganizationDeviceSyncSource do
  use Ecto.Migration

  @snapshots ~w(organization_connection_id organization_connection_version organization_credential_id organization_credential_version github_installation_id)a

  def up do
    alter table(:organization_pat_configurations) do
      add(:configured_by_user_id, references(:users, on_delete: :restrict))
      add(:credential_source, :string, null: false, default: "personal")
      add_snapshots()
    end

    alter table(:organization_pat_sync_runs) do
      modify(:owner_user_id, :bigint, null: true)
      modify(:github_identity_id, :bigint, null: true)
      add(:credential_source, :string, null: false, default: "personal")
      add(:requested_by_user_id, references(:users, on_delete: :restrict))
      add(:github_organization_id, :bigint)
      add_snapshots()
    end

    alter table(:github_import_runs) do
      add(
        :organization_sync_run_id,
        references(:organization_pat_sync_runs, on_delete: :restrict)
      )

      add_snapshots()
    end

    for table <- [:organization_pat_configurations, :organization_pat_sync_runs] do
      create(constraint(table, :"#{table}_organization_source_check", check: source_check(table)))
    end

    for name <- [
          :github_import_runs_credential_source_check,
          :github_import_runs_credential_identity_check,
          :github_import_runs_credential_consistency_check
        ] do
      drop(constraint(:github_import_runs, name))
    end

    create(
      constraint(:github_import_runs, :github_import_runs_credential_source_check,
        check: "credential_source IN ('saved', 'one_time', 'github_app', 'organization_device')"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_credential_identity_check,
        check:
          "(credential_source IN ('saved','one_time') AND github_identity_id IS NOT NULL) OR (credential_source IN ('github_app','organization_device') AND github_identity_id IS NULL)"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_credential_consistency_check,
        check:
          "(credential_source = 'saved' AND (github_credential_id IS NOT NULL OR state IN ('awaiting_credential','completed','completed_with_warnings','canceled','failed')) AND #{empty_envelope()}) OR (credential_source = 'one_time' AND github_credential_id IS NULL AND ((#{empty_envelope()}) OR (credential_ciphertext IS NOT NULL AND credential_nonce IS NOT NULL AND credential_tag IS NOT NULL AND credential_key_id IS NOT NULL))) OR (credential_source IN ('github_app','organization_device') AND github_credential_id IS NULL AND #{empty_envelope()})"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_organization_source_check,
        check:
          "(credential_source = 'organization_device' AND organization_sync_run_id IS NOT NULL AND destination_organization_id IS NOT NULL AND destination_organization_action = 'existing' AND source_owner_github_id IS NOT NULL AND #{positive_snapshots()}) OR (credential_source <> 'organization_device' AND organization_sync_run_id IS NULL AND #{empty_snapshots()})"
      )
    )

    alter table(:organization_mirrors) do
      add(
        :organization_connection_id,
        references(:organization_github_connections, on_delete: :restrict)
      )

      add(:organization_connection_version, :bigint)

      add(
        :organization_credential_id,
        references(:organization_github_credentials, on_delete: :restrict)
      )

      add(:organization_credential_version, :bigint)
    end

    drop(constraint(:organization_mirrors, :organization_mirrors_pat_authority))

    execute("""
    ALTER TABLE organization_mirrors ADD CONSTRAINT organization_mirrors_pat_authority CHECK (
      (credential_source = 'github_app' AND pat_configuration_id IS NULL
        AND pat_configuration_version IS NULL AND credential_owner_user_id IS NULL
        AND github_identity_id IS NULL AND github_credential_id IS NULL AND github_credential_version IS NULL
        AND #{empty_org_snapshots()})
      OR (credential_source = 'pat' AND github_installation_id IS NULL
        AND pat_configuration_id > 0 AND pat_configuration_version > 0
        AND credential_owner_user_id > 0 AND github_identity_id > 0
        AND github_credential_id > 0 AND github_credential_version > 0
        AND github_account_id > 0 AND #{empty_org_snapshots()}
        AND pat_configuration_id IS NOT NULL AND pat_configuration_version IS NOT NULL
        AND credential_owner_user_id IS NOT NULL AND github_identity_id IS NOT NULL
        AND github_credential_id IS NOT NULL AND github_credential_version IS NOT NULL
        AND github_account_id IS NOT NULL)
      OR (credential_source = 'organization_device' AND pat_configuration_id > 0
        AND pat_configuration_id IS NOT NULL AND pat_configuration_version > 0 AND pat_configuration_version IS NOT NULL
        AND credential_owner_user_id IS NULL AND github_identity_id IS NULL
        AND github_credential_id IS NULL AND github_credential_version IS NULL
        AND github_account_id > 0 AND github_account_id IS NOT NULL AND #{positive_snapshots()}))
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      LOCK TABLE organization_pat_configurations, organization_pat_sync_runs,
        github_import_runs, organization_mirrors IN ACCESS EXCLUSIVE MODE;
      IF EXISTS (SELECT 1 FROM organization_pat_configurations WHERE credential_source = 'organization_device')
        OR EXISTS (SELECT 1 FROM organization_pat_sync_runs WHERE credential_source = 'organization_device')
        OR EXISTS (SELECT 1 FROM github_import_runs WHERE credential_source = 'organization_device')
        OR EXISTS (SELECT 1 FROM organization_mirrors WHERE credential_source = 'organization_device') THEN
        RAISE EXCEPTION 'Cannot roll back organization Device Flow source while recorded organization authority exists';
      END IF;
    END $$
    """)

    for table <- [:organization_pat_configurations, :organization_pat_sync_runs] do
      drop(constraint(table, :"#{table}_organization_source_check"))
    end

    for name <- [
          :github_import_runs_credential_source_check,
          :github_import_runs_credential_identity_check,
          :github_import_runs_credential_consistency_check,
          :github_import_runs_organization_source_check
        ] do
      drop(constraint(:github_import_runs, name))
    end

    create(
      constraint(:github_import_runs, :github_import_runs_credential_source_check,
        check: "credential_source IN ('saved', 'one_time', 'github_app')"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_credential_identity_check,
        check:
          "(credential_source IN ('saved','one_time') AND github_identity_id IS NOT NULL) OR (credential_source = 'github_app' AND github_identity_id IS NULL)"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_credential_consistency_check,
        check:
          "(credential_source = 'saved' AND (github_credential_id IS NOT NULL OR state IN ('awaiting_credential','completed','completed_with_warnings','canceled','failed')) AND #{empty_envelope()}) OR (credential_source = 'one_time' AND github_credential_id IS NULL AND ((#{empty_envelope()}) OR (credential_ciphertext IS NOT NULL AND credential_nonce IS NOT NULL AND credential_tag IS NOT NULL AND credential_key_id IS NOT NULL))) OR (credential_source = 'github_app' AND github_credential_id IS NULL AND #{empty_envelope()})"
      )
    )

    drop(constraint(:organization_mirrors, :organization_mirrors_pat_authority))

    create(
      constraint(:organization_mirrors, :organization_mirrors_pat_authority,
        check: """
        (credential_source = 'github_app' AND pat_configuration_id IS NULL
          AND pat_configuration_version IS NULL AND credential_owner_user_id IS NULL
          AND github_identity_id IS NULL AND github_credential_id IS NULL
          AND github_credential_version IS NULL)
        OR (credential_source = 'pat' AND github_installation_id IS NULL
          AND pat_configuration_id IS NOT NULL AND pat_configuration_version IS NOT NULL
          AND credential_owner_user_id IS NOT NULL AND github_identity_id IS NOT NULL
          AND github_credential_id IS NOT NULL AND github_credential_version IS NOT NULL
          AND github_account_id IS NOT NULL
          AND pat_configuration_id > 0 AND pat_configuration_version > 0
          AND credential_owner_user_id > 0 AND github_identity_id > 0
          AND github_credential_id > 0 AND github_credential_version > 0
          AND github_account_id > 0)
        """
      )
    )

    alter table(:organization_mirrors) do
      for field <- @snapshots -- [:github_installation_id], do: remove(field)
    end

    alter table(:github_import_runs) do
      remove(:organization_sync_run_id)
      for field <- @snapshots, do: remove(field)
    end

    alter table(:organization_pat_sync_runs) do
      modify(:owner_user_id, :bigint, null: false)
      modify(:github_identity_id, :bigint, null: false)
      remove(:credential_source)
      remove(:requested_by_user_id)
      remove(:github_organization_id)
      for field <- @snapshots, do: remove(field)
    end

    alter table(:organization_pat_configurations) do
      remove(:configured_by_user_id)
      remove(:credential_source)
      for field <- @snapshots, do: remove(field)
    end
  end

  defp source_check(table) do
    personal =
      if table == :organization_pat_sync_runs,
        do: " AND owner_user_id IS NOT NULL AND github_identity_id IS NOT NULL",
        else: ""

    organization =
      if table == :organization_pat_sync_runs,
        do:
          " AND requested_by_user_id IS NOT NULL AND github_organization_id > 0 AND github_organization_id IS NOT NULL",
        else: " AND configured_by_user_id IS NOT NULL"

    "(credential_source = 'personal' AND #{empty_snapshots()}#{personal}) OR (credential_source = 'organization_device' AND owner_user_id IS NULL AND github_identity_id IS NULL AND #{positive_snapshots()}#{organization})"
  end

  defp add_snapshots do
    add(
      :organization_connection_id,
      references(:organization_github_connections, on_delete: :restrict)
    )

    add(:organization_connection_version, :bigint)

    add(
      :organization_credential_id,
      references(:organization_github_credentials, on_delete: :restrict)
    )

    add(:organization_credential_version, :bigint)
    add(:github_installation_id, :bigint)
  end

  defp empty_org_snapshots,
    do: Enum.map_join(@snapshots -- [:github_installation_id], " AND ", &"#{&1} IS NULL")

  defp positive_snapshots,
    do: Enum.map_join(@snapshots, " AND ", &"#{&1} IS NOT NULL AND #{&1} > 0")

  defp empty_snapshots, do: Enum.map_join(@snapshots, " AND ", &"#{&1} IS NULL")

  defp empty_envelope,
    do:
      "credential_ciphertext IS NULL AND credential_nonce IS NULL AND credential_tag IS NULL AND credential_key_id IS NULL"
end
