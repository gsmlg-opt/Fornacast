defmodule Fornacast.Repo.Migrations.AddGitHubExternalAttribution do
  use Ecto.Migration

  @disable_ddl_transaction true

  @issues_author_check "(author_user_id is not null) <> (author_github_identity_id is not null)"
  @comments_author_check "(author_user_id is not null) <> (author_github_identity_id is not null)"
  @assignees_identity_check "(user_id is not null) <> (github_identity_id is not null)"
  @pulls_merger_check "not (merged_by_user_id is not null and merged_by_github_identity_id is not null)"

  def up do
    if turso?() do
      rebuild_turso_tables()
    else
      alter_postgres_tables()
    end
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop_if_exists(
      index(:issue_assignees, [:issue_id, :github_identity_id],
        name: :issue_assignees_issue_id_github_identity_id_index
      )
    )

    drop_if_exists(index(:pull_requests, [:merged_by_github_identity_id]))
    drop_if_exists(index(:issue_assignees, [:github_identity_id]))
    drop_if_exists(index(:issue_comments, [:author_github_identity_id]))
    drop_if_exists(index(:issues, [:author_github_identity_id]))

    drop(constraint(:pull_requests, :pull_requests_merged_by_identity_check))
    drop(constraint(:issue_assignees, :issue_assignees_identity_check))
    drop(constraint(:issue_comments, :issue_comments_author_identity_check))
    drop(constraint(:issues, :issues_author_identity_check))

    alter table(:pull_requests) do
      remove(:merged_by_github_identity_id)
    end

    alter table(:issue_assignees) do
      remove(:github_identity_id)
    end

    execute("ALTER TABLE issue_assignees ALTER COLUMN user_id SET NOT NULL")

    alter table(:issue_comments) do
      remove(:author_github_identity_id)
    end

    execute("ALTER TABLE issue_comments ALTER COLUMN author_user_id SET NOT NULL")

    alter table(:issues) do
      remove(:author_github_identity_id)
    end

    execute("ALTER TABLE issues ALTER COLUMN author_user_id SET NOT NULL")
  end

  defp alter_postgres_tables do
    alter table(:issues) do
      add(
        :author_github_identity_id,
        references(:github_identities, on_delete: :restrict),
        null: true
      )
    end

    execute("ALTER TABLE issues ALTER COLUMN author_user_id DROP NOT NULL")

    create(
      constraint(:issues, :issues_author_identity_check, check: @issues_author_check)
    )

    create(index(:issues, [:author_github_identity_id]))

    alter table(:issue_comments) do
      add(
        :author_github_identity_id,
        references(:github_identities, on_delete: :restrict),
        null: true
      )
    end

    execute("ALTER TABLE issue_comments ALTER COLUMN author_user_id DROP NOT NULL")

    create(
      constraint(:issue_comments, :issue_comments_author_identity_check,
        check: @comments_author_check
      )
    )

    create(index(:issue_comments, [:author_github_identity_id]))

    alter table(:issue_assignees) do
      add(
        :github_identity_id,
        references(:github_identities, on_delete: :restrict),
        null: true
      )
    end

    execute("ALTER TABLE issue_assignees ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:issue_assignees, :issue_assignees_identity_check,
        check: @assignees_identity_check
      )
    )

    create(index(:issue_assignees, [:github_identity_id]))

    create(
      unique_index(:issue_assignees, [:issue_id, :github_identity_id],
        name: :issue_assignees_issue_id_github_identity_id_index
      )
    )

    alter table(:pull_requests) do
      add(
        :merged_by_github_identity_id,
        references(:github_identities, on_delete: :restrict),
        null: true
      )
    end

    create(
      constraint(:pull_requests, :pull_requests_merged_by_identity_check,
        check: @pulls_merger_check
      )
    )

    create(index(:pull_requests, [:merged_by_github_identity_id]))
  end

  defp rebuild_turso_tables do
    migration_repo = repo()

    migration_repo.checkout(
      fn ->
        query!(migration_repo, "PRAGMA foreign_keys = OFF")

        try do
          Enum.each(turso_rebuild_statements(), &query!(migration_repo, &1))
        after
          query!(migration_repo, "PRAGMA foreign_keys = ON")
        end
      end,
      timeout: :infinity
    )
  end

  defp turso_rebuild_statements do
    [
      """
      CREATE TABLE issues_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        repository_id INTEGER NOT NULL
          CONSTRAINT issues_repository_id_fkey
          REFERENCES repositories (id) ON DELETE CASCADE,
        number BIGINT NOT NULL,
        kind TEXT NOT NULL CONSTRAINT issues_kind_check
          CHECK (kind IN ('issue', 'pull_request')),
        title TEXT NOT NULL,
        body TEXT,
        state TEXT DEFAULT 'open' NOT NULL CONSTRAINT issues_state_check
          CHECK (state IN ('open', 'closed')),
        state_reason TEXT CONSTRAINT issues_state_reason_check
          CHECK (state_reason IS NULL OR state_reason IN ('completed', 'not_planned', 'reopened')),
        author_user_id INTEGER
          CONSTRAINT issues_author_user_id_fkey
          REFERENCES users (id) ON DELETE RESTRICT,
        author_github_identity_id INTEGER
          CONSTRAINT issues_author_github_identity_id_fkey
          REFERENCES github_identities (id) ON DELETE RESTRICT
          CONSTRAINT issues_author_identity_check
          CHECK (#{@issues_author_check}),
        closed_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      INSERT INTO issues_new (
        id, repository_id, number, kind, title, body, state, state_reason,
        author_user_id, author_github_identity_id, closed_at, inserted_at, updated_at
      )
      SELECT
        id, repository_id, number, kind, title, body, state, state_reason,
        author_user_id, NULL, closed_at, inserted_at, updated_at
      FROM issues
      """,
      "DROP TABLE issues",
      "ALTER TABLE issues_new RENAME TO issues",
      "CREATE UNIQUE INDEX issues_repository_id_number_index ON issues (repository_id, number)",
      "CREATE INDEX issues_repository_id_state_updated_at_id_index ON issues (repository_id, state, updated_at, id)",
      "CREATE INDEX issues_author_user_id_index ON issues (author_user_id)",
      "CREATE INDEX issues_author_github_identity_id_index ON issues (author_github_identity_id)",
      """
      CREATE TABLE issue_comments_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        issue_id INTEGER NOT NULL
          CONSTRAINT issue_comments_issue_id_fkey
          REFERENCES issues (id) ON DELETE CASCADE,
        author_user_id INTEGER
          CONSTRAINT issue_comments_author_user_id_fkey
          REFERENCES users (id) ON DELETE RESTRICT,
        author_github_identity_id INTEGER
          CONSTRAINT issue_comments_author_github_identity_id_fkey
          REFERENCES github_identities (id) ON DELETE RESTRICT
          CONSTRAINT issue_comments_author_identity_check
          CHECK (#{@comments_author_check}),
        body TEXT NOT NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      INSERT INTO issue_comments_new (
        id, issue_id, author_user_id, author_github_identity_id, body, inserted_at, updated_at
      )
      SELECT id, issue_id, author_user_id, NULL, body, inserted_at, updated_at
      FROM issue_comments
      """,
      "DROP TABLE issue_comments",
      "ALTER TABLE issue_comments_new RENAME TO issue_comments",
      "CREATE INDEX issue_comments_issue_id_inserted_at_id_index ON issue_comments (issue_id, inserted_at, id)",
      "CREATE INDEX issue_comments_author_user_id_index ON issue_comments (author_user_id)",
      "CREATE INDEX issue_comments_author_github_identity_id_index ON issue_comments (author_github_identity_id)",
      """
      CREATE TABLE issue_assignees_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        issue_id INTEGER NOT NULL
          CONSTRAINT issue_assignees_issue_id_fkey
          REFERENCES issues (id) ON DELETE CASCADE,
        user_id INTEGER
          CONSTRAINT issue_assignees_user_id_fkey
          REFERENCES users (id) ON DELETE CASCADE,
        github_identity_id INTEGER
          CONSTRAINT issue_assignees_github_identity_id_fkey
          REFERENCES github_identities (id) ON DELETE RESTRICT
          CONSTRAINT issue_assignees_identity_check
          CHECK (#{@assignees_identity_check}),
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      INSERT INTO issue_assignees_new (
        id, issue_id, user_id, github_identity_id, inserted_at, updated_at
      )
      SELECT id, issue_id, user_id, NULL, inserted_at, updated_at
      FROM issue_assignees
      """,
      "DROP TABLE issue_assignees",
      "ALTER TABLE issue_assignees_new RENAME TO issue_assignees",
      "CREATE UNIQUE INDEX issue_assignees_issue_id_user_id_index ON issue_assignees (issue_id, user_id)",
      "CREATE INDEX issue_assignees_user_id_index ON issue_assignees (user_id)",
      "CREATE INDEX issue_assignees_github_identity_id_index ON issue_assignees (github_identity_id)",
      "CREATE UNIQUE INDEX issue_assignees_issue_id_github_identity_id_index ON issue_assignees (issue_id, github_identity_id)",
      """
      CREATE TABLE pull_requests_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        issue_id INTEGER NOT NULL
          CONSTRAINT pull_requests_issue_id_fkey
          REFERENCES issues (id) ON DELETE CASCADE,
        repository_id INTEGER NOT NULL
          CONSTRAINT pull_requests_repository_id_fkey
          REFERENCES repositories (id) ON DELETE CASCADE,
        head_ref TEXT NOT NULL,
        base_ref TEXT NOT NULL,
        head_sha TEXT NOT NULL,
        base_sha TEXT NOT NULL,
        mergeable BOOLEAN,
        mergeable_state TEXT,
        merged_at TEXT,
        merged_by_user_id INTEGER
          CONSTRAINT pull_requests_merged_by_user_id_fkey
          REFERENCES users (id) ON DELETE SET NULL,
        merged_by_github_identity_id INTEGER
          CONSTRAINT pull_requests_merged_by_github_identity_id_fkey
          REFERENCES github_identities (id) ON DELETE RESTRICT
          CONSTRAINT pull_requests_merged_by_identity_check
          CHECK (#{@pulls_merger_check}),
        merge_commit_sha TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      """
      INSERT INTO pull_requests_new (
        id, issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
        mergeable, mergeable_state, merged_at, merged_by_user_id,
        merged_by_github_identity_id, merge_commit_sha, inserted_at, updated_at
      )
      SELECT
        id, issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
        mergeable, mergeable_state, merged_at, merged_by_user_id,
        NULL, merge_commit_sha, inserted_at, updated_at
      FROM pull_requests
      """,
      "DROP TABLE pull_requests",
      "ALTER TABLE pull_requests_new RENAME TO pull_requests",
      "CREATE UNIQUE INDEX pull_requests_issue_id_index ON pull_requests (issue_id)",
      "CREATE INDEX pull_requests_repository_id_index ON pull_requests (repository_id)",
      "CREATE INDEX pull_requests_repository_id_base_ref_index ON pull_requests (repository_id, base_ref)",
      "CREATE INDEX pull_requests_merged_by_github_identity_id_index ON pull_requests (merged_by_github_identity_id)"
    ]
  end

  defp query!(migration_repo, sql),
    do: Ecto.Adapters.SQL.query!(migration_repo, sql, [], log: false)

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
