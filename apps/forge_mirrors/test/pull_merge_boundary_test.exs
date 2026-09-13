defmodule ForgeMirrors.PullMergeBoundaryTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.{Changeset, Multi}
  alias ForgeMirrors.{MirrorRefState, MirrorResourceState, PullEligibility, PullMergeBoundary}
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
    head = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: binding.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Merge",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: binding.repository_id,
        head_repository_id: head.repository_id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    now = DateTime.utc_now(:second)

    for {mirror, ref, oid} <- [
          {binding, pull.base_ref, pull.base_sha},
          {head, pull.head_ref, pull.head_sha}
        ] do
      %MirrorRefState{}
      |> MirrorRefState.persistence_changeset(%{
        repository_mirror_id: mirror.id,
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

    {:ok, local} = ForgePulls.sync_projection(binding.repository_id, :pull, pull.id)

    identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => %{
        "id" => binding.github_repository_id,
        "node_id" => binding.github_node_id
      },
      "head_repository" => %{"id" => head.github_repository_id, "node_id" => head.github_node_id}
    }

    mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: binding.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 902,
        github_node_id: "PR_902",
        github_number: 7,
        confirmed_local_version: local.local_version,
        confirmed_remote_updated_at: now,
        confirmed_snapshot: local.fields,
        confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
        provider_identity: identity,
        state: :confirmed
      })
      |> Repo.insert!()

    operation =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "merge.pull",
        cursor: %{"issue_id" => issue.id, "pull_id" => pull.id},
        next_attempt_at: now
      })

    {:ok, claimed} = ForgeMirrors.claim_operations("merge-boundary", now, 60, 100, ["merge.pull"])
    operation = Enum.find(claimed, &(&1.id == operation.id))

    {:ok, proof} =
      PullEligibility.check(
        binding.id,
        head.repository_id,
        Map.take(pull, [:base_ref, :head_ref, :base_sha, :head_sha])
      )

    expected = %{
      pull_id: pull.id,
      issue_id: issue.id,
      local_version: local.local_version,
      fields: local.fields,
      provider_identity: identity,
      resource_state_lock_version: mapping.lock_version,
      pull_eligibility_proof: json(proof)
    }

    signature = %{
      "name" => actor.username,
      "email" => actor.email,
      "seconds" => 1_750_000_000,
      "offset_minutes" => 0
    }

    request = %{
      repository_id: binding.repository_id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      expected_local_version: local.local_version,
      expected_fields: local.fields,
      expected_merge_state: local.merge_state,
      expected_head_repository_id: head.repository_id,
      coordinator_operation_id: operation.id,
      actor_user_id: actor.id,
      request_id: "merge-#{operation.id}",
      commit_intent: %{"message" => "Merge", "author" => signature, "committer" => signature}
    }

    %{
      organization: organization,
      binding: binding,
      head: head,
      issue: issue,
      pull: pull,
      operation: operation,
      mapping: mapping,
      expected: expected,
      request: request,
      now: now
    }
  end

  test "leased preparation persists one exact replayable reservation and context", c do
    assert {:ok, %{reserved: intent}} = prepare(c)
    assert intent.coordinator_operation_id == c.operation.id
    assert {:ok, %{reserved: replay}} = prepare(c)
    assert replay.id == intent.id
    assert {:ok, context} = PullMergeBoundary.context(c.operation, c.now)
    assert context.intent.id == intent.id
    assert context.expected == c.expected
    assert intent.merge_oid == nil
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
  end

  test "pending admission atomically persists one exact replayable reservation", c do
    c = pending(c)

    assert {:ok, %{admitted: intent}} = admit(c)
    assert intent.coordinator_operation_id == c.operation.id
    assert {:ok, %{admitted: replay}} = admit(c)
    assert replay.id == intent.id

    persisted = Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id)
    assert persisted.state == :pending
    assert persisted.lease_owner == nil
    assert persisted.lease_expires_at == nil
    assert persisted.checkpoint["merge_preparation"]["merge_operation_id"] == intent.id
    assert persisted.checkpoint["merge_preparation"]["pull_id"] == c.pull.id
  end

  test "pending operation, coordinated intent and preparation checkpoint roll back together", c do
    c = pending(c)

    multi =
      Multi.new()
      |> PullMergeBoundary.append_admit(
        :admitted,
        c.operation,
        c.now,
        c.expected,
        request_fingerprint(c),
        domain(c)
      )
      |> Multi.error(:abort, :deliberate)

    assert {:error, :abort, :deliberate, _} = Repo.transaction(multi)
    assert Repo.get_by(ForgePulls.MergeOperation, coordinator_operation_id: c.operation.id) == nil
    assert Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).checkpoint == %{}
  end

  test "pending admission rejects changed request evidence without rewriting its checkpoint", c do
    c = pending(c)
    assert {:ok, %{admitted: intent}} = admit(c)
    checkpoint = Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).checkpoint

    changed = %{
      c.request
      | commit_intent: Map.put(c.request.commit_intent, "message", "Different merge")
    }

    assert {:error, :admitted, :merge_intent_conflict, _} =
             Multi.new()
             |> PullMergeBoundary.append_admit(
               :admitted,
               c.operation,
               c.now,
               c.expected,
               request_fingerprint(c),
               Multi.new()
               |> ForgePulls.append_prepare_coordinated_merge(:intent, changed)
             )
             |> Repo.transaction()

    assert Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).checkpoint == checkpoint
    assert Repo.get!(ForgePulls.MergeOperation, intent.id).commit_intent == intent.commit_intent
  end

  test "domain and reservation roll back together", c do
    multi =
      Multi.new()
      |> PullMergeBoundary.append_prepare(:reserved, c.operation, c.now, c.expected, domain(c))
      |> Multi.error(:abort, :deliberate)

    assert {:error, :abort, :deliberate, _} = Repo.transaction(multi)
    assert Repo.get_by(ForgePulls.MergeOperation, coordinator_operation_id: c.operation.id) == nil
  end

  test "competing merge base cannot write a reserved head and competing head cannot read a reserved base",
       c do
    assert {:ok, %{reserved: _}} = prepare(c)
    third = repository_mirror_fixture(c.organization)

    assert {:ok, {:error, :merge_reserved}} =
             Repo.transaction(fn ->
               PullMergeBoundary.check_unreserved(
                 c.head.repository_id,
                 c.pull.head_ref,
                 c.pull.id + 1,
                 c.operation.id + 1,
                 third.repository_id,
                 "refs/heads/topic"
               )
             end)

    assert {:ok, {:error, :merge_reserved}} =
             Repo.transaction(fn ->
               PullMergeBoundary.check_unreserved(
                 third.repository_id,
                 "refs/heads/main",
                 c.pull.id + 1,
                 c.operation.id + 1,
                 c.binding.repository_id,
                 c.pull.base_ref
               )
             end)

    # Two independent bases may read the same immutable head; neither writes it.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               PullMergeBoundary.check_unreserved(
                 third.repository_id,
                 "refs/heads/main",
                 c.pull.id + 1,
                 c.operation.id + 1,
                 c.head.repository_id,
                 c.pull.head_ref
               )
             end)
  end

  test "lease expiration during the domain callback rolls back intent and checkpoint", c do
    operation =
      c.operation
      |> Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(:second), 3, :second))
      |> Repo.update!()

    c = %{c | operation: operation}

    domain =
      domain(c)
      |> Multi.run(:blocked_domain_work, fn _, _ ->
        send(self(), :entered_domain_callback)
        Process.sleep(3_100)
        {:ok, :resumed_after_expiry}
      end)

    assert {:error, :reserved, :lost_lease, _} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(:reserved, operation, c.now, c.expected, domain)
             |> Repo.transaction()

    assert_received :entered_domain_callback
    assert Repo.get_by(ForgePulls.MergeOperation, coordinator_operation_id: operation.id) == nil
    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).checkpoint == %{}
  end

  test "independent PostgreSQL connection cannot acquire either ref reservation before intent publication",
       c do
    domain =
      Multi.new()
      |> Multi.run(:lock_probe, fn repo, _ ->
        assert repo.get_by(ForgePulls.MergeOperation, coordinator_operation_id: c.operation.id) ==
                 nil

        %{rows: [[owner_pid]]} = Ecto.Adapters.SQL.query!(repo, "SELECT pg_backend_pid()", [])

        keys =
          [c.binding.repository_id, c.head.repository_id]
          |> Enum.sort()
          |> Enum.map(&"fornacast:merge-reservation:#{&1}")

        task =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              # A single auto-commit statement: even an erroneously acquired xact
              # lock is released at statement end, and unboxed_run returns its connection.
              Ecto.Adapters.SQL.query!(
                Repo,
                "SELECT pg_backend_pid(), pg_try_advisory_xact_lock(hashtextextended($1, 0)), pg_try_advisory_xact_lock(hashtextextended($2, 0))",
                keys
              )
            end)
          end)

        assert %{rows: [[probe_pid, false, false]]} = Task.await(task, 5_000)
        refute probe_pid == owner_pid
        {:ok, :both_locked}
      end)
      |> ForgePulls.append_prepare_coordinated_merge(:intent, c.request)

    assert {:ok, %{reserved: _}} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(
               :reserved,
               c.operation,
               c.now,
               c.expected,
               domain
             )
             |> Repo.transaction()
  end

  test "a callback cannot claim a reservation without a persisted intent", c do
    fake = %ForgePulls.MergeOperation{
      id: 9_000_000,
      repository_id: c.binding.repository_id,
      pull_request_id: c.pull.id,
      coordinator_operation_id: c.operation.id,
      coordination_mode: :mirror,
      state: :prepared,
      base_ref: c.pull.base_ref,
      head_ref: c.pull.head_ref,
      expected_base_oid: c.pull.base_sha,
      expected_head_oid: c.pull.head_sha,
      commit_intent:
        Map.put(c.request.commit_intent, "resource", %{
          "issue_id" => c.issue.id,
          "expected_local_version" => c.expected.local_version,
          "expected_fields" => c.expected.fields,
          "head_repository_id" => c.head.repository_id,
          "repository_generation" => 1,
          "head_repository_generation" => 1
        })
    }

    domain = Multi.new() |> Multi.put(:intent, fake)

    assert {:error, :reserved, :invalid_merge_intent, _} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(
               :reserved,
               c.operation,
               c.now,
               c.expected,
               domain
             )
             |> Repo.transaction()

    assert Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).checkpoint == %{}
  end

  test "stale capability and changed claimed identity fail before intent", c do
    for operation <- [
          %{c.operation | lock_version: c.operation.lock_version + 1},
          %{c.operation | lease_owner: "other"},
          %{c.operation | lease_owner: nil},
          %{c.operation | repository_mirror_id: c.head.id}
        ] do
      assert {:error, :reserved, :lost_lease, _} = prepare(%{c | operation: operation})
    end

    assert Repo.get_by(ForgePulls.MergeOperation, coordinator_operation_id: c.operation.id) == nil
  end

  test "paused organization and revoked installation cannot prepare", c do
    c.organization |> Changeset.change(state: :paused) |> Repo.update!()
    assert {:error, :reserved, _, _} = prepare(c)

    Repo.get!(ForgeMirrors.OrganizationMirror, c.organization.id)
    |> Changeset.change(state: :active)
    |> Repo.update!()

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: c.organization.github_installation_id
      )

    installation |> Changeset.change(state: :revoked) |> Repo.update!()
    assert {:error, :reserved, _, _} = prepare(c)
  end

  test "stale fields mapping version generation and immutable provider proof are rejected", c do
    for expected <- [
          %{c.expected | local_version: c.expected.local_version + 1},
          %{c.expected | resource_state_lock_version: c.mapping.lock_version + 1},
          put_in(c.expected, [:fields, "title"], "changed"),
          put_in(c.expected, [:provider_identity, "github_issue_object_id"], 999),
          put_in(c.expected, [:pull_eligibility_proof, "base", "repository_generation"], 99)
        ] do
      assert {:error, :reserved, _, _} = prepare(%{c | expected: expected})
    end
  end

  test "already pending remote ref effect prevents creating the reservation", c do
    operation_fixture(c.organization, %{
      repository_mirror_id: c.head.id,
      kind: "sync.git_ref",
      cursor: %{"ref_name" => c.pull.head_ref},
      next_attempt_at: c.now
    })
    |> Changeset.change(
      state: :effect_pending,
      external_effect_marker: %{"action" => "apply_remote"},
      effect_marked_at: c.now
    )
    |> Repo.update!()

    assert {:error, :reserved, :ref_effect_pending, _} = prepare(c)
  end

  test "authorization rechecks reservation and live scope after preparation", c do
    assert {:ok, %{reserved: intent}} = prepare(c)

    assert {:ok, :ok} =
             Repo.transaction(fn -> PullMergeBoundary.authorize(c.operation, c.now, intent) end)

    c.head |> Changeset.change(inventory_included: false) |> Repo.update!()

    assert {:ok, {:error, _}} =
             Repo.transaction(fn -> PullMergeBoundary.authorize(c.operation, c.now, intent) end)
  end

  test "no remote marker without a persisted exact tree and commit", c do
    assert {:ok, %{reserved: intent}} = prepare(c)

    marker = %{
      "phase" => "remote_cas_pending",
      "merge_operation_id" => intent.id,
      "merge_tree_oid" => String.duplicate("c", 40),
      "merge_oid" => String.duplicate("d", 40)
    }

    assert {:error, _} = PullMergeBoundary.mark(c.operation, c.now, nil, marker)
    assert Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  test "only exact committed M can be marked and replay cannot replace its proof", c do
    assert {:ok, %{reserved: intent}} = prepare(c)
    tree = String.duplicate("c", 40)
    oid = String.duplicate("d", 40)

    intent
    |> Changeset.change(state: :merge_written, merge_tree_oid: tree, merge_oid: oid)
    |> Repo.update!()

    marker = %{
      "phase" => "remote_cas_pending",
      "merge_operation_id" => intent.id,
      "merge_tree_oid" => tree,
      "merge_oid" => oid
    }

    assert {:ok, marked} = PullMergeBoundary.mark(c.operation, c.now, nil, marker)
    assert marked.state == :effect_pending
    assert marked.external_effect_marker["merge_oid"] == oid

    assert {:ok, replay} =
             PullMergeBoundary.mark(marked, c.now, marked.external_effect_marker, marker)

    assert replay.external_effect_marker == marked.external_effect_marker

    assert {:error, _} =
             PullMergeBoundary.mark(replay, c.now, replay.external_effect_marker, %{
               marker
               | "merge_oid" => String.duplicate("e", 40)
             })

    assert {:error, _} =
             PullMergeBoundary.mark(replay, c.now, replay.external_effect_marker, %{
               marker
               | "phase" => "remote_proven"
             })

    assert {:error, _} = PullMergeBoundary.mark(c.operation, c.now, nil, marker)
  end

  test "ordinary ref marking and confirmation cannot cross a reserved base", c do
    assert {:ok, %{reserved: _}} = prepare(c)
    fail_coordinator(c)
    operation = claim_child(c, "sync.git_ref", %{"ref_name" => c.pull.base_ref})

    assert {:error, :merge_reserved} =
             ForgeMirrors.mark_external_effect(operation, c.now, %{
               "action" => "apply_remote",
               "expected_oid" => c.pull.base_sha,
               "proposed_oid" => String.duplicate("d", 40)
             })

    assert {:error, :merge_reserved} =
             ForgeMirrors.confirm_git_ref(
               operation,
               c.pull.base_ref,
               c.pull.base_sha,
               c.pull.base_sha,
               c.now
             )

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).state == :processing

    assert {:ok, _} =
             ForgeMirrors.fail_operation(
               operation,
               c.now,
               "provider_validation",
               "test coordinator reservation remains in force"
             )

    unrelated = claim_child(c, "sync.git_ref", %{"ref_name" => "refs/heads/unrelated"})

    assert {:ok, _} =
             ForgeMirrors.mark_external_effect(unrelated, c.now, %{
               "action" => "apply_remote",
               "proposed_oid" => String.duplicate("d", 40)
             })

    head_operation =
      claim_child(%{c | binding: c.head}, "sync.git_ref", %{"ref_name" => c.pull.head_ref})

    assert {:error, :merge_reserved} =
             ForgeMirrors.mark_external_effect(head_operation, c.now, %{
               "action" => "apply_remote",
               "proposed_oid" => String.duplicate("d", 40)
             })
  end

  test "ordinary PR marking cannot cross a reserved canonical pull", c do
    assert {:ok, %{reserved: _}} = prepare(c)
    fail_coordinator(c)

    operation =
      claim_child(c, "sync.pull", %{
        "trigger" => "local",
        "issue_kind" => "pull_request",
        "issue_id" => c.issue.id,
        "sync_version" => c.issue.sync_version
      })

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(c.expected.fields)

    marker = %{
      "action" => "update_remote_pull_issue",
      "github_object_id" => 902,
      "github_node_id" => "PR_902",
      "github_number" => 7,
      "expected_local_version" => c.expected.local_version,
      "expected_local_fingerprint" => fingerprint,
      "proposed_fingerprint" => fingerprint,
      "resource_state_lock_version" => c.mapping.lock_version,
      "provider_identity" => c.expected.provider_identity,
      "pull_eligibility_proof" => c.expected.pull_eligibility_proof,
      "expected_merge_state" => %{"merged_at" => nil, "merge_commit_sha" => nil}
    }

    assert {:error, :merge_reserved} = ForgeMirrors.mark_external_effect(operation, c.now, marker)
    assert {:error, :merge_reserved} = ForgeMirrors.resource_operation_context(operation)
  end

  test "generic effect marking cannot bypass the merge-specific proof boundary", c do
    assert {:ok, %{reserved: _}} = prepare(c)

    assert {:error, :invalid_transition} =
             ForgeMirrors.mark_external_effect(c.operation, c.now, %{
               "action" => "push",
               "merge_oid" => String.duplicate("d", 40)
             })
  end

  for action <- [:complete, :retry, :fail] do
    test "generic #{action} cannot discard coordinated merge effect evidence", c do
      assert {:ok, %{reserved: intent}} = prepare(c)
      tree = String.duplicate("c", 40)
      oid = String.duplicate("d", 40)

      intent
      |> Changeset.change(state: :merge_written, merge_tree_oid: tree, merge_oid: oid)
      |> Repo.update!()

      marker = %{
        "phase" => "remote_cas_pending",
        "merge_operation_id" => intent.id,
        "merge_tree_oid" => tree,
        "merge_oid" => oid
      }

      assert {:ok, marked} = PullMergeBoundary.mark(c.operation, c.now, nil, marker)

      result =
        case unquote(action) do
          :complete ->
            ForgeMirrors.complete_operation(marked, c.now)

          :retry ->
            ForgeMirrors.retry_operation(
              marked,
              c.now,
              DateTime.add(c.now, 30, :second),
              "network",
              external_effect_reconciled: true
            )

          :fail ->
            ForgeMirrors.fail_operation(marked, c.now, "provider_validation", "not proof")
        end

      assert {:error, :invalid_transition} = result
      current = Repo.get!(ForgeMirrors.MirrorOperation, marked.id)
      assert current.state == :effect_pending
      assert current.external_effect_marker == marked.external_effect_marker
      assert Repo.get!(ForgePulls.MergeOperation, intent.id).state == :merge_written
    end
  end

  test "requester losing write access cannot authorize objects or mark a provider effect", c do
    assert {:ok, %{reserved: intent}} = prepare(c)

    member =
      Repo.get_by!(ForgeAccounts.OrganizationMember,
        organization_id: c.organization.organization_id,
        user_id: c.request.actor_user_id
      )

    Repo.delete!(member)
    actor = Repo.get!(ForgeAccounts.User, c.request.actor_user_id)
    repository = Repo.get!(ForgeRepos.Repository, c.binding.repository_id)
    refute Fornacast.Access.allowed?(actor, :repository_write, repository)

    assert {:ok, {:error, :forbidden}} =
             Repo.transaction(fn ->
               PullMergeBoundary.authorize(c.operation, c.now, intent)
             end)

    assert {:error, :forbidden} =
             PullMergeBoundary.mark(c.operation, c.now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => String.duplicate("c", 40),
               "merge_oid" => String.duplicate("d", 40)
             })
  end

  test "other checkpoint APIs cannot overwrite merge preparation", c do
    assert {:ok, %{reserved: _}} = prepare(c)
    before = Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).checkpoint
    assert {:error, _} = ForgeMirrors.checkpoint_resource_operation(c.operation, %{}, c.now)

    assert {:error, _} =
             ForgeMirrors.checkpoint_git_ref_operation(c.operation, c.pull.base_ref, %{}, c.now)

    assert {:error, _} = ForgeMirrors.checkpoint_git_reconciliation(c.operation, %{}, c.now)
    assert Repo.get!(ForgeMirrors.MirrorOperation, c.operation.id).checkpoint == before
  end

  test "marked recovery retains evidence after authorization and local baseline change", c do
    marked = marked(c)
    c.organization |> Changeset.change(state: :paused) |> Repo.update!()
    c.pull |> Changeset.change(base_sha: String.duplicate("e", 40)) |> Repo.update!()
    assert {:error, _} = PullMergeBoundary.context(marked, c.now)
    assert {:ok, recovery} = PullMergeBoundary.recovery_context(marked, c.now)
    assert recovery.github_installation_id == c.organization.github_installation_id

    assert {:ok, deferred} =
             PullMergeBoundary.defer(marked, c.now, DateTime.add(c.now, 30), :network)

    assert deferred.state == :effect_pending
    assert deferred.lease_owner == nil
    assert deferred.checkpoint == marked.checkpoint
    assert deferred.external_effect_marker == marked.external_effect_marker
    assert deferred.lock_version == marked.lock_version + 1
    assert {:error, _} = PullMergeBoundary.recovery_context(marked, c.now)
  end

  test "marked recovery rejects forged expired and corrupted evidence", c do
    marked = marked(c)

    for forged <- [
          %{marked | lease_owner: "forged"},
          %{marked | cursor: %{}},
          %{marked | lock_version: marked.lock_version + 1}
        ] do
      assert {:error, _} = PullMergeBoundary.recovery_context(forged, c.now)
    end

    assert {:error, _} = PullMergeBoundary.recovery_context(marked, DateTime.add(c.now, 120))

    corrupted =
      marked
      |> Changeset.change(
        external_effect_marker:
          Map.put(marked.external_effect_marker, "merge_oid", String.duplicate("e", 40))
      )
      |> Repo.update!()

    assert {:error, _} = PullMergeBoundary.recovery_context(corrupted, c.now)
  end

  test "defer diagnostics have a UTF8 safe byte bound even for combining marks", c do
    marked = marked(c)
    reason = "a" <> String.duplicate("\u0301", 1000)

    assert {:ok, deferred} =
             PullMergeBoundary.defer(marked, c.now, DateTime.add(c.now, 30), reason)

    assert byte_size(deferred.failure_detail) <= 512
    assert String.valid?(deferred.failure_detail)
  end

  test "normal confirmation wait does not invent a network failure", c do
    marked = marked(c)

    assert {:ok, deferred} =
             PullMergeBoundary.defer(
               marked,
               c.now,
               DateTime.add(c.now, 30),
               :remote_confirmation_required
             )

    assert deferred.failure_class == nil
    assert deferred.failure_disposition == nil
    assert deferred.failure_detail == nil
  end

  test "M readiness clears an earlier network failure", c do
    marked =
      marked(c)
      |> Changeset.change(
        failure_class: "network",
        failure_disposition: :retry,
        failure_detail: "timeout"
      )
      |> Repo.update!()

    assert {:ok, observed} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("d", 40),
               provider_pull_id: 902
             })

    assert observed.failure_class == nil
    assert observed.failure_disposition == nil
    assert observed.failure_detail == nil
  end

  test "confirmation wait and M readiness retain an open conflict diagnostic", c do
    marked = marked(c)

    assert {:ok, conflicted} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("e", 40),
               provider_pull_id: 902
             })

    reclaimed =
      conflicted
      |> Changeset.change(lease_owner: "recovery", lease_expires_at: DateTime.add(c.now, 60))
      |> Repo.update!()

    assert {:ok, deferred} =
             PullMergeBoundary.defer(
               reclaimed,
               c.now,
               DateTime.add(c.now, 30),
               :remote_confirmation_required
             )

    assert deferred.failure_class == "git_divergence"

    reclaimed =
      deferred
      |> Changeset.change(lease_owner: "recovery", lease_expires_at: DateTime.add(c.now, 60))
      |> Repo.update!()

    assert {:ok, observed} =
             PullMergeBoundary.record_observation(reclaimed, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("d", 40),
               provider_pull_id: 902
             })

    assert observed.failure_class == "git_divergence"
    assert observed.failure_disposition == :conflict

    assert Repo.get_by!(ForgeMirrors.MirrorConflict, organization_mirror_id: c.organization.id).state ==
             :open
  end

  test "corrupted scalar eligibility proof is rejected without raising", c do
    marked = marked(c)

    corrupted =
      marked
      |> Changeset.change(
        checkpoint:
          put_in(marked.checkpoint, ["merge_preparation", "pull_eligibility_proof"], "corrupted")
      )
      |> Repo.update!()

    assert {:error, :stale_merge_identity} = PullMergeBoundary.recovery_context(corrupted, c.now)
  end

  test "invalid UTF8 LFS checkpoint is rejected without raising", c do
    marked = marked(c)

    checkpoint = %{
      "baseline_fingerprint" => <<255>>,
      "direction" => "outbound",
      "phase" => "scan",
      "requirement_cursor" => nil,
      "scan_key" => "key"
    }

    assert {:error, :invalid_transition} =
             PullMergeBoundary.checkpoint_lfs(marked, c.now, checkpoint)
  end

  test "recovery can defer after installation revocation and requester removal", c do
    marked = marked(c)

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: c.organization.github_installation_id
    )
    |> Changeset.change(state: :revoked)
    |> Repo.update!()

    Repo.get_by!(ForgeAccounts.OrganizationMember,
      organization_id: c.organization.organization_id,
      user_id: c.request.actor_user_id
    )
    |> Repo.delete!()

    assert {:error, _} = PullMergeBoundary.context(marked, c.now)

    assert {:ok, deferred} =
             PullMergeBoundary.defer(marked, c.now, DateTime.add(c.now, 30), :credential_revoked)

    assert deferred.external_effect_marker == marked.external_effect_marker
    assert deferred.checkpoint == marked.checkpoint
  end

  test "observing original B grants no confirmation readiness and retains the lease", c do
    marked = marked(c)

    assert {:error, :remote_base_unchanged} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: c.pull.base_sha,
               provider_pull_id: 902
             })

    assert Repo.get!(ForgeMirrors.MirrorOperation, marked.id) == marked
  end

  test "M observation only records confirmation readiness and yields", c do
    marked = marked(c)

    assert {:ok, observed} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("d", 40),
               provider_pull_id: 902
             })

    assert observed.checkpoint["merge_observation"]["confirmation_ready"] == true
    assert observed.external_effect_marker == marked.external_effect_marker
    assert observed.state == :effect_pending
    assert observed.lease_owner == nil
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
  end

  test "recovery keeps original installation after rebind and rejects altered preparation", c do
    marked = marked(c)

    c.organization
    |> Changeset.change(github_installation_id: c.organization.github_installation_id + 1)
    |> Repo.update!()

    assert {:error, _} = PullMergeBoundary.context(marked, c.now)
    assert {:ok, recovery} = PullMergeBoundary.recovery_context(marked, c.now)
    assert recovery.github_installation_id == c.organization.github_installation_id

    corrupted =
      marked
      |> Changeset.change(
        checkpoint: put_in(marked.checkpoint, ["merge_preparation", "local_version"], 999)
      )
      |> Repo.update!()

    assert {:error, _} = PullMergeBoundary.recovery_context(corrupted, c.now)

    assert {:error, _} =
             PullMergeBoundary.defer(corrupted, c.now, DateTime.add(c.now, 30), :network)
  end

  test "observation cannot substitute the original provider pull object", c do
    marked = marked(c)

    c.mapping
    |> Changeset.change(github_object_id: 903, github_node_id: "PR_903")
    |> Repo.update!()

    assert {:error, _} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("d", 40),
               provider_pull_id: 903
             })
  end

  test "third OID observation records conflict while preserving merge reservation", c do
    marked = marked(c)

    assert {:error, _} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("e", 40),
               provider_pull_id: 999
             })

    assert {:ok, observed} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("e", 40),
               provider_pull_id: 902
             })

    assert observed.failure_disposition == :conflict
    assert observed.state == :effect_pending
    assert observed.external_effect_marker == marked.external_effect_marker

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict, organization_mirror_id: c.organization.id)

    assert conflict.baseline_snapshot == %{"oid" => c.pull.base_sha}
    assert conflict.local_snapshot == %{"oid" => String.duplicate("d", 40)}
    assert conflict.remote_snapshot == %{"oid" => String.duplicate("e", 40)}

    reclaimed =
      observed
      |> Changeset.change(lease_owner: "recovery", lease_expires_at: DateTime.add(c.now, 60))
      |> Repo.update!()

    assert {:ok, replayed} =
             PullMergeBoundary.record_observation(reclaimed, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("e", 40),
               provider_pull_id: 902
             })

    assert Repo.aggregate(ForgeMirrors.MirrorConflict, :count) == 1

    reclaimed =
      replayed
      |> Changeset.change(lease_owner: "recovery", lease_expires_at: DateTime.add(c.now, 60))
      |> Repo.update!()

    assert {:error, :dedupe_conflict} =
             PullMergeBoundary.record_observation(reclaimed, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("f", 40),
               provider_pull_id: 902
             })

    assert Repo.get!(ForgeMirrors.MirrorConflict, conflict.id) == conflict
  end

  test "observation rejects a changed provider node with unchanged numeric ID", c do
    marked = marked(c)
    c.mapping |> Changeset.change(github_node_id: "PR_OTHER") |> Repo.update!()

    assert {:error, _} =
             PullMergeBoundary.record_observation(marked, c.now, DateTime.add(c.now, 30), %{
               remote_base_oid: String.duplicate("d", 40),
               provider_pull_id: 902
             })
  end

  test "LFS checkpoint retains preparation and marker", c do
    marked = marked(c)

    checkpoint = %{
      "baseline_fingerprint" => "fingerprint",
      "direction" => "outbound",
      "phase" => "scan",
      "requirement_cursor" => nil,
      "scan_key" => "key"
    }

    for invalid <- [
          Map.put(checkpoint, "scan_key", String.duplicate("x", 16_385)),
          Map.put(checkpoint, "merge_preparation", %{})
        ] do
      assert {:error, _} = PullMergeBoundary.checkpoint_lfs(marked, c.now, invalid)
    end

    assert {:error, _} =
             PullMergeBoundary.checkpoint_lfs(
               %{marked | lease_owner: "forged"},
               c.now,
               checkpoint
             )

    assert {:ok, updated} = PullMergeBoundary.checkpoint_lfs(marked, c.now, checkpoint)
    assert updated.checkpoint["merge_preparation"] == marked.checkpoint["merge_preparation"]
    assert updated.external_effect_marker == marked.external_effect_marker
    assert updated.checkpoint["scan_key"] == "key"
    assert updated.state == :effect_pending
    assert updated.lease_owner == nil
    assert updated.lease_expires_at == nil
    assert updated.next_attempt_at == DateTime.add(c.now, 1)
    assert updated.lock_version == marked.lock_version + 1

    assert {:error, _} =
             PullMergeBoundary.checkpoint_lfs(updated, c.now, %{"merge_preparation" => %{}})
  end

  test "unmarked LFS checkpoint yields pending without losing preparation", c do
    assert {:ok, %{reserved: _}} = prepare(c)

    checkpoint = %{
      "baseline_fingerprint" => "fingerprint",
      "direction" => "outbound",
      "phase" => "scan",
      "requirement_cursor" => nil,
      "scan_key" => "key"
    }

    assert {:ok, updated} = PullMergeBoundary.checkpoint_lfs(c.operation, c.now, checkpoint)
    assert updated.state == :pending
    assert updated.lease_owner == nil
    assert updated.lease_expires_at == nil
    assert updated.failure_class == nil
    assert updated.external_effect_marker == nil
    assert updated.next_attempt_at == DateTime.add(c.now, 1)
    assert updated.checkpoint["merge_preparation"]["pull_id"] == c.pull.id
  end

  defp marked(c) do
    assert {:ok, %{reserved: intent}} = prepare(c)

    intent
    |> Changeset.change(
      state: :merge_written,
      merge_tree_oid: String.duplicate("c", 40),
      merge_oid: String.duplicate("d", 40)
    )
    |> Repo.update!()

    assert {:ok, marked} =
             PullMergeBoundary.mark(c.operation, c.now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => String.duplicate("c", 40),
               "merge_oid" => String.duplicate("d", 40)
             })

    marked
  end

  defp prepare(c),
    do:
      Multi.new()
      |> PullMergeBoundary.append_prepare(:reserved, c.operation, c.now, c.expected, domain(c))
      |> Repo.transaction()

  defp admit(c),
    do:
      Multi.new()
      |> PullMergeBoundary.append_admit(
        :admitted,
        c.operation,
        c.now,
        c.expected,
        request_fingerprint(c),
        domain(c)
      )
      |> Repo.transaction()

  defp request_fingerprint(c) do
    {:ok, fingerprint} =
      ForgePulls.coordinated_merge_request_fingerprint(
        %{"merge_method" => "merge", "sha" => c.pull.head_sha},
        %{request_id: c.request.request_id}
      )

    fingerprint
  end

  defp pending(c) do
    operation =
      c.operation
      |> Changeset.change(state: :pending, lease_owner: nil, lease_expires_at: nil)
      |> Repo.update!()

    %{c | operation: operation, request: %{c.request | coordinator_operation_id: operation.id}}
  end

  defp domain(c),
    do: Multi.new() |> ForgePulls.append_prepare_coordinated_merge(:intent, c.request)

  defp claim_child(c, kind, cursor) do
    child =
      operation_fixture(c.organization, %{
        repository_mirror_id: c.binding.id,
        kind: kind,
        cursor: cursor,
        next_attempt_at: c.now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-reservation-child", c.now, 60, 100, [kind])

    Enum.find(claimed, &(&1.id == child.id)) || raise "child operation was not claimed"
  end

  defp fail_coordinator(c) do
    assert {:ok, _} =
             ForgeMirrors.fail_operation(
               c.operation,
               c.now,
               "provider_validation",
               "coordinator stopped while durable intent remains nonterminal"
             )
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
