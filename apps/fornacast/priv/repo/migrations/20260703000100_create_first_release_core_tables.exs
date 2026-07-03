defmodule Fornacast.Repo.Migrations.CreateFirstReleaseCoreTables do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:username, :string, null: false)
      add(:email, :string, null: false)
      add(:password_hash, :string, null: false)

      add(:role, :string,
        null: false,
        default: "user",
        check: [name: "users_role_check", expr: "role in ('admin', 'user')"]
      )

      add(:state, :string,
        null: false,
        default: "active",
        check: [name: "users_state_check", expr: "state in ('active', 'disabled')"]
      )

      timestamps(type: :utc_datetime)
    end

    create_postgres_check(:users, :users_role_check, "role in ('admin', 'user')")
    create_postgres_check(:users, :users_state_check, "state in ('active', 'disabled')")

    create(unique_index(:users, [:username]))
    create(unique_index(:users, [:email]))

    create table(:ssh_keys) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:title, :string, null: false)
      add(:public_key, :text, null: false)
      add(:fingerprint_sha256, :string, null: false)
      add(:last_used_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:ssh_keys, [:user_id]))
    create(unique_index(:ssh_keys, [:fingerprint_sha256]))

    create table(:repositories) do
      add(:owner_user_id, references(:users, on_delete: :restrict), null: false)
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)

      add(:visibility, :string,
        null: false,
        default: "private",
        check: [
          name: "repositories_visibility_check",
          expr: "visibility in ('private', 'public')"
        ]
      )

      add(:storage_path, :string, null: false)
      add(:default_branch, :string, null: false, default: "main")
      add(:last_pushed_at, :utc_datetime)
      add(:deleted_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create_postgres_check(
      :repositories,
      :repositories_visibility_check,
      "visibility in ('private', 'public')"
    )

    create(unique_index(:repositories, [:owner_user_id, :slug], where: "deleted_at is null"))
    create(unique_index(:repositories, [:storage_path]))
    create(index(:repositories, [:owner_user_id]))

    create table(:repository_collaborators) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(:role, :string,
        null: false,
        check: [
          name: "repository_collaborators_role_check",
          expr: "role in ('read', 'write', 'admin')"
        ]
      )

      timestamps(type: :utc_datetime)
    end

    create_postgres_check(
      :repository_collaborators,
      :repository_collaborators_role_check,
      "role in ('read', 'write', 'admin')"
    )

    create(unique_index(:repository_collaborators, [:repository_id, :user_id]))
    create(index(:repository_collaborators, [:user_id]))

    create table(:audit_events) do
      add(:actor_user_id, references(:users, on_delete: :nilify_all))
      add(:action, :string, null: false)
      add(:target_type, :string, null: false)
      add(:target_id, :string)
      add(:metadata, :map, null: false, default: %{})
      add(:ip_address, :string)
      add(:user_agent, :text)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create(index(:audit_events, [:actor_user_id]))
    create(index(:audit_events, [:action]))
    create(index(:audit_events, [:target_type, :target_id]))
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
