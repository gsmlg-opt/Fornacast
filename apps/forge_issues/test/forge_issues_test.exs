defmodule ForgeIssuesTest do
  use ExUnit.Case, async: false

  alias Ecto.Multi
  alias ForgeIssues.{Issue, Label}
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
  end

  test "concurrent provisioning leaves exactly nine defaults", %{repository: repository} do
    repository
    |> List.duplicate(8)
    |> Task.async_stream(&ForgeIssues.list_labels/1, max_concurrency: 8, timeout: 30_000)
    |> Enum.each(fn {:ok, labels} -> assert length(labels) == 9 end)

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
    issue = issue_fixture(repository, writer)

    assert {:ok, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"labels" => ["unknown"], "assignee" => "missing-user"},
               :author
             )
             |> ForgeIssues.transaction()

    assert [] = ForgeIssues.load_labels(issue)
    assert [] = ForgeIssues.load_assignees(issue)
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
end
