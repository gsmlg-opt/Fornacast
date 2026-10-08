defmodule Fornacast.Repo.Migrations.AddOrderedLfsClaimIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(
      index(:lfs_pointer_scan_work_items, [:scan_id, :id],
        name: :lfs_pointer_scan_work_items_active_order_index,
        where: "state IN ('pending', 'processing')",
        concurrently: repo().__adapter__() == Ecto.Adapters.Postgres
      )
    )
  end
end
