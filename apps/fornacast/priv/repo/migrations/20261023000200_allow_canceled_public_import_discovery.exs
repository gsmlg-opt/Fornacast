defmodule Fornacast.Repo.Migrations.AllowCanceledPublicImportDiscovery do
  use Ecto.Migration

  @previous "(source_owner_github_id is null or source_owner_github_id > 0) and " <>
              "(state in ('discovering', 'failed') or " <>
              "(source_owner_github_id is not null and " <>
              "(source_kind = 'organization' or source_repository_github_id is not null)))"
  @canceled "credential_source = 'public' AND state = 'canceled' AND organization_sync_run_id IS NULL AND source_owner_github_id IS NULL AND source_repository_github_id IS NULL"

  def up do
    drop(constraint(:github_import_runs, :github_import_runs_verified_source_check))

    create(
      constraint(:github_import_runs, :github_import_runs_verified_source_check,
        check: "(#{@previous}) OR (#{@canceled})"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      LOCK TABLE github_import_runs IN ACCESS EXCLUSIVE MODE;
      IF EXISTS (SELECT 1 FROM github_import_runs WHERE #{@canceled}) THEN
        RAISE EXCEPTION 'Cannot roll back canceled public discovery while recorded provisional cancellations exist';
      END IF;
    END $$
    """)

    drop(constraint(:github_import_runs, :github_import_runs_verified_source_check))

    create(
      constraint(:github_import_runs, :github_import_runs_verified_source_check, check: @previous)
    )
  end
end
