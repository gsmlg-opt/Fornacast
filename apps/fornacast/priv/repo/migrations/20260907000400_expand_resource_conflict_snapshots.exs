defmodule Fornacast.Repo.Migrations.ExpandResourceConflictSnapshots do
  use Ecto.Migration

  @fields [:baseline_snapshot, :local_snapshot, :remote_snapshot]

  def up do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      for field <- @fields do
        name = "mirror_conflicts_#{field}_check"
        drop(constraint(:mirror_conflicts, name))

        create(
          constraint(:mirror_conflicts, name,
            check: "jsonb_typeof(#{field}) = 'object' and octet_length(#{field}::text) <= 2000000"
          )
        )
      end
    end
  end

  def down do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      for field <- @fields do
        name = "mirror_conflicts_#{field}_check"
        drop(constraint(:mirror_conflicts, name))

        create(
          constraint(:mirror_conflicts, name,
            check: "jsonb_typeof(#{field}) = 'object' and pg_column_size(#{field}) <= 65536"
          )
        )
      end
    end
  end
end
