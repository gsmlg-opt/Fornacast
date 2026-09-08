defmodule Fornacast.Repo.Migrations.AddCoordinatedMergeTreeCheckpoint do
  use Ecto.Migration

  def change do
    alter table(:pull_merge_operations) do
      add(:merge_tree_oid, :string)
    end
  end
end
