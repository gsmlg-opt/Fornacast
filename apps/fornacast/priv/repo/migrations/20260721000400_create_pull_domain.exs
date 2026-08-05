defmodule Fornacast.Repo.Migrations.CreatePullDomain do
  use Ecto.Migration

  def change do
    create table(:pull_requests) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:head_ref, :string, null: false)
      add(:base_ref, :string, null: false)
      add(:head_sha, :string, null: false)
      add(:base_sha, :string, null: false)
      add(:mergeable, :boolean)
      add(:mergeable_state, :string)
      add(:merged_at, :utc_datetime)
      add(:merged_by_user_id, references(:users, on_delete: :nilify_all))
      add(:merge_commit_sha, :string)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:pull_requests, [:issue_id]))
    create(index(:pull_requests, [:repository_id]))
    create(index(:pull_requests, [:repository_id, :base_ref]))

    create table(:pull_merge_operations) do
      add(:pull_request_id, references(:pull_requests, on_delete: :delete_all), null: false)
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:actor_user_id, references(:users, on_delete: :nilify_all))
      add(:request_id, :string, null: false)
      add(:base_ref, :string, null: false)
      add(:head_ref, :string, null: false)
      add(:expected_base_oid, :string, null: false)
      add(:expected_head_oid, :string, null: false)
      add(:merge_oid, :string)

      add(:state, :string,
        null: false,
        check: [
          name: "pull_merge_operations_state_check",
          expr: "state in ('prepared', 'merge_written', 'ref_advanced', 'completed', 'failed')"
        ]
      )

      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:failure_reason, :text)
      add(:lock_version, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime)
    end

    create_postgres_check(
      :pull_merge_operations,
      :pull_merge_operations_state_check,
      "state in ('prepared', 'merge_written', 'ref_advanced', 'completed', 'failed')"
    )

    create(index(:pull_merge_operations, [:repository_id, :state]))
    create(index(:pull_merge_operations, [:pull_request_id, :state]))
    create(index(:pull_merge_operations, [:lease_expires_at]))
  end

  defp create_postgres_check(table, name, expr) do
    unless turso?() do
      create(constraint(table, name, check: expr))
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
