defmodule ForgeIssues.NumberAllocatorTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label, NumberSequence}
  alias ForgeRepos.Collaborator
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

    assert {:ok, %{issue: issue, pull_issue: pull_issue}} = ForgeIssues.transaction(multi)
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

    assert {:error, :forced_failure, :forced_failure, _changes} = ForgeIssues.transaction(failed)

    assert {:ok, %{issue: %{number: 1}}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(
               :issue,
               repository,
               actor,
               :issue,
               %{title: "Committed"}
             )
             |> ForgeIssues.transaction()
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

  test "identity updates defer repository authorization to the outer context", %{
    actor: author,
    repository: repository
  } do
    other_actor = user_fixture("identity-writer-#{System.unique_integer([:positive])}")

    %Collaborator{}
    |> Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: other_actor.id,
      role: :write
    })
    |> Repo.insert!()

    assert :ok = Fornacast.Access.authorize(other_actor, :repository_write, repository)

    assert {:ok, %{issue: issue}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(
               :issue,
               repository,
               author,
               :issue,
               %{title: "Original"}
             )
             |> ForgeIssues.transaction()

    assert {:ok, %{issue: author_update}} =
             Multi.new()
             |> ForgeIssues.update_identity(:issue, issue, author, %{title: "Author update"})
             |> ForgeIssues.transaction()

    assert author_update.title == "Author update"

    assert {:ok, %{issue: writer_update}} =
             Multi.new()
             |> ForgeIssues.update_identity(:issue, author_update, other_actor, %{
               title: "Writer update"
             })
             |> ForgeIssues.transaction()

    assert writer_update.title == "Writer update"
  end

  test "transaction does not retry an ordinary multi failure" do
    test_process = self()

    multi =
      Multi.run(Multi.new(), :failure, fn _repo, _changes ->
        send(test_process, :transaction_attempt)
        {:error, :ordinary_failure}
      end)

    assert {:error, :failure, :ordinary_failure, %{}} = ForgeIssues.transaction(multi)
    assert_receive :transaction_attempt
    refute_receive :transaction_attempt, 10
  end

  test "transaction bounds Turso busy retries and does not retry them on other adapters" do
    counter = :counters.new(1, [])

    busy =
      Multi.run(Multi.new(), :busy, fn _repo, _changes ->
        :counters.add(counter, 1, 1)
        raise Turso.Error, code: :busy, message: "database is locked"
      end)

    assert_raise Turso.Error, "database is locked", fn -> ForgeIssues.transaction(busy) end

    expected_attempts = if Repo.__adapter__() == Ecto.Adapters.Turso, do: 12, else: 1
    assert :counters.get(counter, 1) == expected_attempts
  end

  test "independent transactions allocate consecutive numbers concurrently across identity kinds",
       %{
         actor: actor,
         repository: repository
       } do
    {actor, repository} = independent_concurrency_fixture(actor, repository)
    parent = self()
    ready_ref = make_ref()
    worker_count = 8

    tasks =
      for index <- 1..worker_count do
        Task.async(fn ->
          backend_pid = independent_connection!(ready_ref, parent)

          receive do
            {:go, ^ready_ref} ->
              result =
                Multi.new()
                |> ForgeIssues.insert_numbered_identity(
                  {:issue, index},
                  repository,
                  actor,
                  if(rem(index, 2) == 0, do: :pull_request, else: :issue),
                  %{title: "Concurrent #{index}"}
                )
                |> ForgeIssues.transaction()

              independent_checkin()

              case result do
                {:ok, changes} -> {:ok, changes[{:issue, index}].number, backend_pid}
                error -> error
              end
          end
        end)
      end

    backend_pids = await_independent_workers(tasks, ready_ref)

    if postgres?(), do: assert(MapSet.size(MapSet.new(backend_pids)) > 1)

    Enum.each(tasks, fn task -> send(task.pid, {:go, ready_ref}) end)

    numbers =
      tasks
      |> Enum.map(&Task.await(&1, 30_000))
      |> Enum.map(fn {:ok, number, _backend_pid} -> number end)
      |> Enum.sort()

    assert numbers == Enum.to_list(1..worker_count)
  end

  defp independent_concurrency_fixture(actor, repository) do
    if postgres?() do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        committed_actor =
          user_fixture("allocator-pg-#{System.system_time(:nanosecond)}")

        committed_repository = repository_fixture(committed_actor)
        register_committed_fixture_cleanup(committed_actor, committed_repository)
        {committed_actor, committed_repository}
      end)
    else
      {actor, repository}
    end
  end

  defp register_committed_fixture_cleanup(actor, repository) do
    path = ForgeRepos.absolute_storage_path(repository)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        if stored_repository = Repo.get(ForgeRepos.Repository, repository.id) do
          Repo.delete!(stored_repository)
        end

        if stored_actor = Repo.get(ForgeAccounts.User, actor.id) do
          Repo.delete!(stored_actor)
        end
      end)

      File.rm_rf!(path)
    end)
  end

  defp independent_connection!(ready_ref, parent) do
    backend_pid =
      if postgres?() do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
        backend_pid
      end

    send(parent, {ready_ref, self(), backend_pid})
    backend_pid
  end

  defp independent_checkin do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end

  defp await_independent_workers(tasks, ready_ref) do
    Enum.map(tasks, fn task ->
      receive do
        {^ready_ref, worker_pid, backend_pid} when worker_pid == task.pid -> backend_pid
      after
        15_000 -> flunk("independent allocator worker did not reach the start barrier")
      end
    end)
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
