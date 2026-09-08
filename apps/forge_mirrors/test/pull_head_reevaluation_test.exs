defmodule ForgeMirrors.PullHeadReevaluationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, MirrorRefState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(org)
    head = repository_mirror_fixture(org)
    actor = organization_owner_fixture(org)
    now = DateTime.utc_now(:second)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Read-only",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        repository_id: base.repository_id,
        issue_id: issue.id,
        head_repository_id: nil,
        head_ref: "refs/heads/topic",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    for {binding, ref, oid} <- [
          {base, pull.base_ref, pull.base_sha},
          {head, pull.head_ref, pull.head_sha}
        ],
        do:
          Repo.insert!(%MirrorRefState{
            repository_mirror_id: binding.id,
            ref_name: ref,
            ref_kind: :branch,
            state: :confirmed,
            confirmed_oid: oid,
            last_local_oid: oid,
            last_remote_oid: oid,
            last_confirmed_at: now
          })

    {:ok, local} = ForgePulls.sync_projection(base.repository_id, :pull, pull.id)

    identity = %{
      "github_issue_object_id" => 700,
      "github_issue_node_id" => "I_700",
      "github_number" => 7,
      "base_repository" => %{"id" => base.github_repository_id, "node_id" => base.github_node_id},
      "head_repository" => nil
    }

    merge = %{"merged_at" => nil, "merge_commit_sha" => nil}

    pull_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: base.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 1700,
        github_node_id: "PR_1700",
        github_number: 7,
        confirmed_snapshot: local.fields,
        confirmed_local_version: 1,
        confirmed_remote_updated_at: now,
        confirmed_merge_state: merge,
        provider_identity: identity,
        state: :unsupported
      })

    snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => []
      })

    issue_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: base.id,
        resource_kind: :issue,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: issue.id,
        github_object_id: 700,
        github_node_id: "I_700",
        github_number: 7,
        confirmed_snapshot: snapshot,
        confirmed_local_version: 1,
        confirmed_remote_updated_at: now,
        state: :confirmed
      })

    queued =
      operation_fixture(org, %{
        repository_mirror_id: base.id,
        kind: "sync.pull",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "pull",
          "github_object_id" => 1700,
          "github_number" => 7
        },
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("head-reevaluation", now, 120, 100, ["sync.pull"])

    operation = Enum.find(claimed, &(&1.id == queued.id))

    observation = %{
      pull: %{
        github_object_id: 1700,
        github_node_id: "PR_1700",
        github_number: 7,
        confirmed_snapshot: local.fields,
        confirmed_merge_state: merge,
        provider_identity: identity,
        remote_updated_at: now
      },
      issue: %{
        github_object_id: 700,
        github_node_id: "I_700",
        github_number: 7,
        confirmed_snapshot: snapshot,
        remote_updated_at: now
      }
    }

    %{
      org: org,
      base: base,
      head: head,
      issue: issue,
      pull: pull,
      local: local,
      pull_mapping: pull_mapping,
      issue_mapping: issue_mapping,
      operation: operation,
      observation: observation,
      now: now
    }
  end

  test "leased unsupported context binds exact canonical pair without treating it as missing",
       c do
    assert {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)
    assert context.resource.head_repository_id == nil
    assert context.pair.pull.mapping_id == c.pull_mapping.id
    assert context.pair.issue.mapping_id == c.issue_mapping.id
    assert context.provider_identity["head_repository"] == nil
  end

  test "corrupt existing unsupported mapping never grants missing-create fallback", c do
    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^c.pull_mapping.id),
      set: [local_resource_type: "ForgeIssues.Issue"]
    )

    assert {:error, :invalid_unsupported_pull} =
             ForgeMirrors.unsupported_pull_context(c.operation)
  end

  test "fresh head identity is revealed once and yields without changing baselines", c do
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)
    observation = with_head(c, %{"id" => 999_999_999, "node_id" => "R_external"})

    assert {:ok, result} =
             ForgeMirrors.pin_unsupported_pull_head(c.operation, c.now, context.pair, observation)

    assert result.operation.state == :pending

    assert result.pull_state.provider_identity["head_repository"] ==
             observation.pull.provider_identity["head_repository"]

    assert result.pull_state.confirmed_snapshot == c.pull_mapping.confirmed_snapshot
    assert result.pull_state.confirmed_local_version == 1
    assert result.pull_state.state == :unsupported
    assert Repo.get!(MirrorResourceState, c.issue_mapping.id) == c.issue_mapping
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).head_repository_id == nil
  end

  test "known head cannot be replaced or downgraded and stale pair cannot reveal", c do
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    assert {:error, :stale_paired_mapping} =
             ForgeMirrors.pin_unsupported_pull_head(
               c.operation,
               c.now,
               put_in(context.pair, [:pull, :lock_version], 999),
               with_head(c, head_identity(c))
             )

    changeset = MirrorResourceState.reveal_head_changeset(c.pull_mapping, head_identity(c))
    known = Repo.update!(changeset)
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    for observation <- [
          c.observation,
          with_head(c, %{"id" => 999_999_999, "node_id" => "R_other"})
        ] do
      assert {:error, :identity_conflict} =
               ForgeMirrors.resolve_unsupported_pull_head(c.operation, context.pair, observation)
    end

    refute MirrorResourceState.reveal_head_changeset(known, head_identity(c)).valid?
  end

  test "active represented head is enabled atomically at the new canonical version", c do
    c = known(c)
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    assert {:ok, resolution} =
             ForgeMirrors.resolve_unsupported_pull_head(c.operation, context.pair, c.observation)

    expected = %{
      pair: context.pair,
      head_repository_id: resolution.head_repository_id,
      pull_eligibility_proof: resolution.pull_eligibility_proof
    }

    assert {:ok, result} =
             ForgeMirrors.confirm_unsupported_pull_head(
               c.operation,
               c.now,
               expected,
               c.observation
             )

    assert result.operation.state == :completed
    assert result.resource.head_repository_id == c.head.repository_id
    assert result.resource.local_version == 2
    assert result.pull_state.state == :confirmed
    assert result.pull_state.confirmed_local_version == 2
    assert result.issue_state.confirmed_local_version == 2
    assert result.pull_state.confirmed_snapshot == c.pull_mapping.confirmed_snapshot
    assert result.issue_state.confirmed_snapshot == c.issue_mapping.confirmed_snapshot
  end

  test "newer local metadata cannot silently rebase during representation", c do
    c = known(c)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [title: "Local edit", sync_version: 2]
    )

    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    {:ok, resolution} =
      ForgeMirrors.resolve_unsupported_pull_head(c.operation, context.pair, c.observation)

    expected = %{
      pair: context.pair,
      head_repository_id: resolution.head_repository_id,
      pull_eligibility_proof: resolution.pull_eligibility_proof
    }

    assert {:error, :unsupported_metadata_conflict} =
             ForgeMirrors.confirm_unsupported_pull_head(
               c.operation,
               c.now,
               expected,
               c.observation
             )

    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).head_repository_id == nil
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Local edit"
    assert Repo.get!(MirrorResourceState, c.pull_mapping.id).state == :unsupported
  end

  test "still unavailable head completes observation but never enables writes", c do
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)
    expected = %{pair: context.pair, head_repository_id: nil, pull_eligibility_proof: nil}

    assert {:ok, result} =
             ForgeMirrors.confirm_unsupported_pull_head(
               c.operation,
               c.now,
               expected,
               c.observation
             )

    assert result.operation.state == :completed
    assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == 1
  end

  test "known unready head remains retryable and expired lease cannot reveal", c do
    c = known(c)
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    Repo.update_all(from(b in ForgeMirrors.RepositoryMirror, where: b.id == ^c.head.id),
      set: [state: :discovered]
    )

    assert {:error, :head_not_ready} =
             ForgeMirrors.resolve_unsupported_pull_head(c.operation, context.pair, c.observation)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} =
             ForgeMirrors.pin_unsupported_pull_head(
               c.operation,
               c.now,
               context.pair,
               c.observation
             )
  end

  test "opaque head does not acknowledge fresh remote scalar or relationship drift", c do
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)
    expected = %{pair: context.pair, head_repository_id: nil, pull_eligibility_proof: nil}

    scalar =
      c.observation
      |> put_in([:pull, :confirmed_snapshot, "title"], "Remote edit")
      |> put_in([:issue, :confirmed_snapshot, "title"], "Remote edit")

    sets = put_in(c.observation, [:issue, :confirmed_snapshot, "label_github_ids"], [808])

    for observation <- [scalar, sets] do
      assert {:error, :unsupported_metadata_conflict} =
               ForgeMirrors.confirm_unsupported_pull_head(
                 c.operation,
                 c.now,
                 expected,
                 observation
               )

      assert Repo.get!(MirrorOperation, c.operation.id).state == :processing
      assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
    end
  end

  test "opaque head does not acknowledge newer local metadata", c do
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [title: "Local edit", sync_version: 2]
    )

    expected = %{pair: context.pair, head_repository_id: nil, pull_eligibility_proof: nil}

    assert {:error, :unsupported_metadata_conflict} =
             ForgeMirrors.confirm_unsupported_pull_head(
               c.operation,
               c.now,
               expected,
               c.observation
             )

    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Local edit"
    assert Repo.get!(MirrorOperation, c.operation.id).state == :processing
  end

  test "unversioned local merge fact drift cannot activate a head", c do
    c = known(c)
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)

    {:ok, resolution} =
      ForgeMirrors.resolve_unsupported_pull_head(c.operation, context.pair, c.observation)

    Repo.update_all(from(p in ForgePulls.PullRequest, where: p.id == ^c.pull.id),
      set: [merge_commit_sha: String.duplicate("c", 40)]
    )

    expected =
      Map.merge(Map.take(resolution, [:head_repository_id, :pull_eligibility_proof]), %{
        pair: context.pair
      })

    assert {:error, :unsupported_metadata_conflict} =
             ForgeMirrors.confirm_unsupported_pull_head(
               c.operation,
               c.now,
               expected,
               c.observation
             )

    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).head_repository_id == nil
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == 1
  end

  test "paired provider or saved head ref substitution never reveals identity", c do
    {:ok, context} = ForgeMirrors.unsupported_pull_context(c.operation)
    observation = with_head(c, head_identity(c))

    for bad <- [
          put_in(observation, [:pull, :provider_identity, "github_issue_object_id"], 701),
          put_in(observation, [:pull, :confirmed_snapshot, "head_sha"], String.duplicate("c", 40))
        ] do
      assert {:error, :identity_conflict} =
               ForgeMirrors.pin_unsupported_pull_head(c.operation, c.now, context.pair, bad)
    end
  end

  for side <- [:base, :head] do
    test "#{side} advisory contention rejects reevaluation without a blocking row-lock cycle",
         c do
      c = known(c)
      key = "fornacast:merge-reservation:#{Map.fetch!(c, unquote(side)).repository_id}"
      owner = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              %{rows: [[pid, _]]} =
                Ecto.Adapters.SQL.query!(
                  Repo,
                  "SELECT pg_backend_pid(), pg_advisory_xact_lock(hashtextextended($1, 0))",
                  [key]
                )

              send(owner, {:locked, pid})

              receive do
                :release -> :ok
              after
                1_000 -> :probe_timeout
              end
            end)
          end)
        end)

      try do
        assert_receive {:locked, pid}, 2_000
        %{rows: [[own_pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
        refute own_pid == pid
        assert {:error, :busy} = ForgeMirrors.unsupported_pull_context(c.operation)
        assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == 1
        assert Repo.get!(ForgePulls.PullRequest, c.pull.id).head_repository_id == nil
        assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
      after
        send(task.pid, :release)
        Task.await(task, 5_000)
      end
    end
  end

  defp known(c) do
    mapping =
      c.pull_mapping
      |> MirrorResourceState.reveal_head_changeset(head_identity(c))
      |> Repo.update!()

    %{c | pull_mapping: mapping, observation: with_head(c, head_identity(c))}
  end

  defp head_identity(c),
    do: %{"id" => c.head.github_repository_id, "node_id" => c.head.github_node_id}

  defp with_head(c, head),
    do: put_in(c.observation, [:pull, :provider_identity, "head_repository"], head)
end
