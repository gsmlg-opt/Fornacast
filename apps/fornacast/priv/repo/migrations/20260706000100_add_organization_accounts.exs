defmodule Fornacast.Repo.Migrations.AddOrganizationAccounts do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:kind, :string, null: false, default: "user")
      add(:display_name, :string)
      add(:description, :text)
    end

    create_postgres_check(:users, :users_kind_check, "kind in ('user', 'organization')")

    create table(:organization_members) do
      add(:organization_id, references(:users, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(:role, :string,
        null: false,
        check: [
          name: "organization_members_role_check",
          expr: "role in ('owner', 'member')"
        ]
      )

      timestamps(type: :utc_datetime)
    end

    create_postgres_check(
      :organization_members,
      :organization_members_role_check,
      "role in ('owner', 'member')"
    )

    create(unique_index(:organization_members, [:organization_id, :user_id]))
    create(index(:organization_members, [:user_id]))
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
