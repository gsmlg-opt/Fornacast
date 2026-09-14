defmodule Fornacast.Repo.Migrations.AddRepositorySyncPublicationGate do
  use Ecto.Migration

  def up do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(constraint(:repositories, :repositories_lifecycle_check))

      create(
        constraint(:repositories, :repositories_lifecycle_check,
          check: "lifecycle in ('importing', 'synchronizing', 'ready', 'tombstoned')"
        )
      )
    end
  end

  def down do
    ensure_postgres_rollback!()

    execute("""
    do $$
    begin
      if exists (select 1 from repositories where lifecycle = 'synchronizing') then
        raise exception 'Cannot remove the publication gate while synchronized repositories may be pending';
      end if;
    end
    $$;
    """)

    drop(constraint(:repositories, :repositories_lifecycle_check))

    create(
      constraint(:repositories, :repositories_lifecycle_check,
        check: "lifecycle in ('importing', 'ready', 'tombstoned')"
      )
    )
  end

  defp ensure_postgres_rollback! do
    if repo().__adapter__() == Ecto.Adapters.Turso do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end
  end
end
