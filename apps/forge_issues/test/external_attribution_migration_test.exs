defmodule ForgeIssues.ExternalAttributionMigrationTest do
  use ExUnit.Case, async: false

  alias ForgeIssues.{Comment, Issue, IssueAssignee}
  alias ForgePulls.PullRequest
  alias Fornacast.Repo

  import ForgeIssues.Fixtures

  setup do
    reset_database!()
    writer = user_fixture("attr-writer-#{System.unique_integer([:positive])}")
    repository = repository_fixture(writer)
    identity = github_identity_fixture()
    %{writer: writer, repository: repository, identity: identity}
  end

  test "old local-author rows survive and GitHub-author rows insert", %{
    writer: writer,
    repository: repository,
    identity: identity
  } do
    now = DateTime.utc_now(:second)

    local_issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 1,
        kind: :issue,
        title: "Local",
        body: "body",
        state: :open,
        author_user_id: writer.id,
        inserted_at: now,
        updated_at: now
      })

    assert %Issue{author_user_id: author_id, author_github_identity_id: nil} =
             Repo.get!(Issue, local_issue.id)

    assert author_id == writer.id

    github_issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 2,
        kind: :issue,
        title: "Imported",
        body: "imported",
        state: :open,
        author_user_id: nil,
        author_github_identity_id: identity.id,
        inserted_at: now,
        updated_at: now
      })

    assert %Issue{author_user_id: nil, author_github_identity_id: github_id} =
             Repo.get!(Issue, github_issue.id)

    assert github_id == identity.id

    assert_insertable(:issue_comments, %{
      issue_id: local_issue.id,
      author_user_id: nil,
      author_github_identity_id: identity.id,
      body: "imported comment",
      inserted_at: now,
      updated_at: now
    })

    assert_insertable(:issue_assignees, %{
      issue_id: local_issue.id,
      user_id: nil,
      github_identity_id: identity.id,
      inserted_at: now,
      updated_at: now
    })
  end

  test "authored rows require exactly one local or GitHub identity", %{
    writer: writer,
    repository: repository,
    identity: identity
  } do
    now = DateTime.utc_now(:second)
    base = issue_base(repository.id, 10, now)

    assert_constraint(
      :issues,
      Map.merge(base, %{author_user_id: nil, author_github_identity_id: nil}),
      "issues_author_identity_check"
    )

    assert_constraint(
      :issues,
      Map.merge(base, %{
        author_user_id: writer.id,
        author_github_identity_id: identity.id,
        number: 11
      }),
      "issues_author_identity_check"
    )

    assert_insertable(
      :issues,
      Map.merge(base, %{
        author_user_id: nil,
        author_github_identity_id: identity.id,
        number: 12
      })
    )

    issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 13,
        kind: :issue,
        title: "Comment host",
        body: nil,
        state: :open,
        author_user_id: writer.id,
        inserted_at: now,
        updated_at: now
      })

    comment_base = %{
      issue_id: issue.id,
      body: "hi",
      inserted_at: now,
      updated_at: now
    }

    assert_constraint(
      :issue_comments,
      Map.merge(comment_base, %{author_user_id: nil, author_github_identity_id: nil}),
      "issue_comments_author_identity_check"
    )

    assert_constraint(
      :issue_comments,
      Map.merge(comment_base, %{
        author_user_id: writer.id,
        author_github_identity_id: identity.id
      }),
      "issue_comments_author_identity_check"
    )
  end

  test "assignees require exactly one local or GitHub identity", %{
    writer: writer,
    repository: repository,
    identity: identity
  } do
    now = DateTime.utc_now(:second)

    issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 20,
        kind: :issue,
        title: "Assignee host",
        body: nil,
        state: :open,
        author_user_id: writer.id,
        inserted_at: now,
        updated_at: now
      })

    base = %{issue_id: issue.id, inserted_at: now, updated_at: now}

    assert_constraint(
      :issue_assignees,
      Map.merge(base, %{user_id: nil, github_identity_id: nil}),
      "issue_assignees_identity_check"
    )

    assert_constraint(
      :issue_assignees,
      Map.merge(base, %{user_id: writer.id, github_identity_id: identity.id}),
      "issue_assignees_identity_check"
    )

    assert_insertable(
      :issue_assignees,
      Map.merge(base, %{user_id: nil, github_identity_id: identity.id})
    )
  end

  test "a merger has at most one identity", %{
    writer: writer,
    repository: repository,
    identity: identity
  } do
    now = DateTime.utc_now(:second)

    issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 30,
        kind: :pull_request,
        title: "PR",
        body: nil,
        state: :closed,
        author_user_id: writer.id,
        closed_at: now,
        inserted_at: now,
        updated_at: now
      })

    sha = String.duplicate("a", 40)

    base = %{
      issue_id: issue.id,
      repository_id: repository.id,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: sha,
      base_sha: String.duplicate("b", 40),
      inserted_at: now,
      updated_at: now
    }

    assert_constraint(
      :pull_requests,
      Map.merge(base, %{
        merged_by_user_id: writer.id,
        merged_by_github_identity_id: identity.id,
        merged_at: now,
        merge_commit_sha: String.duplicate("c", 40)
      }),
      "pull_requests_merged_by_identity_check"
    )

    assert_insertable(
      :pull_requests,
      Map.merge(base, %{
        merged_by_user_id: nil,
        merged_by_github_identity_id: identity.id,
        merged_at: now,
        merge_commit_sha: String.duplicate("c", 40)
      })
    )

    other_issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 31,
        kind: :pull_request,
        title: "PR unmerged",
        body: nil,
        state: :open,
        author_user_id: writer.id,
        inserted_at: now,
        updated_at: now
      })

    assert_insertable(:pull_requests, %{
      issue_id: other_issue.id,
      repository_id: repository.id,
      head_ref: "refs/heads/other",
      base_ref: "refs/heads/main",
      head_sha: sha,
      base_sha: String.duplicate("b", 40),
      merged_by_user_id: nil,
      merged_by_github_identity_id: nil,
      inserted_at: now,
      updated_at: now
    })
  end

  test "attribution columns and named checks exist" do
    assert column_exists?("issues", "author_github_identity_id")
    assert column_exists?("issue_comments", "author_github_identity_id")
    assert column_exists?("issue_assignees", "github_identity_id")
    assert column_exists?("pull_requests", "merged_by_github_identity_id")

    assert constraint_exists?("issues_author_identity_check")
    assert constraint_exists?("issue_comments_author_identity_check")
    assert constraint_exists?("issue_assignees_identity_check")
    assert constraint_exists?("pull_requests_merged_by_identity_check")

    assert schema_has_field?(Issue, :author_github_identity_id)
    assert schema_has_field?(Comment, :author_github_identity_id)
    assert schema_has_field?(IssueAssignee, :github_identity_id)
    assert schema_has_field?(PullRequest, :merged_by_github_identity_id)
  end

  defp issue_base(repository_id, number, now) do
    %{
      repository_id: repository_id,
      number: number,
      kind: "issue",
      title: "t",
      body: nil,
      state: "open",
      state_reason: nil,
      closed_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp github_identity_fixture do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(
               %{
                 github_user_id: 9_100_000_000 + suffix,
                 login: "attr-gh-#{suffix}",
                 avatar_url: nil,
                 profile_url: nil
               },
               DateTime.utc_now(:second)
             )

    identity
  end

  defp assert_insertable(table, attrs) when is_atom(table) and is_map(attrs) do
    {columns, values} = Enum.unzip(Enum.map(attrs, fn {k, v} -> {to_string(k), v} end))
    placeholders = Enum.map_join(1..length(values), ", ", &"$#{&1}")

    assert {:ok, _} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into #{table} (#{Enum.join(columns, ", ")}) values (#{placeholders})",
               encode_values(values)
             )
  end

  defp assert_constraint(table, attrs, constraint_name)
       when is_atom(table) and is_map(attrs) and is_binary(constraint_name) do
    {columns, values} = Enum.unzip(Enum.map(attrs, fn {k, v} -> {to_string(k), v} end))
    placeholders = Enum.map_join(1..length(values), ", ", &"$#{&1}")

    assert {:error, %{postgres: %{constraint: ^constraint_name}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into #{table} (#{Enum.join(columns, ", ")}) values (#{placeholders})",
               encode_values(values)
             )
  end

  defp encode_values(values) do
    Enum.map(values, fn
      %DateTime{} = dt -> DateTime.to_naive(dt)
      other -> other
    end)
  end

  defp column_exists?(table, column) do
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        select exists (
          select 1 from information_schema.columns
          where table_name = $1 and column_name = $2
        )
        """,
        [table, column]
      )

    exists?
  end

  defp constraint_exists?(name) do
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select exists (select 1 from pg_constraint where conname = $1)",
        [name]
      )

    exists?
  end

  defp schema_has_field?(module, field) do
    field in module.__schema__(:fields)
  end
end
