defmodule Fornacast.Repo.Migrations.AddImportRecoveryConstraints do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create(
      unique_index(:github_import_runs, [:predecessor_run_id],
        name: :github_import_runs_predecessor_run_id_unique_index,
        where: "predecessor_run_id is not null"
      )
    )

    create(
      unique_index(:github_import_repository_items, [:predecessor_item_id],
        name: :github_import_items_predecessor_item_id_unique_index,
        where: "predecessor_item_id is not null"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:github_import_repository_items, [:predecessor_item_id],
        name: :github_import_items_predecessor_item_id_unique_index
      )
    )

    drop_if_exists(
      index(:github_import_runs, [:predecessor_run_id],
        name: :github_import_runs_predecessor_run_id_unique_index
      )
    )
  end
end
