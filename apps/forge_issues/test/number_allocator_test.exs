defmodule ForgeIssues.NumberAllocatorTest do
  use ExUnit.Case, async: false

  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label, NumberSequence}
  alias Fornacast.Repo

  import ForgeIssues.Fixtures

  setup do
    reset_database!()
    actor = user_fixture("issue-allocator-#{System.unique_integer([:positive])}")
    repository = repository_fixture(actor)
    %{actor: actor, repository: repository}
  end

  test "allocates a shared repository-local sequence for issue and pull request identities", %{
    actor: actor,
    repository: repository
  } do
    multi =
      Multi.new()
      |> ForgeIssues.insert_numbered_identity(
        :issue,
        repository,
        actor,
        :issue,
        %{title: "First issue", body: "body"}
      )
      |> ForgeIssues.insert_numbered_identity(
        :pull_issue,
        repository,
        actor,
        :pull_request,
        %{title: "First pull", body: nil}
      )

    assert {:ok, %{issue: issue, pull_issue: pull_issue}} = Repo.transaction(multi)
    assert {issue.number, issue.kind} == {1, :issue}
    assert {pull_issue.number, pull_issue.kind} == {2, :pull_request}
    assert issue.repository_id == repository.id
    assert issue.author_user_id == actor.id
  end

  test "rolls back an allocated number with a later multi failure", %{
    actor: actor,
    repository: repository
  } do
    failed =
      Multi.new()
      |> ForgeIssues.insert_numbered_identity(
        :issue,
        repository,
        actor,
        :issue,
        %{title: "Rolled back"}
      )
      |> Multi.run(:forced_failure, fn _repo, _changes -> {:error, :forced_failure} end)

    assert {:error, :forced_failure, :forced_failure, _changes} = Repo.transaction(failed)

    assert {:ok, %{issue: %{number: 1}}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(
               :issue,
               repository,
               actor,
               :issue,
               %{title: "Committed"}
             )
             |> Repo.transaction()
  end

  test "schema changesets preserve canonical identity contracts" do
    assert %NumberSequence{repository_id: nil, next_number: 1} = %NumberSequence{}

    assert %{valid?: false, errors: [title: {"must not contain NUL bytes", _}]} =
             Issue.create_changeset(
               %Issue{repository_id: 1, number: 1, kind: :issue, state: :open, author_user_id: 1},
               %{title: "bad" <> <<0>>}
             )

    closed =
      Issue.update_changeset(%Issue{title: "Open", state: :open}, %{
        state: :closed,
        state_reason: :completed
      })

    assert closed.valid?
    assert %DateTime{} = Ecto.Changeset.get_change(closed, :closed_at)

    reopened =
      Issue.update_changeset(%Issue{title: "Closed", state: :closed}, %{
        state: :open,
        state_reason: :reopened
      })

    assert reopened.valid?
    assert Ecto.Changeset.get_change(reopened, :closed_at) == nil

    refute Issue.update_changeset(
             %Issue{title: "Closed", state: :closed, state_reason: :completed},
             %{state: :open}
           ).valid?

    refute Comment.changeset(%Comment{}, %{issue_id: 1, author_user_id: 1, body: ""}).valid?

    assert %{changes: %{normalized_name: "bug", color: "a0b1c2"}} =
             Label.changeset(%Label{}, %{
               repository_id: 1,
               name: "Bug",
               normalized_name: " BUG ",
               color: "a0b1c2"
             })

    assert IssueLabel.changeset(%IssueLabel{}, %{issue_id: 1, label_id: 1}).valid?
    assert IssueAssignee.changeset(%IssueAssignee{}, %{issue_id: 1, user_id: 1}).valid?
  end

  test "allocates eight distinct numbers concurrently across identity kinds", %{
    actor: actor,
    repository: repository
  } do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          receive do
            :go ->
              Multi.new()
              |> ForgeIssues.insert_numbered_identity(
                {:issue, index},
                repository,
                actor,
                if(rem(index, 2) == 0, do: :pull_request, else: :issue),
                %{title: "Concurrent #{index}"}
              )
              |> Repo.transaction()
              |> case do
                {:ok, changes} -> {:ok, changes[{:issue, index}].number}
                error -> error
              end
          end
        end)
      end

    Enum.each(tasks, fn task -> Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid) end)

    Enum.each(tasks, fn task -> send(task.pid, :go) end)

    numbers =
      tasks
      |> Enum.map(&Task.await(&1, 15_000))
      |> Enum.map(fn {:ok, number} -> number end)
      |> Enum.sort()

    assert numbers == Enum.to_list(1..8)
  end
end
