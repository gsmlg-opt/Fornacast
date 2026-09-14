defmodule Fornacast.Repo.Migrations.CreateReleaseDomain do
  use Ecto.Migration

  @author_check "(author_user_id is not null) <> (author_github_identity_id is not null)"
  @publication_check "(draft = true and published_at is null) or (draft = false and published_at is not null)"

  def change do
    create table(:releases) do
      add(:repository_id, references(:repositories, on_delete: :delete_all), null: false)
      add(:tag_name, :string, null: false)
      add(:name, :string)
      add(:body, :text)
      add(:draft, :boolean, null: false, default: false)
      add(:prerelease, :boolean, null: false, default: false)
      add(:target_commitish, :string, null: false)

      add(:published_at, :utc_datetime,
        check: [name: "releases_publication_state_check", expr: @publication_check]
      )

      add(:deleted_at, :utc_datetime)

      add(:author_user_id, references(:users, on_delete: :restrict),
        check: [name: "releases_author_identity_check", expr: @author_check]
      )

      add(:author_github_identity_id, references(:github_identities, on_delete: :restrict))

      timestamps(type: :utc_datetime)
    end

    create_postgres_check(:releases, :releases_author_identity_check, @author_check)
    create_postgres_check(:releases, :releases_publication_state_check, @publication_check)

    create(
      unique_index(:releases, [:repository_id, :tag_name],
        where: "deleted_at is null",
        name: :releases_active_repository_tag_index
      )
    )

    create(index(:releases, [:repository_id, :published_at, :id]))
    create(index(:releases, [:author_user_id]))
    create(index(:releases, [:author_github_identity_id]))
  end

  defp create_postgres_check(table, name, expression) do
    unless turso?() do
      create(constraint(table, name, check: expression))
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
