defmodule Fornacast.Repo.Migrations.AddCoordinatedMergeIntents do
  use Ecto.Migration

  def change do
    alter table(:pull_merge_operations) do
      add(:coordination_mode, :string, null: false, default: "standalone")
      add(:coordinator_operation_id, :bigint)
      add(:commit_intent, :map)
    end

    create(unique_index(:pull_merge_operations, [:coordinator_operation_id]))

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(:pull_merge_operations, :pull_merge_operations_coordination_check,
          check:
            "(coordination_mode = 'standalone' and coordinator_operation_id is null and commit_intent is null) or " <>
              "(coordination_mode = 'mirror' and coordinator_operation_id is not null and coordinator_operation_id > 0 and commit_intent is not null " <>
              "and jsonb_typeof(commit_intent) = 'object' and octet_length(commit_intent::text) <= 2000000)"
        )
      )
    end
  end
end
