defmodule Fornacast.Repo.Migrations.CreateGitHubAppInstallations do
  use Ecto.Migration

  def change do
    create table(:github_app_installations) do
      add(:github_installation_id, :bigint, null: false)
      add(:github_account_id, :bigint, null: false)
      add(:github_account_login, :string, null: false)
      add(:account_type, :string, null: false)
      add(:repository_selection, :string, null: false)
      add(:permissions, :map, null: false, default: %{})
      add(:state, :string, null: false)
      add(:last_verified_at, :utc_datetime, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:github_app_installations, [:github_installation_id]))
    create(index(:github_app_installations, [:github_account_id, :state]))

    unless turso?() do
      create(
        constraint(:github_app_installations, :github_app_installations_installation_id_check,
          check: "github_installation_id > 0"
        )
      )

      create(
        constraint(:github_app_installations, :github_app_installations_account_id_check,
          check: "github_account_id > 0"
        )
      )

      create(
        constraint(:github_app_installations, :github_app_installations_account_login_check,
          check:
            "octet_length(github_account_login) between 1 and 255 and github_account_login = btrim(github_account_login)"
        )
      )

      create(
        constraint(:github_app_installations, :github_app_installations_account_type_check,
          check: "account_type in ('organization', 'user', 'enterprise')"
        )
      )

      create(
        constraint(
          :github_app_installations,
          :github_app_installations_repository_selection_check,
          check: "repository_selection in ('all', 'selected')"
        )
      )

      create(
        constraint(:github_app_installations, :github_app_installations_permissions_check,
          check:
            "jsonb_typeof(permissions) = 'object' and permissions <> '{}'::jsonb and pg_column_size(permissions) <= 65536"
        )
      )

      create(
        constraint(:github_app_installations, :github_app_installations_state_check,
          check: "state in ('active', 'suspended', 'revoked')"
        )
      )
    end
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
