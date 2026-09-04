defmodule Fornacast.Repo.Migrations.AddGitHubInstallationIntents do
  use Ecto.Migration

  def change do
    create table(:github_installation_intents) do
      add(
        :organization_mirror_id,
        references(:organization_mirrors, on_delete: :delete_all),
        null: false
      )

      add(:organization_id, references(:users, on_delete: :restrict), null: false)
      add(:actor_user_id, references(:users, on_delete: :restrict), null: false)
      add(:state_digest, :binary, null: false)
      add(:github_installation_id, :bigint)
      add(:setup_action, :string)
      add(:state, :string, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:callback_received_at, :utc_datetime)
      add(:confirmed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:github_installation_intents, [:state_digest]))

    create(
      unique_index(:github_installation_intents, [:organization_mirror_id],
        where: "state in ('pending', 'callback_received')",
        name: :github_installation_intents_open_mirror_index
      )
    )

    create(
      index(:github_installation_intents, [:github_installation_id, :state],
        name: :github_installation_intents_installation_state_index
      )
    )

    create(
      constraint(:github_installation_intents, :github_installation_intents_digest_check,
        check: "octet_length(state_digest) = 32"
      )
    )

    create(
      constraint(:github_installation_intents, :github_installation_intents_installation_check,
        check: "github_installation_id is null or github_installation_id > 0"
      )
    )

    create(
      constraint(:github_installation_intents, :github_installation_intents_setup_action_check,
        check: "setup_action is null or setup_action in ('install', 'update')"
      )
    )

    create(
      constraint(:github_installation_intents, :github_installation_intents_state_check,
        check: "state in ('pending', 'callback_received', 'completed', 'cancelled', 'expired')"
      )
    )

    create(
      constraint(:github_installation_intents, :github_installation_intents_lifecycle_check,
        check: """
        (state = 'pending' and github_installation_id is null and setup_action is null and callback_received_at is null and confirmed_at is null)
        or (state = 'callback_received' and github_installation_id is not null and setup_action is not null and callback_received_at is not null and confirmed_at is null)
        or (state = 'completed' and github_installation_id is not null and setup_action is not null and callback_received_at is not null and confirmed_at is not null)
        or (state in ('cancelled', 'expired') and confirmed_at is null)
        """
      )
    )
  end
end
