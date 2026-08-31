defmodule Fornacast.Repo.Migrations.AddRepositoryCleanupSelectorIndexes do
  use Ecto.Migration

  def up do
    unless turso?() do
      drop(
        index(
          :github_import_repository_cleanups,
          [:state, :next_attempt_at, :eligible_at, :id],
          name: :github_import_repository_cleanups_recovery_index
        )
      )

      create(
        index(
          :github_import_repository_cleanups,
          [:kind, :state, :next_attempt_at, :eligible_at, :id],
          name: :github_import_repository_cleanups_recovery_index
        )
      )

      create(
        index(
          :github_import_repository_items,
          [:cleanup_state, :cleanup_eligible_at, :id],
          name: :github_import_items_cleanup_due_index
        )
      )

      create(
        index(
          :github_import_repository_items,
          [:replacement_repository_id, :id],
          name: :github_import_items_replacement_cleanup_index
        )
      )

      execute("""
      CREATE INDEX github_import_items_unpublished_cleanup_index
      ON github_import_repository_items
        ((COALESCE(cleanup_eligible_at, updated_at)), id)
      WHERE state IN ('completed', 'skipped', 'canceled', 'failed', 'published')
        AND publication_evidence = '{}'::jsonb
        AND lease_owner IS NULL
        AND lease_expires_at IS NULL
      """)
    end
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    execute("DROP INDEX github_import_items_unpublished_cleanup_index")

    drop(
      index(
        :github_import_repository_items,
        [:replacement_repository_id, :id],
        name: :github_import_items_replacement_cleanup_index
      )
    )

    drop(
      index(
        :github_import_repository_items,
        [:cleanup_state, :cleanup_eligible_at, :id],
        name: :github_import_items_cleanup_due_index
      )
    )

    drop(
      index(
        :github_import_repository_cleanups,
        [:kind, :state, :next_attempt_at, :eligible_at, :id],
        name: :github_import_repository_cleanups_recovery_index
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

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
