defmodule ForgePullsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias Ecto.Adapters.SQL
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel}
  alias ForgePulls.{MergeOperation, PullRequest}
  alias Fornacast.{AuditEvent, OperationLease, Repo}

  @states ~w(prepared merge_written ref_advanced completed failed)

  @expected_contract %{
    "pull_requests" => %{
      columns: %{
        "id" => %{type: :bigint, nullable: false, default: :generated},
        "issue_id" => %{type: :bigint, nullable: false, default: nil},
        "repository_id" => %{type: :bigint, nullable: false, default: nil},
        "head_ref" => %{type: :text, nullable: false, default: nil},
        "base_ref" => %{type: :text, nullable: false, default: nil},
        "head_sha" => %{type: :text, nullable: false, default: nil},
        "base_sha" => %{type: :text, nullable: false, default: nil},
        "mergeable" => %{type: :boolean, nullable: true, default: nil},
        "mergeable_state" => %{type: :text, nullable: true, default: nil},
        "merged_at" => %{type: :timestamp, nullable: true, default: nil, utc: true},
        "merged_by_user_id" => %{type: :bigint, nullable: true, default: nil},
        "merge_commit_sha" => %{type: :text, nullable: true, default: nil},
        "inserted_at" => %{type: :timestamp, nullable: false, default: nil, utc: true},
        "updated_at" => %{type: :timestamp, nullable: false, default: nil, utc: true}
      },
      foreign_keys:
        MapSet.new([
          {"issue_id", "issues", "id", :cascade},
          {"repository_id", "repositories", "id", :cascade},
          {"merged_by_user_id", "users", "id", :nilify}
        ]),
      indexes:
        MapSet.new([
          {false, ["repository_id"]},
          {false, ["repository_id", "base_ref"]},
          {true, ["issue_id"]}
        ]),
      checks: %{}
    },
    "pull_merge_operations" => %{
      columns: %{
        "id" => %{type: :bigint, nullable: false, default: :generated},
        "pull_request_id" => %{type: :bigint, nullable: false, default: nil},
        "repository_id" => %{type: :bigint, nullable: false, default: nil},
        "actor_user_id" => %{type: :bigint, nullable: true, default: nil},
        "request_id" => %{type: :text, nullable: false, default: nil},
        "api_version" => %{type: :text, nullable: true, default: nil},
        "ip_address" => %{type: :text, nullable: true, default: nil},
        "user_agent" => %{type: :text, nullable: true, default: nil},
        "token_id" => %{type: :text, nullable: true, default: nil},
        "base_ref" => %{type: :text, nullable: false, default: nil},
        "head_ref" => %{type: :text, nullable: false, default: nil},
        "expected_base_oid" => %{type: :text, nullable: false, default: nil},
        "expected_head_oid" => %{type: :text, nullable: false, default: nil},
        "merge_oid" => %{type: :text, nullable: true, default: nil},
        "state" => %{type: :text, nullable: false, default: nil},
        "lease_owner" => %{type: :text, nullable: true, default: nil},
        "lease_expires_at" => %{
          type: :timestamp,
          nullable: true,
          default: nil,
          utc: true
        },
        "failure_reason" => %{type: :text, nullable: true, default: nil},
        "lock_version" => %{type: :integer, nullable: false, default: 0},
        "inserted_at" => %{type: :timestamp, nullable: false, default: nil, utc: true},
        "updated_at" => %{type: :timestamp, nullable: false, default: nil, utc: true}
      },
      foreign_keys:
        MapSet.new([
          {"pull_request_id", "pull_requests", "id", :cascade},
          {"repository_id", "repositories", "id", :cascade},
          {"actor_user_id", "users", "id", :nilify}
        ]),
      indexes:
        MapSet.new([
          {false, ["repository_id", "state"]},
          {false, ["pull_request_id", "state"]},
          {false, ["lease_expires_at"]}
        ]),
      checks: %{"state" => MapSet.new(@states)}
    }
  }

  setup do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    :ok
  end

  test "pull request creation accepts the documented Task 2 constructor" do
    attrs = %{
      issue_id: 1,
      repository_id: 10,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40)
    }

    changeset = PullRequest.create_changeset(%PullRequest{}, attrs)

    assert changeset.valid?

    assert %PullRequest{
             issue_id: 1,
             repository_id: 10,
             head_ref: "refs/heads/feature",
             base_ref: "refs/heads/main",
             head_sha: head_sha,
             base_sha: base_sha
           } = Ecto.Changeset.apply_changes(changeset)

    assert head_sha == String.duplicate("a", 40)
    assert base_sha == String.duplicate("b", 40)
  end

  test "changed file pages require aggregate additions and deletions" do
    assert_raise ArgumentError, fn ->
      struct!(ForgePulls.ChangedFilePage,
        entries: [],
        total: 0,
        page: 1,
        per_page: 100,
        truncated: false
      )
    end
  end

  test "browser comparison views authorize reads and retain immutable branch snapshots" do
    owner = user_fixture(unique("pull-compare-owner"))
    reader = user_fixture(unique("pull-compare-reader"))
    outsider = user_fixture(unique("pull-compare-outsider"))
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    {base_oid, commit_oids} = create_comparison_branches!(repository)
    [first_oid, second_oid, head_oid] = commit_oids

    assert {:ok, branches} = ForgePulls.branch_options(repository, reader)
    assert Enum.map(branches, & &1.name) == ["refs/heads/feature", "refs/heads/main"]
    assert {:error, :not_found} = ForgePulls.branch_options(repository, outsider)

    path = ForgeRepos.absolute_storage_path(repository)

    for index <- 0..100 do
      git!(path, ["update-ref", "refs/heads/z-#{index}", base_oid])
    end

    assert {:ok, all_branches} = ForgePulls.branch_options(repository, reader)
    assert length(all_branches) == 103
    assert Enum.any?(all_branches, &(&1.name == "refs/heads/z-100"))

    assert {:ok,
            %ForgePulls.Comparison{
              head_ref: "refs/heads/feature",
              base_ref: "refs/heads/main",
              head_oid: ^head_oid,
              base_oid: ^base_oid,
              analysis: %GitCore.MergeAnalysis{mergeable: true, ahead_by: 3}
            }} = ForgePulls.compare(repository, reader, "feature", "main", [])

    assert {:error, :head_equals_base} =
             ForgePulls.compare(repository, reader, "main", "main", [])

    assert {:ok, pull} = create_pull(repository, reader, "Comparison", "feature", "main")

    for {name, operation} <- [
          branches: fn -> ForgePulls.branch_options(repository, reader) end,
          compare: fn -> ForgePulls.compare(repository, reader, "feature", "main", []) end,
          commits: fn -> ForgePulls.list_commits(repository, pull, reader, []) end,
          files: fn -> ForgePulls.changed_files(repository, pull, reader, []) end,
          list_refresh: fn -> ForgePulls.list_pull_requests(repository, reader, []) end,
          detail_refresh: fn ->
            ForgePulls.get_pull_request(repository, pull.issue.number, reader)
          end
        ] do
      deadline = System.monotonic_time(:millisecond) + 2_000

      assert {:ok, cleanup} =
               GitCore.RepositoryReadLimiter.acquire_cleanup(repository.id, deadline)

      path = ForgeRepos.absolute_storage_path(repository)
      assert :ok = GitCore.invalidate_repository_cache_strict(path)
      parent = self()

      task =
        Task.async(fn ->
          ForgePulls.with_test_read_phase_hook(
            fn -> send(parent, {:git_read_entered, name}) end,
            operation
          )
        end)

      assert Task.yield(task, 30) == nil, "#{name} bypassed cleanup"
      refute_received {:git_read_entered, ^name}
      assert cache_keys_for(path) == MapSet.new(), "#{name} repopulated cache during cleanup"
      assert :ok = GitCore.RepositoryReadLimiter.release(cleanup)
      assert_receive {:git_read_entered, ^name}
      assert {:ok, _result} = Task.await(task)
      refute_receive {:git_read_entered, ^name}, 10
    end

    assert {:ok, %Fornacast.Page{entries: commits, total: 3, page: 1, per_page: 2}} =
             ForgePulls.list_commits(repository, pull, reader, page: 1, per_page: 2)

    assert Enum.map(commits, & &1.oid) == [head_oid, second_oid]

    assert {:ok, %Fornacast.Page{entries: [last], total: 3, page: 2, per_page: 2}} =
             ForgePulls.list_commits(repository, pull, reader, page: 2, per_page: 2)

    assert last.oid == first_oid

    assert {:ok,
            %ForgePulls.ChangedFilePage{
              entries: files,
              total: 2,
              page: 1,
              per_page: 100,
              truncated: false
            }} = ForgePulls.changed_files(repository, pull, reader, page: 1, per_page: 100)

    assert Enum.map(files, & &1.path) == ["lib/added.ex", "lib/changed.ex"]

    assert {:ok,
            %ForgePulls.ChangedFilePage{
              entries: [second_page_file],
              total: 2,
              additions: 2,
              deletions: 1,
              page: 2,
              per_page: 1
            }} = ForgePulls.changed_files(repository, pull, reader, page: 2, per_page: 1)

    assert second_page_file.path == "lib/changed.ex"
    assert second_page_file.additions == 1
    assert second_page_file.deletions == 1

    assert {:ok, %ForgePulls.ChangedFilePage{per_page: 100}} =
             ForgePulls.changed_files(repository, pull, reader, page: 1, per_page: 1_000)

    moved_head = child_commit!(ForgeRepos.absolute_storage_path(repository), head_oid, "moved")

    git!(ForgeRepos.absolute_storage_path(repository), [
      "update-ref",
      "refs/heads/feature",
      moved_head
    ])

    assert {:ok, %Fornacast.Page{entries: [moved | _], total: 4}} =
             ForgePulls.list_commits(repository, pull, reader, page: 1, per_page: 50)

    assert moved.oid == moved_head
    assert {:error, :not_found} = ForgePulls.changed_files(repository, pull, outsider, [])
  end

  test "comparison holds one repository read handle across every Git phase" do
    owner = user_fixture(unique("pull-single-read-owner"))
    repository = repository_fixture(owner)
    create_comparison_branches!(repository)

    {result, query_count} =
      count_repo_queries(fn ->
        ForgePulls.with_test_read_phase_hook(
          fn ->
            cleanup =
              Task.async(fn ->
                deadline = System.monotonic_time(:millisecond) + 2_000
                GitCore.RepositoryReadLimiter.acquire_cleanup(repository.id, deadline)
              end)

            Process.put({__MODULE__, :queued_cleanup}, cleanup)
            assert Task.yield(cleanup, 30) == nil
          end,
          fn -> ForgePulls.compare(repository, owner, "feature", "main", []) end
        )
      end)

    assert {:ok, %ForgePulls.Comparison{}} = result
    # Authorization/context plus one exact repository-generation reload.
    assert query_count <= 4
    cleanup = Process.delete({__MODULE__, :queued_cleanup})
    assert {:ok, cleanup_lease} = Task.await(cleanup)
    assert :ok = GitCore.RepositoryReadLimiter.release(cleanup_lease)
  end

  test "fully loaded pulls expose canonical issues analysis and reader-specific capabilities" do
    owner = user_fixture(unique("pull-caps-owner"))
    author = user_fixture(unique("pull-caps-author"))
    writer = user_fixture(unique("pull-caps-writer"))
    repository = repository_fixture(owner)
    grant_reader!(repository, author)
    grant_writer!(repository, writer)
    create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, author, "Capabilities", "feature", "main")

    assert {:ok, author_view} =
             ForgePulls.get_pull_request(repository, pull.issue.number, author)

    assert %Issue{id: issue_id, capabilities: issue_capabilities} = author_view.issue
    assert issue_id == pull.issue_id
    assert %GitCore.MergeAnalysis{mergeable: true} = author_view.analysis

    assert author_view.capabilities ==
             Map.take(issue_capabilities, [:can_edit, :can_close, :can_comment])
             |> Map.put(:can_merge, false)

    assert {:ok, %Fornacast.Page{entries: [listed]}} =
             ForgePulls.list_pull_requests(repository, author)

    assert %Issue{id: ^issue_id} = listed.issue
    assert %GitCore.MergeAnalysis{mergeable: true} = listed.analysis

    assert Map.keys(listed.capabilities) |> Enum.sort() ==
             [:can_close, :can_comment, :can_edit, :can_merge]

    assert {:ok, writer_view} = ForgePulls.get_pull_request(repository, pull.issue.number, writer)
    assert writer_view.capabilities.can_merge

    merge_disabled =
      repository |> Ecto.Changeset.change(allow_merge_commit: false) |> Repo.update!()

    assert {:ok, merge_disabled_view} =
             ForgePulls.get_pull_request(merge_disabled, pull.issue.number, writer)

    refute merge_disabled_view.capabilities.can_merge

    repository =
      merge_disabled |> Ecto.Changeset.change(allow_merge_commit: true) |> Repo.update!()

    public_repository = repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()

    assert {:ok, anonymous_view} =
             ForgePulls.get_pull_request(public_repository, pull.issue.number, nil)

    refute Enum.any?(anonymous_view.capabilities, fn {_key, allowed?} -> allowed? end)

    assert {:ok, closed} =
             ForgePulls.update_pull_request(repository, pull, author, %{state: :closed}, %{})

    assert {:ok, closed_view} =
             ForgePulls.get_pull_request(repository, closed.issue.number, owner)

    refute closed_view.capabilities.can_merge

    Repo.update_all(from(candidate in PullRequest, where: candidate.id == ^pull.id),
      set: [merged_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert {:ok, merged_view} =
             ForgePulls.get_pull_request(repository, pull.issue.number, owner)

    refute merged_view.capabilities.can_merge

    conflicting_repository = repository_fixture(owner)
    create_conflicting_branches!(conflicting_repository)

    assert {:ok, conflicting_pull} =
             create_pull(conflicting_repository, owner, "Conflict", "feature", "main")

    assert {:ok, conflicting_view} =
             ForgePulls.get_pull_request(
               conflicting_repository,
               conflicting_pull.issue.number,
               owner
             )

    refute conflicting_view.analysis.mergeable
    refute conflicting_view.capabilities.can_merge

    git!(ForgeRepos.absolute_storage_path(conflicting_repository), [
      "update-ref",
      "-d",
      "refs/heads/feature"
    ])

    assert {:ok, %Fornacast.Page{entries: [listed_conflict]}} =
             ForgePulls.list_pull_requests(conflicting_repository, owner)

    refute listed_conflict.analysis.mergeable
    refute listed_conflict.capabilities.can_merge
  end

  test "a reader opens a pull with the next canonical issue identity and only shared title and body" do
    suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    owner = user_fixture("pull-owner-#{suffix}")
    reader = user_fixture("pull-reader-#{suffix}")
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    create_branch!(repository, "main")
    create_branch!(repository, "feature/x")

    assert {:ok, issue} =
             ForgeIssues.create(
               owner,
               owner.username,
               repository.slug,
               %{title: "Shared issue"},
               %{}
             )

    assert issue.number == 1

    attrs = %{
      title: "Add feature",
      body: "description",
      state: :closed,
      state_reason: :not_planned,
      labels: ["bug"],
      head: "feature/x",
      base: "main"
    }

    assert {:ok, pull} = ForgePulls.create_pull_request(repository, reader, attrs, %{})

    assert %PullRequest{
             head_ref: "refs/heads/feature/x",
             base_ref: "refs/heads/main",
             mergeable: nil,
             mergeable_state: :unknown
           } = pull

    assert %Issue{
             number: 2,
             kind: :pull_request,
             title: "Add feature",
             body: "description",
             state: :open,
             state_reason: nil,
             labels: []
           } = pull.issue
  end

  test "bare and case-normalized personal owner-qualified heads resolve in the target repository" do
    owner = user_fixture(unique("pull-personal-owner"))
    reader = user_fixture(unique("pull-personal-reader"))
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    create_branch!(repository, "main")
    create_branch!(repository, "bare")
    create_branch!(repository, "qualified")

    assert {:ok, bare} =
             create_pull(repository, reader, "Bare", "bare", "main")

    assert bare.head_ref == "refs/heads/bare"

    assert {:ok, qualified} =
             create_pull(
               repository,
               reader,
               "Qualified",
               "#{String.upcase(owner.username)}:qualified",
               "main"
             )

    assert qualified.head_ref == "refs/heads/qualified"
  end

  test "case-normalized organization-qualified heads require the target organization identity" do
    manager = user_fixture(unique("pull-org-manager"))
    reader = user_fixture(unique("pull-org-reader"))
    foreign_owner = user_fixture(unique("pull-foreign-owner"))
    organization = organization_fixture(manager, unique("pull-org"))
    foreign_organization = organization_fixture(foreign_owner, unique("pull-foreign-org"))
    repository = repository_fixture(organization)
    grant_reader!(repository, reader)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")

    assert {:ok, pull} =
             create_pull(
               repository,
               reader,
               "Organization",
               "#{String.upcase(organization.username)}:feature",
               "main"
             )

    assert pull.head_ref == "refs/heads/feature"

    assert {:error, :cross_repository_head} =
             create_pull(
               repository,
               reader,
               "Foreign organization",
               "#{foreign_organization.username}:feature",
               "main"
             )

    assert {:error, :cross_repository_head} =
             create_pull(
               repository,
               reader,
               "Foreign user",
               "#{foreign_owner.username}:feature",
               "main"
             )
  end

  test "missing equal foreign and nonexistent pull refs return stable errors" do
    owner = user_fixture(unique("pull-ref-owner"))
    reader = user_fixture(unique("pull-ref-reader"))
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    create_branch!(repository, "main")
    create_branch!(repository, "feature/x")

    assert {:error, :invalid_head} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing", base: "main"},
               %{}
             )

    assert {:error, :invalid_base} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing", head: "feature/x"},
               %{}
             )

    assert {:error, :head_equals_base} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "same", head: "main", base: "main"},
               %{}
             )

    assert {:error, :cross_repository_head} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "foreign", head: "other:feature/x", base: "main"},
               %{}
             )

    assert {:error, :invalid_head} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing ref", head: "missing", base: "main"},
               %{}
             )

    assert {:error, :invalid_base} =
             ForgePulls.create_pull_request(
               repository,
               reader,
               %{title: "missing ref", head: "feature/x", base: "missing"},
               %{}
             )
  end

  test "Git snapshot failures retain their typed unavailable reason" do
    owner = user_fixture(unique("pull-git-error-owner"))
    repository = repository_fixture(owner)

    missing_storage = "missing/#{System.unique_integer([:positive, :monotonic])}.git"

    Repo.update_all(from(repo in ForgeRepos.Repository, where: repo.id == ^repository.id),
      set: [storage_path: missing_storage]
    )

    assert {:error, {:unavailable, reason}} =
             create_pull(repository, owner, "Unavailable", "feature", "main")

    assert reason in [:invalid_repository, :storage_unavailable, :corrupt_repository]
  end

  test "a forced pull insert constraint failure rolls back the issue identity audit and number" do
    owner = user_fixture(unique("pull-rollback-owner"))
    repository = repository_fixture(owner)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    refs = resolved_pair(repository, "feature", "main")

    failed_multi =
      owner
      |> ForgePulls.Mutations.create_multi(
        repository,
        %{title: "Rolled back", head: "feature", base: "main"},
        refs,
        request_metadata("pull-rollback")
      )
      |> Multi.insert(:duplicate_pull, fn %{pull_request: pull} ->
        %PullRequest{}
        |> PullRequest.create_changeset(%{
          issue_id: pull.issue_id,
          repository_id: repository.id,
          head_ref: pull.head_ref,
          base_ref: pull.base_ref,
          head_sha: pull.head_sha,
          base_sha: pull.base_sha
        })
        |> Ecto.Changeset.unique_constraint(:issue_id,
          name: ~r/^pull_requests_issue_id(?: \(\d+\))?_index$/
        )
      end)

    assert {:error, :duplicate_pull, %Ecto.Changeset{}, _changes} =
             ForgeIssues.transaction(failed_multi)

    refute Repo.get_by(Issue, repository_id: repository.id, title: "Rolled back")
    refute Repo.get_by(AuditEvent, action: "pull_request.created", target_id: "#{repository.id}")

    assert {:ok, pull} = create_pull(repository, owner, "Committed", "feature", "main")
    assert pull.issue.number == 1
  end

  test "simultaneous public issue and pull creates share unique consecutive numbers" do
    {owner, repository} = independent_pull_concurrency_fixture()
    create_branch!(repository, "main")

    Enum.each(1..4, fn index -> create_branch!(repository, "feature-#{index}") end)

    parent = self()
    ready_ref = make_ref()
    worker_count = 8

    tasks =
      Enum.map(1..worker_count, fn index ->
        Task.async(fn ->
          backend_pid = independent_pull_connection!(ready_ref, parent)

          receive do
            {:go, ^ready_ref} ->
              result =
                if rem(index, 2) == 0 do
                  ForgeIssues.create(
                    owner,
                    owner.username,
                    repository.slug,
                    %{title: "Issue #{index}"},
                    %{}
                  )
                else
                  create_pull(
                    repository,
                    owner,
                    "Pull #{index}",
                    "feature-#{div(index + 1, 2)}",
                    "main"
                  )
                end

              independent_pull_checkin()
              {result, backend_pid}
          end
        end)
      end)

    backend_pids = await_independent_pull_workers(tasks, ready_ref)

    if database_adapter() == :postgres,
      do: assert(MapSet.size(MapSet.new(backend_pids)) > 1)

    Enum.each(tasks, &send(&1.pid, {:go, ready_ref}))

    numbers =
      tasks
      |> Enum.map(&Task.await(&1, 30_000))
      |> Enum.map(fn
        {{:ok, %PullRequest{issue: issue}}, _backend_pid} -> issue.number
        {{:ok, %Issue{} = issue}, _backend_pid} -> issue.number
      end)
      |> Enum.sort()

    assert numbers == Enum.to_list(1..worker_count)
  end

  test "updates keep source repository and head immutable and refresh an existing base snapshot" do
    owner = user_fixture(unique("pull-update-owner"))
    repository = repository_fixture(owner)
    create_branch!(repository, "main")
    create_branch!(repository, "release")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, owner, "Update", "feature", "main")

    assert {:error, :invalid_head} =
             ForgePulls.update_pull_request(repository, pull, owner, %{head: "release"}, %{})

    assert {:error, {:validation, [repository_error]}} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               owner,
               %{repository_id: repository.id + 1},
               %{}
             )

    assert repository_error == %{
             resource: "PullRequest",
             field: "repository",
             code: :invalid
           }

    assert {:error, :invalid_base} =
             ForgePulls.update_pull_request(repository, pull, owner, %{base: "missing"}, %{})

    assert {:ok, updated} =
             ForgePulls.update_pull_request(repository, pull, owner, %{base: "release"}, %{})

    assert updated.head_ref == pull.head_ref
    assert updated.base_ref == "refs/heads/release"
    assert updated.head_sha == snapshot_oid(repository, "feature")
    assert updated.base_sha == snapshot_oid(repository, "release")
    assert updated.mergeable == nil
    assert updated.mergeable_state == :unknown

    foreign_repository = repository_fixture(owner)

    assert {:error, :not_found} =
             ForgePulls.update_pull_request(
               foreign_repository,
               updated,
               owner,
               %{title: "No"},
               %{}
             )
  end

  test "authors and writers close and reopen pulls with public string states and derived reasons" do
    owner = user_fixture(unique("pull-policy-owner"))
    author = user_fixture(unique("pull-policy-author"))
    writer = user_fixture(unique("pull-policy-writer"))
    unrelated = user_fixture(unique("pull-policy-unrelated"))
    repository = repository_fixture(owner)
    grant_reader!(repository, author)
    grant_writer!(repository, writer)
    grant_reader!(repository, unrelated)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, author, "Policy", "feature", "main")

    assert {:ok, author_update} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               author,
               %{"title" => "Author edit", "body" => "body", "state" => "closed"},
               %{}
             )

    assert author_update.issue.title == "Author edit"
    assert author_update.issue.state == :closed
    assert author_update.issue.state_reason == :completed

    assert {:ok, author_unchanged} =
             ForgePulls.update_pull_request(
               repository,
               author_update,
               author,
               %{"state" => "closed"},
               %{}
             )

    assert author_unchanged.issue.state_reason == :completed

    assert {:ok, author_reopen} =
             ForgePulls.update_pull_request(
               repository,
               author_unchanged,
               author,
               %{"state" => "open"},
               %{}
             )

    assert author_reopen.issue.state == :open
    assert author_reopen.issue.state_reason == :reopened

    assert {:ok, writer_close} =
             ForgePulls.update_pull_request(
               repository,
               author_reopen,
               writer,
               %{"state" => "closed"},
               %{}
             )

    assert writer_close.issue.state == :closed
    assert writer_close.issue.state_reason == :completed

    assert {:ok, writer_update} =
             ForgePulls.update_pull_request(
               repository,
               writer_close,
               writer,
               %{"title" => "Writer edit", "state" => "open"},
               %{}
             )

    assert writer_update.issue.title == "Writer edit"
    assert writer_update.issue.state == :open
    assert writer_update.issue.state_reason == :reopened

    assert {:ok, writer_unchanged} =
             ForgePulls.update_pull_request(
               repository,
               writer_update,
               writer,
               %{"state" => "open"},
               %{}
             )

    assert writer_unchanged.issue.state_reason == :reopened

    assert {:error, :forbidden} =
             ForgePulls.update_pull_request(
               repository,
               writer_unchanged,
               unrelated,
               %{head: "immutable", base: "missing"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgePulls.update_pull_request(
               %{repository | storage_path: "missing/corrupt.git"},
               %{writer_unchanged | head_ref: "corrupt"},
               unrelated,
               %{base: "missing"},
               %{}
             )
  end

  test "pull state updates accept atom equivalents ignore internal reasons and reject other values" do
    owner = user_fixture(unique("pull-state-owner"))
    repository = repository_fixture(owner)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, owner, "States", "feature", "main")

    assert {:ok, closed} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               owner,
               %{state: :closed, state_reason: :not_planned},
               %{}
             )

    assert closed.issue.state == :closed
    assert closed.issue.state_reason == :completed

    assert {:ok, reopened} =
             ForgePulls.update_pull_request(repository, closed, owner, %{state: :open}, %{})

    assert reopened.issue.state == :open
    assert reopened.issue.state_reason == :reopened

    for invalid_state <- ["merged", :merged, nil] do
      assert {:error, {:validation, [%{resource: "PullRequest", field: "state", code: :invalid}]}} =
               ForgePulls.update_pull_request(
                 repository,
                 reopened,
                 owner,
                 %{"state" => invalid_state},
                 %{}
               )
    end
  end

  test "mutations revalidate disabled and revoked actors and deleted repositories inside the transaction" do
    owner = user_fixture(unique("pull-stale-owner"))
    author = user_fixture(unique("pull-stale-author"))
    writer = user_fixture(unique("pull-stale-writer"))
    repository = repository_fixture(owner)
    grant_reader!(repository, author)
    writer_collaborator = grant_writer!(repository, writer)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, author, "Stale", "feature", "main")

    author
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert {:error, :forbidden} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               author,
               %{title: "Disabled"},
               %{}
             )

    public_repository = repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()
    Repo.delete!(writer_collaborator)

    assert {:error, :forbidden} =
             ForgePulls.update_pull_request(
               public_repository,
               pull,
               writer,
               %{title: "Revoked"},
               %{}
             )

    Repo.update_all(from(user in ForgeAccounts.User, where: user.id == ^author.id),
      set: [state: :active]
    )

    owner
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgePulls.update_pull_request(
               public_repository,
               pull,
               author,
               %{title: "Inactive owner"},
               %{}
             )

    Repo.update_all(from(user in ForgeAccounts.User, where: user.id == ^owner.id),
      set: [state: :active]
    )

    Repo.update_all(
      from(repo in ForgeRepos.Repository, where: repo.id == ^repository.id),
      set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert {:error, :not_found} =
             ForgePulls.update_pull_request(
               public_repository,
               pull,
               owner,
               %{title: "Deleted"},
               %{}
             )
  end

  test "reads reload repository owner actor visibility and deletion before pull queries" do
    owner = user_fixture(unique("pull-read-owner"))
    reader = user_fixture(unique("pull-read-reader"))
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, owner, "Canonical read", "feature", "main")

    stale_public = repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()

    Repo.update_all(from(repo in ForgeRepos.Repository, where: repo.id == ^repository.id),
      set: [visibility: :private]
    )

    assert {:error, :not_found} = ForgePulls.list_pull_requests(stale_public, nil)

    assert {:error, :not_found} =
             ForgePulls.get_pull_request(stale_public, pull.issue.number, nil)

    assert {:error, :not_found} =
             ForgePulls.pull_links_for_issue_ids(stale_public, [pull.issue_id], nil)

    reader
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert {:error, :not_found} = ForgePulls.list_pull_requests(repository, reader)

    assert {:error, :not_found} =
             ForgePulls.get_pull_request(repository, pull.issue.number, reader)

    assert {:error, :not_found} =
             ForgePulls.pull_links_for_issue_ids(repository, [pull.issue_id], reader)

    Repo.update_all(from(repo in ForgeRepos.Repository, where: repo.id == ^repository.id),
      set: [visibility: :public]
    )

    owner
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    current_public = %{repository | visibility: :public}
    assert {:error, :not_found} = ForgePulls.list_pull_requests(current_public, nil)

    Repo.update_all(from(user in ForgeAccounts.User, where: user.id == ^owner.id),
      set: [state: :active]
    )

    Repo.update_all(from(repo in ForgeRepos.Repository, where: repo.id == ^repository.id),
      set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert {:error, :not_found} = ForgePulls.list_pull_requests(current_public, nil)
  end

  test "detail refreshes one immutable pair clears old mergeability and loads full canonical issue metadata" do
    owner = user_fixture(unique("pull-detail-owner"))
    assignee = user_fixture(unique("pull-detail-assignee"))
    repository = repository_fixture(owner)
    grant_reader!(repository, assignee)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, owner, "Detail", "feature", "main")

    label = ForgeIssues.list_labels(repository) |> hd()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%IssueLabel{
      issue_id: pull.issue_id,
      label_id: label.id,
      inserted_at: now,
      updated_at: now
    })

    Repo.insert!(%IssueAssignee{
      issue_id: pull.issue_id,
      user_id: assignee.id,
      inserted_at: now,
      updated_at: now
    })

    Repo.insert!(%Comment{
      issue_id: pull.issue_id,
      author_user_id: assignee.id,
      body: "canonical comment",
      inserted_at: now,
      updated_at: now
    })

    pull
    |> PullRequest.update_changeset(%{mergeable: true, mergeable_state: :mergeable})
    |> Repo.update!()

    old_head_sha = pull.head_sha
    create_branch!(repository, "feature")

    assert {:ok, refreshed} =
             ForgePulls.get_pull_request(repository, pull.issue.number, owner)

    refute refreshed.head_sha == old_head_sha
    assert refreshed.head_sha == snapshot_oid(repository, "feature")
    assert refreshed.base_sha == snapshot_oid(repository, "main")
    assert refreshed.mergeable == nil
    assert refreshed.mergeable_state == :unknown
    assert refreshed.issue.id == pull.issue_id
    assert refreshed.issue.title == "Detail"
    assert refreshed.issue.author.id == owner.id
    assert refreshed.issue.author_association == "OWNER"
    assert [%{id: label_id}] = refreshed.issue.labels
    assert label_id == label.id
    assert [%{id: assignee_id}] = refreshed.issue.assignees
    assert assignee_id == assignee.id
    assert refreshed.issue.comment_count == 1
  end

  test "list accepts canonical states and sorts by issue timestamps popularity and stable IDs" do
    owner = user_fixture(unique("pull-list-owner"))
    repository = repository_fixture(owner)
    create_branch!(repository, "main")
    Enum.each(~w(alpha beta gamma), &create_branch!(repository, &1))
    assert {:ok, alpha} = create_pull(repository, owner, "Alpha", "alpha", "main")
    assert {:ok, beta} = create_pull(repository, owner, "Beta", "beta", "main")
    assert {:ok, gamma} = create_pull(repository, owner, "Gamma", "gamma", "main")

    assert {:ok, gamma} =
             ForgePulls.update_pull_request(
               repository,
               gamma,
               owner,
               %{state: :closed},
               %{}
             )

    early = ~U[2026-01-01 00:00:00Z]
    late = ~U[2026-01-02 00:00:00Z]

    Repo.update_all(from(issue in Issue, where: issue.id in ^[alpha.issue_id, beta.issue_id]),
      set: [inserted_at: early, updated_at: late]
    )

    Repo.update_all(from(issue in Issue, where: issue.id == ^gamma.issue_id),
      set: [inserted_at: late, updated_at: early]
    )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {issue_id, body} <- [
          {alpha.issue_id, "alpha one"},
          {alpha.issue_id, "alpha two"},
          {gamma.issue_id, "gamma one"}
        ] do
      Repo.insert!(%Comment{
        issue_id: issue_id,
        author_user_id: owner.id,
        body: body,
        inserted_at: now,
        updated_at: now
      })
    end

    assert {:ok, %{entries: [first], total: 2, page: 1, per_page: 1}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :open,
               sort: :created,
               direction: :asc,
               page: 1,
               per_page: 1
             )

    assert first.id == alpha.id

    assert {:ok, %{entries: [second], total: 2}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :open,
               sort: :created,
               direction: :asc,
               page: 2,
               per_page: 1
             )

    assert second.id == beta.id

    assert {:ok, %{entries: [updated_first, updated_second]}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :open,
               sort: :updated,
               direction: :desc
             )

    assert [updated_first.id, updated_second.id] == [beta.id, alpha.id]

    assert {:ok, %{entries: [popular_first, popular_second]}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :open,
               sort: :popularity,
               direction: :desc
             )

    assert [popular_first.id, popular_second.id] == [alpha.id, beta.id]

    assert {:ok, %{entries: [quiet_first, quiet_second]}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: "open",
               sort: "popularity"
             )

    assert [quiet_first.id, quiet_second.id] == [beta.id, alpha.id]

    assert {:ok, %{entries: [long_first, long_second]}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :open,
               sort: "long-running"
             )

    assert [long_first.id, long_second.id] == [alpha.id, beta.id]

    assert {:ok, %{entries: all_entries, total: 3}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :all,
               sort: :long_running,
               direction: :asc
             )

    assert Enum.map(all_entries, & &1.id) == [alpha.id, beta.id, gamma.id]

    assert {:ok, %{entries: [head_only]}} =
             ForgePulls.list_pull_requests(repository, owner,
               state: :closed,
               head: "#{String.upcase(owner.username)}:gamma",
               base: "main"
             )

    assert head_only.id == gamma.id

    public_repository = repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()

    {result, query_count} =
      count_repo_queries(fn ->
        ForgePulls.list_pull_requests(public_repository, nil,
          state: :open,
          sort: :created,
          direction: :asc
        )
      end)

    assert {:ok, %{entries: [_, _], total: 2}} = result
    # One exact repository-generation reload is part of opening the read lease.
    assert query_count <= 12

    for {field, filters} <- [
          {"state", [state: :merged]},
          {"state", [state: "merged"]},
          {"sort", [sort: :number]},
          {"sort", [sort: "number"]},
          {"sort", [sort: "long_running"]},
          {"direction", [direction: :sideways]},
          {"direction", [direction: "sideways"]}
        ] do
      assert {:error, {:validation, [%{resource: "PullRequest", field: ^field, code: :invalid}]}} =
               ForgePulls.list_pull_requests(repository, owner, filters)
    end

    assert {:error, {:validation, [_]}} = ForgePulls.list_pull_requests(repository, owner, %{})
  end

  test "conditional snapshot persistence rejects stale OIDs when ref names are unchanged" do
    owner = user_fixture(unique("pull-race-owner"))
    repository = repository_fixture(owner)
    Enum.each(~w(main release feature), &create_branch!(repository, &1))
    assert {:ok, pull} = create_pull(repository, owner, "Race", "feature", "main")

    stale_attrs =
      repository
      |> resolved_pair("feature", "main")
      |> Map.merge(%{head_sha: String.duplicate("1", 40), base_sha: String.duplicate("2", 40)})

    fresh_attrs =
      repository
      |> resolved_pair("feature", "main")
      |> Map.merge(%{head_sha: String.duplicate("3", 40), base_sha: String.duplicate("4", 40)})

    assert {:ok, raced} = ForgePulls.SnapshotRefresh.persist(pull, fresh_attrs)
    assert raced.head_ref == pull.head_ref
    assert raced.base_ref == pull.base_ref

    assert {:error, :ref_conflict} =
             ForgePulls.SnapshotRefresh.persist(pull, stale_attrs)

    assert {:error, :ref_conflict} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               owner,
               %{title: "Stale mutation"},
               %{}
             )

    stored = Repo.get!(PullRequest, pull.id)
    assert stored.head_ref == fresh_attrs.head_ref
    assert stored.base_ref == fresh_attrs.base_ref
    assert stored.head_sha == fresh_attrs.head_sha
    assert stored.base_sha == fresh_attrs.base_sha
    assert stored.mergeable == nil
    assert stored.mergeable_state == :unknown
  end

  test "successful create and update write exact audits while validation authorization and later failure write none" do
    owner = user_fixture(unique("pull-audit-owner"))
    outsider = user_fixture(unique("pull-audit-outsider"))
    repository = repository_fixture(owner)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")

    metadata = %{
      "request_id" => "pull-audit-success",
      "ip_address" => "203.0.113.44",
      request_id: "ignored-atom-request",
      api_version: "2026-03-10",
      ip_address: "198.51.100.9",
      user_agent: "forge-pulls-test",
      token_id: 42,
      repository_id: -1,
      token: "secret-token",
      password: "secret-password",
      body: "secret-body",
      unknown: "discard-me"
    }

    assert {:ok, pull} =
             ForgePulls.create_pull_request(
               repository,
               owner,
               %{title: "Audited", head: "feature", base: "main"},
               metadata
             )

    assert %AuditEvent{
             actor_user_id: actor_id,
             action: "pull_request.created",
             target_type: "repository",
             target_id: target_id,
             metadata: audit_metadata,
             ip_address: "203.0.113.44",
             user_agent: "forge-pulls-test"
           } =
             Repo.get_by!(AuditEvent,
               action: "pull_request.created",
               target_id: Integer.to_string(repository.id)
             )

    assert actor_id == owner.id
    assert target_id == Integer.to_string(repository.id)
    assert audit_metadata["repository_id"] == repository.id
    assert audit_metadata["result"] == "success"
    assert audit_metadata["request_id"] == "pull-audit-success"
    assert audit_metadata["api_version"] == "2026-03-10"
    assert audit_metadata["token_id"] == 42

    assert Map.keys(audit_metadata) |> Enum.sort() ==
             ~w(api_version ip_address repository_id request_id result token_id user_agent)

    refute audit_metadata["token"]
    refute audit_metadata["password"]
    refute audit_metadata["body"]
    refute audit_metadata["unknown"]

    assert {:ok, _updated} =
             ForgePulls.update_pull_request(
               repository,
               pull,
               owner,
               %{title: "Audited update"},
               %{
                 "request_id" => "pull-audit-update",
                 "repository_id" => -2,
                 "token" => "update-secret"
               }
             )

    assert %AuditEvent{metadata: update_metadata} =
             Repo.get_by!(AuditEvent,
               action: "pull_request.updated",
               target_id: Integer.to_string(repository.id)
             )

    assert update_metadata == %{
             "repository_id" => repository.id,
             "request_id" => "pull-audit-update",
             "result" => "success"
           }

    before_count = pull_audit_count(repository)

    assert {:error, {:validation, _errors}} =
             ForgePulls.create_pull_request(
               repository,
               owner,
               %{head: "feature", base: "main"},
               request_metadata("pull-audit-validation")
             )

    assert {:error, :not_found} =
             ForgePulls.create_pull_request(
               repository,
               outsider,
               %{title: "Forbidden", head: "feature", base: "main"},
               request_metadata("pull-audit-forbidden")
             )

    refs = resolved_pair(repository, "feature", "main")

    forced =
      owner
      |> ForgePulls.Mutations.create_multi(
        repository,
        %{title: "Forced", head: "feature", base: "main"},
        refs,
        request_metadata("pull-audit-forced")
      )
      |> Multi.run(:forced_later_failure, fn _repo, _changes ->
        {:error, :forced_later_failure}
      end)

    assert {:error, :forced_later_failure, :forced_later_failure, _changes} =
             ForgeIssues.transaction(forced)

    assert pull_audit_count(repository) == before_count
    refute Repo.get_by(Issue, repository_id: repository.id, title: "Forced")
  end

  test "pull links handle empty subset duplicate mixed repository IDs masking and bounded queries" do
    owner = user_fixture(unique("pull-links-owner"))
    repository = repository_fixture(owner)
    other_repository = repository_fixture(owner)

    Enum.each([repository, other_repository], fn repo ->
      create_branch!(repo, "main")
      create_branch!(repo, "feature")
    end)

    assert {:ok, first} = create_pull(repository, owner, "First", "feature", "main")
    create_branch!(repository, "second")
    assert {:ok, second} = create_pull(repository, owner, "Second", "second", "main")
    assert {:ok, foreign} = create_pull(other_repository, owner, "Foreign", "feature", "main")
    merged_at = ~U[2026-01-03 00:00:00Z]

    Repo.update_all(from(pull in PullRequest, where: pull.id == ^first.id),
      set: [merged_at: merged_at]
    )

    public_repository = repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()

    assert {:ok, %{}} = ForgePulls.pull_links_for_issue_ids(public_repository, [], nil)

    {result, query_count} =
      count_repo_queries(fn ->
        ForgePulls.pull_links_for_issue_ids(
          public_repository,
          [first.issue_id, first.issue_id, foreign.issue_id, 9_999_999],
          nil
        )
      end)

    first_issue_id = first.issue_id
    assert {:ok, %{^first_issue_id => %{merged_at: ^merged_at}}} = result
    assert query_count == 3

    second_issue_id = second.issue_id

    assert {:ok, %{^second_issue_id => %{merged_at: nil}}} =
             ForgePulls.pull_links_for_issue_ids(public_repository, [second.issue_id], nil)

    assert {:error, :not_found} =
             ForgePulls.pull_links_for_issue_ids(other_repository, [foreign.issue_id], nil)
  end

  test "merged? reconciles nonterminal operations, reports persisted state, and masks inaccessible pulls" do
    owner = user_fixture(unique("pull-merged-owner"))
    outsider = user_fixture(unique("pull-merged-outsider"))
    repository = repository_fixture(owner)
    create_branch!(repository, "main")
    create_branch!(repository, "feature")
    assert {:ok, pull} = create_pull(repository, owner, "Merged state", "feature", "main")

    {settled_result, settled_queries} =
      count_repo_queries(fn -> ForgePulls.merged?(repository, pull, owner) end)

    assert {:ok, false} = settled_result
    assert {:error, :not_found} = ForgePulls.merged?(repository, pull, outsider)

    pending =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: pull.id,
        repository_id: repository.id,
        actor_user_id: owner.id,
        request_id: unique("merged-check-pending"),
        base_ref: pull.base_ref,
        head_ref: pull.head_ref,
        expected_base_oid: pull.base_sha,
        expected_head_oid: pull.head_sha,
        state: :prepared
      })
      |> Repo.insert!()

    {pending_result, pending_queries} =
      count_repo_queries(fn -> ForgePulls.merged?(repository, pull, owner) end)

    assert {:ok, false} = pending_result
    assert pending_queries > settled_queries
    Repo.delete!(pending)

    merged_at = ~U[2026-07-21 00:00:00Z]

    Repo.update_all(from(candidate in PullRequest, where: candidate.id == ^pull.id),
      set: [merged_at: merged_at, merge_commit_sha: String.duplicate("c", 40)]
    )

    assert {:ok, true} = ForgePulls.merged?(repository, pull, owner)
  end

  test "pull requests require distinct canonical branch refs and immutable repository identity" do
    pull = %PullRequest{repository_id: 10}

    changeset =
      PullRequest.create_changeset(pull, %{
        issue_id: 1,
        repository_id: 11,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{repository_id: ["is immutable"]} = errors_on(changeset)

    invalid_ref =
      PullRequest.create_changeset(%PullRequest{repository_id: 10}, %{
        issue_id: 1,
        head_ref: "feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(invalid_ref)

    equal_refs =
      PullRequest.create_changeset(%PullRequest{repository_id: 10}, %{
        issue_id: 1,
        head_ref: "refs/heads/main",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{base_ref: ["must differ from head ref"]} = errors_on(equal_refs)
  end

  test "pull requests accept valid Unicode nested branches and reject Git-invalid ref forms" do
    valid_refs = ["refs/heads/feature/東京", "refs/heads/release/v1", "refs/heads/feature-v1"]

    for ref <- valid_refs do
      changeset =
        PullRequest.create_changeset(
          %PullRequest{repository_id: 10},
          valid_pull_attrs(%{head_ref: ref})
        )

      refute Map.has_key?(errors_on(changeset), :head_ref)
    end

    invalid_refs = [
      "refs/heads/..",
      "refs/heads/feature..next",
      "refs/heads/feature name",
      "refs/heads/feature\nnext",
      "refs/heads/feature~next",
      "refs/heads/feature^next",
      "refs/heads/feature:next",
      "refs/heads/feature?next",
      "refs/heads/feature*next",
      "refs/heads/feature[next",
      "refs/heads/feature\\next",
      "refs/heads/feature@{next",
      "refs/heads//feature",
      "refs/heads/feature/",
      "refs/heads/./feature",
      "refs/heads/feature/../next",
      "refs/heads/.hidden",
      "refs/heads/feature/.hidden",
      "refs/heads/feature.",
      "refs/heads/feature.lock"
    ]

    for ref <- invalid_refs do
      changeset =
        PullRequest.create_changeset(
          %PullRequest{repository_id: 10},
          valid_pull_attrs(%{head_ref: ref})
        )

      assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(changeset)
    end
  end

  test "pull request creation rejects persisted structs without applying mutable snapshots" do
    pull = %PullRequest{
      id: 42,
      issue_id: 1,
      repository_id: 10,
      head_ref: "refs/heads/original",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40)
    }

    changeset =
      PullRequest.create_changeset(
        pull,
        valid_pull_attrs(%{
          issue_id: 2,
          repository_id: 11,
          head_ref: "refs/heads/replacement",
          base_ref: "refs/heads/release",
          head_sha: String.duplicate("c", 40),
          base_sha: String.duplicate("d", 40)
        })
      )

    assert %{base: ["cannot create a persisted pull request"]} = errors_on(changeset)
    assert changeset.changes == %{}
  end

  test "a writer merges the resolved snapshots through a durable two-parent ref CAS" do
    owner = user_fixture(unique("merge-owner"))
    repository = repository_fixture(owner)
    {base_oid, head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Merge feature", "feature", "main")

    merge_request_id = unique("merge-request")

    merge_metadata = %{
      "request_id" => merge_request_id,
      "api_version" => "2026-03-10",
      "ip_address" => "198.51.100.9",
      "user_agent" => "fornacast-merge-test/1.0",
      "token_id" => "token-immediate",
      "unsafe" => "must-not-persist",
      request_id: "ignored-atom-request",
      api_version: "ignored-atom-version",
      ip_address: "198.51.100.1",
      user_agent: "ignored-atom-agent",
      token_id: "ignored-atom-token"
    }

    assert {:ok, %{merged: true, message: "Pull Request successfully merged", sha: merge_oid}} =
             ForgePulls.merge(
               repository,
               pull,
               owner,
               %{
                 sha: head_oid,
                 merge_method: "merge",
                 commit_title: "Custom merge title",
                 commit_message: "Custom merge body"
               },
               merge_metadata
             )

    path = ForgeRepos.absolute_storage_path(repository)
    assert {:ok, ^merge_oid} = GitCore.exact_ref(path, "refs/heads/main")

    commit = git!(path, ["cat-file", "-p", merge_oid])
    assert String.contains?(commit, "parent #{base_oid}\nparent #{head_oid}\n")
    assert String.ends_with?(commit, "\n\nCustom merge title\n\nCustom merge body")

    assert %PullRequest{merge_commit_sha: ^merge_oid, merged_by_user_id: actor_id} =
             Repo.get!(PullRequest, pull.id)

    assert actor_id == owner.id
    assert %Issue{state: :closed, state_reason: :completed} = Repo.get!(Issue, pull.issue_id)

    assert %MergeOperation{
             state: :completed,
             merge_oid: ^merge_oid,
             request_id: ^merge_request_id,
             api_version: "2026-03-10",
             ip_address: "198.51.100.9",
             user_agent: "fornacast-merge-test/1.0",
             token_id: "token-immediate"
           } =
             operation =
             Repo.one!(
               from candidate in MergeOperation,
                 where: candidate.pull_request_id == ^pull.id,
                 order_by: [desc: candidate.id],
                 limit: 1
             )

    assert %AuditEvent{
             request_id: ^merge_request_id,
             ip_address: "198.51.100.9",
             user_agent: "fornacast-merge-test/1.0",
             metadata: audit_metadata
           } = Repo.get_by!(AuditEvent, operation_id: "pull_merge:#{operation.id}")

    assert audit_metadata["api_version"] == "2026-03-10"
    assert audit_metadata["token_id"] == "token-immediate"
    refute Map.has_key?(audit_metadata, "unsafe")
  end

  test "merge validates method messages sha policy and closed or already-merged pulls" do
    owner = user_fixture(unique("merge-policy"))
    repository = repository_fixture(owner)
    {_base_oid, head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Default merge", "feature", "main")
    metadata = request_metadata(unique("merge-policy"))

    for {attrs, field} <- [
          {%{merge_method: "squash"}, "merge_method"},
          {%{sha: "not-an-oid"}, "sha"},
          {%{commit_title: ""}, "commit_title"},
          {%{commit_message: <<0>>}, "commit_message"}
        ] do
      assert {:error, {:validation, [%{field: ^field, code: :invalid}]}} =
               ForgePulls.merge(repository, pull, owner, attrs, metadata)
    end

    assert {:error, :head_changed} =
             ForgePulls.merge(
               repository,
               pull,
               owner,
               %{sha: String.duplicate("0", 40)},
               metadata
             )

    path = ForgeRepos.absolute_storage_path(repository)
    moved_head_oid = child_commit!(path, head_oid, "head moved")
    git!(path, ["update-ref", "refs/heads/feature", moved_head_oid, head_oid])

    assert {:error, :head_changed} =
             ForgePulls.merge(repository, pull, owner, %{sha: head_oid}, metadata)

    disabled = repository |> Ecto.Changeset.change(allow_merge_commit: false) |> Repo.update!()

    assert {:error, :merge_commits_disabled} =
             ForgePulls.merge(disabled, pull, owner, %{}, metadata)

    repository = disabled |> Ecto.Changeset.change(allow_merge_commit: true) |> Repo.update!()
    issue = Repo.get!(Issue, pull.issue_id)
    Repo.update!(Ecto.Changeset.change(issue, state: :closed, state_reason: :completed))
    assert {:error, :conflict} = ForgePulls.merge(repository, pull, owner, %{}, metadata)

    pull.issue_id
    |> then(&Repo.get!(Issue, &1))
    |> Ecto.Changeset.change(state: :open, state_reason: nil)
    |> Repo.update!()

    assert {:ok, %{sha: merge_oid}} =
             ForgePulls.merge(repository, pull, owner, %{sha: moved_head_oid}, metadata)

    commit = git!(ForgeRepos.absolute_storage_path(repository), ["cat-file", "-p", merge_oid])

    assert String.ends_with?(
             commit,
             "\n\nMerge pull request ##{pull.issue.number} from feature\n\nDefault merge"
           )

    assert {:error, :conflict} = ForgePulls.merge(repository, pull, owner, %{}, metadata)
  end

  test "merge authorization masks malformed attrs before validation" do
    owner = user_fixture(unique("merge-mask-owner"))
    reader = user_fixture(unique("merge-mask-reader"))
    outsider = user_fixture(unique("merge-mask-outsider"))
    repository = repository_fixture(owner)
    grant_reader!(repository, reader)
    create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Masked merge", "feature", "main")

    assert {:error, :not_found} =
             ForgePulls.merge(
               repository,
               pull,
               outsider,
               %{sha: "not-an-oid"},
               request_metadata(unique("masked-outsider"))
             )

    assert {:error, :forbidden} =
             ForgePulls.merge(
               repository,
               pull,
               reader,
               %{merge_method: "squash"},
               request_metadata(unique("masked-reader"))
             )

    refute Repo.get_by(MergeOperation, pull_request_id: pull.id)
  end

  test "a moved base loses the exact CAS and leaves merge evidence diagnosable" do
    owner = user_fixture(unique("merge-base-race"))
    repository = repository_fixture(owner)
    {_base_oid, _head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Base race", "feature", "main")
    path = ForgeRepos.absolute_storage_path(repository)

    assert {:error, :ref_conflict} =
             ForgePulls.with_test_merge_transition_hook(
               fn
                 :merge_written, operation ->
                   raced_oid = child_commit!(path, operation.expected_base_oid, "base raced")
                   _updated = git!(path, ["update-ref", operation.base_ref, raced_oid])
                   :ok

                 _state, _operation ->
                   :ok
               end,
               fn ->
                 ForgePulls.merge(
                   repository,
                   pull,
                   owner,
                   %{},
                   request_metadata(unique("merge-base-race"))
                 )
               end
             )

    assert %MergeOperation{state: :merge_written, merge_oid: merge_oid} =
             Repo.one!(
               from operation in MergeOperation,
                 where: operation.pull_request_id == ^pull.id,
                 order_by: [desc: operation.id],
                 limit: 1
             )

    assert is_binary(merge_oid)
    refute Repo.get!(PullRequest, pull.id).merge_commit_sha
  end

  test "a retarget starting after merge preparation serializes behind the merge" do
    owner = user_fixture(unique("merge-retarget-overlap"))
    repository = repository_fixture(owner)
    {base_oid, _head_oid} = create_mergeable_branches!(repository)
    path = ForgeRepos.absolute_storage_path(repository)
    release_oid = child_commit!(path, base_oid, "release")
    git!(path, ["update-ref", "refs/heads/release", release_oid])
    assert {:ok, pull} = create_pull(repository, owner, "Retarget overlap", "feature", "main")
    parent = self()
    prepared = make_ref()

    merge_task =
      Task.async(fn ->
        ForgePulls.with_test_merge_transition_hook(
          fn
            :prepared, _operation ->
              send(parent, {:merge_prepared, prepared})
              receive do: ({:continue_merge, ^prepared} -> :ok)

            _state, _operation ->
              :ok
          end,
          fn ->
            ForgePulls.merge(
              repository,
              pull,
              owner,
              %{},
              request_metadata(unique("merge-retarget-overlap"))
            )
          end
        )
      end)

    assert_receive {:merge_prepared, ^prepared}, 5_000

    update_task =
      Task.async(fn ->
        send(parent, {:retarget_started, prepared})

        ForgePulls.update_pull_request(
          repository,
          pull,
          owner,
          %{base: "release"},
          request_metadata(unique("retarget-overlap"))
        )
      end)

    assert_receive {:retarget_started, ^prepared}, 5_000
    early_update = Task.yield(update_task, 200)
    send(merge_task.pid, {:continue_merge, prepared})
    merge_result = Task.await(merge_task, 30_000)

    update_result =
      case early_update do
        nil -> Task.await(update_task, 30_000)
        {:ok, result} -> result
      end

    assert early_update == nil
    assert {:ok, %{sha: merge_oid}} = merge_result
    assert {:error, :conflict} = update_result

    assert %PullRequest{base_ref: "refs/heads/main", merge_commit_sha: ^merge_oid} =
             Repo.get!(PullRequest, pull.id)

    assert {:ok, ^merge_oid} = GitCore.exact_ref(path, "refs/heads/main")
    assert {:ok, ^release_oid} = GitCore.exact_ref(path, "refs/heads/release")
  end

  test "a close starting after merge preparation serializes to an idempotent closed result" do
    owner = user_fixture(unique("merge-close-overlap"))
    repository = repository_fixture(owner)
    create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Close overlap", "feature", "main")
    parent = self()
    prepared = make_ref()

    merge_task =
      Task.async(fn ->
        ForgePulls.with_test_merge_transition_hook(
          fn
            :prepared, _operation ->
              send(parent, {:merge_prepared, prepared})
              receive do: ({:continue_merge, ^prepared} -> :ok)

            _state, _operation ->
              :ok
          end,
          fn ->
            ForgePulls.merge(
              repository,
              pull,
              owner,
              %{},
              request_metadata(unique("merge-close-overlap"))
            )
          end
        )
      end)

    assert_receive {:merge_prepared, ^prepared}, 5_000

    update_task =
      Task.async(fn ->
        send(parent, {:close_started, prepared})

        ForgePulls.update_pull_request(
          repository,
          pull,
          owner,
          %{state: :closed},
          request_metadata(unique("close-overlap"))
        )
      end)

    assert_receive {:close_started, ^prepared}, 5_000
    early_update = Task.yield(update_task, 200)
    send(merge_task.pid, {:continue_merge, prepared})
    merge_result = Task.await(merge_task, 30_000)

    update_result =
      case early_update do
        nil -> Task.await(update_task, 30_000)
        {:ok, result} -> result
      end

    assert early_update == nil
    assert {:ok, %{sha: merge_oid}} = merge_result

    assert {:ok, %PullRequest{merge_commit_sha: ^merge_oid, issue: %Issue{state: :closed}}} =
             update_result

    assert %PullRequest{base_ref: "refs/heads/main", merge_commit_sha: ^merge_oid} =
             Repo.get!(PullRequest, pull.id)

    assert %Issue{state: :closed, state_reason: :completed} = Repo.get!(Issue, pull.issue_id)
  end

  test "conflicts and writer exhaustion never prepare or advance a merge" do
    owner = user_fixture(unique("merge-reject"))
    conflict_repository = repository_fixture(owner)
    create_conflicting_branches!(conflict_repository)

    assert {:ok, conflict_pull} =
             create_pull(conflict_repository, owner, "Conflict", "feature", "main")

    base_before = snapshot_oid(conflict_repository, "main")

    assert {:error, :conflict} =
             ForgePulls.merge(
               conflict_repository,
               conflict_pull,
               owner,
               %{},
               request_metadata(unique("merge-conflict"))
             )

    assert snapshot_oid(conflict_repository, "main") == base_before
    refute Repo.get_by(MergeOperation, pull_request_id: conflict_pull.id)

    repository = repository_fixture(owner)
    create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Exhausted", "feature", "main")
    original_limits = Application.fetch_env!(:git_core, :limits)
    Application.put_env(:git_core, :limits, Keyword.put(original_limits, :content_deadline_ms, 1))

    assert {:ok, lease} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 10_000
             )

    try do
      assert {:error, {:unavailable, :write_timeout}} =
               ForgePulls.merge(
                 repository,
                 pull,
                 owner,
                 %{},
                 request_metadata(unique("merge-exhausted"))
               )
    after
      GitCore.RepositoryWriteLimiter.release(lease)
      Application.put_env(:git_core, :limits, original_limits)
    end

    refute Repo.get_by(MergeOperation, pull_request_id: pull.id)
  end

  test "the earlier-operation fence resolves old evidence before a new merge" do
    owner = user_fixture(unique("merge-fence"))
    repository = repository_fixture(owner)
    {base_oid, head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Fenced", "feature", "main")

    older =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: pull.id,
        repository_id: repository.id,
        actor_user_id: owner.id,
        request_id: unique("older-merge"),
        base_ref: pull.base_ref,
        head_ref: pull.head_ref,
        expected_base_oid: base_oid,
        expected_head_oid: head_oid,
        state: :prepared
      })
      |> Repo.insert!()

    assert {:ok, %{merged: true}} =
             ForgePulls.merge(
               repository,
               pull,
               owner,
               %{},
               request_metadata(unique("new-merge"))
             )

    assert %MergeOperation{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(MergeOperation, older.id)
  end

  test "an older live operation lease blocks a newer merge at the recovery fence" do
    owner = user_fixture(unique("merge-live-fence"))
    repository = repository_fixture(owner)
    {base_oid, head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Live fence", "feature", "main")

    older =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: pull.id,
        repository_id: repository.id,
        actor_user_id: owner.id,
        request_id: unique("older-live-merge"),
        base_ref: pull.base_ref,
        head_ref: pull.head_ref,
        expected_base_oid: base_oid,
        expected_head_oid: head_oid,
        state: :prepared
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, claimed} = OperationLease.claim(MergeOperation, older.id, "live", now, 30)

    try do
      assert {:error, {:unavailable, :pull_recovery}} =
               ForgePulls.merge(
                 repository,
                 pull,
                 owner,
                 %{},
                 request_metadata(unique("blocked-new-merge"))
               )

      assert snapshot_oid(repository, "main") == base_oid

      assert Repo.aggregate(
               from(operation in MergeOperation,
                 where: operation.pull_request_id == ^pull.id
               ),
               :count
             ) == 1

      assert %MergeOperation{state: :prepared, lease_owner: "live"} =
               Repo.get!(MergeOperation, older.id)
    after
      OperationLease.release(MergeOperation, claimed)
    end
  end

  test "an older operation claim race blocks rather than advancing the recovery cursor" do
    owner = user_fixture(unique("merge-claim-race"))
    repository = repository_fixture(owner)
    {base_oid, head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Claim race", "feature", "main")

    older =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: pull.id,
        repository_id: repository.id,
        actor_user_id: owner.id,
        request_id: unique("older-raced-merge"),
        base_ref: pull.base_ref,
        head_ref: pull.head_ref,
        expected_base_oid: base_oid,
        expected_head_oid: head_oid,
        state: :prepared
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      OperationLease.with_test_after_write_hook(
        fn :claim, MergeOperation, id, _version ->
          Repo.update_all(from(operation in MergeOperation, where: operation.id == ^id),
            set: [lease_expires_at: DateTime.add(now, -1, :second)]
          )

          assert {:ok, _stolen} =
                   OperationLease.claim(MergeOperation, id, "stolen", now, 30)
        end,
        fn ->
          ForgePulls.merge(
            repository,
            pull,
            owner,
            %{},
            request_metadata(unique("blocked-raced-merge"))
          )
        end
      )

    assert {:error, {:unavailable, :pull_recovery}} = result
    assert snapshot_oid(repository, "main") == base_oid

    assert Repo.aggregate(
             from(operation in MergeOperation, where: operation.pull_request_id == ^pull.id),
             :count
           ) == 1

    assert %MergeOperation{state: :prepared, lease_owner: "stolen"} =
             raced =
             Repo.get!(MergeOperation, older.id)

    assert :ok = OperationLease.release(MergeOperation, raced)
  end

  test "faults after every persisted transition leave one recoverable operation" do
    for {fault_state, recovered_state} <- [
          prepared: :failed,
          merge_written: :failed,
          ref_advanced: :completed,
          completed: :completed
        ] do
      owner = user_fixture(unique("merge-fault"))
      repository = repository_fixture(owner)
      create_mergeable_branches!(repository)
      assert {:ok, pull} = create_pull(repository, owner, "Fault", "feature", "main")

      assert_raise RuntimeError, "fault after #{fault_state}", fn ->
        ForgePulls.with_test_merge_transition_hook(
          fn state, _operation ->
            if state == fault_state, do: raise("fault after #{state}"), else: :ok
          end,
          fn ->
            ForgePulls.merge(
              repository,
              pull,
              owner,
              %{},
              request_metadata(unique("merge-fault"))
            )
          end
        )
      end

      operation =
        Repo.one!(
          from candidate in MergeOperation,
            where: candidate.pull_request_id == ^pull.id,
            order_by: [desc: candidate.id],
            limit: 1
        )

      assert operation.state == fault_state

      assert :ok =
               ForgePulls.MergeRecovery.reconcile_repository_locked(
                 repository,
                 ForgeRepos.absolute_storage_path(repository),
                 System.monotonic_time(:millisecond) + 10_000
               )

      assert Repo.get!(MergeOperation, operation.id).state == recovered_state
    end
  end

  test "recovery completes a proven merge after the public issue API closes its issue" do
    owner = user_fixture(unique("merge-issue-close-race"))
    repository = repository_fixture(owner)
    create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Issue close race", "feature", "main")
    path = ForgeRepos.absolute_storage_path(repository)
    cache_key = {path, :pull_issue_close_race}
    assert {:ok, :cached} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :cached} end)

    assert {:error, {:unavailable, :forced_after_ref}} =
             ForgePulls.with_test_merge_transition_hook(
               fn
                 :ref_advanced, _operation ->
                   assert {:ok, %Issue{state: :closed, state_reason: :not_planned}} =
                            ForgeIssues.update(
                              owner,
                              owner.username,
                              repository.slug,
                              pull.issue.number,
                              %{"state" => "closed", "state_reason" => "not_planned"},
                              request_metadata(unique("issue-close-race"))
                            )

                   {:error, {:unavailable, :forced_after_ref}}

                 _state, _operation ->
                   :ok
               end,
               fn ->
                 ForgePulls.merge(
                   repository,
                   pull,
                   owner,
                   %{},
                   request_metadata(unique("merge-issue-close-race"))
                 )
               end
             )

    assert %MergeOperation{state: :ref_advanced, merge_oid: merge_oid} =
             operation =
             Repo.one!(
               from candidate in MergeOperation,
                 where: candidate.pull_request_id == ^pull.id,
                 order_by: [desc: candidate.id],
                 limit: 1
             )

    assert {:ok, true} = ForgePulls.merged?(repository, pull, owner)

    assert %MergeOperation{state: :completed} = Repo.get!(MergeOperation, operation.id)
    assert %PullRequest{merge_commit_sha: ^merge_oid} = Repo.get!(PullRequest, pull.id)

    assert %Issue{state: :closed, state_reason: :completed} =
             Repo.get!(Issue, pull.issue_id)

    assert %AuditEvent{action: "pull_request.merged"} =
             Repo.get_by!(AuditEvent, operation_id: "pull_merge:#{operation.id}")

    assert {:ok, ^merge_oid} = GitCore.exact_ref(path, pull.base_ref)

    assert {:ok, :refreshed} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :refreshed} end)
  end

  test "merged? blocks on ambiguous third-OID recovery evidence" do
    owner = user_fixture(unique("merge-third-oid"))
    repository = repository_fixture(owner)
    {base_oid, _head_oid} = create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Third OID", "feature", "main")
    path = ForgeRepos.absolute_storage_path(repository)

    assert {:error, {:unavailable, :forced_after_write}} =
             ForgePulls.with_test_merge_transition_hook(
               fn
                 :merge_written, _operation -> {:error, {:unavailable, :forced_after_write}}
                 _state, _operation -> :ok
               end,
               fn ->
                 ForgePulls.merge(
                   repository,
                   pull,
                   owner,
                   %{},
                   request_metadata(unique("merge-third-oid"))
                 )
               end
             )

    assert %MergeOperation{state: :merge_written, merge_oid: merge_oid} =
             operation = Repo.get_by!(MergeOperation, pull_request_id: pull.id)

    third_oid = child_commit!(path, base_oid, "third oid")
    _updated = git!(path, ["update-ref", pull.base_ref, third_oid, base_oid])

    assert third_oid != merge_oid

    assert {:error, {:unavailable, :pull_recovery}} =
             ForgePulls.merged?(repository, pull, owner)

    assert %MergeOperation{state: :merge_written, failure_reason: "unexpected_ref"} =
             Repo.get!(MergeOperation, operation.id)

    assert %PullRequest{merged_at: nil, merge_commit_sha: nil} =
             Repo.get!(PullRequest, pull.id)
  end

  test "two racing merge callers produce exactly one winning ref update" do
    owner = user_fixture(unique("merge-race"))
    repository = repository_fixture(owner)
    create_mergeable_branches!(repository)
    assert {:ok, pull} = create_pull(repository, owner, "Race", "feature", "main")
    parent = self()
    barrier = make_ref()

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          send(parent, {barrier, self()})
          receive do: ({:go, ^barrier} -> :ok)

          ForgePulls.merge(
            repository,
            pull,
            owner,
            %{},
            request_metadata(unique("merge-racer-#{index}"))
          )
        end)
      end

    for task <- tasks do
      assert_receive {^barrier, worker} when worker == task.pid
    end

    Enum.each(tasks, &send(&1.pid, {:go, barrier}))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert 1 == Enum.count(results, &match?({:ok, %{merged: true}}, &1))
    assert 1 == Enum.count(results, &match?({:error, :conflict}, &1))

    assert 1 ==
             Repo.aggregate(
               from(op in MergeOperation,
                 where: op.pull_request_id == ^pull.id and op.state == :completed
               ),
               :count
             )
  end

  test "merge operations only move through durable next states and redact failure reasons" do
    operation = %MergeOperation{state: :prepared, failure_reason: "private git error"}

    assert %{state: ["is not a valid transition"]} =
             operation |> MergeOperation.transition_changeset(:completed) |> errors_on()

    assert %{state: :merge_written} =
             operation
             |> MergeOperation.transition_changeset(:merge_written)
             |> Ecto.Changeset.apply_changes()

    assert %{failure_reason: nil} = MergeOperation.public(operation)
  end

  test "merge operation preparation only accepts the prepared state" do
    attrs = %{
      pull_request_id: 1,
      repository_id: 1,
      request_id: "request-1",
      base_ref: "refs/heads/main",
      head_ref: "refs/heads/feature",
      expected_base_oid: String.duplicate("a", 40),
      expected_head_oid: String.duplicate("b", 40),
      state: :merge_written
    }

    assert %{state: ["is invalid"]} =
             %MergeOperation{} |> MergeOperation.prepare_changeset(attrs) |> errors_on()

    prepared =
      MergeOperation.prepare_changeset(
        %MergeOperation{},
        Map.merge(attrs, %{
          state: :prepared,
          merge_oid: String.duplicate("c", 40),
          failure_reason: "effect_not_started"
        })
      )

    assert prepared.valid?
    assert Ecto.Changeset.get_field(prepared, :merge_oid) == nil
    assert Ecto.Changeset.get_field(prepared, :failure_reason) == nil
  end

  test "operation leases preserve immutable merge evidence and validate transitions" do
    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)
    assert {:ok, _} = insert_merge_operation(fixture, "prepared", "lease-contract")

    operation = Repo.get_by!(MergeOperation, request_id: "lease-contract")
    now = ~U[2026-07-21 12:00:00Z]
    assert {:ok, claimed} = OperationLease.claim(MergeOperation, operation.id, "owner-a", now, 30)

    immutable_updates = [
      id: operation.id + 1,
      pull_request_id: operation.pull_request_id + 1,
      repository_id: operation.repository_id + 1,
      actor_user_id: fixture.user_id,
      request_id: "changed-request",
      base_ref: "refs/heads/changed",
      head_ref: "refs/heads/changed-head",
      expected_base_oid: String.duplicate("c", 40),
      expected_head_oid: String.duplicate("d", 40),
      lease_owner: "owner-b",
      lease_expires_at: DateTime.add(now, 60, :second),
      lock_version: 0,
      inserted_at: DateTime.add(now, -60, :second),
      updated_at: DateTime.add(now, -60, :second)
    ]

    for update <- immutable_updates do
      assert {:error, :invalid_update} =
               OperationLease.update_owned(MergeOperation, claimed, [update])

      assert Repo.get!(MergeOperation, claimed.id) == claimed
    end

    assert {:error, :invalid_update} =
             OperationLease.update_owned(MergeOperation, claimed,
               failure_reason: "native panic at /private/repository token=secret"
             )

    assert Repo.get!(MergeOperation, claimed.id) == claimed

    merge_oid = String.duplicate("E", 40)

    assert {:ok, updated} =
             OperationLease.update_owned(MergeOperation, claimed,
               state: :merge_written,
               merge_oid: merge_oid
             )

    assert updated.state == :merge_written
    assert updated.merge_oid == String.downcase(merge_oid)

    assert {:ok, reclaimed} =
             OperationLease.claim(MergeOperation, updated.id, "owner-b", now, 30)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(MergeOperation, reclaimed,
               merge_oid: String.duplicate("f", 40)
             )

    assert Repo.get!(MergeOperation, reclaimed.id) == reclaimed
    assert :ok = OperationLease.release(MergeOperation, reclaimed)

    assert {:ok, _} = insert_merge_operation(fixture, "prepared", "lease-split")
    split = Repo.get_by!(MergeOperation, request_id: "lease-split")

    assert {:ok, split_claimed} =
             OperationLease.claim(MergeOperation, split.id, "split-a", now, 30)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(MergeOperation, split_claimed, state: :merge_written)

    assert Repo.get!(MergeOperation, split_claimed.id) == split_claimed

    split_oid = String.duplicate("A", 40)

    assert {:ok, split_recorded} =
             OperationLease.update_owned(MergeOperation, split_claimed, merge_oid: split_oid)

    assert split_recorded.state == :prepared
    assert split_recorded.merge_oid == String.downcase(split_oid)

    assert {:ok, split_reclaimed} =
             OperationLease.claim(MergeOperation, split_recorded.id, "split-b", now, 30)

    assert {:ok, split_advanced} =
             OperationLease.update_owned(MergeOperation, split_reclaimed, state: :merge_written)

    assert split_advanced.merge_oid == String.downcase(split_oid)

    assert {:ok, split_nil_reclaimed} =
             OperationLease.claim(MergeOperation, split_advanced.id, "split-c", now, 30)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(MergeOperation, split_nil_reclaimed,
               state: :ref_advanced,
               merge_oid: nil
             )

    assert Repo.get!(MergeOperation, split_nil_reclaimed.id) == split_nil_reclaimed
    assert :ok = OperationLease.release(MergeOperation, split_nil_reclaimed)

    assert {:ok, _} = insert_merge_operation(fixture, "prepared", "lease-failure")
    failure = Repo.get_by!(MergeOperation, request_id: "lease-failure")

    assert {:ok, failure_claimed} =
             OperationLease.claim(MergeOperation, failure.id, "failure-a", now, 30)

    assert {:ok, alerted} =
             OperationLease.update_owned(MergeOperation, failure_claimed,
               failure_reason: "unexpected_ref"
             )

    assert {:ok, alert_reclaimed} =
             OperationLease.claim(MergeOperation, alerted.id, "failure-b", now, 30)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(MergeOperation, alert_reclaimed, state: :failed)

    assert Repo.get!(MergeOperation, alert_reclaimed.id) == alert_reclaimed
    assert :ok = OperationLease.release(MergeOperation, alert_reclaimed)

    assert {:ok, _} = insert_merge_operation(fixture, "prepared", "lease-valid-failure")
    valid_failure = Repo.get_by!(MergeOperation, request_id: "lease-valid-failure")

    assert {:ok, valid_failure_claimed} =
             OperationLease.claim(MergeOperation, valid_failure.id, "failure-c", now, 30)

    assert {:ok, failed} =
             OperationLease.update_owned(MergeOperation, valid_failure_claimed,
               state: :failed,
               failure_reason: "effect_not_started"
             )

    assert failed.state == :failed
    assert failed.failure_reason == "effect_not_started"

    assert {:ok, _} = insert_merge_operation(fixture, "prepared", "lease-persisted-failure")
    persisted_failure = Repo.get_by!(MergeOperation, request_id: "lease-persisted-failure")

    Repo.update_all(from(item in MergeOperation, where: item.id == ^persisted_failure.id),
      set: [failure_reason: "effect_not_started"]
    )

    persisted_failure = Repo.get!(MergeOperation, persisted_failure.id)

    assert {:ok, persisted_claimed} =
             OperationLease.claim(MergeOperation, persisted_failure.id, "failure-d", now, 30)

    assert {:ok, persisted_failed} =
             OperationLease.update_owned(MergeOperation, persisted_claimed, state: :failed)

    assert persisted_failed.failure_reason == "effect_not_started"
  end

  test "merge transitions expose only the sequential graph and sanitized pre-CAS failure" do
    sources = [:prepared, :merge_written, :ref_advanced, :completed, :failed]

    sequential =
      MapSet.new(prepared: :merge_written, merge_written: :ref_advanced, ref_advanced: :completed)

    for source <- sources, target <- sources do
      changeset = MergeOperation.transition_changeset(%MergeOperation{state: source}, target)

      if MapSet.member?(sequential, {source, target}) do
        assert %{state: ^target} = Ecto.Changeset.apply_changes(changeset)
      else
        assert %{state: ["is not a valid transition"]} = errors_on(changeset)
      end
    end

    for {transition, expected_source, target} <- [
          {:merge_written_changeset, :prepared, :merge_written},
          {:ref_advanced_changeset, :merge_written, :ref_advanced},
          {:completed_changeset, :ref_advanced, :completed}
        ],
        source <- sources do
      changeset = apply(MergeOperation, transition, [%MergeOperation{state: source}])

      if source == expected_source do
        assert %{state: ^target} = Ecto.Changeset.apply_changes(changeset)
      else
        assert %{state: ["is not a valid transition"]} = errors_on(changeset)
      end
    end

    for {source, reason, sanitized_reason} <- [
          {:prepared, "prepared\n\u0000failure", "prepared failure"},
          {:merge_written, "merge-written\u0000\n failure", "merge-written failure"}
        ] do
      assert %{state: :failed, failure_reason: ^sanitized_reason} =
               %MergeOperation{state: source}
               |> MergeOperation.failed_changeset(reason)
               |> Ecto.Changeset.apply_changes()
    end

    for source <- [:ref_advanced, :completed, :failed] do
      assert %{state: ["is not a valid transition"]} =
               %MergeOperation{state: source}
               |> MergeOperation.failed_changeset("failure")
               |> errors_on()
    end

    for source <- [:prepared, :merge_written], reason <- [nil, "", " \n\u0000\t "] do
      assert %{failure_reason: ["can't be blank"]} =
               %MergeOperation{state: source}
               |> MergeOperation.failed_changeset(reason)
               |> errors_on()
    end

    bounded_reason = String.duplicate("x", 600)

    assert %{state: :failed, failure_reason: sanitized_reason} =
             %MergeOperation{state: :prepared}
             |> MergeOperation.failed_changeset(bounded_reason)
             |> Ecto.Changeset.apply_changes()

    assert String.length(sanitized_reason) == 512
  end

  test "the active adapter enforces the exact durable pull database contract" do
    assert database_contract() == @expected_contract

    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)

    for state <- @states do
      assert {:ok, %{num_rows: 1}} =
               insert_merge_operation(fixture, state, "allowed-#{state}")
    end

    assert_constraint_rejected(fn ->
      insert_merge_operation(fixture, "not-a-pull-state", "invalid-state")
    end)

    assert_constraint_rejected(fn -> insert_pull(fixture.issue_id, fixture.repository_id) end)
    assert_constraint_rejected(fn -> insert_pull(-1, fixture.repository_id) end)
    assert_constraint_rejected(fn -> insert_pull(fixture.spare_issue_ids.issue_2, -1) end)

    assert_constraint_rejected(fn ->
      insert_pull(fixture.spare_issue_ids.issue_3, fixture.repository_id, -1)
    end)

    assert_constraint_rejected(fn ->
      insert_merge_operation(%{fixture | pull_request_id: -1}, "prepared", "missing-pull")
    end)

    assert_constraint_rejected(fn ->
      insert_merge_operation(%{fixture | repository_id: -1}, "prepared", "missing-repo")
    end)

    assert_constraint_rejected(fn ->
      insert_merge_operation(fixture, "prepared", "missing-actor", -1)
    end)
  end

  test "the Turso metadata migration up and down DDL preserve operation values FKs and indexes" do
    if database_adapter() == :turso do
      database =
        Path.join(System.tmp_dir!(), "pull-metadata-migration-#{System.unique_integer()}.db")

      migrations_path = Ecto.Migrator.migrations_path(Repo)

      migration_specs = [
        {20_260_703_000_100, "CreateFirstReleaseCoreTables",
         "20260703000100_create_first_release_core_tables.exs"},
        {20_260_706_000_100, "AddOrganizationAccounts",
         "20260706000100_add_organization_accounts.exs"},
        {20_260_717_000_100, "CreateAPIKeys", "20260717000100_create_api_keys.exs"},
        {20_260_721_000_100, "AddAPIRepositorySettings",
         "20260721000100_add_api_repository_settings.exs"},
        {20_260_721_000_200, "CreateGitWriteOperations",
         "20260721000200_create_git_write_operations.exs"},
        {20_260_721_000_300, "CreateIssueDomain", "20260721000300_create_issue_domain.exs"},
        {20_260_721_000_400, "CreatePullDomain", "20260721000400_create_pull_domain.exs"},
        {20_260_809_000_100, "AddPullMergeRequestMetadata",
         "20260809000100_add_pull_merge_request_metadata.exs"}
      ]

      migration_specs =
        Enum.map(migration_specs, fn {version, module_name, file} ->
          {version, Module.concat(["Fornacast", "Repo", "Migrations", module_name]), file}
        end)

      newly_loaded_migrations =
        Enum.flat_map(migration_specs, fn {_version, module, file} ->
          if Code.ensure_loaded?(module) and function_exported?(module, :__migration__, 0) do
            []
          else
            compiled = Code.compile_file(Path.join(migrations_path, file))
            assert {^module, _bytecode} = List.keyfind(compiled, module, 0)
            [module]
          end
        end)

      migrations = Enum.map(migration_specs, fn {version, module, _file} -> {version, module} end)

      metadata_migration =
        Module.concat(["Fornacast", "Repo", "Migrations", "AddPullMergeRequestMetadata"])

      assert {:ok, isolated_repo} =
               Repo.start_link(
                 name: nil,
                 database: database,
                 pool: DBConnection.ConnectionPool,
                 pool_size: 2
               )

      previous_repo = Repo.get_dynamic_repo()
      Repo.put_dynamic_repo(isolated_repo)

      previous_version = 20_260_721_000_400
      version = 20_260_809_000_100

      try do
        assert previous_version in Ecto.Migrator.run(Repo, migrations, :up, to: previous_version)

        key = contract_fixture_key()
        fixture = insert_contract_fixture(key)
        request_id = "migration-existing-#{key}"
        assert {:ok, %{num_rows: 1}} = insert_merge_operation(fixture, "prepared", request_id)

        assert [^version] = Ecto.Migrator.run(Repo, migrations, :up, to: version)

        Enum.each(
          apply(metadata_migration, :turso_down_statements, []),
          &SQL.query!(Repo, &1, [])
        )

        assert %{rows: [[^request_id, "refs/heads/main", "refs/heads/feature", "prepared"]]} =
                 SQL.query!(
                   Repo,
                   "SELECT request_id, base_ref, head_ref, state " <>
                     "FROM pull_merge_operations WHERE request_id = ?",
                   [request_id]
                 )

        %{rows: down_column_rows} =
          SQL.query!(Repo, "PRAGMA table_info('pull_merge_operations')", [])

        down_columns = MapSet.new(down_column_rows, &Enum.at(&1, 1))

        for removed <- ~w(api_version ip_address user_agent token_id) do
          refute MapSet.member?(down_columns, removed)
        end

        down_table_sql = turso_table_sql("pull_merge_operations")
        assert MapSet.size(turso_foreign_keys("pull_merge_operations", down_table_sql)) == 3
        assert MapSet.size(turso_indexes("pull_merge_operations")) == 3
        assert Map.has_key?(turso_checks(down_table_sql), "state")

        Enum.each(
          apply(metadata_migration, :turso_up_statements, []),
          &SQL.query!(Repo, &1, [])
        )

        # WORKAROUND(upstream): gsmlg-dev/concord#69
        assert_raise Turso.Error, ~r/no such table: s0/, fn ->
          Ecto.Migrator.run(Repo, migrations, :down, step: 1)
        end

        assert %{rows: [[^request_id]]} =
                 SQL.query!(
                   Repo,
                   "SELECT request_id FROM pull_merge_operations WHERE request_id = ?",
                   [request_id]
                 )

        %{rows: failed_rollback_column_rows} =
          SQL.query!(Repo, "PRAGMA table_info('pull_merge_operations')", [])

        failed_rollback_columns = MapSet.new(failed_rollback_column_rows, &Enum.at(&1, 1))

        for retained <- ~w(api_version ip_address user_agent token_id) do
          assert MapSet.member?(failed_rollback_columns, retained)
        end

        assert database_contract() == @expected_contract

        assert %{
                 rows: [
                   [
                     ^request_id,
                     "refs/heads/main",
                     "refs/heads/feature",
                     "prepared",
                     nil,
                     nil,
                     nil,
                     nil
                   ]
                 ]
               } =
                 SQL.query!(
                   Repo,
                   "SELECT request_id, base_ref, head_ref, state, " <>
                     "api_version, ip_address, user_agent, token_id " <>
                     "FROM pull_merge_operations WHERE request_id = ?",
                   [request_id]
                 )

        table_sql = turso_table_sql("pull_merge_operations")

        assert MapSet.size(turso_foreign_keys("pull_merge_operations", table_sql)) == 3
        assert MapSet.size(turso_indexes("pull_merge_operations")) == 3

        assert database_contract() == @expected_contract
      after
        Repo.put_dynamic_repo(previous_repo)
        GenServer.stop(isolated_repo)
        File.rm(database)

        Enum.each(newly_loaded_migrations, fn module ->
          :code.purge(module)
          :code.delete(module)
        end)
      end
    end
  end

  test "deleting a repository cascades through issues, pulls, and merge operations" do
    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)
    assert {:ok, %{num_rows: 1}} = insert_merge_operation(fixture, "prepared", "repo-cascade")

    assert %{num_rows: 1} = delete_by_id("repositories", fixture.repository_id)
    assert count_by_id("repositories", fixture.repository_id) == 0
    assert count_by_foreign_key("issues", "repository_id", fixture.repository_id) == 0
    assert count_by_foreign_key("pull_requests", "repository_id", fixture.repository_id) == 0

    assert count_by_foreign_key(
             "pull_merge_operations",
             "repository_id",
             fixture.repository_id
           ) == 0

    assert count_by_id("users", fixture.user_id) == 1
  end

  test "deleting an issue cascades through its pull and operation but retains the repository" do
    key = contract_fixture_key()
    cleanup_contract_fixture(key)
    fixture = insert_contract_fixture(key)
    assert {:ok, %{num_rows: 1}} = insert_merge_operation(fixture, "prepared", "issue-cascade")

    assert %{num_rows: 1} = delete_by_id("issues", fixture.issue_id)
    assert count_by_id("issues", fixture.issue_id) == 0
    assert count_by_id("pull_requests", fixture.pull_request_id) == 0

    assert count_by_foreign_key(
             "pull_merge_operations",
             "pull_request_id",
             fixture.pull_request_id
           ) == 0

    assert count_by_id("repositories", fixture.repository_id) == 1
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        replacement = if is_list(value), do: inspect(value), else: to_string(value)
        String.replace(acc, "%{#{key}}", replacement)
      end)
    end)
  end

  defp valid_pull_attrs(overrides) do
    Map.merge(
      %{
        issue_id: 1,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      },
      overrides
    )
  end

  defp unique(prefix) do
    stamp = System.system_time(:nanosecond) |> Integer.to_string(36) |> String.slice(-10, 10)
    counter = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "#{String.slice(prefix, 0, 12)}-#{stamp}-#{counter}"
  end

  defp independent_pull_concurrency_fixture do
    if database_adapter() == :postgres do
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        owner = user_fixture(unique("pull-pg-owner"))
        repository = repository_fixture(owner)
        register_committed_pull_fixture_cleanup(owner, repository)
        {owner, repository}
      end)
    else
      owner = user_fixture(unique("pull-concurrent-owner"))
      {owner, repository_fixture(owner)}
    end
  end

  defp register_committed_pull_fixture_cleanup(owner, repository) do
    path = ForgeRepos.absolute_storage_path(repository)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from(event in AuditEvent,
            where:
              event.target_type == "repository" and
                event.target_id == ^Integer.to_string(repository.id)
          )
        )

        if stored_repository = Repo.get(ForgeRepos.Repository, repository.id) do
          Repo.delete!(stored_repository)
        end

        if stored_owner = Repo.get(ForgeAccounts.User, owner.id) do
          Repo.delete!(stored_owner)
        end
      end)

      File.rm_rf!(path)
    end)
  end

  defp independent_pull_connection!(ready_ref, parent) do
    backend_pid =
      if database_adapter() == :postgres do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
        backend_pid
      end

    send(parent, {ready_ref, self(), backend_pid})
    backend_pid
  end

  defp independent_pull_checkin do
    if database_adapter() == :postgres,
      do: :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end

  defp await_independent_pull_workers(tasks, ready_ref) do
    Enum.map(tasks, fn task ->
      receive do
        {^ready_ref, worker_pid, backend_pid} when worker_pid == task.pid -> backend_pid
      after
        15_000 -> flunk("independent pull worker did not reach the start barrier")
      end
    end)
  end

  defp create_pull(repository, actor, title, head, base) do
    ForgePulls.create_pull_request(
      repository,
      actor,
      %{title: title, body: "#{title} body", head: head, base: base},
      request_metadata("create-#{System.unique_integer([:positive])}")
    )
  end

  defp resolved_pair(repository, head, base) do
    %{
      head_ref: "refs/heads/#{head}",
      base_ref: "refs/heads/#{base}",
      head_sha: snapshot_oid(repository, head),
      base_sha: snapshot_oid(repository, base),
      mergeable: nil,
      mergeable_state: :unknown
    }
  end

  defp snapshot_oid(repository, branch) do
    assert {:ok, snapshot} =
             GitCore.resolve_snapshot(
               ForgeRepos.absolute_storage_path(repository),
               %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/#{branch}"}
             )

    snapshot.oid
  end

  defp organization_fixture(owner, username) do
    assert {:ok, organization} =
             ForgeAccounts.create_organization(owner, %{
               username: username,
               display_name: username
             })

    organization
  end

  defp grant_writer!(repository, user) do
    %ForgeRepos.Collaborator{}
    |> ForgeRepos.Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: :write
    })
    |> Repo.insert!()
  end

  defp request_metadata(request_id) do
    %{
      request_id: request_id,
      ip_address: "203.0.113.44",
      user_agent: "forge-pulls-test"
    }
  end

  defp pull_audit_count(repository) do
    Repo.aggregate(
      from(event in AuditEvent,
        where:
          event.target_type == "repository" and
            event.target_id == ^Integer.to_string(repository.id) and
            event.action in ["pull_request.created", "pull_request.updated"]
      ),
      :count,
      :id
    )
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

  defp cache_keys_for(path) do
    parent = self()
    ref = make_ref()

    :sys.replace_state(GitCore.Cache, fn state ->
      send(parent, {ref, :ets.tab2list(state.table)})
      state
    end)

    assert_receive {^ref, entries}

    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(is_tuple(&1) and tuple_size(&1) > 0 and elem(&1, 0) == path))
    |> MapSet.new()
  end

  defp database_contract do
    case database_adapter() do
      :turso -> turso_database_contract()
      :postgres -> postgres_database_contract()
    end
  end

  defp turso_database_contract do
    Map.new(Map.keys(@expected_contract), fn table ->
      table_sql = turso_table_sql(table)

      {table,
       %{
         columns: turso_columns(table),
         foreign_keys: turso_foreign_keys(table, table_sql),
         indexes: turso_indexes(table),
         checks: turso_checks(table_sql)
       }}
    end)
  end

  defp turso_columns(table) do
    %{rows: rows} = SQL.query!(Repo, "PRAGMA table_info('#{table}')", [])

    Map.new(rows, fn [_cid, name, declared_type, not_null, default, primary_key] ->
      type = turso_semantic_type(name, declared_type)

      metadata = %{
        type: type,
        nullable: not_null == 0 and primary_key == 0,
        default: normalize_default(name, default, primary_key == 1)
      }

      {name, maybe_mark_utc(metadata)}
    end)
  end

  defp turso_semantic_type(name, "INTEGER")
       when name in [
              "id",
              "issue_id",
              "repository_id",
              "merged_by_user_id",
              "pull_request_id",
              "actor_user_id"
            ],
       do: :bigint

  defp turso_semantic_type("mergeable", "INTEGER"), do: :boolean
  defp turso_semantic_type("lock_version", "INTEGER"), do: :integer

  defp turso_semantic_type(name, "TEXT")
       when name in ["merged_at", "lease_expires_at", "inserted_at", "updated_at"],
       do: :timestamp

  defp turso_semantic_type(_name, "TEXT"), do: :text

  defp turso_foreign_keys(table, table_sql) do
    case SQL.query(Repo, "PRAGMA foreign_key_list('#{table}')", []) do
      {:ok, %{rows: rows}} ->
        MapSet.new(rows, fn [_id, _seq, target, source, target_column, _update, delete, _match] ->
          {source, target, target_column, normalize_delete_action(delete)}
        end)

      {:error, _unsupported_by_exturso} ->
        sqlite_master_foreign_keys(table_sql)
    end
  end

  defp sqlite_master_foreign_keys(table_sql) do
    ~r/[\(,]\s*"([^"]+)"\s+INTEGER\b[^,]*?CONSTRAINT\s+"[^"]+"\s+REFERENCES\s+"([^"]+)"\s+\("([^"]+)"\)\s+ON DELETE\s+(CASCADE|RESTRICT|NO ACTION|SET NULL)/
    |> Regex.scan(table_sql, capture: :all_but_first)
    |> MapSet.new(fn [source, target, target_column, delete] ->
      {source, target, target_column, normalize_delete_action(delete)}
    end)
  end

  defp turso_indexes(table) do
    %{rows: rows} = SQL.query!(Repo, "PRAGMA index_list('#{table}')", [])

    MapSet.new(rows, fn [_sequence, index_name, unique, _origin, _partial] ->
      %{rows: column_rows} = SQL.query!(Repo, "PRAGMA index_info('#{index_name}')", [])
      {unique == 1, Enum.map(column_rows, fn [_sequence, _column_id, name] -> name end)}
    end)
  end

  defp turso_table_sql(table) do
    %{rows: [[sql]]} =
      SQL.query!(Repo, "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?", [
        "table",
        table
      ])

    sql
  end

  defp turso_checks(table_sql) do
    allowed_states =
      ~r/'([^']+)'/
      |> Regex.scan(table_sql, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    if MapSet.size(allowed_states) == 0,
      do: %{},
      else: %{"state" => allowed_states}
  end

  defp postgres_database_contract do
    columns = postgres_columns()
    foreign_keys = postgres_foreign_keys()
    indexes = postgres_indexes()
    checks = postgres_checks()

    Map.new(Map.keys(@expected_contract), fn table ->
      {table,
       %{
         columns: Map.fetch!(columns, table),
         foreign_keys: Map.get(foreign_keys, table, MapSet.new()),
         indexes: Map.get(indexes, table, MapSet.new()),
         checks: Map.get(checks, table, %{})
       }}
    end)
  end

  defp postgres_columns do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT table_name, column_name, data_type, udt_name, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name IN ('pull_requests', 'pull_merge_operations')
      ORDER BY table_name, ordinal_position
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {table, table_rows} ->
      columns =
        Map.new(table_rows, fn [_table, name, data_type, udt_name, nullable, default] ->
          type = postgres_semantic_type(data_type, udt_name)

          metadata = %{
            type: type,
            nullable: nullable == "YES",
            default: normalize_default(name, default, name == "id")
          }

          {name, maybe_mark_utc(metadata)}
        end)

      {table, columns}
    end)
  end

  defp postgres_semantic_type("bigint", "int8"), do: :bigint
  defp postgres_semantic_type("integer", "int4"), do: :integer
  defp postgres_semantic_type("boolean", "bool"), do: :boolean
  defp postgres_semantic_type("character varying", "varchar"), do: :text
  defp postgres_semantic_type("text", "text"), do: :text
  defp postgres_semantic_type("timestamp without time zone", "timestamp"), do: :timestamp

  defp postgres_foreign_keys do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT tc.table_name, kcu.column_name, ccu.table_name, ccu.column_name,
             rc.delete_rule
      FROM information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu
        ON kcu.constraint_schema = tc.constraint_schema
       AND kcu.constraint_name = tc.constraint_name
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_schema = tc.constraint_schema
       AND ccu.constraint_name = tc.constraint_name
      JOIN information_schema.referential_constraints AS rc
        ON rc.constraint_schema = tc.constraint_schema
       AND rc.constraint_name = tc.constraint_name
      WHERE tc.table_schema = 'public'
        AND tc.constraint_type = 'FOREIGN KEY'
        AND tc.table_name IN ('pull_requests', 'pull_merge_operations')
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {table, table_rows} ->
      values =
        MapSet.new(table_rows, fn [_table, source, target, target_column, delete] ->
          {source, target, target_column, normalize_delete_action(delete)}
        end)

      {table, values}
    end)
  end

  defp postgres_indexes do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT tablename, indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename IN ('pull_requests', 'pull_merge_operations')
        AND indexname NOT LIKE '%\\_pkey' ESCAPE '\\'
      """)

    rows
    |> Enum.group_by(&hd/1)
    |> Map.new(fn {table, table_rows} ->
      values =
        MapSet.new(table_rows, fn [_table, _index_name, definition] ->
          [columns] = Regex.run(~r/\(([^()]+)\)$/, definition, capture: :all_but_first)

          {String.starts_with?(definition, "CREATE UNIQUE INDEX"),
           columns |> String.split(",") |> Enum.map(&String.trim/1)}
        end)

      {table, values}
    end)
  end

  defp postgres_checks do
    %{rows: rows} =
      SQL.query!(Repo, """
      SELECT table_name, pg_get_constraintdef(pg_constraint.oid)
      FROM pg_constraint
      JOIN information_schema.table_constraints
        ON constraint_name = conname
       AND constraint_schema = 'public'
      WHERE conname = 'pull_merge_operations_state_check'
      """)

    Map.new(rows, fn [table, definition] ->
      states =
        ~r/'([^']+)'/
        |> Regex.scan(definition, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      {table, %{"state" => states}}
    end)
  end

  defp normalize_default(_name, _default, true), do: :generated
  defp normalize_default("lock_version", default, false) when default in [0, "0"], do: 0
  defp normalize_default(_name, nil, false), do: nil

  defp maybe_mark_utc(%{type: :timestamp} = metadata), do: Map.put(metadata, :utc, true)
  defp maybe_mark_utc(metadata), do: metadata

  defp normalize_delete_action(action) when action in ["RESTRICT", "NO ACTION"], do: :restrict
  defp normalize_delete_action("CASCADE"), do: :cascade
  defp normalize_delete_action("SET NULL"), do: :nilify

  defp insert_contract_fixture(key) do
    user_id =
      insert_id(
        """
        INSERT INTO users
          (username, email, password_hash, role, state, inserted_at, updated_at)
        VALUES (?, ?, 'hash', 'user', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        """
        INSERT INTO users
          (username, email, password_hash, role, state, inserted_at, updated_at)
        VALUES ($1, $2, 'hash', 'user', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        [key, "#{key}@example.test"]
      )

    repository_id =
      insert_id(
        """
        INSERT INTO repositories
          (owner_user_id, slug, name, visibility, storage_path, default_branch,
           inserted_at, updated_at)
        VALUES (?, ?, ?, 'private', ?, 'main', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        """
        INSERT INTO repositories
          (owner_user_id, slug, name, visibility, storage_path, default_branch,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, 'private', $4, 'main', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """,
        [user_id, key, key, "/tmp/#{key}.git"]
      )

    issue_ids =
      Map.new(1..3, fn number ->
        issue_id =
          insert_id(
            """
            INSERT INTO issues
              (repository_id, number, kind, title, state, author_user_id,
               inserted_at, updated_at)
            VALUES (?, ?, 'pull_request', ?, 'open', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING id
            """,
            """
            INSERT INTO issues
              (repository_id, number, kind, title, state, author_user_id,
               inserted_at, updated_at)
            VALUES ($1, $2, 'pull_request', $3, 'open', $4,
                    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING id
            """,
            [repository_id, number, "#{key}-#{number}", user_id]
          )

        {String.to_atom("issue_#{number}"), issue_id}
      end)

    issue_id = issue_ids.issue_1
    pull_request_id = insert_pull!(issue_id, repository_id)

    %{
      key: key,
      user_id: user_id,
      repository_id: repository_id,
      issue_id: issue_id,
      spare_issue_ids: issue_ids,
      pull_request_id: pull_request_id
    }
  end

  defp contract_fixture_key do
    "pull-contract-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_pull(issue_id, repository_id, merged_by_user_id \\ nil) do
    sql(
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         merged_by_user_id, inserted_at, updated_at)
      VALUES (?, ?, 'refs/heads/feature', 'refs/heads/main', ?, ?, ?,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         merged_by_user_id, inserted_at, updated_at)
      VALUES ($1, $2, 'refs/heads/feature', 'refs/heads/main', $3, $4, $5,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        issue_id,
        repository_id,
        String.duplicate("a", 40),
        String.duplicate("b", 40),
        merged_by_user_id
      ]
    )
  end

  defp insert_pull!(issue_id, repository_id) do
    insert_id(
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         inserted_at, updated_at)
      VALUES (?, ?, 'refs/heads/feature', 'refs/heads/main', ?, ?,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
      """,
      """
      INSERT INTO pull_requests
        (issue_id, repository_id, head_ref, base_ref, head_sha, base_sha,
         inserted_at, updated_at)
      VALUES ($1, $2, 'refs/heads/feature', 'refs/heads/main', $3, $4,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
      """,
      [issue_id, repository_id, String.duplicate("a", 40), String.duplicate("b", 40)]
    )
  end

  defp insert_merge_operation(fixture, state, request_id, actor_user_id \\ nil) do
    sql(
      """
      INSERT INTO pull_merge_operations
        (pull_request_id, repository_id, actor_user_id, request_id, base_ref, head_ref,
         expected_base_oid, expected_head_oid, state, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, 'refs/heads/main', 'refs/heads/feature', ?, ?, ?,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      """
      INSERT INTO pull_merge_operations
        (pull_request_id, repository_id, actor_user_id, request_id, base_ref, head_ref,
         expected_base_oid, expected_head_oid, state, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'refs/heads/main', 'refs/heads/feature', $5, $6, $7,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        fixture.pull_request_id,
        fixture.repository_id,
        actor_user_id,
        request_id,
        String.duplicate("a", 40),
        String.duplicate("b", 40),
        state
      ]
    )
  end

  defp assert_constraint_rejected(fun) do
    assert {:error, {:constraint, _error}} =
             Repo.transaction(fn ->
               case fun.() do
                 {:ok, _result} -> Repo.rollback(:constraint_not_enforced)
                 {:error, error} -> Repo.rollback({:constraint, error})
               end
             end)
  end

  defp delete_contract_fixture(key) do
    sql!(
      "DELETE FROM pull_merge_operations WHERE pull_request_id IN (SELECT id FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE ?))",
      "DELETE FROM pull_merge_operations WHERE pull_request_id IN (SELECT id FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE $1))",
      ["#{key}%"]
    )

    sql!(
      "DELETE FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE ?)",
      "DELETE FROM pull_requests WHERE issue_id IN (SELECT id FROM issues WHERE title LIKE $1)",
      ["#{key}%"]
    )

    sql!("DELETE FROM issues WHERE title LIKE ?", "DELETE FROM issues WHERE title LIKE $1", [
      "#{key}%"
    ])

    sql!("DELETE FROM repositories WHERE slug = ?", "DELETE FROM repositories WHERE slug = $1", [
      key
    ])

    sql!("DELETE FROM users WHERE username = ?", "DELETE FROM users WHERE username = $1", [key])
  end

  defp cleanup_contract_fixture(key) do
    if database_adapter() == :turso, do: on_exit(fn -> delete_contract_fixture(key) end)
  end

  defp delete_by_id(table, id) do
    sql!("DELETE FROM #{table} WHERE id = ?", "DELETE FROM #{table} WHERE id = $1", [id])
  end

  defp count_by_id(table, id), do: count_by_foreign_key(table, "id", id)

  defp count_by_foreign_key(table, column, id) do
    %{rows: [[count]]} =
      sql!(
        "SELECT count(*) FROM #{table} WHERE #{column} = ?",
        "SELECT count(*) FROM #{table} WHERE #{column} = $1",
        [id]
      )

    count
  end

  defp insert_id(turso_sql, postgres_sql, params) do
    %{rows: [[id]]} = sql!(turso_sql, postgres_sql, params)
    id
  end

  defp sql(turso_sql, postgres_sql, params) do
    SQL.query(Repo, adapter_sql(turso_sql, postgres_sql), params)
  end

  defp sql!(turso_sql, postgres_sql, params) do
    SQL.query!(Repo, adapter_sql(turso_sql, postgres_sql), params)
  end

  defp adapter_sql(turso_sql, postgres_sql) do
    case database_adapter() do
      :turso -> turso_sql
      :postgres -> postgres_sql
    end
  end

  defp database_adapter do
    case Application.fetch_env!(:fornacast, :database_adapter) do
      value when value in ["turso", "libsql"] -> :turso
      value when value in ["postgres", "postgresql"] -> :postgres
    end
  end

  defp grant_reader!(repository, user) do
    %ForgeRepos.Collaborator{}
    |> ForgeRepos.Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: :read
    })
    |> Repo.insert!()
  end

  defp user_fixture(username) do
    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp repository_fixture(owner) do
    slug = "pull-#{System.unique_integer([:positive])}"

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{name: slug, slug: slug, visibility: :private})

    repository
  end

  defp create_branch!(repository, branch) do
    path = ForgeRepos.absolute_storage_path(repository)

    empty_tree =
      Path.join(System.tmp_dir!(), "pull-empty-tree-#{System.unique_integer([:positive])}")

    File.write!(empty_tree, "")
    on_exit(fn -> File.rm(empty_tree) end)

    {tree, 0} =
      System.cmd("git", ["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", empty_tree])

    {commit, 0} =
      System.cmd(
        "git",
        [
          "--git-dir=#{path}",
          "commit-tree",
          String.trim(tree),
          "-m",
          "#{branch}-#{System.unique_integer([:positive, :monotonic])}"
        ],
        env: [
          {"GIT_AUTHOR_NAME", "Test"},
          {"GIT_AUTHOR_EMAIL", "test@example.test"},
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@example.test"}
        ]
      )

    {_, 0} =
      System.cmd("git", [
        "--git-dir=#{path}",
        "update-ref",
        "refs/heads/#{branch}",
        String.trim(commit)
      ])
  end

  defp create_mergeable_branches!(repository) do
    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    _main = git!(path, ["update-ref", "refs/heads/main", base])
    _feature = git!(path, ["update-ref", "refs/heads/feature", head])
    {base, head}
  end

  defp create_comparison_branches!(repository) do
    worktree = Path.join(System.tmp_dir!(), "pull-compare-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(worktree, "lib"))
    on_exit(fn -> File.rm_rf!(worktree) end)
    _init = worktree_git!(worktree, ["init", "-b", "main"])
    _name = worktree_git!(worktree, ["config", "user.name", "Pull Test"])
    _email = worktree_git!(worktree, ["config", "user.email", "pull@example.test"])
    File.write!(Path.join(worktree, "lib/changed.ex"), "base\n")
    _add = worktree_git!(worktree, ["add", "lib/changed.ex"])
    _base = worktree_git!(worktree, ["commit", "-m", "base"])
    base_oid = worktree_git!(worktree, ["rev-parse", "HEAD"])
    _branch = worktree_git!(worktree, ["checkout", "-b", "feature"])
    File.write!(Path.join(worktree, "lib/changed.ex"), "first\n")
    _first = worktree_git!(worktree, ["commit", "-am", "first"])
    first_oid = worktree_git!(worktree, ["rev-parse", "HEAD"])
    File.write!(Path.join(worktree, "lib/added.ex"), "second\n")
    _add = worktree_git!(worktree, ["add", "lib/added.ex"])
    _second = worktree_git!(worktree, ["commit", "-m", "second"])
    second_oid = worktree_git!(worktree, ["rev-parse", "HEAD"])
    File.write!(Path.join(worktree, "lib/changed.ex"), "head\n")
    _head = worktree_git!(worktree, ["commit", "-am", "head"])
    head_oid = worktree_git!(worktree, ["rev-parse", "HEAD"])
    path = ForgeRepos.absolute_storage_path(repository)
    _push = worktree_git!(worktree, ["push", path, "main", "feature"])
    {base_oid, [first_oid, second_oid, head_oid]}
  end

  defp child_commit!(path, parent, message) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    git!(path, ["commit-tree", tree, "-p", parent, "-m", message])
  end

  defp create_conflicting_branches!(repository) do
    worktree =
      Path.join(System.tmp_dir!(), "pull-conflict-#{System.unique_integer([:positive])}")

    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(worktree) end)
    _init = worktree_git!(worktree, ["init", "-b", "main"])
    _name = worktree_git!(worktree, ["config", "user.name", "Pull Test"])
    _email = worktree_git!(worktree, ["config", "user.email", "pull@example.test"])
    file = Path.join(worktree, "conflict.txt")
    File.write!(file, "base\n")
    _add = worktree_git!(worktree, ["add", "conflict.txt"])
    _base = worktree_git!(worktree, ["commit", "-m", "base"])
    _branch = worktree_git!(worktree, ["checkout", "-b", "feature"])
    File.write!(file, "feature\n")
    _head = worktree_git!(worktree, ["commit", "-am", "feature"])
    _main = worktree_git!(worktree, ["checkout", "main"])
    File.write!(file, "main\n")
    _main_commit = worktree_git!(worktree, ["commit", "-am", "main"])

    path = ForgeRepos.absolute_storage_path(repository)
    _push = worktree_git!(worktree, ["push", path, "main", "feature"])
    :ok
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Pull Test"},
      {"GIT_AUTHOR_EMAIL", "pull@example.test"},
      {"GIT_COMMITTER_NAME", "Pull Test"},
      {"GIT_COMMITTER_EMAIL", "pull@example.test"}
    ]

    {output, 0} = System.cmd("git", ["--git-dir=#{path}" | args], env: env)
    String.trim(output)
  end

  defp worktree_git!(worktree, args) do
    {output, 0} = System.cmd("git", ["-C", worktree | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
