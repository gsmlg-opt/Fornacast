defmodule Fornacast.Repo.Migrations.AddConfirmedResourceSnapshots do
  use Ecto.Migration

  def up do
    alter table(:mirror_resource_states) do
      add(:confirmed_snapshot, :map)
    end

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(:mirror_resource_states, :mirror_resource_states_snapshot_check,
          check:
            "confirmed_snapshot is null or (jsonb_typeof(confirmed_snapshot) = 'object' " <>
              "and octet_length(confirmed_snapshot::text) <= 2000000)"
        )
      )
    end
  end

  def down do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(constraint(:mirror_resource_states, :mirror_resource_states_snapshot_check))
    end

    alter table(:mirror_resource_states) do
      remove(:confirmed_snapshot)
    end
  end
end
