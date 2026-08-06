defmodule ForgeIssuesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label}
  alias ForgeRepos.Collaborator
  alias Fornacast.{AuditEvent, Page, Repo}

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

  test "metadata-by-id loading stays repository scoped and batches canonical presentation fields",
       %{
         writer: writer,
         repository: repository
       } do
    first = issue_fixture(repository, writer)
    second = issue_fixture(repository, writer)
    other_repository = repository_fixture(writer)
    foreign = issue_fixture(other_repository, writer)

    {loaded, query_count} =
      count_repo_queries(fn ->
        ForgeIssues.load_issue_metadata_by_ids(
          [second.id, foreign.id, first.id, first.id],
          repository
        )
      end)

    assert MapSet.new(Enum.map(loaded, & &1.id)) == MapSet.new([first.id, second.id])
    assert Enum.all?(loaded, &(&1.repository_id == repository.id))
    assert Enum.all?(loaded, &(&1.author.id == writer.id))
    assert Enum.all?(loaded, &is_list(&1.labels))
    assert Enum.all?(loaded, &is_list(&1.assignees))
    assert query_count <= 7
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

  test "relationship writes reject an issue from another repository without joins", %{
    writer: writer,
    repository: repository
  } do
    other_repository = repository_fixture(writer)
    issue = issue_fixture(other_repository, writer)
    [label | _] = ForgeIssues.list_labels(repository)

    assert {:error, {:issue, :relationships}, :not_found, _} =
             Multi.new()
             |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
             |> ForgeIssues.put_relationship_operations(
               :issue,
               repository,
               writer,
               %{"labels" => [label.name], "assignees" => [writer.username]},
               :writer
             )
             |> ForgeIssues.transaction()

    assert [] = ForgeIssues.load_labels(issue)
    assert [] = ForgeIssues.load_assignees(issue)
  end

  test "metadata loading rejects one issue from another repository before queries", %{
    writer: writer,
    repository: repository
  } do
    other_repository = repository_fixture(writer)
    issue = issue_fixture(other_repository, writer)

    {result, query_count} =
      count_repo_queries(fn -> ForgeIssues.load_issue_metadata(issue, repository) end)

    assert result == {:error, :not_found}
    assert query_count == 0
  end

  test "metadata loading rejects mixed repositories before queries", %{
    writer: writer,
    repository: repository
  } do
    other_repository = repository_fixture(writer)
    issues = [issue_fixture(repository, writer), issue_fixture(other_repository, writer)]

    {result, query_count} =
      count_repo_queries(fn -> ForgeIssues.load_issue_metadata(issues, repository) end)

    assert result == {:error, :not_found}
    assert query_count == 0
  end

  test "malformed writer label fields return the exact missing error without writes", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    [existing | _] = ForgeIssues.list_labels(repository)
    Repo.insert_all(IssueLabel, [join_row(issue.id, existing.id)])

    for attrs <- [
          %{"labels" => "bug"},
          %{"labels" => [123]},
          %{"labels" => [%{"name" => 123}]},
          %{"labels" => [%{"wrong" => "bug"}]}
        ] do
      assert {:error, {:issue, :relationships},
              {:validation, [%{resource: "Issue", field: "labels", code: :missing}]},
              _} =
               relationship_transaction(issue, repository, writer, attrs)

      assert [existing.id] == ForgeIssues.load_labels(issue) |> Enum.map(& &1.id)
    end
  end

  test "malformed writer assignee fields return the exact invalid error without writes", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    existing = readable_user(repository, "malformed-preserved")
    Repo.insert_all(IssueAssignee, [assignee_row(issue.id, existing.id)])

    for attrs <- [
          %{"assignees" => "user"},
          %{"assignees" => [123]},
          %{"assignees" => [%{"name" => writer.username}]},
          %{"assignee" => 123}
        ] do
      assert {:error, {:issue, :relationships},
              {:validation, [%{resource: "Issue", field: "assignees", code: :invalid}]},
              _} =
               relationship_transaction(issue, repository, writer, attrs)

      assert [existing.id] == ForgeIssues.load_assignees(issue) |> Enum.map(& &1.id)
    end
  end

  test "public slug APIs create, update, and audit an issue", %{writer: writer} do
    repository = repository_fixture(writer, %{visibility: :public})
    metadata = request_metadata()

    assert {:ok, created} =
             ForgeIssues.create(
               writer,
               writer.username,
               repository.slug,
               %{"title" => "Lifecycle", "body" => "first"},
               metadata
             )

    assert %{kind: :issue, number: 1, title: "Lifecycle", comment_count: 0} = created
    assert {:ok, fetched} = ForgeIssues.get(nil, writer.username, repository.slug, created.number)
    assert fetched.id == created.id

    assert {:ok, updated} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               created.number,
               %{"state" => :closed, "state_reason" => :completed},
               metadata
             )

    assert %{state: :closed, state_reason: :completed, closed_at: %DateTime{}} = updated

    assert {:ok, %{state: :open, state_reason: :reopened, closed_at: nil}} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               created.number,
               %{"state" => :open, "state_reason" => :reopened},
               metadata
             )

    audits = Repo.all(from audit in AuditEvent, order_by: [asc: audit.id])
    assert Enum.map(audits, & &1.action) == ["issue.created", "issue.updated", "issue.updated"]

    [created_audit, closed_audit, reopened_audit] = audits

    assert {created_audit.target_type, created_audit.target_id} ==
             {"repository", to_string(repository.id)}

    assert {closed_audit.target_type, closed_audit.target_id} == {"issue", to_string(created.id)}

    assert {reopened_audit.target_type, reopened_audit.target_id} ==
             {"issue", to_string(created.id)}

    assert Enum.all?(audits, fn audit ->
             audit.actor_user_id == writer.id and audit.metadata["result"] == "success" and
               audit.metadata["repository_id"] == repository.id and
               audit.metadata["request_id"] == "req-issue-1" and
               audit.metadata["api_version"] == "2022-11-28" and
               audit.metadata["token_id"] == 41 and audit.ip_address == "192.0.2.10" and
               audit.user_agent == "Octokit/9.0"
           end)
  end

  test "audit metadata accepts atom string and mixed keys with string precedence", %{
    writer: writer,
    repository: repository
  } do
    atom_metadata = Map.put(request_metadata(), :request_id, "atom-only")

    string_metadata = %{
      "request_id" => "string-only",
      "api_version" => "2022-11-28",
      "ip_address" => "192.0.2.11",
      "user_agent" => "Octokit/9.1",
      "token_id" => 42,
      "secret" => "must-not-be-audited"
    }

    mixed_metadata =
      Map.merge(string_metadata, %{
        "request_id" => "string-wins",
        "token_id" => 43,
        request_id: "atom-loses",
        token_id: 99
      })

    for {title, metadata} <- [
          {"Atom metadata", atom_metadata},
          {"String metadata", string_metadata},
          {"Mixed metadata", mixed_metadata}
        ] do
      assert {:ok, _issue} =
               ForgeIssues.create(
                 writer,
                 writer.username,
                 repository.slug,
                 %{title: title},
                 metadata
               )
    end

    audits = Repo.all(from audit in AuditEvent, order_by: [asc: audit.id])

    assert Enum.map(audits, & &1.metadata["request_id"]) == [
             "atom-only",
             "string-only",
             "string-wins"
           ]

    assert Enum.map(audits, & &1.metadata["token_id"]) == [41, 42, 43]
    assert Enum.all?(audits, &(not Map.has_key?(&1.metadata, "secret")))
  end

  test "page accepts values beyond one and returns the requested stable slice", %{
    writer: writer,
    repository: repository
  } do
    issues = Enum.map(1..3, &issue_fixture(repository, writer, "Page #{&1}"))

    assert {:ok, %Page{page: 2, per_page: 2, total: 3, entries: [entry]}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               state: :all,
               sort: :created,
               direction: :asc,
               page: 2,
               per_page: 2
             })

    assert entry.id == List.last(issues).id
  end

  test "authenticated public readers create with author capability and ignore relationships", %{
    writer: writer
  } do
    repository = repository_fixture(writer, %{visibility: :public})
    reader = user_fixture("public-reader-#{System.unique_integer([:positive])}")

    assert {:ok, issue} =
             ForgeIssues.create(
               reader,
               writer.username,
               repository.slug,
               %{
                 title: "Reader issue",
                 labels: ["missing-label"],
                 assignees: ["missing-assignee"]
               },
               request_metadata()
             )

    assert issue.author_user_id == reader.id
    assert issue.labels == []
    assert issue.assignees == []
  end

  test "disabled stale actors cannot create or update through a public repository", %{
    writer: writer
  } do
    repository = repository_fixture(writer, %{visibility: :public})
    stale_actor = readable_user(repository, "stale-actor")
    issue = issue_fixture(repository, stale_actor, "Stale issue")

    stale_actor
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:error, :forbidden} =
             ForgeIssues.create(
               stale_actor,
               writer.username,
               repository.slug,
               %{"title" => "Rejected create"},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.update(
               stale_actor,
               writer.username,
               repository.slug,
               issue.number,
               %{"title" => "Rejected update"},
               request_metadata()
             )

    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "anonymous public mutation attempts return forbidden without bypassing repository lookup",
       %{
         writer: writer
       } do
    repository = repository_fixture(writer, %{visibility: :public})
    issue = issue_fixture(repository, writer, "Anonymous mutation")

    assert {:error, :forbidden} =
             ForgeIssues.create(
               nil,
               writer.username,
               repository.slug,
               %{title: "Anonymous create"},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.update(
               nil,
               writer.username,
               repository.slug,
               issue.number,
               %{title: "Anonymous update"},
               request_metadata()
             )
  end

  test "create multi revalidates actor and repository state at transaction execution", %{
    writer: writer,
    repository: repository
  } do
    actor = readable_user(repository, "multi-create-actor")

    actor_multi =
      ForgeIssues.create_multi(
        actor,
        repository,
        %{title: "Actor revoked"},
        request_metadata()
      )

    actor |> Ecto.Changeset.change(state: :disabled) |> Repo.update!()
    assert {:error, :authorization, :forbidden, %{}} = ForgeIssues.transaction(actor_multi)

    issues_multi =
      ForgeIssues.create_multi(
        writer,
        repository,
        %{title: "Issues disabled"},
        request_metadata()
      )

    repository |> Ecto.Changeset.change(has_issues: false) |> Repo.update!()
    assert {:error, :authorization, :issues_disabled, %{}} = ForgeIssues.transaction(issues_multi)

    deleted_repository = repository_fixture(writer)

    deleted_multi =
      ForgeIssues.create_multi(
        writer,
        deleted_repository,
        %{title: "Repository deleted"},
        request_metadata()
      )

    deleted_repository
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert {:error, :authorization, :not_found, %{}} = ForgeIssues.transaction(deleted_multi)

    assert Repo.aggregate(Issue, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "update multi revalidates repository permission and current issue ownership", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "multi-update-author")
    issue = issue_fixture(repository, writer, "Revalidated update")

    collaborator =
      Repo.get_by!(Collaborator, repository_id: repository.id, user_id: author.id)
      |> Ecto.Changeset.change(role: :write)
      |> Repo.update!()

    permission_multi =
      ForgeIssues.update_multi(
        author,
        repository,
        issue.number,
        %{title: "Permission revoked"},
        request_metadata()
      )

    collaborator |> Ecto.Changeset.change(role: :read) |> Repo.update!()
    assert {:error, :authorization, :forbidden, %{}} = ForgeIssues.transaction(permission_multi)

    own_issue = issue_fixture(repository, author, "Ownership changed")

    ownership_multi =
      ForgeIssues.update_multi(
        author,
        repository,
        own_issue.number,
        %{title: "Stale ownership"},
        request_metadata()
      )

    Repo.update_all(from(row in Issue, where: row.id == ^own_issue.id),
      set: [author_user_id: writer.id]
    )

    assert {:error, :authorization, :forbidden, %{}} = ForgeIssues.transaction(ownership_multi)
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "authors derive close and reopen reasons and discard hostile supplied reasons", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "state-author")
    issue = issue_fixture(repository, author, "State issue")

    assert {:ok, closed} =
             ForgeIssues.update(
               author,
               writer.username,
               repository.slug,
               issue.number,
               %{state: "closed", state_reason: "not_planned"},
               request_metadata()
             )

    assert %{state: :closed, state_reason: :completed, closed_at: %DateTime{}} = closed

    assert {:ok, reopened} =
             ForgeIssues.update(
               author,
               writer.username,
               repository.slug,
               issue.number,
               %{"state" => "open", "state_reason" => "completed"},
               request_metadata()
             )

    assert %{state: :open, state_reason: :reopened, closed_at: nil} = reopened
  end

  test "get batches metadata for multiple assignees", %{writer: writer, repository: repository} do
    issue = issue_fixture(repository, writer, "Assigned issue")
    comparison_issue = issue_fixture(repository, writer, "Single assigned issue")

    assignees =
      Enum.map(1..4, fn index -> readable_user(repository, "get-assignee-#{index}") end)

    Repo.insert_all(IssueAssignee, Enum.map(assignees, &assignee_row(issue.id, &1.id)))
    Repo.insert_all(IssueAssignee, [assignee_row(comparison_issue.id, hd(assignees).id)])

    {{:ok, _comparison}, comparison_query_count} =
      count_repo_queries(fn ->
        ForgeIssues.get(writer, writer.username, repository.slug, comparison_issue.number)
      end)

    {{:ok, loaded}, query_count} =
      count_repo_queries(fn ->
        ForgeIssues.get(writer, writer.username, repository.slug, issue.number)
      end)

    assert Enum.map(loaded.assignees, & &1.id) == Enum.map(assignees, & &1.id)
    assert query_count == comparison_query_count
    assert query_count <= 9
  end

  test "writers and site admins mutate other authors while disabled identities stay blocked", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "permission-author")
    issue = issue_fixture(repository, author, "Permission issue")

    assert {:ok, %{state_reason: :not_planned}} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{state: :closed, state_reason: :not_planned},
               request_metadata()
             )

    assert {:ok, %{state_reason: :completed}} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{state_reason: :completed},
               request_metadata()
             )

    {:ok, admin} =
      ForgeAccounts.create_admin(%{
        username: "issue-admin-#{System.unique_integer([:positive])}",
        email: "issue-admin-#{System.unique_integer([:positive])}@example.test",
        password: "correct horse battery staple"
      })

    assert {:ok, %{title: "Admin edit"}} =
             ForgeIssues.update(
               admin,
               writer.username,
               repository.slug,
               issue.number,
               %{title: "Admin edit"},
               request_metadata()
             )

    repository |> Ecto.Changeset.change(has_issues: false) |> Repo.update!()

    assert {:error, :issues_disabled} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{title: "Disabled edit"},
               request_metadata()
             )
  end

  test "failed issue mutations never write success audits", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "failure-author")
    stranger = readable_user(repository, "failure-stranger")
    issue = issue_fixture(repository, author, "Failure issue")

    assert {:error, {:validation, _errors}} =
             ForgeIssues.create(
               writer,
               writer.username,
               repository.slug,
               %{"title" => ""},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.update(
               stranger,
               writer.username,
               repository.slug,
               issue.number,
               %{"title" => "Unauthorized"},
               request_metadata()
             )

    assert {:error, {:validation, [%{resource: "Issue", field: "labels", code: :missing}]}} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{"labels" => ["transaction-failure"]},
               request_metadata()
             )

    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "issue filters cover state relationships ordering since and paging", %{
    writer: writer,
    repository: repository
  } do
    [bug | _] = ForgeIssues.list_labels(repository)
    help = Enum.find(ForgeIssues.list_labels(repository), &(&1.name == "help wanted"))
    assignee = readable_user(repository, "matrix-assignee")
    creator = readable_user(repository, "matrix-creator")

    first =
      create_issue!(writer, repository, %{
        title: "First",
        labels: [bug.name, help.name],
        assignees: [assignee.username]
      })

    second = create_issue!(creator, repository, %{title: "Second"})
    third = create_issue!(writer, repository, %{title: "Third"})
    pull = pull_fixture(repository, writer)

    assert {:ok, second} =
             ForgeIssues.update(
               writer,
               writer.username,
               repository.slug,
               second.number,
               %{state: :closed, state_reason: :completed},
               request_metadata()
             )

    base = ~U[2026-07-01 00:00:00Z]
    set_issue_times(first, base, DateTime.add(base, 30, :second))
    set_issue_times(second, DateTime.add(base, 10, :second), DateTime.add(base, 20, :second))
    set_issue_times(third, DateTime.add(base, 20, :second), DateTime.add(base, 10, :second))
    set_issue_times(pull, DateTime.add(base, 30, :second), base)
    insert_comments(first, writer, 2)
    insert_comments(second, writer, 1)

    assert_issue_ids(repository, writer, %{}, [pull.id, third.id, first.id])
    assert_issue_ids(repository, writer, %{state: :open}, [pull.id, third.id, first.id])
    assert_issue_ids(repository, writer, %{state: :closed}, [second.id])

    assert_issue_ids(repository, writer, %{state: :all, sort: :created, direction: :asc}, [
      first.id,
      second.id,
      third.id,
      pull.id
    ])

    assert_issue_ids(repository, writer, %{state: :all, labels: "BUG, help wanted"}, [first.id])
    assert_issue_ids(repository, writer, %{state: :all, assignee: assignee.username}, [first.id])
    assert_issue_ids(repository, writer, %{state: :all, assignee: "*"}, [first.id])

    assert_issue_ids(
      repository,
      writer,
      %{state: :all, assignee: "none", sort: :created, direction: :asc},
      [second.id, third.id, pull.id]
    )

    assert_issue_ids(repository, writer, %{state: :all, creator: creator.username}, [second.id])

    assert_issue_ids(repository, writer, %{state: :all, sort: :updated, direction: :asc}, [
      pull.id,
      third.id,
      second.id,
      first.id
    ])

    assert_issue_ids(repository, writer, %{state: :all, sort: :comments, direction: :desc}, [
      first.id,
      second.id,
      pull.id,
      third.id
    ])

    assert_issue_ids(
      repository,
      writer,
      %{state: :all, since: DateTime.add(base, 20, :second), sort: :updated, direction: :asc},
      [second.id, first.id]
    )

    assert {:ok, %Page{entries: page_two, total: 4, page: 2, per_page: 2}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               state: :all,
               sort: :created,
               direction: :asc,
               page: 2,
               per_page: 2
             })

    assert Enum.map(page_two, & &1.id) == [third.id, pull.id]

    tied_at = ~U[2026-07-02 00:00:00Z]
    Enum.each([first, second, third, pull], &set_issue_times(&1, tied_at, tied_at))
    ids = Enum.sort([first.id, second.id, third.id, pull.id])
    assert_issue_ids(repository, writer, %{state: :all, sort: :created, direction: :asc}, ids)

    assert_issue_ids(
      repository,
      writer,
      %{state: :all, sort: :created, direction: :desc},
      Enum.reverse(ids)
    )

    assert_issue_ids(repository, writer, %{state: :all, sort: :updated, direction: :asc}, ids)

    assert_issue_ids(
      repository,
      writer,
      %{state: :all, sort: :updated, direction: :desc},
      Enum.reverse(ids)
    )
  end

  test "issue filters accept limits and reject every invalid field exactly", %{
    writer: writer,
    repository: repository
  } do
    hundred_labels = Enum.map_join(1..100, ",", &"label-#{&1}")

    assert {:ok, %Page{entries: [], per_page: 100}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               labels: hundred_labels,
               per_page: 100
             })

    too_many_labels = hundred_labels <> ",label-101"

    invalid_filters = [
      {%{state: :invalid}, "state", :invalid},
      {%{labels: 1}, "labels", :invalid},
      {%{labels: too_many_labels}, "labels", :unprocessable},
      {%{assignee: 1}, "assignee", :invalid},
      {%{creator: 1}, "creator", :invalid},
      {%{sort: :invalid}, "sort", :invalid},
      {%{direction: :invalid}, "direction", :invalid},
      {%{since: "not-a-date"}, "since", :unprocessable},
      {%{page: 0}, "page", :unprocessable},
      {%{per_page: 101}, "per_page", :unprocessable}
    ]

    Enum.each(invalid_filters, fn {filters, field, code} ->
      assert {:error, {:validation, [%{resource: "Issue", field: ^field, code: ^code}]}} =
               ForgeIssues.list(writer, writer.username, repository.slug, filters)
    end)
  end

  test "page offset accepts the signed 64-bit boundary and rejects overflow before querying", %{
    writer: writer,
    repository: repository
  } do
    max_signed_64 = 9_223_372_036_854_775_807

    assert {:ok, %Page{entries: [], page: boundary_page, per_page: 1}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               page: max_signed_64 + 1,
               per_page: 1
             })

    assert boundary_page == max_signed_64 + 1

    assert {:error, {:validation, [%{resource: "Issue", field: "page", code: :unprocessable}]}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               page: String.duplicate("9", 100),
               per_page: 100
             })
  end

  test "mixed filter keys use string request values deterministically", %{
    writer: writer,
    repository: repository
  } do
    first = issue_fixture(repository, writer, "First mixed filter")
    second = issue_fixture(repository, writer, "Second mixed filter")

    assert {:ok, %Page{entries: [entry], page: 2, per_page: 1, total: 2}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               "state" => "open",
               "page" => "2",
               state: :closed,
               page: 1,
               per_page: 1,
               sort: :created,
               direction: :asc
             })

    assert first.id < second.id
    assert entry.id == second.id
  end

  test "issue lists filter and page pull-backed identities with stable ties", %{
    writer: writer,
    repository: repository
  } do
    other = readable_user(repository, "filter-author")
    bug = ForgeIssues.list_labels(repository) |> hd()

    assert {:ok, first} =
             ForgeIssues.create(
               writer,
               writer.username,
               repository.slug,
               %{"title" => "First", "labels" => [bug.name]},
               request_metadata()
             )

    assert {:ok, second} =
             ForgeIssues.create(
               other,
               writer.username,
               repository.slug,
               %{"title" => "Second", "labels" => [bug.name]},
               request_metadata()
             )

    pull = pull_fixture(repository, writer)
    timestamp = ~U[2026-07-01 00:00:00Z]

    Repo.update_all(from(issue in Issue, where: issue.id in ^[first.id, second.id, pull.id]),
      set: [inserted_at: timestamp, updated_at: timestamp]
    )

    assert {:ok, %Page{entries: entries, total: 1, page: 1, per_page: 30}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               labels: " BUG ",
               sort: :created,
               direction: :asc,
               creator: writer.username,
               since: timestamp
             })

    assert Enum.map(entries, & &1.id) == [first.id]

    assert {:ok, %Page{entries: all_entries, total: 3}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{
               state: :all,
               sort: :created,
               direction: :asc
             })

    assert Enum.map(all_entries, & &1.id) == Enum.sort(Enum.map(all_entries, & &1.id))
    assert Enum.any?(all_entries, &(&1.kind == :pull_request))
  end

  test "author and disabled issue permissions preserve identity semantics", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "lifecycle-author")
    stranger = readable_user(repository, "lifecycle-stranger")

    assert {:ok, issue} =
             ForgeIssues.create(
               author,
               writer.username,
               repository.slug,
               %{"title" => "Author issue", "labels" => ["missing"]},
               request_metadata()
             )

    assert {:ok, %{title: "Edited", body: "Edited body"}} =
             ForgeIssues.update(
               author,
               writer.username,
               repository.slug,
               issue.number,
               %{"title" => "Edited", "body" => "Edited body", "labels" => ["missing"]},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.update(
               stranger,
               writer.username,
               repository.slug,
               issue.number,
               %{"title" => "Nope"},
               request_metadata()
             )

    disabled_repository =
      repository
      |> Ecto.Changeset.change(has_issues: false)
      |> Repo.update!()

    pull = pull_fixture(disabled_repository, writer)

    assert {:error, :issues_disabled} =
             ForgeIssues.get(writer, writer.username, disabled_repository.slug, issue.number)

    assert {:ok, %{id: pull_id}} =
             ForgeIssues.get(writer, writer.username, disabled_repository.slug, pull.number)

    assert pull_id == pull.id

    assert {:error, :issues_disabled} =
             ForgeIssues.create(
               writer,
               writer.username,
               disabled_repository.slug,
               %{"title" => "No issue"},
               request_metadata()
             )

    assert {:ok, %Page{entries: [%{id: ^pull_id}], total: 1}} =
             ForgeIssues.list(writer, writer.username, disabled_repository.slug, %{state: :all})
  end

  test "slug APIs mask private reads and return exact invalid paging errors", %{
    writer: writer,
    repository: repository
  } do
    assert {:error, :not_found} = ForgeIssues.list(nil, writer.username, repository.slug, %{})

    assert {:error,
            {:validation, [%{resource: "Issue", field: "per_page", code: :unprocessable}]}} =
             ForgeIssues.list(writer, writer.username, repository.slug, %{per_page: 101})
  end

  test "public repositories expose issue comments anonymously in creation order", %{
    writer: writer,
    repository: repository
  } do
    repository = Repo.update!(Ecto.Changeset.change(repository, visibility: :public))
    issue = issue_fixture(repository, writer)
    first = insert_comment(issue, writer, "First")
    second = insert_comment(issue, writer, "Second")
    first_id = first.id

    assert {:ok, %Page{entries: comments, total: 2, page: 1, per_page: 30}} =
             ForgeIssues.list_comments(nil, writer.username, repository.slug, issue.number, %{})

    assert Enum.map(comments, & &1.id) == [first.id, second.id]
    assert Enum.map(comments, & &1.author.id) == [writer.id, writer.id]
    assert Enum.map(comments, & &1.issue_number) == [issue.number, issue.number]

    assert {:ok, %{id: ^first_id, issue_number: issue_number}} =
             ForgeIssues.get_comment(nil, writer.username, repository.slug, first.id)

    assert issue_number == issue.number
  end

  test "anonymous public comment mutations are forbidden without auditing", %{
    writer: writer,
    repository: repository
  } do
    repository = Repo.update!(Ecto.Changeset.change(repository, visibility: :public))
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, writer, "Protected")

    assert {:error, :forbidden} =
             ForgeIssues.create_comment(
               nil,
               writer.username,
               repository.slug,
               issue.number,
               %{"body" => "No"},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.update_comment(
               nil,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "No"},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.delete_comment(
               nil,
               writer.username,
               repository.slug,
               comment.id,
               request_metadata()
             )

    assert Repo.get!(Comment, comment.id).body == "Protected"
    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
  end

  test "private comment reads are authorized and mask unauthorized callers", %{
    writer: writer,
    repository: repository
  } do
    reader = readable_user(repository, "comment-reader")
    outsider = user_fixture("comment-outsider-#{System.unique_integer([:positive])}")
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, writer, "Private")
    comment_id = comment.id

    assert {:ok, %Page{entries: [%{id: ^comment_id}]}} =
             ForgeIssues.list_comments(
               reader,
               writer.username,
               repository.slug,
               issue.number,
               %{}
             )

    assert {:ok, %{id: ^comment_id}} =
             ForgeIssues.get_comment(reader, writer.username, repository.slug, comment.id)

    assert {:error, :not_found} =
             ForgeIssues.list_comments(
               outsider,
               writer.username,
               repository.slug,
               issue.number,
               %{}
             )

    assert {:error, :not_found} =
             ForgeIssues.get_comment(nil, writer.username, repository.slug, comment.id)
  end

  test "readers create comments and authors or writers mutate them with one audit each", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "comment-author")
    issue = issue_fixture(repository, writer)

    assert {:ok, comment} =
             ForgeIssues.create_comment(
               author,
               writer.username,
               repository.slug,
               issue.number,
               %{"body" => "Initial"},
               request_metadata()
             )

    assert {:ok, %{body: "Edited"}} =
             ForgeIssues.update_comment(
               author,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "Edited"},
               request_metadata()
             )

    assert :ok =
             ForgeIssues.delete_comment(
               writer,
               writer.username,
               repository.slug,
               comment.id,
               request_metadata()
             )

    audits = Repo.all(from(audit in AuditEvent, order_by: [asc: audit.id]))

    assert Enum.map(audits, &{&1.action, &1.target_type, &1.target_id}) == [
             {"issue_comment.created", "issue_comment", to_string(comment.id)},
             {"issue_comment.updated", "issue_comment", to_string(comment.id)},
             {"issue_comment.deleted", "issue_comment", to_string(comment.id)}
           ]

    assert hd(audits).metadata == %{
             "api_version" => "2022-11-28",
             "ip_address" => "192.0.2.10",
             "repository_id" => repository.id,
             "request_id" => "req-issue-1",
             "result" => "success",
             "token_id" => 41,
             "user_agent" => "Octokit/9.0"
           }
  end

  test "comment mutations enforce author and writer roles", %{
    writer: writer,
    repository: repository
  } do
    author = readable_user(repository, "comment-role-author")
    reader = readable_user(repository, "comment-role-reader")
    other_writer = user_fixture("comment-role-writer-#{System.unique_integer([:positive])}")
    grant_write(repository, other_writer)
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, author, "Owned")

    assert {:ok, %{body: "Writer edit"}} =
             ForgeIssues.update_comment(
               other_writer,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "Writer edit"},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.update_comment(
               reader,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "Reader edit"},
               request_metadata()
             )

    assert {:error, :forbidden} =
             ForgeIssues.delete_comment(
               reader,
               writer.username,
               repository.slug,
               comment.id,
               request_metadata()
             )

    assert :ok =
             ForgeIssues.delete_comment(
               author,
               writer.username,
               repository.slug,
               comment.id,
               request_metadata()
             )
  end

  test "comment queries keep IDs and mutations scoped to the repository", %{
    writer: writer,
    repository: repository
  } do
    other = repository_fixture(writer)
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, writer, "Scoped")
    stranger = readable_user(repository, "comment-stranger")

    assert {:error, :forbidden} =
             ForgeIssues.update_comment(
               stranger,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "No"},
               request_metadata()
             )

    assert {:error, :not_found} =
             ForgeIssues.get_comment(writer, writer.username, other.slug, comment.id)

    assert {:error, :not_found} =
             ForgeIssues.update_comment(
               writer,
               writer.username,
               other.slug,
               comment.id,
               %{"body" => "No leak"},
               request_metadata()
             )

    assert {:error, :not_found} =
             ForgeIssues.delete_comment(
               writer,
               writer.username,
               other.slug,
               comment.id,
               request_metadata()
             )

    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
  end

  test "comment listing validates stable paging and inclusive since", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    first = insert_comment(issue, writer, "First")
    second = insert_comment(issue, writer, "Second")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    comment_ids = [first.id, second.id]

    Repo.update_all(from(comment in Comment, where: comment.id in ^comment_ids),
      set: [inserted_at: now, updated_at: now]
    )

    assert {:ok, %Page{entries: [%{id: second_id}], total: 2, page: 2, per_page: 1}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               page: 2,
               per_page: 1,
               since: now
             })

    assert second_id == second.id

    assert {:ok, %Page{total: 2, page: 1, per_page: 100}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               per_page: 100
             })

    assert {:error,
            {:validation, [%{resource: "IssueComment", field: "per_page", code: :unprocessable}]}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               per_page: 101
             })

    assert {:error,
            {:validation, [%{resource: "IssueComment", field: "page", code: :unprocessable}]}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               page: "999999999999999999999999999999999999999999999999999999999999999999999999"
             })

    assert {:error,
            {:validation, [%{resource: "IssueComment", field: "per_page", code: :unprocessable}]}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               per_page: 0
             })

    assert {:error,
            {:validation, [%{resource: "IssueComment", field: "since", code: :unprocessable}]}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               since: "not-a-time"
             })
  end

  test "disabled issues reject ordinary comments but retain pull conversations", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    ordinary_comment = insert_comment(issue, writer, "Ordinary")
    repository = Repo.update!(Ecto.Changeset.change(repository, has_issues: false))
    pull = pull_fixture(repository, writer)
    comment = insert_comment(pull, writer, "Conversation")

    assert {:error, :issues_disabled} =
             ForgeIssues.list_comments(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{}
             )

    assert {:error, :issues_disabled} =
             ForgeIssues.get_comment(
               writer,
               writer.username,
               repository.slug,
               ordinary_comment.id
             )

    assert {:error, :issues_disabled} =
             ForgeIssues.create_comment(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{"body" => "Blocked"},
               request_metadata()
             )

    assert {:error, :issues_disabled} =
             ForgeIssues.update_comment(
               writer,
               writer.username,
               repository.slug,
               ordinary_comment.id,
               %{"body" => "Blocked"},
               request_metadata()
             )

    assert {:error, :issues_disabled} =
             ForgeIssues.delete_comment(
               writer,
               writer.username,
               repository.slug,
               ordinary_comment.id,
               request_metadata()
             )

    assert 0 == Repo.aggregate(AuditEvent, :count, :id)

    assert {:ok, %Page{entries: [%{id: comment_id}]}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, pull.number, %{})

    assert comment_id == comment.id

    assert {:ok, _} =
             ForgeIssues.update_comment(
               writer,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "Still here"},
               request_metadata()
             )

    assert {:ok, %{id: ^comment_id}} =
             ForgeIssues.get_comment(writer, writer.username, repository.slug, comment.id)

    assert {:ok, pull_comment} =
             ForgeIssues.create_comment(
               writer,
               writer.username,
               repository.slug,
               pull.number,
               %{"body" => "New conversation"},
               request_metadata()
             )

    assert :ok =
             ForgeIssues.delete_comment(
               writer,
               writer.username,
               repository.slug,
               pull_comment.id,
               request_metadata()
             )
  end

  test "comment since filters preserve non-UTC instants", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, writer, "Time zone")
    comment_id = comment.id
    utc = ~U[2026-08-06 01:02:03Z]
    Repo.update_all(from(row in Comment, where: row.id == ^comment.id), set: [updated_at: utc])

    shanghai = %{
      utc
      | hour: 9,
        utc_offset: 28_800,
        time_zone: "Asia/Shanghai",
        zone_abbr: "CST"
    }

    assert {:ok, %Page{entries: [%{id: ^comment_id}], total: 1}} =
             ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{
               since: shanghai
             })
  end

  test "comment pages batch author metadata", %{writer: writer, repository: repository} do
    issue = issue_fixture(repository, writer)

    Enum.each(1..4, fn index ->
      author = user_fixture("comment-page-author-#{index}-#{System.unique_integer([:positive])}")
      insert_comment(issue, author, "Comment #{index}")
    end)

    {{:ok, %Page{entries: entries}}, query_count} =
      count_repo_queries(fn ->
        ForgeIssues.list_comments(writer, writer.username, repository.slug, issue.number, %{})
      end)

    assert length(entries) == 4
    assert Enum.all?(entries, & &1.author)
    assert query_count <= 8
  end

  test "comment mutation multi rechecks actor state and rolls audit back on a later failure", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)

    stale_actor_multi =
      ForgeIssues.create_comment_multi(
        writer,
        repository,
        issue.number,
        %{"body" => "Stale actor"},
        request_metadata()
      )

    Repo.update!(Ecto.Changeset.change(writer, state: :disabled))

    assert {:error, :authorization, :forbidden, %{}} = ForgeIssues.transaction(stale_actor_multi)
    assert 0 == Repo.aggregate(AuditEvent, :count, :id)

    active_writer = Repo.get!(ForgeAccounts.User, writer.id)
    Repo.update!(Ecto.Changeset.change(active_writer, state: :active))

    failed_multi =
      ForgeIssues.create_comment_multi(
        active_writer,
        repository,
        issue.number,
        %{"body" => "Rollback"},
        request_metadata()
      )
      |> Multi.run(:forced_failure, fn _repo, _changes -> {:error, :forced_failure} end)

    assert {:error, :forced_failure, :forced_failure, _} = ForgeIssues.transaction(failed_multi)
    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
    assert 0 == Repo.aggregate(Comment, :count, :id)
  end

  test "retrying a comment multi leaves one audit row", %{writer: writer, repository: repository} do
    issue = issue_fixture(repository, writer)
    retry_key = {__MODULE__, :comment_retry, System.unique_integer([:positive])}

    multi =
      ForgeIssues.create_comment_multi(
        writer,
        repository,
        issue.number,
        %{"body" => "Retry"},
        request_metadata()
      )
      |> Multi.run(:busy_once, fn _repo, _changes ->
        case Process.get(retry_key, 0) do
          0 ->
            Process.put(retry_key, 1)
            raise Turso.Error, code: :busy, message: "database is locked"

          _ ->
            {:ok, :retried}
        end
      end)

    if Repo.__adapter__() == Ecto.Adapters.Turso do
      assert {:ok, %{comment: _comment}} = ForgeIssues.transaction(multi)
      assert 1 == Repo.aggregate(AuditEvent, :count, :id)
    else
      assert_raise Turso.Error, "database is locked", fn -> ForgeIssues.transaction(multi) end
    end
  end

  test "comment validation failures do not audit", %{writer: writer, repository: repository} do
    issue = issue_fixture(repository, writer)

    assert {:error, {:validation, [%{resource: "IssueComment", field: "body", code: :invalid}]}} =
             ForgeIssues.create_comment(
               writer,
               writer.username,
               repository.slug,
               issue.number,
               %{"body" => <<0>>},
               request_metadata()
             )

    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
  end

  test "comment updates require a valid body field and audit only success", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, writer, "Original")

    Enum.each(
      [%{}, %{"unknown" => "value"}, %{"body" => nil}, %{"body" => ""}, %{"body" => <<0>>}],
      fn attrs ->
        assert {:error,
                {:validation, [%{resource: "IssueComment", field: "body", code: :invalid}]}} =
                 ForgeIssues.update_comment(
                   writer,
                   writer.username,
                   repository.slug,
                   comment.id,
                   attrs,
                   request_metadata()
                 )
      end
    )

    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
    assert Repo.get!(Comment, comment.id).body == "Original"

    assert {:ok, %{body: "Updated"}} =
             ForgeIssues.update_comment(
               writer,
               writer.username,
               repository.slug,
               comment.id,
               %{"body" => "Updated"},
               request_metadata()
             )

    assert 1 == Repo.aggregate(AuditEvent, :count, :id)
  end

  test "comment multis recheck repository, identity, and comment state", %{
    writer: writer,
    repository: repository
  } do
    reader = readable_user(repository, "comment-stale-reader")
    issue = issue_fixture(repository, writer)
    comment = insert_comment(issue, reader, "Stale")

    deleted_comment_multi =
      ForgeIssues.update_comment_multi(
        reader,
        repository,
        comment.id,
        %{"body" => "Nope"},
        request_metadata()
      )

    Repo.delete!(comment)

    assert {:error, :authorization, :not_found, %{}} =
             ForgeIssues.transaction(deleted_comment_multi)

    deleted_issue_multi =
      ForgeIssues.create_comment_multi(
        reader,
        repository,
        issue.number,
        %{"body" => "Nope"},
        request_metadata()
      )

    Repo.delete!(issue)

    assert {:error, :authorization, :not_found, %{}} =
             ForgeIssues.transaction(deleted_issue_multi)

    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
  end

  test "comment update and delete return not found when the row disappears after authorization",
       %{
         writer: writer,
         repository: repository
       } do
    issue = issue_fixture(repository, writer)

    Enum.each([:update, :delete], fn operation ->
      comment = insert_comment(issue, writer, "Race #{operation}")

      multi =
        ForgeIssues.comment_mutation_multi(writer, repository, comment.id)
        |> Multi.run(:concurrent_delete, fn repo, %{authorization: %{comment: authorized}} ->
          {:ok, _deleted} = repo.delete(authorized)
          {:ok, :deleted}
        end)
        |> case do
          multi when operation == :update ->
            ForgeIssues.put_comment_update(
              multi,
              %{"body" => "Too late"},
              request_metadata()
            )

          multi ->
            ForgeIssues.put_comment_delete(multi, request_metadata())
        end

      assert {:error, :comment, :not_found, _changes} = ForgeIssues.transaction(multi)
      assert Repo.get(Comment, comment.id)
      assert 0 == Repo.aggregate(AuditEvent, :count, :id)
    end)
  end

  test "comment multis recheck access and repository availability", %{
    writer: writer,
    repository: repository
  } do
    reader = readable_user(repository, "comment-revoked-reader")
    issue = issue_fixture(repository, writer)

    revoked_multi =
      ForgeIssues.create_comment_multi(
        reader,
        repository,
        issue.number,
        %{"body" => "Nope"},
        request_metadata()
      )

    Repo.delete_all(
      from(collaborator in Collaborator,
        # WORKAROUND(upstream): gsmlg-dev/concord#66
        where: fragment("repository_id = ? AND user_id = ?", ^repository.id, ^reader.id)
      )
    )

    assert {:error, :authorization, :not_found, %{}} = ForgeIssues.transaction(revoked_multi)

    repository_multi =
      ForgeIssues.create_comment_multi(
        writer,
        repository,
        issue.number,
        %{"body" => "Nope"},
        request_metadata()
      )

    Repo.update!(
      Ecto.Changeset.change(repository,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    )

    assert {:error, :authorization, :not_found, %{}} = ForgeIssues.transaction(repository_multi)
    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
  end

  test "comment creation multi rechecks issues availability before writing", %{
    writer: writer,
    repository: repository
  } do
    issue = issue_fixture(repository, writer)

    multi =
      ForgeIssues.create_comment_multi(
        writer,
        repository,
        issue.number,
        %{"body" => "Blocked by disabled issues"},
        request_metadata()
      )

    Repo.update!(Ecto.Changeset.change(repository, has_issues: false))

    assert {:error, :authorization, :issues_disabled, %{}} = ForgeIssues.transaction(multi)
    assert 0 == Repo.aggregate(Comment, :count, :id)
    assert 0 == Repo.aggregate(AuditEvent, :count, :id)
  end

  defp issue_fixture(repository, author, title \\ "Relationship test") do
    %Issue{
      repository_id: repository.id,
      number: System.unique_integer([:positive]),
      kind: :issue,
      author_user_id: author.id
    }
    |> Issue.create_changeset(%{title: title})
    |> Repo.insert!()
  end

  defp pull_fixture(repository, author) do
    {:ok, %{pull: pull}} =
      Ecto.Multi.new()
      |> ForgeIssues.insert_numbered_identity(:pull, repository, author, :pull_request, %{
        title: "Pull identity"
      })
      |> ForgeIssues.transaction()

    pull
  end

  defp request_metadata do
    %{
      request_id: "req-issue-1",
      api_version: "2022-11-28",
      ip_address: "192.0.2.10",
      user_agent: "Octokit/9.0",
      token_id: 41
    }
  end

  defp create_issue!(actor, repository, attrs) do
    assert {:ok, issue} =
             ForgeIssues.create(
               actor,
               repository_owner_slug(repository),
               repository.slug,
               attrs,
               request_metadata()
             )

    issue
  end

  defp repository_owner_slug(repository), do: ForgeRepos.repository_owner(repository).username

  defp set_issue_times(issue, inserted_at, updated_at) do
    Repo.update_all(from(row in Issue, where: row.id == ^issue.id),
      set: [inserted_at: inserted_at, updated_at: updated_at]
    )
  end

  defp insert_comments(issue, author, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Comment,
      Enum.map(1..count, fn index ->
        %{
          issue_id: issue.id,
          author_user_id: author.id,
          body: "Comment #{index}",
          inserted_at: now,
          updated_at: now
        }
      end)
    )
  end

  defp insert_comment(issue, author, body) do
    %Comment{}
    |> Comment.changeset(%{issue_id: issue.id, author_user_id: author.id, body: body})
    |> Repo.insert!()
  end

  defp assert_issue_ids(repository, actor, filters, expected_ids) do
    assert {:ok, %Page{entries: entries}} =
             ForgeIssues.list(actor, repository_owner_slug(repository), repository.slug, filters)

    assert Enum.map(entries, & &1.id) == expected_ids
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

  defp grant_write(repository, user) do
    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: user.id, role: :write})
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

  defp relationship_transaction(issue, repository, writer, attrs) do
    Multi.new()
    |> Multi.run(:issue, fn _repo, _changes -> {:ok, issue} end)
    |> ForgeIssues.put_relationship_operations(:issue, repository, writer, attrs, :writer)
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
