defmodule ForgeIssues.GitHubImportTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label, NumberSequence}
  alias Fornacast.Repo

  import ForgeIssues.Fixtures

  @closed_at ~U[2025-01-03 00:00:00Z]
  @inserted_at ~U[2025-01-01 00:00:00Z]
  @updated_at ~U[2025-01-03 00:00:00Z]

  setup do
    reset_database!()
    writer = user_fixture("import-writer-#{System.unique_integer([:positive])}")
    repository = repository_fixture(writer)
    identity = github_identity_fixture("import-author")
    assignee = github_identity_fixture("import-assignee")
    %{writer: writer, repository: repository, identity: identity, assignee: assignee}
  end

  test "imports sparse issue numbers with exact source metadata", %{
    repository: repository,
    identity: identity
  } do
    multi =
      Multi.new()
      |> ForgeIssues.import_identity_multi(:issue_7, repository, identity, :issue, %{
        number: 7,
        title: "Early",
        body: "Body 7",
        state: :open,
        inserted_at: @inserted_at,
        updated_at: @updated_at
      })
      |> ForgeIssues.import_identity_multi(:issue_41, repository, identity, :issue, %{
        number: 41,
        title: "Imported",
        body: "Body",
        state: :closed,
        state_reason: :completed,
        closed_at: @closed_at,
        inserted_at: @inserted_at,
        updated_at: @updated_at
      })

    assert {:ok, %{issue_7: issue_7, issue_41: issue_41}} = ForgeIssues.transaction(multi)

    assert issue_7.number == 7
    assert issue_7.author_github_identity_id == identity.id
    assert is_nil(issue_7.author_user_id)

    assert issue_41.number == 41
    assert issue_41.state == :closed
    assert issue_41.state_reason == :completed
    assert issue_41.closed_at == @closed_at
    assert issue_41.inserted_at == @inserted_at
    assert issue_41.updated_at == @updated_at

    refute Repo.exists?(
             from(sequence in NumberSequence, where: sequence.repository_id == ^repository.id)
           )
  end

  test "imports comments, labels, and github assignees", %{
    repository: repository,
    identity: identity,
    assignee: assignee
  } do
    comment_attrs = %{
      body: "Imported comment",
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }

    assert {:ok, %{issue: issue, label: label, comment: comment, assignment: assignment}} =
             Multi.new()
             |> ForgeIssues.import_identity_multi(:issue, repository, identity, :issue, %{
               number: 7,
               title: "Labeled",
               body: nil,
               state: :open,
               inserted_at: @inserted_at,
               updated_at: @updated_at
             })
             |> ForgeIssues.import_label_multi(:label, repository, %{
               name: "bug",
               color: "d73a4a",
               description: "Something isn't working"
             })
             |> Multi.merge(fn %{issue: issue, label: label} ->
               Multi.new()
               |> ForgeIssues.import_issue_label_multi(:issue_label, issue, label)
             end)
             |> Multi.merge(fn %{issue: issue} ->
               Multi.new()
               |> ForgeIssues.import_comment_multi(:comment, issue, identity, comment_attrs)
               |> ForgeIssues.import_assignee_multi(:assignment, issue, assignee)
             end)
             |> ForgeIssues.transaction()

    assert %Label{name: "bug"} = label
    assert Repo.get_by!(IssueLabel, issue_id: issue.id, label_id: label.id)
    assert %Comment{author_github_identity_id: author_id, body: "Imported comment"} = comment
    assert author_id == identity.id
    assert %IssueAssignee{github_identity_id: assignee_id, user_id: nil} = assignment
    assert assignee_id == assignee.id
  end

  test "returns label normalization conflict explicitly", %{repository: repository} do
    assert {:ok, %{label: _label}} =
             Multi.new()
             |> ForgeIssues.import_label_multi(:label, repository, %{
               name: "Bug",
               color: "aabbcc",
               description: "First"
             })
             |> ForgeIssues.transaction()

    assert {:error, :second, :label_normalization_conflict, _} =
             Multi.new()
             |> ForgeIssues.import_label_multi(:second, repository, %{
               name: "bug",
               color: "ccddee",
               description: "Different"
             })
             |> ForgeIssues.transaction()
  end

  test "rejects invalid import payloads" do
    assert %{valid?: false} =
             Issue.import_changeset(
               %Issue{repository_id: 1, author_github_identity_id: 1},
               %{
                 number: 1,
                 kind: :issue,
                 title: "bad" <> <<0>>,
                 state: :open,
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )

    assert %{valid?: false} =
             Issue.import_changeset(
               %Issue{repository_id: 1, author_github_identity_id: 1},
               %{
                 number: 1,
                 kind: :issue,
                 title: String.duplicate("x", 300),
                 state: :open,
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )

    assert %{valid?: false} =
             Issue.import_changeset(
               %Issue{repository_id: 1, author_github_identity_id: 1},
               %{
                 number: 1,
                 kind: :issue,
                 title: "Closed",
                 state: :closed,
                 state_reason: :reopened,
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )
  end

  test "replay of the same issue number fails inside a later transaction", %{
    repository: repository,
    identity: identity
  } do
    attrs = %{
      number: 7,
      title: "Replay",
      body: nil,
      state: :open,
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }

    assert {:ok, _} =
             Multi.new()
             |> ForgeIssues.import_identity_multi(:issue, repository, identity, :issue, attrs)
             |> ForgeIssues.transaction()

    assert {:error, :issue, %Ecto.Changeset{}, _} =
             Multi.new()
             |> ForgeIssues.import_identity_multi(:issue, repository, identity, :issue, attrs)
             |> ForgeIssues.transaction()
  end

  test "finalize sets the sequence to highest imported number plus one and ordinary creation continues",
       %{
         repository: repository,
         identity: identity,
         writer: writer
       } do
    assert {:ok, _} =
             Multi.new()
             |> ForgeIssues.import_identity_multi(:issue_7, repository, identity, :issue, %{
               number: 7,
               title: "Seven",
               body: nil,
               state: :open,
               inserted_at: @inserted_at,
               updated_at: @updated_at
             })
             |> ForgeIssues.import_identity_multi(:issue_41, repository, identity, :issue, %{
               number: 41,
               title: "Forty-one",
               body: nil,
               state: :open,
               inserted_at: @inserted_at,
               updated_at: @updated_at
             })
             |> ForgeIssues.finalize_import_sequence_multi(:sequence, repository)
             |> ForgeIssues.transaction()

    assert %NumberSequence{next_number: 42} = Repo.get!(NumberSequence, repository.id)

    assert {:ok, %{issue: issue}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(
               :issue,
               repository,
               writer,
               :issue,
               %{title: "Forty-two", body: nil}
             )
             |> ForgeIssues.transaction()

    assert issue.number == 42
  end

  defp github_identity_fixture(login) do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(
               %{
                 github_user_id: 9_300_000_000 + suffix,
                 login: "#{login}-#{suffix}",
                 avatar_url: nil,
                 profile_url: nil
               },
               DateTime.utc_now(:second)
             )

    identity
  end
end
