defmodule Fornacast.Repo.Migrations.CreateGitHubIdentities do
  use Ecto.Migration

  def change do
    if turso?(), do: create_turso_table(), else: create_postgres_table()

    create(
      unique_index(:github_identities, [:github_user_id],
        where: "github_user_id is not null",
        name: :github_identities_user_id_index
      )
    )

    create(
      unique_index(:github_identities, [:kind],
        where: "kind = 'deleted'",
        name: :github_identities_deleted_singleton_index
      )
    )

    create(index(:github_identities, [:local_user_id]))
  end

  defp create_turso_table do
    create table(:github_identities) do
      add(:kind, :string,
        null: false,
        check: [name: "github_identities_kind_check", expr: "kind in ('user', 'deleted')"]
      )

      add(:github_user_id, :bigint,
        check: [
          name: "github_identities_user_id_required_check",
          expr: "kind != 'user' or github_user_id is not null"
        ]
      )

      add(:login, :string,
        null: false,
        check: [
          name: "github_identities_deleted_sentinel_check",
          expr:
            "kind != 'deleted' or (github_user_id is null and local_user_id is null and login = 'ghost')"
        ]
      )

      add(:avatar_url, :text)
      add(:profile_url, :text)
      add(:local_user_id, references(:users, on_delete: :nilify_all))
      add(:last_verified_at, :utc_datetime)
      add(:last_observed_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end
  end

  defp create_postgres_table do
    create table(:github_identities) do
      add(:kind, :string,
        null: false,
        check: [name: "github_identities_kind_check", expr: "kind in ('user', 'deleted')"]
      )

      add(:github_user_id, :bigint)
      add(:login, :string, null: false)
      add(:avatar_url, :text)
      add(:profile_url, :text)
      add(:local_user_id, references(:users, on_delete: :nilify_all))
      add(:last_verified_at, :utc_datetime)
      add(:last_observed_at, :utc_datetime)
      timestamps(type: :utc_datetime)
    end

    create(
      constraint(:github_identities, :github_identities_kind_check,
        check: "kind in ('user', 'deleted')"
      )
    )

    create(
      constraint(:github_identities, :github_identities_user_id_required_check,
        check: "kind != 'user' or github_user_id is not null"
      )
    )

    create(
      constraint(:github_identities, :github_identities_deleted_sentinel_check,
        check:
          "kind != 'deleted' or (github_user_id is null and local_user_id is null and login = 'ghost')"
      )
    )
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
