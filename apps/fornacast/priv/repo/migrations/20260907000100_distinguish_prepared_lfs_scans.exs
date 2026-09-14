defmodule Fornacast.Repo.Migrations.DistinguishPreparedLfsScans do
  use Ecto.Migration

  def up do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(constraint(:lfs_pointer_scans, :lfs_pointer_scans_state_check))
      drop(constraint(:lfs_pointer_scans, :lfs_pointer_scans_completion_check))

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_state_check,
          check: "state in ('scanning', 'complete', 'prepared', 'published')"
        )
      )

      create(
        constraint(:lfs_pointer_scans, :lfs_pointer_scans_completion_check,
          check:
            "(state = 'scanning' and completed_at is null and published_at is null) or " <>
              "(state = 'complete' and completed_at is not null and published_at is null) or " <>
              "(state in ('prepared', 'published') and completed_at is not null and published_at is not null)"
        )
      )
    end
  end

  def down do
    ensure_postgres_rollback!()

    execute("""
    do $$
    begin
      if exists (select 1 from lfs_pointer_scans where state in ('prepared', 'published')) then
        raise exception 'Cannot discard the distinction between prepared and authoritative LFS scans';
      end if;
    end
    $$;
    """)

    drop(constraint(:lfs_pointer_scans, :lfs_pointer_scans_state_check))
    drop(constraint(:lfs_pointer_scans, :lfs_pointer_scans_completion_check))

    create(
      constraint(:lfs_pointer_scans, :lfs_pointer_scans_state_check,
        check: "state in ('scanning', 'complete', 'published')"
      )
    )

    create(
      constraint(:lfs_pointer_scans, :lfs_pointer_scans_completion_check,
        check:
          "(state = 'scanning' and completed_at is null and published_at is null) or " <>
            "(state = 'complete' and completed_at is not null and published_at is null) or " <>
            "(state = 'published' and completed_at is not null and published_at is not null)"
      )
    )
  end

  defp ensure_postgres_rollback! do
    if repo().__adapter__() == Ecto.Adapters.Turso do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end
  end
end
