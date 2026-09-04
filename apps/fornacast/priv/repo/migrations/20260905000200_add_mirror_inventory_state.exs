defmodule Fornacast.Repo.Migrations.AddMirrorInventoryState do
  use Ecto.Migration

  def up do
    alter table(:repository_mirrors) do
      add(:github_archived, :boolean)
      add(:inventory_included, :boolean, null: false, default: true)
      add(:inventory_selection, :string, null: false, default: "all")
      add(:last_inventory_sweep, :string)
    end

    alter table(:mirror_operations) do
      add(:checkpoint, :map, null: false, default: %{})
    end

    create(
      index(:repository_mirrors, [:organization_mirror_id, :last_inventory_sweep, :id],
        name: :repository_mirrors_inventory_sweep_index,
        where: "github_repository_id is not null and state <> 'tombstoned'"
      )
    )

    unless turso?() do
      create(
        constraint(:repository_mirrors, :repository_mirrors_inventory_selection_check,
          check: "inventory_selection in ('all', 'selected')"
        )
      )

      create(
        constraint(:repository_mirrors, :repository_mirrors_inventory_sweep_check,
          check:
            "last_inventory_sweep is null or (octet_length(last_inventory_sweep) between 1 and 255 and last_inventory_sweep = btrim(last_inventory_sweep))"
        )
      )

      create(
        constraint(:mirror_operations, :mirror_operations_checkpoint_check,
          check: "jsonb_typeof(checkpoint) = 'object' and pg_column_size(checkpoint) <= 65536"
        )
      )
    end
  end

  def down do
    unless turso?() do
      drop(constraint(:mirror_operations, :mirror_operations_checkpoint_check))
      drop(constraint(:repository_mirrors, :repository_mirrors_inventory_sweep_check))
      drop(constraint(:repository_mirrors, :repository_mirrors_inventory_selection_check))
    end

    drop(
      index(:repository_mirrors, [:organization_mirror_id, :last_inventory_sweep, :id],
        name: :repository_mirrors_inventory_sweep_index
      )
    )

    alter table(:mirror_operations) do
      remove(:checkpoint)
    end

    alter table(:repository_mirrors) do
      remove(:last_inventory_sweep)
      remove(:inventory_selection)
      remove(:inventory_included)
      remove(:github_archived)
    end
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
