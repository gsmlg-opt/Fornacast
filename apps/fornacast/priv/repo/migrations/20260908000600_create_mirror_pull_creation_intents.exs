defmodule Fornacast.Repo.Migrations.CreateMirrorPullCreationIntents do
  use Ecto.Migration

  def change do
    create table(:mirror_pull_creation_intents) do
      add(:operation_id, references(:mirror_operations, on_delete: :restrict), null: false)

      add(:repository_mirror_id, references(:repository_mirrors, on_delete: :restrict),
        null: false
      )

      add(:repository_id, references(:repositories, on_delete: :restrict), null: false)
      add(:pull_id, references(:pull_requests, on_delete: :restrict), null: false)
      add(:issue_id, references(:issues, on_delete: :restrict), null: false)
      add(:local_version, :bigint, null: false)
      add(:creation_uuid, :uuid, null: false)
      add(:payload, :map, null: false)
      add(:payload_fingerprint, :string, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:mirror_pull_creation_intents, [:operation_id]))
    create(unique_index(:mirror_pull_creation_intents, [:repository_mirror_id, :pull_id]))
    create(unique_index(:mirror_pull_creation_intents, [:creation_uuid]))

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(:mirror_pull_creation_intents, :mirror_pull_creation_intents_payload_check,
          check: "jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 2000000"
        )
      )

      create(
        constraint(:mirror_pull_creation_intents, :mirror_pull_creation_intents_version_check,
          check: "local_version > 0"
        )
      )
    end
  end
end
