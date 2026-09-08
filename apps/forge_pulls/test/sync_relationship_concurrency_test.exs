defmodule ForgePulls.SyncRelationshipConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias ForgeAccounts.{GitHubIdentity, User}
  alias Fornacast.Repo

  setup do
    fixture =
      SQL.Sandbox.unboxed_run(Repo, fn ->
        suffix = System.unique_integer([:positive, :monotonic])

        actor =
          Repo.insert!(%User{
            username: "relation-race-#{suffix}",
            email: "relation-race-#{suffix}@example.test",
            password_hash: "fixture"
          })

        repository =
          Repo.insert!(%ForgeRepos.Repository{
            owner_user_id: actor.id,
            name: "race",
            slug: "race",
            storage_path: "/tmp/never-created-relationship-race-#{suffix}.git"
          })

        issue =
          Repo.insert!(%ForgeIssues.Issue{
            repository_id: repository.id,
            number: 1,
            kind: :pull_request,
            title: "Original",
            author_user_id: actor.id
          })

        pull =
          Repo.insert!(%ForgePulls.PullRequest{
            repository_id: repository.id,
            issue_id: issue.id,
            head_repository_id: repository.id,
            head_ref: "refs/heads/feature",
            base_ref: "refs/heads/main",
            head_sha: String.duplicate("a", 40),
            base_sha: String.duplicate("b", 40)
          })

        Repo.insert!(%ForgeIssues.IssueAssignee{issue_id: issue.id, user_id: actor.id})

        {:ok, identity} =
          ForgeAccounts.observe_github_identity(
            %{id: suffix + 9_000_000_000, login: "remote-#{suffix}"},
            DateTime.utc_now(:second)
          )

        %{
          actor: actor,
          repository: repository,
          issue: issue,
          pull: pull,
          identity: identity,
          insert_github_id: suffix + 10_000_000_000
        }
      end)

    on_exit(fn ->
      SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in ForgeRepos.Repository, where: r.id == ^fixture.repository.id)
        Repo.delete_all(from i in GitHubIdentity, where: i.id == ^fixture.identity.id)

        Repo.delete_all(
          from i in GitHubIdentity, where: i.github_user_id == ^fixture.insert_github_id
        )

        Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
      end)
    end)

    fixture
  end

  test "independent new link cannot change an unmanaged member while projection awaits confirmation",
       c do
    SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        owner_pid = backend_pid()
        assert {:ok, projection} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)
        assert projection.relationship_preimage.managed_assignee_identity_ids == []

        task =
          Task.async(fn ->
            SQL.Sandbox.unboxed_run(Repo, fn ->
              pid = backend_pid()

              result =
                captured(fn ->
                  Repo.transaction(fn ->
                    SQL.query!(Repo, "SET LOCAL lock_timeout = '250ms'", [])
                    ForgeAccounts.link_github_identity(c.actor, c.identity)
                  end)
                end)

              {pid, result}
            end)
          end)

        {probe_pid, result} = Task.await(task, 5_000)
        refute probe_pid == owner_pid
        assert result == {:raised, :lock_not_available}
        assert Repo.get!(GitHubIdentity, c.identity.id).local_user_id == nil
      end)
    end)
  end

  test "contended known identity yields typed retry instead of waiting with inverse locks", c do
    SQL.Sandbox.unboxed_run(Repo, fn ->
      {:ok, _} = ForgeAccounts.link_github_identity(c.actor, c.identity)
    end)

    parent = self()

    holder =
      Task.async(fn ->
        SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            pid = backend_pid()

            SQL.query!(Repo, "SELECT id FROM github_identities WHERE id = $1 FOR UPDATE", [
              c.identity.id
            ])

            send(parent, {:identity_locked, self(), pid})

            receive do
              :release -> :ok
            after
              5_000 -> flunk("identity lock holder was not released")
            end
          end)
        end)
      end)

    assert_receive {:identity_locked, holder_pid, holder_backend}, 2_000
    assert holder_pid == holder.pid

    try do
      SQL.Sandbox.unboxed_run(Repo, fn ->
        refute backend_pid() == holder_backend

        result =
          captured(fn ->
            Repo.transaction(fn ->
              SQL.query!(Repo, "SET LOCAL lock_timeout = '250ms'", [])

              case ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id) do
                {:ok, _} -> :unexpected_success
                {:error, reason} -> Repo.rollback(reason)
              end
            end)
          end)

        assert result == {:error, :relationship_lock_busy}
        assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == 1

        refute Repo.exists?(
                 from e in Fornacast.DomainOutboxEvent,
                   where: e.aggregate_type == "issue" and e.aggregate_id == ^to_string(c.issue.id)
               )
      end)
    after
      send(holder.pid, :release)
      Task.await(holder, 5_000)
    end
  end

  test "independent INSERT with a linked user is also fenced until projection commits", c do
    SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        owner_pid = backend_pid()
        assert {:ok, _} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)

        task =
          Task.async(fn ->
            SQL.Sandbox.unboxed_run(Repo, fn ->
              pid = backend_pid()

              result =
                captured(fn ->
                  Repo.transaction(fn ->
                    SQL.query!(Repo, "SET LOCAL lock_timeout = '250ms'", [])

                    Repo.insert!(%GitHubIdentity{
                      kind: :user,
                      github_user_id: c.insert_github_id,
                      login: "new-linked",
                      local_user_id: c.actor.id
                    })
                  end)
                end)

              {pid, result}
            end)
          end)

        {probe_pid, result} = Task.await(task, 5_000)
        refute owner_pid == probe_pid
        assert result == {:raised, :lock_not_available}
      end)

      refute Repo.exists?(
               from i in GitHubIdentity, where: i.github_user_id == ^c.insert_github_id
             )

      assert {:ok, _} = ForgeAccounts.link_github_identity(c.actor, c.identity)
    end)
  end

  test "contended newly targeted user rolls back scalar draft version and outbox together", c do
    expected =
      SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in ForgeIssues.IssueAssignee, where: a.issue_id == ^c.issue.id)
        {:ok, projection} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)
        projection
      end)

    parent = self()

    holder =
      Task.async(fn ->
        SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            SQL.query!(Repo, "SELECT id FROM users WHERE id = $1 FOR UPDATE", [c.actor.id])
            send(parent, {:target_locked, backend_pid()})

            receive do
              :release -> :ok
            after
              5_000 -> flunk("target holder was not released")
            end
          end)
        end)
      end)

    assert_receive {:target_locked, holder_backend}, 2_000

    try do
      SQL.Sandbox.unboxed_run(Repo, fn ->
        refute backend_pid() == holder_backend

        request = %{
          repository_id: c.repository.id,
          resource_kind: :pull,
          local_resource_id: c.pull.id,
          expected_local_version: expected.local_version,
          expected_fields: expected.fields,
          expected_merge_state: expected.merge_state,
          expected_relationships: expected.relationship_preimage,
          fields: %{expected.fields | "title" => "Remote", "draft" => true},
          action: :update,
          local_label_ids: [],
          assignee_refs: [%{kind: :local_user, id: c.actor.id}],
          provenance: %{origin: :github}
        }

        assert {:error, :resource, :relationship_lock_busy, _} =
                 Ecto.Multi.new()
                 |> ForgePulls.append_sync_apply(:resource, request)
                 |> Repo.transaction()

        assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == 1
        assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Original"
        refute Repo.get!(ForgePulls.PullRequest, c.pull.id).draft

        refute Repo.exists?(
                 from e in Fornacast.DomainOutboxEvent,
                   where: e.aggregate_type == "issue" and e.aggregate_id == ^to_string(c.issue.id)
               )
      end)
    after
      send(holder.pid, :release)
      Task.await(holder, 5_000)
    end
  end

  defp captured(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:raised, error.postgres.code}
  end

  defp backend_pid do
    %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end
end
