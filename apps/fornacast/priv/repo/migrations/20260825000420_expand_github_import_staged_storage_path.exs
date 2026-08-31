defmodule Fornacast.Repo.Migrations.ExpandGitHubImportStagedStoragePath do
  use Ecto.Migration

  def up do
    # SQLite/libSQL already stores Ecto :string columns as unbounded TEXT, so only PostgreSQL
    # needs a physical type change for the absolute staging-path contract.
    unless turso?() do
      execute(
        "ALTER TABLE github_import_repository_items " <>
          "ALTER COLUMN staged_storage_path TYPE text"
      )
    end
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM github_import_repository_items
        WHERE char_length(staged_storage_path) > 255
      ) THEN
        RAISE EXCEPTION 'staged_storage_path exceeds varchar(255)';
      END IF;
    END
    $$
    """)

    execute(
      "ALTER TABLE github_import_repository_items " <>
        "ALTER COLUMN staged_storage_path TYPE varchar(255)"
    )
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
