defmodule Fornacast.Repo.Migrations.DeferPullHeadRepositoryConstraint do
  use Ecto.Migration

  def up do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      # PostgreSQL orders FK triggers by name. Check head identity after all
      # repository cascades, regardless of the generated trigger names.
      execute(
        "ALTER TABLE pull_requests ALTER CONSTRAINT pull_requests_head_repository_id_fkey " <>
          "DEFERRABLE INITIALLY DEFERRED"
      )
    end
  end

  def down do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute(
        "ALTER TABLE pull_requests ALTER CONSTRAINT pull_requests_head_repository_id_fkey " <>
          "NOT DEFERRABLE INITIALLY IMMEDIATE"
      )
    end
  end
end
