defmodule ForgePulls.CoordinatedMergeIntentTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, MergeRecovery, PullRequest}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "merge-intent-#{suffix}",
        email: "merge-intent-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{name: "intent", slug: "intent", visibility: :private})

    {:ok, %{issue: issue}} =
      Multi.new()
      |> ForgeIssues.insert_numbered_identity(:issue, repository, actor, :pull_request, %{
        title: "Prepared"
      })
      |> Repo.transaction()

    pull =
      %PullRequest{}
      |> PullRequest.create_changeset(%{
        issue_id: issue.id,
        repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })
      |> Repo.insert!()

    {:ok, projection} = ForgePulls.sync_projection(repository.id, :pull, pull.id)

    signature = %{
      "name" => actor.username,
      "email" => actor.email,
      "seconds" => 1_750_000_000,
      "offset_minutes" => 0
    }

    request = %{
      repository_id: repository.id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      expected_local_version: projection.local_version,
      expected_fields: projection.fields,
      expected_merge_state: projection.merge_state,
      expected_head_repository_id: repository.id,
      coordinator_operation_id: suffix,
      actor_user_id: actor.id,
      request_id: "coordinator-#{suffix}",
      commit_intent: %{
        "message" => "Merge prepared pull\n\nExact message",
        "author" => signature,
        "committer" => signature
      }
    }

    %{actor: actor, repository: repository, issue: issue, pull: pull, request: request}
  end

  test "commits one replay-stable intent without Git or PR effects", c do
    assert {:ok, %{prepared: first}} = prepare(c.request)
    assert Map.get(first, :coordination_mode) == :mirror
    assert first.state == :prepared
    assert first.merge_oid == nil
    assert first.expected_base_oid == c.pull.base_sha
    assert first.expected_head_oid == c.pull.head_sha
    assert first.commit_intent["message"] == c.request.commit_intent["message"]
    assert first.commit_intent["committer"] == c.request.commit_intent["committer"]
    c.actor |> Changeset.change(email: "changed@example.test") |> Repo.update!()
    assert {:ok, %{prepared: replay}} = prepare(c.request)
    assert replay.id == first.id
    assert replay.commit_intent == first.commit_intent
    assert operation_count(c.repository.id) == 1
    assert Repo.get!(Issue, c.issue.id).sync_version == c.issue.sync_version
    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil

    assert {:ok, nil} =
             GitCore.exact_ref(ForgeRepos.absolute_storage_path(c.repository), c.pull.base_ref)
  end

  test "replay rejects changed message timestamp or request identity", c do
    assert {:ok, %{prepared: first}} = prepare(c.request)

    for changed <- [
          put_in(c.request, [:commit_intent, "message"], "Different"),
          put_in(c.request, [:commit_intent, "author", "seconds"], 1_750_000_001),
          %{c.request | request_id: "different-request"}
        ] do
      assert {:error, :prepared, :merge_intent_conflict, _} = prepare(changed)
    end

    assert Repo.get!(MergeOperation, first.id).commit_intent == first.commit_intent
  end

  test "another coordinator cannot reserve the same pull or base while intent is nonterminal",
       c do
    assert {:ok, %{prepared: first}} = prepare(c.request)

    competing = %{
      c.request
      | coordinator_operation_id: c.request.coordinator_operation_id + 1,
        request_id: "another-coordinator"
    }

    assert {:error, :prepared, :merge_reserved, _} = prepare(competing)
    assert {:ok, %{prepared: replay}} = prepare(c.request)
    assert replay.id == first.id

    issue =
      Repo.insert!(%Issue{
        repository_id: c.repository.id,
        number: 99,
        kind: :pull_request,
        title: "Another",
        author_user_id: c.actor.id
      })

    pull =
      Repo.insert!(%PullRequest{
        repository_id: c.repository.id,
        issue_id: issue.id,
        head_repository_id: c.repository.id,
        head_ref: c.pull.head_ref,
        base_ref: c.pull.base_ref,
        head_sha: c.pull.head_sha,
        base_sha: c.pull.base_sha
      })

    {:ok, projection} = ForgePulls.sync_projection(c.repository.id, :pull, pull.id)

    competing = %{
      competing
      | local_resource_id: pull.id,
        expected_fields: projection.fields,
        expected_local_version: projection.local_version
    }

    assert {:error, :prepared, :merge_reserved, _} = prepare(competing)
    assert operation_count(c.repository.id) == 1
  end

  test "bare domain preparation rejects both directions of base/head overlap", c do
    {:ok, second} =
      ForgeRepos.create_repository(c.actor, %{
        name: "second",
        slug: "second",
        visibility: :private
      })

    {:ok, third} =
      ForgeRepos.create_repository(c.actor, %{name: "third", slug: "third", visibility: :private})

    c.pull |> Changeset.change(head_repository_id: second.id) |> Repo.update!()
    request = %{c.request | expected_head_repository_id: second.id}
    assert {:ok, %{prepared: _}} = prepare(request)

    for {base, head, base_ref, head_ref} <- [
          {second, third, c.pull.head_ref, "refs/heads/topic"},
          {third, c.repository, "refs/heads/other", c.pull.base_ref}
        ] do
      issue =
        Repo.insert!(%Issue{
          repository_id: base.id,
          number: 1,
          kind: :pull_request,
          title: "Competing",
          author_user_id: c.actor.id
        })

      pull =
        Repo.insert!(%PullRequest{
          repository_id: base.id,
          issue_id: issue.id,
          head_repository_id: head.id,
          head_ref: head_ref,
          base_ref: base_ref,
          head_sha: c.pull.head_sha,
          base_sha: c.pull.base_sha
        })

      {:ok, projection} = ForgePulls.sync_projection(base.id, :pull, pull.id)

      competing = %{
        request
        | repository_id: base.id,
          local_resource_id: pull.id,
          expected_head_repository_id: head.id,
          expected_fields: projection.fields,
          expected_local_version: projection.local_version,
          coordinator_operation_id: request.coordinator_operation_id + 1,
          request_id: "competing-cross-repository"
      }

      assert {:error, :prepared, :merge_reserved, _} = prepare(competing)
    end
  end

  test "stale aggregate version fields and head identity cannot prepare", c do
    for request <- [
          %{c.request | expected_local_version: c.issue.sync_version + 1},
          put_in(c.request, [:expected_fields, "head_sha"], String.duplicate("c", 40)),
          %{c.request | expected_head_repository_id: nil},
          %{c.request | expected_head_repository_id: c.repository.id + 1}
        ] do
      assert {:error, _, _, _} = prepare(request)
    end

    assert operation_count(c.repository.id) == 0
  end

  test "invalid coordinator and commit signature are rejected", c do
    for request <- [
          %{c.request | coordinator_operation_id: nil},
          %{c.request | coordinator_operation_id: -1},
          put_in(c.request, [:commit_intent, "committer", "seconds"], "now"),
          put_in(c.request, [:commit_intent, "author", "name"], "name\nparent injected"),
          put_in(c.request, [:commit_intent, "message"], String.duplicate("x", 70_000))
        ] do
      assert {:error, _, _, _} = prepare(request)
    end
  end

  test "caller transaction rollback leaves no durable intent", c do
    assert {:error, :rollback, :deliberate, _} =
             Multi.new()
             |> ForgePulls.append_prepare_coordinated_merge(:prepared, c.request)
             |> Multi.error(:rollback, :deliberate)
             |> Repo.transaction()

    assert operation_count(c.repository.id) == 0
  end

  test "ordinary recovery ignores mirror intent but cleanup retains its blocker", c do
    assert {:ok, %{prepared: prepared}} = prepare(c.request)

    assert :ok =
             MergeRecovery.reconcile_repository_locked(
               c.repository,
               ForgeRepos.absolute_storage_path(c.repository),
               System.monotonic_time(:millisecond) + 10_000
             )

    assert Repo.get!(MergeOperation, prepared.id).state == :prepared
    assert Repo.get!(MergeOperation, prepared.id).lease_owner == nil

    assert {:blocked, :claimable_operation} =
             MergeRecovery.cleanup_safety_locked(c.repository, DateTime.utc_now(:second))
  end

  test "ordinary state transitions cannot complete or rewrite mirror-owned intent", c do
    assert {:ok, %{prepared: prepared}} = prepare(c.request)
    refute MergeOperation.merge_written_changeset(prepared, String.duplicate("c", 40)).valid?
    refute MergeOperation.completed_changeset(%{prepared | state: :ref_advanced}).valid?

    refute MergeOperation.lease_update_changeset(prepared,
             state: :failed,
             failure_reason: "effect_not_started"
           ).valid?

    refute MergeOperation.prepare_coordinated_changeset(prepared, %{commit_intent: %{}}).valid?
  end

  test "database rejects a mirror intent with a null coordinator identity", c do
    assert {:ok, %{prepared: prepared}} = prepare(c.request)

    changeset =
      prepared
      |> Changeset.change(coordinator_operation_id: nil)
      |> Changeset.check_constraint(:commit_intent,
        name: :pull_merge_operations_coordination_check
      )

    assert {:error, rejected} = Repo.update(changeset, mode: :savepoint)
    assert rejected.errors[:commit_intent]

    assert Repo.get!(MergeOperation, prepared.id).coordinator_operation_id ==
             c.request.coordinator_operation_id
  end

  defp prepare(request),
    do:
      Multi.new()
      |> ForgePulls.append_prepare_coordinated_merge(:prepared, request)
      |> Repo.transaction()

  defp operation_count(repository_id),
    do:
      Repo.aggregate(
        from(operation in MergeOperation, where: operation.repository_id == ^repository_id),
        :count
      )
end
