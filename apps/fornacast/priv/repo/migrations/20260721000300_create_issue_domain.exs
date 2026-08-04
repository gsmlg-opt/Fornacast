defmodule Fornacast.Repo.Migrations.CreateIssueDomain do
  use Ecto.Migration

  def change do
    create table(:repository_number_sequences, primary_key: false) do
      add(:repository_id, references(:repositories, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:next_number, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime)
    end

    create_postgres_check(
      :repository_number_sequences,
      :number_sequence_positive,
      "next_number > 0"
    )

    create table(:issues) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:number, :bigint, null: false)
      add(:kind, :string, null: false)
      add(:title, :string, null: false)
      add(:body, :text)
      add(:state, :string, null: false, default: "open")
      add(:state_reason, :string)
      add(:author_user_id, references(:users, on_delete: :restrict), null: false)
      add(:closed_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create_postgres_check(:issues, :issues_kind_check, "kind in ('issue', 'pull_request')")
    create_postgres_check(:issues, :issues_state_check, "state in ('open', 'closed')")

    create_postgres_check(
      :issues,
      :issues_state_reason_check,
      "state_reason is null or state_reason in ('completed', 'not_planned', 'reopened')"
    )

    create(unique_index(:issues, [:repository_id, :number]))
    create(index(:issues, [:repository_id, :state, :updated_at, :id]))
    create(index(:issues, [:author_user_id]))

    create table(:issue_comments) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:author_user_id, references(:users, on_delete: :restrict), null: false)
      add(:body, :text, null: false)
      timestamps(type: :utc_datetime)
    end

    create(index(:issue_comments, [:issue_id, :inserted_at, :id]))
    create(index(:issue_comments, [:author_user_id]))

    create table(:repository_labels) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:normalized_name, :string, null: false)
      add(:color, :string, null: false)
      add(:description, :text)
      add(:default, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:repository_labels, [:repository_id, :normalized_name]))
    create(index(:repository_labels, [:repository_id, :name]))

    create table(:issue_labels) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:label_id, references(:repository_labels, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:issue_labels, [:issue_id, :label_id]))
    create(index(:issue_labels, [:label_id]))

    create table(:issue_assignees) do
      add(:issue_id, references(:issues, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:issue_assignees, [:issue_id, :user_id]))
    create(index(:issue_assignees, [:user_id]))
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
