defmodule Fornacast.Repo.Migrations.AddPatGitMirrorAuthority do
  use Ecto.Migration

  def change do
    alter table(:organization_mirrors) do
      add(:credential_source, :string, default: "github_app", null: false)
      add(:pat_configuration_id, :bigint)
      add(:pat_configuration_version, :integer)
      add(:credential_owner_user_id, :bigint)
      add(:github_identity_id, :bigint)
      add(:github_credential_id, :bigint)
      add(:github_credential_version, :integer)
    end

    alter table(:repository_mirrors) do
      add(:pat_repository_generation, :integer)
    end

    create(
      constraint(:repository_mirrors, :repository_mirrors_pat_generation,
        check: "pat_repository_generation IS NULL OR pat_repository_generation > 0"
      )
    )

    create(
      constraint(:organization_mirrors, :organization_mirrors_pat_authority,
        check: """
        (credential_source = 'github_app' AND pat_configuration_id IS NULL
          AND pat_configuration_version IS NULL AND credential_owner_user_id IS NULL
          AND github_identity_id IS NULL AND github_credential_id IS NULL
          AND github_credential_version IS NULL)
        OR (credential_source = 'pat' AND github_installation_id IS NULL
          AND pat_configuration_id IS NOT NULL AND pat_configuration_version IS NOT NULL
          AND credential_owner_user_id IS NOT NULL AND github_identity_id IS NOT NULL
          AND github_credential_id IS NOT NULL AND github_credential_version IS NOT NULL
          AND github_account_id IS NOT NULL
          AND pat_configuration_id > 0 AND pat_configuration_version > 0
          AND credential_owner_user_id > 0 AND github_identity_id > 0
          AND github_credential_id > 0 AND github_credential_version > 0
          AND github_account_id > 0)
        """
      )
    )
  end
end
