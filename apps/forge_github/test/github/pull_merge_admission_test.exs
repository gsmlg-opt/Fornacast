defmodule ForgeGitHub.PullMergeAdmissionTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Changeset

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState
  }

  alias ForgePulls.{MergeOperation, PullRequest}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: organization.github_installation_id
    )
    |> Changeset.change(
      permissions: %{
        "contents" => "write",
        "pull_requests" => "read",
        "issues" => "read",
        "metadata" => "read"
      }
    )
    |> Repo.update!()

    binding = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)

    repository =
      binding.repository_id
      |> ForgeRepos.fetch_live_repository()
      |> then(fn {:ok, repository} -> repository end)
      |> Changeset.change(allow_merge_commit: true)
      |> Repo.update!()

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: repository.id,
        number: 7,
        kind: :pull_request,
        title: "Merge this",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%PullRequest{
        issue_id: issue.id,
        repository_id: repository.id,
        head_repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    now = ~U[2026-09-14 12:00:00Z]

    for {ref, oid} <- [{pull.base_ref, pull.base_sha}, {pull.head_ref, pull.head_sha}] do
      %MirrorRefState{}
      |> MirrorRefState.persistence_changeset(%{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: now
      })
      |> Repo.insert!()
    end

    {:ok, local} = ForgePulls.sync_projection(repository.id, :pull, pull.id)

    identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => issue.number,
      "base_repository" => %{
        "id" => binding.github_repository_id,
        "node_id" => binding.github_node_id
      },
      "head_repository" => %{
        "id" => binding.github_repository_id,
        "node_id" => binding.github_node_id
      }
    }

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: binding.id,
      resource_kind: :pull,
      local_resource_type: "ForgePulls.PullRequest",
      local_resource_id: pull.id,
      github_object_id: 902,
      github_node_id: "PR_902",
      github_number: issue.number,
      confirmed_local_version: local.local_version,
      confirmed_remote_updated_at: now,
      confirmed_snapshot: local.fields,
      confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
      provider_identity: identity,
      state: :confirmed
    })
    |> Repo.insert!()

    %{
      actor: actor,
      binding: binding,
      issue: issue,
      now: now,
      pull: pull,
      repository: repository
    }
  end

  test "one transaction admits the scheduler operation, intent, and exact checkpoint", c do
    assert {:ok, first} = admit(c)
    assert first.operation.state == :pending
    assert first.operation.lease_owner == nil
    assert first.intent.state == :prepared
    assert first.intent.coordinator_operation_id == first.operation.id

    preparation = first.operation.checkpoint["merge_preparation"]
    assert preparation["merge_operation_id"] == first.intent.id
    assert preparation["pull_id"] == c.pull.id
    assert preparation["issue_id"] == c.issue.id

    assert {:ok, replay} = admit(c)
    assert replay.operation.id == first.operation.id
    assert replay.operation.checkpoint == first.operation.checkpoint
    assert replay.intent.id == first.intent.id
    assert replay.intent.commit_intent == first.intent.commit_intent
  end

  test "invalid intent data rolls back the newly enqueued scheduler operation", c do
    assert {:error, {:validation, _errors}} =
             ForgeGitHub.PullMergeAdmission.admit(
               c.repository,
               c.pull,
               c.actor,
               %{"merge_method" => "merge", "commit_title" => ""},
               metadata(c),
               now: fn -> c.now end
             )

    refute Repo.exists?(from operation in MirrorOperation, where: operation.kind == "merge.pull")

    refute Repo.exists?(
             from intent in MergeOperation, where: intent.pull_request_id == ^c.pull.id
           )
  end

  test "an exact request id cannot be replayed with a different merge message", c do
    assert {:ok, first} = admit(c)

    assert {:error, :merge_intent_conflict} =
             ForgeGitHub.PullMergeAdmission.admit(
               c.repository,
               c.pull,
               c.actor,
               %{
                 "merge_method" => "merge",
                 "sha" => c.pull.head_sha,
                 "commit_message" => "Different"
               },
               metadata(c),
               now: fn -> DateTime.add(c.now, 60) end
             )

    assert Repo.get!(MirrorOperation, first.operation.id).checkpoint == first.operation.checkpoint
    assert Repo.get!(MergeOperation, first.intent.id).commit_intent == first.intent.commit_intent
  end

  test "nonpending replay rejects changed message and head sha in every operation state", c do
    assert {:ok, admitted} = admit(c)

    changed_requests = [
      %{
        "merge_method" => "merge",
        "sha" => c.pull.head_sha,
        "commit_message" => "Different"
      },
      %{"merge_method" => "merge", "sha" => String.duplicate("c", 40)}
    ]

    states = [
      processing: [
        lease_owner: "replay-worker",
        lease_expires_at: DateTime.add(c.now, 60)
      ],
      effect_pending: [
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: %{"phase" => "remote_cas_pending"},
        effect_marked_at: c.now
      ],
      completed: [
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        completed_at: c.now
      ],
      failed: [
        completed_at: nil,
        failure_class: "local_validation",
        failure_disposition: :terminal,
        failure_detail: "terminal"
      ]
    ]

    Enum.reduce(states, admitted.operation, fn {state, state_attrs}, operation ->
      operation =
        operation
        |> Changeset.change(Keyword.merge([state: state], state_attrs))
        |> Repo.update!()

      for changed_attrs <- changed_requests do
        assert {:error, :merge_intent_conflict} =
                 ForgeGitHub.PullMergeAdmission.admit(
                   c.repository,
                   c.pull,
                   c.actor,
                   changed_attrs,
                   metadata(c),
                   now: fn -> DateTime.add(c.now, 60) end
                 )
      end

      operation
    end)
  end

  test "admission rechecks the current repository merge policy inside its transaction", c do
    c.repository
    |> Changeset.change(allow_merge_commit: false)
    |> Repo.update!()

    assert {:error, :merge_commits_disabled} = admit(c)
    refute Repo.exists?(from operation in MirrorOperation, where: operation.kind == "merge.pull")

    refute Repo.exists?(
             from intent in MergeOperation, where: intent.pull_request_id == ^c.pull.id
           )
  end

  test "existing-operation replay reauthorizes the requester", c do
    assert {:ok, admitted} = admit(c)

    admitted.operation
    |> Changeset.change(
      state: :processing,
      lease_owner: "replay-worker",
      lease_expires_at: DateTime.add(c.now, 60)
    )
    |> Repo.update!()

    c.actor
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert {:error, :forbidden} = admit(c)
  end

  test "a mirrored request times out safely while durable recovery remains queued", c do
    assert {:error, {:unavailable, :mirror_merge_pending}} =
             ForgeGitHub.PullMergeAdmission.merge(
               c.repository,
               c.pull,
               c.actor,
               attrs(c),
               metadata(c),
               now: fn -> c.now end,
               worker_available?: fn -> true end,
               wake_worker: fn -> :ok end,
               await_timeout_ms: 0
             )

    operation =
      Repo.one!(from operation in MirrorOperation, where: operation.kind == "merge.pull")

    intent = Repo.get_by!(MergeOperation, coordinator_operation_id: operation.id)
    assert operation.state == :pending
    assert operation.checkpoint["merge_preparation"]["merge_operation_id"] == intent.id
    assert intent.state == :prepared
  end

  test "a terminal worker failure returns unavailable without waiting as pending", c do
    assert {:ok, admitted} = admit(c)

    admitted.operation
    |> Changeset.change(
      state: :failed,
      failure_class: "local_validation",
      failure_disposition: :terminal,
      failure_detail: "coordinated merge state is invalid"
    )
    |> Repo.update!()

    assert {:error, {:unavailable, :mirror_merge_failed}} =
             ForgeGitHub.PullMergeAdmission.merge(
               c.repository,
               c.pull,
               c.actor,
               attrs(c),
               metadata(c),
               worker_available?: fn -> true end,
               wake_worker: fn -> :ok end,
               await_timeout_ms: 0
             )
  end

  test "a failed conflict remains a conflict instead of an unavailable worker failure", c do
    assert {:ok, admitted} = admit(c)

    admitted.operation
    |> Changeset.change(
      state: :failed,
      failure_class: "stale_baseline",
      failure_disposition: :conflict,
      failure_detail: "base changed"
    )
    |> Repo.update!()

    assert {:error, :conflict} =
             ForgeGitHub.PullMergeAdmission.merge(
               c.repository,
               c.pull,
               c.actor,
               attrs(c),
               metadata(c),
               worker_available?: fn -> true end,
               wake_worker: fn -> :ok end,
               await_timeout_ms: 0
             )
  end

  test "the same completed request returns the exact durable merge result", c do
    assert {:ok, admitted} = admit(c)
    merge_oid = String.duplicate("c", 40)

    admitted.operation
    |> Changeset.change(state: :completed, completed_at: c.now)
    |> Repo.update!()

    admitted.intent
    |> Changeset.change(
      state: :completed,
      merge_tree_oid: String.duplicate("d", 40),
      merge_oid: merge_oid
    )
    |> Repo.update!()

    c.pull
    |> Changeset.change(merged_at: c.now, merge_commit_sha: merge_oid)
    |> Repo.update!()

    assert {:ok,
            %{
              merged: true,
              message: "Pull Request successfully merged",
              sha: ^merge_oid
            }} =
             ForgeGitHub.PullMergeAdmission.merge(
               c.repository,
               c.pull,
               c.actor,
               attrs(c),
               metadata(c),
               worker_available?: fn -> true end,
               wake_worker: fn -> :ok end
             )
  end

  test "a mirror-owned repository never falls back when the worker is unavailable", c do
    assert {:error, {:unavailable, :mirror_merge_worker}} =
             ForgeGitHub.PullMergeAdmission.merge(
               c.repository,
               c.pull,
               c.actor,
               attrs(c),
               metadata(c),
               worker_available?: fn -> false end,
               standalone_merge: fn _, _, _, _, _ -> flunk("must not merge independently") end
             )

    refute Repo.exists?(from operation in MirrorOperation, where: operation.kind == "merge.pull")
  end

  test "an unmirrored repository preserves the standalone merge route", c do
    parent = self()
    repository = %{c.repository | id: c.repository.id + 9_000_000}
    pull = %{c.pull | repository_id: repository.id, head_repository_id: repository.id}

    expected = {:ok, %{merged: true, message: "standalone", sha: String.duplicate("c", 40)}}

    assert ^expected =
             ForgeGitHub.PullMergeAdmission.merge(
               repository,
               pull,
               c.actor,
               attrs(c),
               metadata(c),
               standalone_merge: fn repository, pull, actor, attrs, request_metadata ->
                 send(parent, {repository, pull, actor, attrs, request_metadata})
                 expected
               end
             )

    actor = c.actor
    assert_received {^repository, ^pull, ^actor, attrs, metadata}
    assert attrs == attrs(c)
    assert metadata == metadata(c)
  end

  defp admit(c) do
    ForgeGitHub.PullMergeAdmission.admit(
      c.repository,
      c.pull,
      c.actor,
      attrs(c),
      metadata(c),
      now: fn -> c.now end
    )
  end

  defp attrs(c), do: %{"merge_method" => "merge", "sha" => c.pull.head_sha}
  defp metadata(_c), do: %{request_id: "merge-admission-request"}
end
