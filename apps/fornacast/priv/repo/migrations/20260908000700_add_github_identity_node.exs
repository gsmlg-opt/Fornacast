defmodule Fornacast.Repo.Migrations.AddGithubIdentityNode do
  use Ecto.Migration

  def change do
    alter table(:github_identities) do
      add(:github_node_id, :text)
    end

    create(unique_index(:github_identities, [:github_node_id]))

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(:github_identities, :github_identities_node_check,
          check:
            "github_node_id IS NULL OR (kind = 'user' AND octet_length(github_node_id) BETWEEN 1 AND 512 AND github_node_id = btrim(github_node_id) AND github_node_id !~ '^[[:space:]]|[[:space:]]$')"
        )
      )
    end
  end
end
