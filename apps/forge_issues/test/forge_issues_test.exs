defmodule ForgeIssuesTest do
  use ExUnit.Case, async: false

  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label}
  alias ForgeRepos.Collaborator
  alias Fornacast.Repo

  import ForgeIssues.Fixtures

  setup do
    reset_database!()
    writer = user_fixture("issue-writer-#{System.unique_integer([:positive])}")
    repository = repository_fixture(writer)
    %{writer: writer, repository: repository}
  end

  test "provisions the immutable default labels once", %{repository: repository} do
    assert labels = ForgeIssues.list_labels(repository)
    assert length(labels) == 9

    assert Enum.map(labels, &{&1.name, &1.color, &1.description, &1.default}) == [
             {"bug", "d73a4a", "Something isn't working", true},
             {"documentation", "0075ca", "Improvements or additions to documentation", true},
             {"duplicate", "cfd3d7", "This issue or pull request already exists", true},
             {"enhancement", "a2eeef", "New feature or request", true},
             {"good first issue", "7057ff", "Good for newcomers", true},
             {"help wanted", "008672", "Extra attention is needed", true},
             {"invalid", "e4e669", "This doesn't seem right", true},
             {"question", "d876e3", "Further information is requested", true},
             {"wontfix", "ffffff", "This will not be worked on", true}
           ]

    assert Enum.map(labels, & &1.normalized_name) ==
             Enum.sort(Enum.map(labels, & &1.normalized_name))

    assert Enum.all?(labels, &(&1.inserted_at.microsecond == {0, 0}))
    assert Enum.all?(labels, &(&1.updated_at.microsecond == {0, 0}))
  end

  test "a pre-feature repository receives defaults lazily on its first issue read", %{
    writer: writer
  } do
    repository = repository_fixture(writer)
    assert 0 == Repo.aggregate(Label, :count, :id)

    assert 9 == repository |> ForgeIssues.list_labels() |> length()
    assert 9 == Repo.aggregate(Label, :count, :id)
  end

  test "concurrent provisioning leaves exactly nine defaults", %{repository: repository} do
    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          receive do
            :go -> ForgeIssues.list_labels(repository)
          end
        end)
      end

    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Enum.each(tasks, &Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), &1.pid))
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.each(tasks, fn task -> assert 9 == task |> Task.await(30_000) |> length() end)

    assert 9 == Repo.aggregate(Label, :count, :id)
  end

  test "disabled repositories are not provisioned", %{writer: writer} do
    repository =
      writer
      |> repository_fixture()
      |> Ecto.Changeset.change(has_issues: false)
      |> Repo.update!()

    assert [] = ForgeIssues.list_labels(repository)
    assert 0 == Repo.aggregate(Label, :count, :id)
  end

  test "writers replace labels and assignees", %{writer: writer, repository: repository} do
    %Label{}
    |> Label.changeset(%{
      repository_id: repository.id,
      name: "Custom",
      normalized_name: "custom",
      color: "aabbcc"
    })
    |> Repo.insert!()

    assignee = user_fixture("issue-assignee-#{System.unique_integer([:positive])}")

    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: assignee.id, role: :read})
    |> Repo.insert!()

    issue = issue_fixture(repository, writer)

    assert {:ok, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"labels" => [%{"name" => " CUSTOM "}], "assignee" => assignee.username},
               :writer
             )
             |> ForgeIssues.transaction()

    assert [%{name: "Custom"}] = ForgeIssues.load_labels(issue)
    assert [assignee.id] == ForgeIssues.load_assignees(issue) |> Enum.map(& &1.id)
  end

  test "writers replace existing label and assignee joins", %{
    writer: writer,
    repository: repository
  } do
    [old_label | _] = ForgeIssues.list_labels(repository)
    new_label = label_fixture(repository, "Replacement")
    old_assignee = readable_user(repository, "old-assignee")
    new_assignee = readable_user(repository, "new-assignee")
    issue = issue_fixture(repository, writer)
    Repo.insert_all(IssueLabel, [join_row(issue.id, old_label.id)])
    Repo.insert_all(IssueAssignee, [assignee_row(issue.id, old_assignee.id)])

    assert {:ok, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"labels" => [new_label.name], "assignees" => [new_assignee.username]},
               :writer
             )
             |> ForgeIssues.transaction()

    assert [new_label.id] == ForgeIssues.load_labels(issue) |> Enum.map(& &1.id)
    assert [new_assignee.id] == ForgeIssues.load_assignees(issue) |> Enum.map(& &1.id)
  end

  test "writers receive stable relationship errors", %{writer: writer, repository: repository} do
    issue = issue_fixture(repository, writer)

    assert {:error, {:issue, :relationships},
            {:validation, [%{resource: "Issue", field: "labels", code: :missing}]},
            _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"labels" => ["unknown"]},
               :writer
             )
             |> ForgeIssues.transaction()

    assert {:error, {:issue, :relationships},
            {:validation, [%{resource: "Issue", field: "assignees", code: :invalid}]},
            _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"assignee" => "missing-user"},
               :writer
             )
             |> ForgeIssues.transaction()
  end

  test "authors ignore submitted relationship changes", %{writer: writer, repository: repository} do
    author = user_fixture("issue-author-#{System.unique_integer([:positive])}")
    grant_read(repository, author)
    issue = issue_fixture(repository, author)
    label = ForgeIssues.list_labels(repository) |> hd()

    Repo.insert_all(IssueLabel, [join_row(issue.id, label.id)])
    Repo.insert_all(IssueAssignee, [assignee_row(issue.id, writer.id)])

    assert {:ok, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               author,
               %{"labels" => ["unknown"], "assignee" => "missing-user"},
               :author
             )
             |> ForgeIssues.transaction()

    assert [label.id] == ForgeIssues.load_labels(issue) |> Enum.map(& &1.id)
    assert [writer.id] == ForgeIssues.load_assignees(issue) |> Enum.map(& &1.id)
  end

  test "disabled assignees return the exact invalid error", %{
    writer: writer,
    repository: repository
  } do
    disabled = user_fixture("disabled-#{System.unique_integer([:positive])}", %{state: :disabled})
    assert_invalid_assignee(repository, writer, disabled.username)
  end

  test "organization assignees return the exact invalid error", %{
    writer: writer,
    repository: repository
  } do
    {:ok, organization} =
      ForgeAccounts.create_organization(writer, %{
        username: "org-#{System.unique_integer([:positive])}"
      })

    assert_invalid_assignee(repository, writer, organization.username)
  end

  test "repository-ineligible assignees return the exact invalid error", %{
    writer: writer,
    repository: repository
  } do
    ineligible = user_fixture("ineligible-#{System.unique_integer([:positive])}")
    assert_invalid_assignee(repository, writer, ineligible.username)
  end

  test "metadata loading batches joins, accounts, and comment counts", %{
    writer: writer,
    repository: repository
  } do
    issues = Enum.map(1..3, fn _ -> issue_fixture(repository, writer) end)
    label = ForgeIssues.list_labels(repository) |> hd()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(IssueLabel, Enum.map(issues, &join_row(&1.id, label.id, now)))
    Repo.insert_all(IssueAssignee, Enum.map(issues, &assignee_row(&1.id, writer.id, now)))

    Repo.insert_all(Comment, [
      %{
        issue_id: hd(issues).id,
        author_user_id: writer.id,
        body: "one",
        inserted_at: now,
        updated_at: now
      },
      %{
        issue_id: hd(issues).id,
        author_user_id: writer.id,
        body: "two",
        inserted_at: now,
        updated_at: now
      }
    ])

    {loaded, query_count} =
      count_repo_queries(fn -> ForgeIssues.load_issue_metadata(issues, repository) end)

    assert Enum.map(loaded, & &1.comment_count) == [2, 0, 0]
    assert Enum.all?(loaded, &match?([%Label{}], &1.labels))
    assert query_count <= 6
  end

  test "plural assignees take precedence", %{writer: writer, repository: repository} do
    issue = issue_fixture(repository, writer)
    first = readable_user(repository, "first")
    second = readable_user(repository, "second")

    assert {:ok, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"assignee" => first.username, "assignees" => [second.username]},
               :writer
             )
             |> ForgeIssues.transaction()

    assert [second.id] == ForgeIssues.load_assignees(issue) |> Enum.map(& &1.id)
  end

  test "absent nil and empty singular assignee values preserve existing joins", %{
    writer: writer,
    repository: repository
  } do
    assignee = readable_user(repository, "preserved")

    for attrs <- [%{}, %{"assignee" => nil}, %{"assignee" => ""}] do
      issue = issue_fixture(repository, writer)
      Repo.insert_all(IssueAssignee, [assignee_row(issue.id, assignee.id)])

      assert {:ok, _} =
               Multi.new()
               |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
               |> ForgeIssues.put_relationship_operations(
                 :issue,
                 repository,
                 writer,
                 attrs,
                 :writer
               )
               |> ForgeIssues.transaction()

      assert [assignee.id] == ForgeIssues.load_assignees(issue) |> Enum.map(& &1.id)
    end
  end

  test "relationship replacement rolls back as part of the outer multi", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    [old_label | _] = ForgeIssues.list_labels(repository)
    new_label = label_fixture(repository, "Replacement")
    Repo.insert_all(IssueLabel, [join_row(issue.id, old_label.id)])

    assert {:error, :rollback, :forced, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"labels" => [new_label.name]},
               :writer
             )
             |> Multi.run(:rollback, fn _repo, _changes -> {:error, :forced} end)
             |> ForgeIssues.transaction()

    assert [old_label.id] == ForgeIssues.load_labels(issue) |> Enum.map(& &1.id)
  end

  test "metadata maps owner member collaborator and none author associations", %{writer: writer} do
    {:ok, organization} =
      ForgeAccounts.create_organization(writer, %{
        username: "issues-org-#{System.unique_integer([:positive])}"
      })

    repository = repository_fixture(organization)
    member = user_fixture("member-#{System.unique_integer([:positive])}")
    collaborator = user_fixture("collaborator-#{System.unique_integer([:positive])}")
    stranger = user_fixture("stranger-#{System.unique_integer([:positive])}")
    {:ok, _} = ForgeAccounts.add_organization_member(organization, member)

    %Collaborator{}
    |> Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: collaborator.id,
      role: :read
    })
    |> Repo.insert!()

    associations =
      [
        issue_fixture(repository, writer),
        issue_fixture(repository, member),
        issue_fixture(repository, collaborator),
        issue_fixture(repository, stranger)
      ]
      |> ForgeIssues.load_issue_metadata(repository)
      |> Enum.map(& &1.author_association)

    assert associations == ["OWNER", "MEMBER", "COLLABORATOR", "NONE"]
  end

  defp issue_fixture(repository, author) do
    %Issue{
      repository_id: repository.id,
      number: System.unique_integer([:positive]),
      kind: :issue,
      author_user_id: author.id
    }
    |> Issue.create_changeset(%{title: "Relationship test"})
    |> Repo.insert!()
  end

  defp join_row(issue_id, label_id, now \\ DateTime.utc_now() |> DateTime.truncate(:second)),
    do: %{issue_id: issue_id, label_id: label_id, inserted_at: now, updated_at: now}

  defp assignee_row(issue_id, user_id, now \\ DateTime.utc_now() |> DateTime.truncate(:second)),
    do: %{issue_id: issue_id, user_id: user_id, inserted_at: now, updated_at: now}

  defp readable_user(repository, prefix) do
    user = user_fixture("#{prefix}-#{System.unique_integer([:positive])}")

    grant_read(repository, user)

    user
  end

  defp grant_read(repository, user) do
    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: user.id, role: :read})
    |> Repo.insert!()
  end

  defp label_fixture(repository, name) do
    %Label{}
    |> Label.changeset(%{
      repository_id: repository.id,
      name: name,
      normalized_name: String.downcase(name),
      color: "aabbcc"
    })
    |> Repo.insert!()
  end

  defp assert_invalid_assignee(repository, writer, username) do
    issue = issue_fixture(repository, writer)

    assert {:error, {:issue, :relationships},
            {:validation, [%{resource: "Issue", field: "assignees", code: :invalid}]},
            _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"assignee" => username},
               :writer
             )
             |> ForgeIssues.transaction()
  end

  defp count_repo_queries(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:fornacast, :repo, :query],
        fn _event, _measurements, _metadata, {pid, query_ref} ->
          send(pid, {query_ref, :repo_query})
        end,
        {test_pid, ref}
      )

    try do
      result = fun.()
      {result, drain_repo_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(ref, count) do
    receive do
      {^ref, :repo_query} -> drain_repo_queries(ref, count + 1)
    after
      0 -> count
    end
  end
end
