defmodule Fornacast.Repo.Migrations.RequireCoordinatorIdentityForMergeIntents do
  use Ecto.Migration

  def up do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(constraint(:pull_merge_operations, :pull_merge_operations_coordination_check))

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

  # Both the corrected original migration and this upgrade require the same
  # invariant. Rolling back this upgrade must not reintroduce the NULL loophole.
  def down, do: :ok
end
