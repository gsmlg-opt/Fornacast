defmodule Fornacast.Repo.Migrations.AddGitHubCredentialVerificationVersion do
  use Ecto.Migration

  def up do
    if turso?() do
      alter table(:github_credentials) do
        add(:verification_version, :integer,
          null: false,
          default: 1,
          check: [
            name: "github_credentials_verification_version_check",
            expr: "verification_version > 0"
          ]
        )
      end
    else
      alter table(:github_credentials) do
        add(:verification_version, :integer, null: false, default: 1)
      end

      create(
        constraint(:github_credentials, :github_credentials_verification_version_check,
          check: "verification_version > 0"
        )
      )
    end
  end

  def down do
    if turso?() do
      # TODO(upstream): gsmlg-dev/concord#81
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop(constraint(:github_credentials, :github_credentials_verification_version_check))

    alter table(:github_credentials) do
      remove(:verification_version)
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
