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
    raise "Cannot remove the publication gate while synchronized repositories may be pending"
  end
end
