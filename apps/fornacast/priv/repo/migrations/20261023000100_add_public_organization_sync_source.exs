defmodule Fornacast.Repo.Migrations.AddPublicOrganizationSyncSource do
  use Ecto.Migration

  @snapshots ~w(organization_connection_id organization_connection_version organization_credential_id organization_credential_version github_installation_id)a
  @tables [:organization_pat_configurations, :organization_pat_sync_runs]
  @checks [
    :github_import_runs_credential_source_check,
    :github_import_runs_credential_identity_check,
    :github_import_runs_credential_consistency_check,
    :github_import_runs_organization_source_check
  ]

  def up do
    alter(table(:organization_pat_configurations), do: add(:github_organization_id, :bigint))
    alter(table(:organization_pat_sync_runs), do: add(:public_configuration_version, :bigint))
    alter(table(:github_import_runs), do: add(:public_configuration_version, :bigint))
    replace_constraints(true)
  end

  def down do
    execute("""
    DO $$ BEGIN
      LOCK TABLE organization_pat_configurations, organization_pat_sync_runs, github_import_runs IN ACCESS EXCLUSIVE MODE;
      IF EXISTS (SELECT 1 FROM organization_pat_configurations WHERE credential_source = 'public')
        OR EXISTS (SELECT 1 FROM organization_pat_sync_runs WHERE credential_source = 'public')
        OR EXISTS (SELECT 1 FROM github_import_runs WHERE credential_source = 'public') THEN
        RAISE EXCEPTION 'Cannot roll back public source while recorded public authority exists';
      END IF;
    END $$
    """)

    replace_constraints(false)
    alter(table(:github_import_runs), do: remove(:public_configuration_version))
    alter(table(:organization_pat_sync_runs), do: remove(:public_configuration_version))
    alter(table(:organization_pat_configurations), do: remove(:github_organization_id))
  end

  defp replace_constraints(public?) do
    for table <- @tables do
      drop(constraint(table, :"#{table}_organization_source_check"))
      previous = previous_source_check(table)
      check = if public?, do: public_source_check(table, previous), else: previous
      create(constraint(table, :"#{table}_organization_source_check", check: check))
    end

    for name <- @checks, do: drop(constraint(:github_import_runs, name))

    sources =
      if public?,
        do: "'github_app','organization_device','public'",
        else: "'github_app','organization_device'"

    create(
      constraint(:github_import_runs, :github_import_runs_credential_source_check,
        check: "credential_source IN ('saved','one_time',#{sources})"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_credential_identity_check,
        check:
          "(credential_source IN ('saved','one_time') AND github_identity_id IS NOT NULL) OR (credential_source IN (#{sources}) AND github_identity_id IS NULL)"
      )
    )

    create(
      constraint(:github_import_runs, :github_import_runs_credential_consistency_check,
        check:
          "(credential_source = 'saved' AND (github_credential_id IS NOT NULL OR state IN ('awaiting_credential','completed','completed_with_warnings','canceled','failed')) AND #{empty_envelope()}) OR (credential_source = 'one_time' AND github_credential_id IS NULL AND ((#{empty_envelope()}) OR (credential_ciphertext IS NOT NULL AND credential_nonce IS NOT NULL AND credential_tag IS NOT NULL AND credential_key_id IS NOT NULL))) OR (credential_source IN (#{sources}) AND github_credential_id IS NULL AND #{empty_envelope()})"
      )
    )

    device =
      "credential_source = 'organization_device' AND organization_sync_run_id IS NOT NULL AND destination_organization_id IS NOT NULL AND destination_organization_action = 'existing' AND source_owner_github_id IS NOT NULL AND #{positive_snapshots()}"

    other =
      "credential_source <> 'organization_device' AND organization_sync_run_id IS NULL AND #{empty_snapshots()}"

    check =
      if public? do
        "((#{device}) AND public_configuration_version IS NULL) OR (credential_source = 'public' AND #{empty_snapshots()} AND ((organization_sync_run_id IS NULL AND public_configuration_version IS NULL) OR (organization_sync_run_id IS NOT NULL AND public_configuration_version IS NOT NULL AND public_configuration_version > 0 AND source_owner_github_id IS NOT NULL AND source_owner_github_id > 0 AND destination_organization_id IS NOT NULL AND destination_organization_action = 'existing'))) OR ((#{other}) AND credential_source <> 'public' AND public_configuration_version IS NULL)"
      else
        "(#{device}) OR (#{other})"
      end

    create(
      constraint(:github_import_runs, :github_import_runs_organization_source_check, check: check)
    )
  end

  defp public_source_check(table, previous) do
    provenance =
      if table == :organization_pat_sync_runs,
        do:
          "requested_by_user_id IS NOT NULL AND public_configuration_version IS NOT NULL AND public_configuration_version > 0",
        else: "configured_by_user_id IS NOT NULL"

    empty =
      if table == :organization_pat_sync_runs,
        do: "public_configuration_version IS NULL",
        else: "github_organization_id IS NULL"

    "((#{previous}) AND #{empty}) OR (credential_source = 'public' AND owner_user_id IS NULL AND github_identity_id IS NULL AND github_organization_id IS NOT NULL AND github_organization_id > 0 AND #{empty_snapshots()} AND #{provenance})"
  end

  defp previous_source_check(table) do
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

  defp positive_snapshots,
    do: Enum.map_join(@snapshots, " AND ", &"#{&1} IS NOT NULL AND #{&1} > 0")

  defp empty_snapshots, do: Enum.map_join(@snapshots, " AND ", &"#{&1} IS NULL")

  defp empty_envelope,
    do:
      "credential_ciphertext IS NULL AND credential_nonce IS NULL AND credential_tag IS NULL AND credential_key_id IS NULL"
end
