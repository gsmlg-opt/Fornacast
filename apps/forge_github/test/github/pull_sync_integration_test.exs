defmodule ForgeGitHub.PullSyncIntegrationTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{Error, InstallationToken, IssueClient, PullClient, PullSyncWorker}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState
  }

  alias ForgePulls.PullRequest
  alias Fornacast.Repo

  @source_time ~U[2026-09-01 00:00:00Z]
  @base %{
    "title" => "Baseline",
    "body" => "Baseline body",
    "state" => "open",
    "state_reason" => nil,
    "draft" => false,
    "head_ref" => "refs/heads/feature",
    "head_sha" => nil,
    "base_ref" => "refs/heads/main",
    "base_sha" => nil
  }

  setup {Req.Test, :verify_on_exit!}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base =
      repository_mirror_fixture(organization, %{
        github_full_name: "acme/project",
        github_repository_id: 900,
        github_node_id: "R_900"
      })

    head =
      repository_mirror_fixture(organization, %{
        github_full_name: "acme/head",
        github_repository_id: 901,
        github_node_id: "R_901"
      })

    {base_path, base_sha} = initialize_branch!(base.repository_id, @base["base_ref"])
    {head_path, head_sha} = initialize_branch!(head.repository_id, @base["head_ref"])
    baseline = @base |> Map.put("base_sha", base_sha) |> Map.put("head_sha", head_sha)

    on_exit(fn ->
      File.rm_rf!(base_path)
      File.rm_rf!(head_path)
    end)

    actor = organization_owner_fixture(organization)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: baseline["title"],
        body: baseline["body"],
        state: :open,
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: head.repository_id,
        draft: false,
        head_ref: baseline["head_ref"],
        head_sha: baseline["head_sha"],
        base_ref: baseline["base_ref"],
        base_sha: baseline["base_sha"],
        mergeable_state: :unknown
      })

    for {binding, ref, oid} <- [
          {base, baseline["base_ref"], baseline["base_sha"]},
          {head, baseline["head_ref"], baseline["head_sha"]}
        ] do
      %MirrorRefState{}
      |> MirrorRefState.persistence_changeset(%{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: @source_time
      })
      |> Repo.insert!()
    end

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(baseline)

    identity = %{
      "github_issue_object_id" => 801,
      "github_issue_node_id" => "I_801",
      "github_number" => 7,
      "head_repository" => %{"id" => 901, "node_id" => "R_901"},
      "base_repository" => %{"id" => 900, "node_id" => "R_900"}
    }

    mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: base.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 802,
        github_node_id: "PR_802",
        github_number: 7,
        confirmed_local_version: issue.sync_version,
        confirmed_remote_updated_at: @source_time,
        confirmed_snapshot: baseline,
        confirmed_fingerprint: fingerprint,
        confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
        provider_identity: identity,
        state: :confirmed
      })
      |> Repo.insert!()

    issue_baseline =
      Map.take(baseline, ~w(title body state state_reason))
      |> Map.merge(%{"label_github_ids" => [], "assignee_github_ids" => []})

    {:ok, issue_fingerprint} = ForgeMirrors.resource_fingerprint(issue_baseline)

    issue_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: base.id,
        resource_kind: :issue,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: issue.id,
        github_object_id: 801,
        github_node_id: "I_801",
        github_number: 7,
        confirmed_local_version: issue.sync_version,
        confirmed_remote_updated_at: @source_time,
        confirmed_snapshot: issue_baseline,
        confirmed_fingerprint: issue_fingerprint,
        state: :confirmed
      })

    %{
      organization: organization,
      base: base,
      head: head,
      issue: issue,
      pull: pull,
      mapping: mapping,
      issue_mapping: issue_mapping,
      baseline: baseline,
      base_path: base_path,
      head_path: head_path,
      stub: {__MODULE__, System.unique_integer([:positive])}
    }
  end

  for recovery <- [:applied, :absent, :different, :local_changed, :deleted, :corrupted] do
    test "new mapped local label #{recovery} recovery never repeats POST", ctx do
      now = DateTime.utc_now(:second)

      label =
        Repo.insert!(%ForgeIssues.Label{
          repository_id: ctx.base.repository_id,
          name: "new-local-label",
          normalized_name: "new-local-label",
          color: "abcdef",
          description: "Local label"
        })

      Repo.insert!(%ForgeIssues.IssueLabel{issue_id: ctx.issue.id, label_id: label.id})
      Repo.update!(Ecto.Changeset.change(ctx.issue, sync_version: 2))
      operation = local_operation(ctx, 2, now)
      state = start_supervised!({Agent, fn -> %{posts: 0, gets: 0} end})
      local_label_provider(ctx, state, now, unquote(recovery))
      opts = relationship_options(ctx)

      assert {:ok, %{state: :effect_pending}} =
               PullSyncWorker.process_operation(operation, now, opts)

      pending = Repo.get!(MirrorOperation, operation.id)
      assert pending.external_effect_marker["action"] == "create_remote_label"
      assert pending.external_effect_marker["proposed_snapshot"]["name"] == label.name
      assert Agent.get(state, & &1.posts) == 1
      assert Repo.get!(MirrorResourceState, ctx.mapping.id) == ctx.mapping
      assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id) == ctx.issue_mapping

      if unquote(recovery) == :local_changed do
        Repo.update!(
          Ecto.Changeset.change(label,
            name: "newer-label-name",
            normalized_name: "newer-label-name",
            sync_version: 2
          )
        )
      end

      if unquote(recovery) == :deleted do
        Repo.get_by!(ForgeIssues.IssueLabel, issue_id: ctx.issue.id, label_id: label.id)
        |> Repo.delete!()

        Repo.delete!(label)
      end

      if unquote(recovery) == :corrupted,
        do: Repo.update!(Ecto.Changeset.change(label, color: "000000"))

      next_now = pending.next_attempt_at
      PullSyncWorker.process_operation(claim(operation.id, next_now), next_now, opts)
      assert Agent.get(state, & &1.posts) == 1
      saved = Repo.get!(MirrorOperation, operation.id)

      if unquote(recovery) in [:applied, :local_changed] do
        assert saved.state == :pending
        assert saved.external_effect_marker == nil

        mapping =
          Repo.get_by!(MirrorResourceState,
            repository_mirror_id: ctx.base.id,
            resource_kind: :label,
            local_resource_id: label.id
          )

        assert mapping.github_object_id == 938
        assert mapping.github_node_id == "LA_938"
        assert mapping.confirmed_local_version == 1
        assert mapping.confirmed_snapshot["name"] == "new-local-label"

        if unquote(recovery) == :local_changed,
          do: assert(Repo.get!(ForgeIssues.Label, label.id).name == "newer-label-name")

        assert Repo.get!(MirrorResourceState, ctx.mapping.id) == ctx.mapping
        assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id) == ctx.issue_mapping
      else
        assert saved.state == :failed

        expected_kind =
          if unquote(recovery) in [:deleted, :corrupted],
            do: "label_metadata_conflict",
            else: "ambiguous_label_create"

        assert Repo.get_by!(ForgeMirrors.MirrorConflict,
                 repository_mirror_id: ctx.base.id,
                 state: :open
               ).conflict_kind == expected_kind

        if unquote(recovery) in [:deleted, :corrupted] do
          assert saved.checkpoint["conflicted_effect_marker"] == pending.external_effect_marker
        end

        refute Repo.get_by(MirrorResourceState,
                 repository_mirror_id: ctx.base.id,
                 resource_kind: :label,
                 local_resource_id: label.id
               )

        if unquote(recovery) == :local_changed,
          do: assert(Repo.get!(ForgeIssues.Label, label.id).name == "newer-label-name")
      end
    end
  end

  for outcome <- [:adopt, :created] do
    test "new mapped local label #{outcome} yields after exact confirmation", ctx do
      now = DateTime.utc_now(:second)

      label =
        Repo.insert!(%ForgeIssues.Label{
          repository_id: ctx.base.repository_id,
          name: "new-local-label",
          normalized_name: "new-local-label",
          color: "abcdef",
          description: "Local label"
        })

      Repo.insert!(%ForgeIssues.IssueLabel{issue_id: ctx.issue.id, label_id: label.id})
      Repo.update!(Ecto.Changeset.change(ctx.issue, sync_version: 2))
      operation = local_operation(ctx, 2, now)
      state = start_supervised!({Agent, fn -> %{posts: 0, gets: 0} end})
      local_label_provider(ctx, state, now, unquote(outcome))

      assert {:ok, %{operation: %{state: :pending}}} =
               PullSyncWorker.process_operation(operation, now, relationship_options(ctx))

      assert Agent.get(state, & &1.posts) == if(unquote(outcome) == :adopt, do: 0, else: 1)

      assert Repo.get_by!(MirrorResourceState,
               repository_mirror_id: ctx.base.id,
               resource_kind: :label,
               local_resource_id: label.id
             ).github_object_id == 938

      assert Repo.get!(MirrorResourceState, ctx.mapping.id) == ctx.mapping
      assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id) == ctx.issue_mapping

      pending = Repo.get!(MirrorOperation, operation.id)

      assert {:ok, %{operation: %{state: :completed}}} =
               PullSyncWorker.process_operation(
                 claim(operation.id, pending.next_attempt_at),
                 pending.next_attempt_at,
                 relationship_options(ctx)
               )

      assert Agent.get(state, &Map.get(&1, :patches, 0)) == 1
      assert Agent.get(state, & &1.posts) == if(unquote(outcome) == :adopt, do: 0, else: 1)
      assert_confirmed(ctx, operation, ctx.baseline, 2)

      assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id).confirmed_snapshot[
               "label_github_ids"
             ] == [938]
    end
  end

  for substitution <- [:replaced_before_post, :replaced_after_post] do
    test "new mapped local label #{substitution} preserves marked evidence", ctx do
      now = DateTime.utc_now(:second)

      label =
        Repo.insert!(%ForgeIssues.Label{
          repository_id: ctx.base.repository_id,
          name: "new-local-label",
          normalized_name: "new-local-label",
          color: "abcdef",
          description: "Local label"
        })

      Repo.insert!(%ForgeIssues.IssueLabel{issue_id: ctx.issue.id, label_id: label.id})
      Repo.update!(Ecto.Changeset.change(ctx.issue, sync_version: 2))
      operation = local_operation(ctx, 2, now)
      state = start_supervised!({Agent, fn -> %{posts: 0, gets: 0} end})
      local_label_provider(ctx, state, now, unquote(substitution))
      PullSyncWorker.process_operation(operation, now, relationship_options(ctx))
      saved = Repo.get!(MirrorOperation, operation.id)
      assert saved.state == :effect_pending
      assert saved.external_effect_marker["action"] == "create_remote_label"

      assert Agent.get(state, & &1.posts) ==
               if(unquote(substitution) == :replaced_before_post, do: 0, else: 1)

      refute Repo.get_by(MirrorResourceState,
               repository_mirror_id: ctx.base.id,
               resource_kind: :label,
               local_resource_id: label.id
             )
    end
  end

  test "new mapped local label rejects substituted pull identity before label HTTP", ctx do
    now = DateTime.utc_now(:second)

    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: ctx.base.repository_id,
        name: "new-local-label",
        normalized_name: "new-local-label",
        color: "abcdef"
      })

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: ctx.issue.id, label_id: label.id})
    Repo.update!(Ecto.Changeset.change(ctx.issue, sync_version: 2))
    operation = local_operation(ctx, 2, now)

    Req.Test.expect(
      ctx.stub,
      &Req.Test.json(&1, Map.put(pull_json(ctx.baseline, now), "id", 999_802))
    )

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(ctx.baseline, now)))
    PullSyncWorker.process_operation(operation, now, relationship_options(ctx))
    assert Repo.get!(MirrorOperation, operation.id).state == :failed
    assert Repo.get!(MirrorOperation, operation.id).external_effect_marker == nil

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             local_resource_id: label.id
           )
  end

  test "mapped inbound labels materialize one prerequisite before paired confirmation", ctx do
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)
    target = Map.put(ctx.baseline, "title", "Remote with new label")

    label = %{
      "id" => 933,
      "node_id" => "LA_933",
      "name" => "new-remote-label",
      "color" => "abcdef",
      "description" => "Imported prerequisite"
    }

    for _claim <- 1..2 do
      Req.Test.expect(ctx.stub, &Req.Test.json(&1, pull_json(target, now)))

      Req.Test.expect(
        ctx.stub,
        &Req.Test.json(&1, Map.put(issue_json(target, now), "labels", [label]))
      )
    end

    opts = Keyword.delete(options(ctx), :remote_relationships)
    assert {:ok, %{operation: pending}} = PullSyncWorker.process_operation(operation, now, opts)
    assert pending.state == :pending
    assert pending.cursor == operation.cursor
    assert pending.external_effect_marker == nil
    assert pending.lease_owner == nil
    assert Repo.get!(MirrorResourceState, ctx.mapping.id) == ctx.mapping
    assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id) == ctx.issue_mapping

    imported =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.base.id,
        resource_kind: :label,
        github_object_id: 933
      )

    assert imported.github_node_id == "LA_933"

    refute Repo.get_by(ForgeIssues.IssueLabel,
             issue_id: ctx.issue.id,
             label_id: imported.local_resource_id
           )

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(claim(operation.id, now), now, opts)

    assert Repo.get_by!(ForgeIssues.IssueLabel,
             issue_id: ctx.issue.id,
             label_id: imported.local_resource_id
           )

    assert_confirmed(ctx, operation, target, 2)

    assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id).confirmed_snapshot[
             "label_github_ids"
           ] == [933]
  end

  test "effect-pending unknown remote label preserves intent without materializing", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, _} = relationship_fixture(ctx, now)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :lost_response)
    opts = relationship_options(ctx)

    assert {:ok, %{state: :effect_pending}} =
             PullSyncWorker.process_operation(operation, now, opts)

    pending = Repo.get!(MirrorOperation, operation.id)
    assert Agent.get(remote, & &1.patches) == 1
    Agent.update(remote, &Map.put(&1, :labels, [999]))
    next_now = pending.next_attempt_at
    PullSyncWorker.process_operation(claim(operation.id, next_now), next_now, opts)
    saved = Repo.get!(MirrorOperation, operation.id)
    assert saved.state == :effect_pending
    assert saved.external_effect_marker == pending.external_effect_marker
    assert saved.checkpoint == pending.checkpoint
    assert Agent.get(remote, & &1.patches) == 1

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             github_object_id: 999
           )

    refute Repo.get_by(ForgeIssues.Label,
             repository_id: ctx.base.repository_id,
             name: "current-label-999"
           )
  end

  test "mapped unknown label cannot adopt a different local namespace occupant", ctx do
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    existing =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: ctx.base.repository_id,
        name: "occupied",
        normalized_name: "occupied",
        color: "000000"
      })

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, pull_json(ctx.baseline, now)))

    Req.Test.expect(
      ctx.stub,
      &Req.Test.json(
        &1,
        Map.put(issue_json(ctx.baseline, now), "labels", [
          %{
            "id" => 935,
            "node_id" => "LA_935",
            "name" => "occupied",
            "color" => "ffffff",
            "description" => nil
          }
        ])
      )
    )

    PullSyncWorker.process_operation(
      operation,
      now,
      Keyword.delete(options(ctx), :remote_relationships)
    )

    assert Repo.get!(ForgeIssues.Label, existing.id) == existing

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             github_object_id: 935
           )

    conflicted = Repo.get!(MirrorResourceState, ctx.mapping.id)
    assert conflicted.state == :conflicted
    assert conflicted.confirmed_snapshot == ctx.mapping.confirmed_snapshot
    assert conflicted.confirmed_fingerprint == ctx.mapping.confirmed_fingerprint
    assert conflicted.confirmed_local_version == ctx.mapping.confirmed_local_version
    assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id) == ctx.issue_mapping
    assert Repo.get!(MirrorOperation, operation.id).external_effect_marker == nil
    assert Repo.get!(MirrorOperation, operation.id).state == :failed

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        repository_mirror_id: ctx.base.id,
        state: :open
      )

    assert conflict.conflict_kind == "label_namespace_collision"
    assert conflict.baseline_snapshot == %{"pull" => ctx.baseline}

    assert conflict.local_snapshot == %{
             "pull" => ctx.baseline,
             "label" => %{
               "local_resource_id" => existing.id,
               "local_version" => existing.sync_version,
               "name" => "occupied",
               "color" => "000000",
               "description" => nil
             }
           }

    assert conflict.remote_snapshot == %{
             "pull" => ctx.baseline,
             "label" => %{
               "github_object_id" => 935,
               "github_node_id" => "LA_935",
               "name" => "occupied",
               "color" => "ffffff",
               "description" => nil
             }
           }
  end

  test "mapped unknown label node collision becomes an actionable identity conflict", ctx do
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    existing =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: ctx.base.repository_id,
        name: "existing-node-label",
        normalized_name: "existing-node-label",
        color: "000000"
      })

    mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: ctx.base.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: existing.id,
        github_object_id: 936,
        github_node_id: "LA_collision",
        state: :confirmed
      })

    candidate = %{
      "id" => 937,
      "node_id" => "LA_collision",
      "name" => "new-node-label",
      "color" => "ffffff",
      "description" => nil
    }

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, pull_json(ctx.baseline, now)))

    Req.Test.expect(
      ctx.stub,
      &Req.Test.json(&1, Map.put(issue_json(ctx.baseline, now), "labels", [candidate]))
    )

    PullSyncWorker.process_operation(
      operation,
      now,
      Keyword.delete(options(ctx), :remote_relationships)
    )

    assert Repo.get!(MirrorOperation, operation.id).state == :failed
    assert Repo.get!(MirrorResourceState, mapping.id) == mapping

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             github_object_id: 937
           )

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict, repository_mirror_id: ctx.base.id, state: :open)

    assert conflict.conflict_kind == "label_identity_collision"

    assert conflict.remote_snapshot["label"] == %{
             "github_object_id" => 937,
             "github_node_id" => "LA_collision",
             "name" => "new-node-label",
             "color" => "ffffff",
             "description" => nil
           }

    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
  end

  test "mapped unknown label cannot import after a live ref changes during paired GET", ctx do
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)
    Req.Test.expect(ctx.stub, &Req.Test.json(&1, pull_json(ctx.baseline, now)))

    Req.Test.expect(ctx.stub, fn conn ->
      git!(ctx.head_path, ["update-ref", "-d", ctx.baseline["head_ref"]])

      Req.Test.json(
        conn,
        Map.put(issue_json(ctx.baseline, now), "labels", [
          %{
            "id" => 934,
            "node_id" => "LA_934",
            "name" => "untrusted-ref-label",
            "color" => "abcdef",
            "description" => nil
          }
        ])
      )
    end)

    PullSyncWorker.process_operation(
      operation,
      now,
      Keyword.delete(options(ctx), :remote_relationships)
    )

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             github_object_id: 934
           )

    refute Repo.get_by(ForgeIssues.Label,
             repository_id: ctx.base.repository_id,
             name: "untrusted-ref-label"
           )

    assert Repo.get!(MirrorResourceState, ctx.mapping.id) == ctx.mapping
    assert Repo.get!(MirrorOperation, operation.id).state == :pending
    assert Repo.get!(MirrorOperation, operation.id).failure_class == "network"
  end

  test "bounded pull-head discovery promotes an existing external head without a webhook", ctx do
    unsupported_head_fixture(ctx, %{"id" => 901, "node_id" => "R_901"})
    now = DateTime.utc_now(:second)

    assert {:ok, sweep} =
             ForgeMirrors.enqueue_repository_pull_head_reconciliation(
               ctx.base,
               "integration-head-discovery",
               now
             )

    assert {:ok, claimed} =
             ForgeMirrors.claim_operations("head-discovery-integration", now, 60, 100, [
               sweep.kind
             ])

    page = Enum.find(claimed, &(&1.id == sweep.id)) || flunk("head sweep was not claimable")

    assert {:ok, %{operation: %{state: :completed}, operations: [child]}} =
             PullSyncWorker.process_operation(page, now,
               token_fetch: fn _, _ -> flunk("discovery page must not request a token") end
             )

    assert child.kind == "sync.pull"
    assert child.cursor["trigger"] == "reconcile"
    expect_observation(ctx, ctx.baseline, now)

    assert {:ok, _} =
             PullSyncWorker.process_operation(
               claim(child.id, now),
               now,
               Keyword.delete(options(ctx), :remote_relationships)
             )

    assert Repo.get!(MirrorOperation, child.id).state == :completed
    assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == ctx.head.repository_id
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).state == :confirmed
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_local_version == 2
    assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id).confirmed_local_version == 2
  end

  test "corrupt unsupported pull identity fails without a network retry", ctx do
    unsupported_head_fixture(ctx, nil)

    Repo.get!(MirrorResourceState, ctx.mapping.id)
    |> Ecto.Changeset.change(local_resource_type: "ForgeIssues.Issue")
    |> Repo.update!()

    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    PullSyncWorker.process_operation(operation, now,
      token_fetch: fn _, _ -> flunk("corrupt identity must not request credentials") end
    )

    persisted = Repo.get!(MirrorOperation, operation.id)
    assert persisted.state == :failed
    assert persisted.failure_class == "local_validation"
    assert persisted.failure_detail == "read-only pull has an invalid persisted identity"
    assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == nil
  end

  for original <- [nil, :known] do
    test "unsupported #{inspect(original)} head becomes represented only through exact paired evidence",
         ctx do
      identity = if unquote(original) == :known, do: %{"id" => 901, "node_id" => "R_901"}
      unsupported_head_fixture(ctx, identity)
      now = DateTime.utc_now(:second)
      operation = remote_operation(ctx, now)
      expect_observation(ctx, ctx.baseline, now)

      assert {:ok, _} =
               PullSyncWorker.process_operation(
                 operation,
                 now,
                 Keyword.delete(options(ctx), :remote_relationships)
               )

      if unquote(original) == nil do
        assert Repo.get!(MirrorOperation, operation.id).state == :pending
        assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == nil
        expect_observation(ctx, ctx.baseline, now)

        assert {:ok, _} =
                 PullSyncWorker.process_operation(
                   claim(operation.id, now),
                   now,
                   Keyword.delete(options(ctx), :remote_relationships)
                 )
      end

      assert Repo.get!(MirrorOperation, operation.id).state == :completed
      assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == ctx.head.repository_id
      assert Repo.get!(ForgeIssues.Issue, ctx.issue.id).sync_version == 2
      assert Repo.get!(MirrorResourceState, ctx.mapping.id).state == :confirmed
      assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
      assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_local_version == 2
      assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id).confirmed_local_version == 2
    end
  end

  test "unsupported opaque head can pin one authenticated identity but cannot substitute it later",
       ctx do
    unsupported_head_fixture(ctx, nil)
    now = DateTime.utc_now(:second)
    initial = remote_operation(ctx, now)

    for {id, node} <- [{9901, "R_9901"}, {9902, "R_9902"}] do
      operation = if id == 9901, do: initial, else: claim(initial.id, now)

      Req.Test.expect(
        ctx.stub,
        &Req.Test.json(
          &1,
          put_in(pull_json(ctx.baseline, now), ["head", "repo"], %{
            "id" => id,
            "node_id" => node,
            "full_name" => "external/head"
          })
        )
      )

      Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(ctx.baseline, now)))

      PullSyncWorker.process_operation(
        operation,
        now,
        Keyword.delete(options(ctx), :remote_relationships)
      )

      mapping = Repo.get!(MirrorResourceState, ctx.mapping.id)

      assert mapping.provider_identity["head_repository"] == %{
               "id" => 9901,
               "node_id" => "R_9901"
             }

      assert mapping.confirmed_snapshot == ctx.baseline
      assert mapping.confirmed_local_version == 1
      assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == nil
    end
  end

  test "unsupported still-opaque head completes read-only reevaluation without fabricating identity",
       ctx do
    unsupported_head_fixture(ctx, nil)
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    Req.Test.expect(
      ctx.stub,
      &Req.Test.json(&1, put_in(pull_json(ctx.baseline, now), ["head", "repo"], nil))
    )

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(ctx.baseline, now)))

    assert {:ok, _} =
             PullSyncWorker.process_operation(
               operation,
               now,
               Keyword.delete(options(ctx), :remote_relationships)
             )

    assert Repo.get!(MirrorOperation, operation.id).state == :completed

    assert Repo.get!(MirrorResourceState, ctx.mapping.id).provider_identity["head_repository"] ==
             nil

    assert Repo.get!(ForgeIssues.Issue, ctx.issue.id).sync_version == 1
    assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == nil
  end

  for drift <- [:remote, :local] do
    test "still-opaque head #{drift} metadata drift fails visibly without rebasing", ctx do
      unsupported_head_fixture(ctx, nil)
      now = DateTime.utc_now(:second)
      operation = remote_operation(ctx, now)

      if unquote(drift) == :local,
        do:
          Repo.update!(
            Ecto.Changeset.change(ctx.issue, title: "Newer local metadata", sync_version: 2)
          )

      snapshot =
        if unquote(drift) == :remote,
          do: Map.put(ctx.baseline, "title", "Unexpected remote metadata"),
          else: ctx.baseline

      Req.Test.expect(
        ctx.stub,
        &Req.Test.json(&1, put_in(pull_json(snapshot, now), ["head", "repo"], nil))
      )

      Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(snapshot, now)))

      PullSyncWorker.process_operation(
        operation,
        now,
        Keyword.delete(options(ctx), :remote_relationships)
      )

      assert %{
               state: :failed,
               failure_class: "local_validation",
               failure_detail: "read-only pull metadata differs from confirmed baseline"
             } = Repo.get!(MirrorOperation, operation.id)

      assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
      assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_local_version == 1
      assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == nil
    end
  end

  for failure <- [
        :head_inactive,
        :head_ref_missing,
        :remote_drift,
        :local_drift,
        :relationship_drift,
        :revoked,
        :expired
      ] do
    test "unsupported head #{failure} cannot promote or rebase confirmed metadata", ctx do
      unsupported_head_fixture(ctx, %{"id" => 901, "node_id" => "R_901"})
      now = DateTime.utc_now(:second)
      operation = remote_operation(ctx, now)

      if unquote(failure) == :head_inactive,
        do: Repo.update!(Ecto.Changeset.change(ctx.head, state: :orphaned))

      if unquote(failure) == :head_ref_missing,
        do: git!(ctx.head_path, ["update-ref", "-d", ctx.baseline["head_ref"]])

      if unquote(failure) == :local_drift,
        do:
          Repo.update!(
            Ecto.Changeset.change(ctx.issue, title: "Newer local metadata", sync_version: 2)
          )

      snapshot =
        if unquote(failure) == :remote_drift,
          do: Map.put(ctx.baseline, "title", "Unexpected new metadata"),
          else: ctx.baseline

      Req.Test.expect(ctx.stub, &Req.Test.json(&1, pull_json(snapshot, now)))

      Req.Test.expect(ctx.stub, fn conn ->
        if unquote(failure) == :revoked,
          do: Repo.update!(Ecto.Changeset.change(ctx.organization, state: :revoked))

        if unquote(failure) == :expired,
          do:
            Repo.update!(
              Ecto.Changeset.change(Repo.get!(MirrorOperation, operation.id),
                lease_expires_at: DateTime.add(now, -1)
              )
            )

        issue = issue_json(snapshot, now)

        issue =
          if unquote(failure) == :relationship_drift,
            do:
              Map.put(issue, "labels", [
                %{
                  "id" => 998,
                  "node_id" => "LA_998",
                  "name" => "unknown-external-label",
                  "color" => "abcdef",
                  "description" => nil
                }
              ]),
            else: issue

        Req.Test.json(conn, issue)
      end)

      PullSyncWorker.process_operation(
        operation,
        now,
        Keyword.delete(options(ctx), :remote_relationships)
      )

      assert Repo.get!(PullRequest, ctx.pull.id).head_repository_id == nil

      assert Repo.get!(ForgeIssues.Issue, ctx.issue.id).sync_version ==
               if(unquote(failure) == :local_drift, do: 2, else: 1)

      assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
      assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_local_version == 1

      if unquote(failure) in [:remote_drift, :local_drift, :relationship_drift] do
        assert %{
                 state: :failed,
                 failure_class: "local_validation",
                 failure_detail: "read-only pull metadata differs from confirmed baseline"
               } = Repo.get!(MirrorOperation, operation.id)
      end
    end
  end

  test "authenticated opaque head imports read-only without guessing repository identity", ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    Req.Test.expect(
      ctx.stub,
      &Req.Test.json(&1, put_in(pull_json(ctx.baseline, now), ["head", "repo"], nil))
    )

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(ctx.baseline, now)))

    assert {:ok,
            %{
              operation: %{state: :completed},
              resource: created,
              pull_state: %{state: :unsupported}
            }} =
             PullSyncWorker.process_operation(
               operation,
               now,
               Keyword.delete(options(ctx), :remote_relationships)
             )

    assert created.head_repository_id == nil

    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.base.id,
        resource_kind: :pull,
        github_object_id: 802
      )

    assert mapping.provider_identity["head_repository"] == nil
    assert mapping.provider_identity["base_repository"] == %{"id" => 900, "node_id" => "R_900"}
    assert Repo.get!(PullRequest, created.local_resource_id).head_repository_id == nil

    assert Repo.get_by!(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :issue,
             github_object_id: 801
           ).local_resource_id == created.issue_id
  end

  for invalid <- [:incoherent_issue, :base_git_missing] do
    test "opaque head #{invalid} cannot import or bypass authenticated preflight", ctx do
      Repo.delete!(ctx.mapping)
      Repo.delete!(ctx.issue_mapping)
      now = DateTime.utc_now(:second)
      operation = remote_operation(ctx, now)

      if unquote(invalid) == :base_git_missing,
        do: git!(ctx.base_path, ["update-ref", "-d", ctx.baseline["base_ref"]])

      Req.Test.expect(
        ctx.stub,
        &Req.Test.json(&1, put_in(pull_json(ctx.baseline, now), ["head", "repo"], nil))
      )

      author_id = System.unique_integer([:positive]) + 10_000_000

      Req.Test.expect(ctx.stub, fn conn ->
        issue = issue_json(ctx.baseline, now)

        issue =
          if unquote(invalid) == :incoherent_issue,
            do:
              issue
              |> Map.put("title", "incoherent")
              |> Map.put("user", %{
                "id" => author_id,
                "node_id" => "U_#{author_id}",
                "login" => "untrusted-null-head",
                "type" => "User"
              }),
            else: issue

        Req.Test.json(conn, issue)
      end)

      PullSyncWorker.process_operation(
        operation,
        now,
        Keyword.delete(options(ctx), :remote_relationships)
      )

      refute Repo.get_by(MirrorResourceState,
               repository_mirror_id: ctx.base.id,
               resource_kind: :pull,
               github_object_id: 802
             )

      refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: author_id)
      assert Repo.get!(MirrorOperation, operation.id).state != :completed
    end
  end

  test "an unmapped inbound pull creates its canonical issue and both identities through the worker",
       ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)
    expect_observation(ctx, ctx.baseline, now)

    assert {:ok, %{operation: %{state: :completed}, resource: created}} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    assert created.local_resource_id != ctx.pull.id
    assert created.issue_number != 7
    assert created.head_repository_id == ctx.head.repository_id
    assert created.local_version == 1

    assert %{github_object_id: 802, github_number: 7, state: :confirmed} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: ctx.base.id,
               resource_kind: :pull,
               local_resource_id: created.local_resource_id
             )

    assert %{github_object_id: 801, github_number: 7, state: :confirmed} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: ctx.base.id,
               resource_kind: :issue,
               local_resource_id: created.issue_id
             )

    issue = Repo.get!(ForgeIssues.Issue, created.issue_id)

    assert Repo.get!(ForgeAccounts.GitHubIdentity, issue.author_github_identity_id).kind ==
             :deleted
  end

  test "inbound creation checks live Git rather than trusting only mirrored ref rows", ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    git!(ctx.head_path, ["update-ref", "-d", ctx.baseline["head_ref"]])
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)
    expect_observation(ctx, ctx.baseline, now)

    assert {:ok, %{state: :pending}} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :pull,
             github_object_id: 802
           )

    assert Repo.all(PullRequest)
           |> Enum.count(&(&1.repository_id == ctx.base.repository_id)) == 1
  end

  test "inbound creation rejects a substituted base identity before observing relationships",
       ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    Req.Test.expect(ctx.stub, fn conn ->
      Req.Test.json(
        conn,
        put_in(pull_json(ctx.baseline, now), ["base", "repo", "node_id"], "R_wrong")
      )
    end)

    assert {:ok, %{state: :failed}} =
             PullSyncWorker.process_operation(
               operation,
               now,
               options(ctx,
                 remote_relationships: fn _, _, _ ->
                   flunk("untrusted repository mutated identities")
                 end
               )
             )

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :pull,
             github_object_id: 802
           )
  end

  test "an authenticated unrepresented head creates explicitly read-only metadata", ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    Req.Test.expect(ctx.stub, fn conn ->
      pull =
        put_in(pull_json(ctx.baseline, now), ["head", "repo"], %{
          "id" => 9901,
          "node_id" => "R_9901",
          "full_name" => "external/head"
        })

      Req.Test.json(conn, pull)
    end)

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(ctx.baseline, now)))

    assert {:ok, %{resource: %{head_repository_id: nil}, pull_state: %{state: :unsupported}}} =
             PullSyncWorker.process_operation(operation, now, options(ctx))
  end

  test "substituted head and canonical issue identities cannot persist author observations",
       ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    now = DateTime.utc_now(:second)
    original = remote_operation(ctx, now)

    for substitution <- [:head, :issue] do
      author_id = System.unique_integer([:positive]) + 1_000_000

      cursor =
        if substitution == :issue,
          do: Map.put(original.cursor, "github_issue_id", 999_801),
          else: original.cursor

      operation = original |> Ecto.Changeset.change(cursor: cursor) |> Repo.update!()

      Req.Test.expect(ctx.stub, fn conn ->
        pull = pull_json(ctx.baseline, now)

        pull =
          if substitution == :head,
            do: put_in(pull, ["head", "repo", "node_id"], "R_substituted"),
            else: pull

        Req.Test.json(conn, pull)
      end)

      Req.Test.expect(ctx.stub, fn conn ->
        issue =
          Map.put(issue_json(ctx.baseline, now), "user", %{
            "id" => author_id,
            "node_id" => "U_#{author_id}",
            "login" => "untrusted-author",
            "type" => "User"
          })

        Req.Test.json(conn, issue)
      end)

      assert {:ok, _} =
               PullSyncWorker.process_operation(
                 operation,
                 now,
                 Keyword.delete(options(ctx), :remote_relationships)
               )

      refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: author_id)
      # Restore the same owned fixture capability for the independent substitution.
      Repo.get!(MirrorOperation, operation.id)
      |> Ecto.Changeset.change(
        state: :processing,
        lease_owner: original.lease_owner,
        lease_expires_at: original.lease_expires_at,
        lock_version: original.lock_version,
        cursor: original.cursor
      )
      |> Repo.update!()
    end
  end

  test "real inbound pull metadata and draft observation commits with its mirror baseline", ctx do
    now = DateTime.utc_now(:second)
    target = ctx.baseline |> Map.put("title", "GitHub title") |> Map.put("draft", true)
    operation = remote_operation(ctx, now)

    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: ctx.base.repository_id,
        name: "remote-label",
        normalized_name: "remote-label",
        color: "abcdef"
      })

    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: ctx.base.id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: label.id,
      github_object_id: 333,
      github_node_id: "LA_333",
      state: :confirmed
    })

    Req.Test.expect(ctx.stub, &Req.Test.json(&1, pull_json(target, now)))

    Req.Test.expect(
      ctx.stub,
      &Req.Test.json(
        &1,
        Map.put(issue_json(target, now), "labels", [
          %{"id" => 333, "node_id" => "LA_333", "name" => "remote-label"}
        ])
      )
    )

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(
               operation,
               now,
               Keyword.delete(options(ctx), :remote_relationships)
             )

    assert %{title: "GitHub title", sync_version: 2} =
             Repo.get!(ForgeIssues.Issue, ctx.issue.id)

    assert %{draft: true} = Repo.get!(PullRequest, ctx.pull.id)
    assert_confirmed(ctx, operation, target, 2)
    assert Repo.get_by!(ForgeIssues.IssueLabel, issue_id: ctx.issue.id, label_id: label.id)
    companion = Repo.get!(MirrorResourceState, ctx.issue_mapping.id)
    assert companion.confirmed_local_version == 2

    assert companion.confirmed_snapshot ==
             Map.merge(
               Map.take(target, ~w(title body state state_reason)),
               %{"label_github_ids" => [333], "assignee_github_ids" => []}
             )

    assert companion.confirmed_remote_updated_at == now
  end

  test "unknown remote labels yield one per claim on the same inbound parent", ctx do
    Repo.delete!(ctx.mapping)
    Repo.delete!(ctx.issue_mapping)
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    label = %{
      "id" => 333,
      "node_id" => "LA_333",
      "name" => "remote-label",
      "color" => "abcdef",
      "description" => "Discovered with pull"
    }

    second_label = %{label | "id" => 334, "node_id" => "LA_334", "name" => "another-label"}

    Req.Test.expect(ctx.stub, 6, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/repos/acme/project/pulls/7" ->
          Req.Test.json(conn, pull_json(ctx.baseline, now))

        "/repos/acme/project/issues/7" ->
          Req.Test.json(
            conn,
            Map.put(issue_json(ctx.baseline, now), "labels", [label, second_label])
          )
      end
    end)

    worker_options = Keyword.delete(options(ctx), :remote_relationships)

    assert {:ok, %{operation: %{state: :pending, id: id}}} =
             PullSyncWorker.process_operation(operation, now, worker_options)

    assert id == operation.id

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :pull,
             github_object_id: 802
           )

    label_mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.base.id,
        resource_kind: :label,
        github_object_id: 333
      )

    assert Repo.get!(ForgeIssues.Label, label_mapping.local_resource_id).name == "remote-label"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             github_object_id: 334
           )

    assert {:ok, %{operation: %{state: :pending, id: ^id}}} =
             PullSyncWorker.process_operation(claim(id, now), now, worker_options)

    second_mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.base.id,
        resource_kind: :label,
        github_object_id: 334
      )

    assert {:ok, %{operation: %{state: :completed}, resource: created}} =
             PullSyncWorker.process_operation(claim(id, now), now, worker_options)

    assert Repo.get_by!(ForgeIssues.IssueLabel,
             issue_id: created.issue_id,
             label_id: label_mapping.local_resource_id
           )

    assert Repo.get_by!(ForgeIssues.IssueLabel,
             issue_id: created.issue_id,
             label_id: second_mapping.local_resource_id
           )
  end

  test "real outbound issue and draft effects use distinct durable markers before confirmation",
       ctx do
    now = DateTime.utc_now(:second)
    target = ctx.baseline |> Map.put("title", "Local title") |> Map.put("draft", true)

    issue =
      ctx.issue
      |> ForgeIssues.Issue.update_changeset(%{title: target["title"]})
      |> Repo.update!()

    ctx.pull
    |> PullRequest.update_changeset(%{draft: true})
    |> Repo.update!()

    operation = local_operation(ctx, issue.sync_version, now)
    expect_observation(ctx, ctx.baseline, @source_time)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/project/issues/7"

      assert %{
               state: :effect_pending,
               external_effect_marker: %{"action" => "update_remote_pull_issue"}
             } = Repo.get!(MirrorOperation, operation.id)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body)["title"] == target["title"]
      Req.Test.json(conn, issue_json(target, now))
    end)

    after_issue = Map.put(target, "draft", false)
    expect_observation(ctx, after_issue, now)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"

      assert %{
               state: :effect_pending,
               external_effect_marker: %{"action" => "set_remote_pull_draft"}
             } = Repo.get!(MirrorOperation, operation.id)

      Req.Test.json(conn, %{
        "data" => %{
          "convertPullRequestToDraft" => %{
            "pullRequest" => %{"id" => "PR_802", "isDraft" => true}
          }
        }
      })
    end)

    expect_observation(ctx, target, now)

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    assert_confirmed(ctx, operation, target, 2)
  end

  test "a pending disjoint effect survives GET failure and confirms its preimage after a newer edit",
       ctx do
    now = DateTime.utc_now(:second)
    old_local = Map.put(ctx.baseline, "title", "Sent title")
    remote_before = Map.put(ctx.baseline, "body", "Remote body")
    postcondition = Map.put(remote_before, "title", "Sent title")

    issue =
      ctx.issue
      |> ForgeIssues.Issue.update_changeset(%{title: old_local["title"]})
      |> Repo.update!()

    operation = local_operation(ctx, issue.sync_version, now)
    remote = start_supervised!({Agent, fn -> remote_before end})

    first_options =
      options(ctx,
        get_pull: fn _, _, _, _, _ -> {:ok, pull_json(Agent.get(remote, & &1), now)} end,
        get_pull_issue: fn _, _, _, _, _ ->
          {:ok, issue_json(Agent.get(remote, & &1), now)}
        end,
        update_pull_issue: fn _, _, _, _, _, _ ->
          Agent.update(remote, fn _ -> postcondition end)
          {:error, Error.new(:transport)}
        end
      )

    assert {:ok, %{state: :effect_pending}} =
             PullSyncWorker.process_operation(operation, now, first_options)

    pending = Repo.get!(MirrorOperation, operation.id)
    marker = pending.external_effect_marker
    assert marker["action"] == "update_remote_pull_issue"

    pending = claim(operation.id, pending.next_attempt_at)

    failed_get_options =
      options(ctx,
        get_pull: fn _, _, _, _, _ -> {:error, Error.new(:transport)} end
      )

    assert {:ok, %{state: :effect_pending, external_effect_marker: ^marker}} =
             PullSyncWorker.process_operation(
               pending,
               pending.next_attempt_at,
               failed_get_options
             )

    still_pending = Repo.get!(MirrorOperation, operation.id)
    assert still_pending.external_effect_marker == marker

    newer_issue =
      issue
      |> ForgeIssues.Issue.update_changeset(%{state: :closed, state_reason: :completed})
      |> Repo.update!()

    unmapped =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: ctx.base.repository_id,
        name: "new-unmapped",
        normalized_name: "new-unmapped",
        color: "abcdef"
      })

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: newer_issue.id, label_id: unmapped.id})

    pending = claim(operation.id, still_pending.next_attempt_at)

    recovery_options =
      options(ctx,
        get_pull: fn _, _, _, _, _ -> {:ok, pull_json(postcondition, now)} end,
        get_pull_issue: fn _, _, _, _, _ -> {:ok, issue_json(postcondition, now)} end,
        update_pull_issue: fn _, _, _, _, _, _ -> flunk("proven effect was replayed") end
      )

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(
               pending,
               pending.next_attempt_at,
               recovery_options
             )

    assert %{sync_version: 3, title: "Sent title", body: "Baseline body", state: :closed} =
             Repo.get!(ForgeIssues.Issue, newer_issue.id)

    assert_confirmed(ctx, operation, postcondition, 2)
    assert Repo.get_by!(ForgeIssues.IssueLabel, issue_id: newer_issue.id, label_id: unmapped.id)
  end

  test "a removed cross-repository head ref blocks inbound confirmation", ctx do
    now = DateTime.utc_now(:second)
    git!(ctx.head_path, ["update-ref", "-d", ctx.baseline["head_ref"]])

    operation = remote_operation(ctx, now)
    caller = self()

    Req.Test.stub(ctx.stub, fn _ ->
      send(caller, :provider_read)
      flunk("unavailable local Git must prevent provider reads")
    end)

    assert {:ok,
            %{
              state: :pending,
              failure_class: "network",
              failure_detail: "required Git ref or commit is unavailable"
            }} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    assert %{title: "Baseline", sync_version: 1} = Repo.get!(ForgeIssues.Issue, ctx.issue.id)
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
    refute_received :provider_read
  end

  test "full relationship effects merge removals and additions and recover one lost PATCH", ctx do
    now = DateTime.utc_now(:second)
    {operation, labels, users} = relationship_fixture(ctx, now)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :lost_response)

    opts =
      options(ctx)
      |> Keyword.delete(:remote_relationships)
      |> Keyword.put(:relationship_client_options, transport_options(ctx, []))

    assert {:ok, %{state: :effect_pending}} =
             PullSyncWorker.process_operation(operation, now, opts)

    assert Agent.get(remote, & &1.patches) == 1
    assert Agent.get(remote, & &1.labels) == [332, 333]
    assert Agent.get(remote, & &1.users) == [442, 443]
    pending = Repo.get!(MirrorOperation, operation.id)
    assert pending.external_effect_marker["metadata_intent_id"]
    operation = claim(operation.id, pending.next_attempt_at)

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(operation, pending.next_attempt_at, opts)

    assert Agent.get(remote, & &1.patches) == 1
    assert Agent.get(remote, & &1.queries) == 1
    issue_mapping = Repo.get!(MirrorResourceState, ctx.issue_mapping.id)
    pull_mapping = Repo.get!(MirrorResourceState, ctx.mapping.id)
    assert issue_mapping.confirmed_snapshot["label_github_ids"] == [332, 333]
    assert issue_mapping.confirmed_snapshot["assignee_github_ids"] == [442, 443]
    assert issue_mapping.confirmed_local_version == pull_mapping.confirmed_local_version
    assert issue_mapping.confirmed_local_version == 3

    for id <- [332, 333],
        do:
          assert(
            Repo.get_by(ForgeIssues.IssueLabel, issue_id: ctx.issue.id, label_id: labels[id].id)
          )

    for id <- [442, 443],
        do:
          assert(
            Repo.get_by(ForgeIssues.IssueAssignee,
              issue_id: ctx.issue.id,
              github_identity_id: users[id].id
            )
          )

    refute Repo.get_by(ForgeIssues.IssueLabel, issue_id: ctx.issue.id, label_id: labels[331].id)

    refute Repo.get_by(ForgeIssues.IssueAssignee,
             issue_id: ctx.issue.id,
             github_identity_id: users[441].id
           )
  end

  test "provider metadata drift during relationship lookup prevents PATCH", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, _} = relationship_fixture(ctx, now)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :drift)

    opts =
      options(ctx)
      |> Keyword.delete(:remote_relationships)
      |> Keyword.put(:relationship_client_options, transport_options(ctx, []))

    assert {:ok, _} = PullSyncWorker.process_operation(operation, now, opts)
    assert Agent.get(remote, & &1.queries) == 1
    assert Agent.get(remote, & &1.patches) == 0
    assert Repo.get!(MirrorOperation, operation.id).state == :failed
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
  end

  test "mapped missing nodes seed one user or label page per claim without metadata writes",
       ctx do
    now = DateTime.utc_now(:second)
    {operation, labels, users} = relationship_fixture(ctx, now)
    ctx.pull |> Ecto.Changeset.change(draft: true) |> Repo.update!()
    clear_relationship_nodes(ctx, users)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :missing_nodes)
    opts = relationship_options(ctx)
    assert {:ok, _} = PullSyncWorker.process_operation(operation, now, opts)
    marked = Repo.get!(MirrorOperation, operation.id)
    assert marked.state == :effect_pending and is_nil(marked.lease_owner)
    assert Agent.get(remote, &Map.get(&1, :user_gets)) == [442]
    assert Repo.get!(ForgeAccounts.GitHubIdentity, users[442].id).github_node_id == "U_442"

    for page <- [1, 2] do
      assert {:ok, _} = PullSyncWorker.process_operation(claim(operation.id, now), now, opts)
      current = Repo.get!(MirrorOperation, operation.id)
      assert current.external_effect_marker == marked.external_effect_marker
      assert current.state == :effect_pending and is_nil(current.lease_owner)
      assert Agent.get(remote, &Map.get(&1, :label_pages)) == Enum.to_list(1..page)
      assert Agent.get(remote, & &1.patches) == 0
      assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id).confirmed_local_version == 1
      assert Repo.get!(ForgeIssues.Label, labels[332].id).name == "label-332"
    end

    assert {:ok, _} = PullSyncWorker.process_operation(claim(operation.id, now), now, opts)
    pending = Repo.get!(MirrorOperation, operation.id)
    assert Agent.get(remote, & &1.patches) == 1

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(
               claim(operation.id, pending.next_attempt_at),
               pending.next_attempt_at,
               opts
             )

    assert Agent.get(remote, & &1.patches) == 1
    assert Agent.get(remote, & &1.queries) == 1
    assert Agent.get(remote, &Map.get(&1, :draft_writes)) == 1
    assert Agent.get(remote, &Map.get(&1, :label_pages)) == [1, 2]
    assert Agent.get(remote, &Map.get(&1, :user_gets)) == [442]
  end

  test "draft-only effect does not require label node inventory or user lookup", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, users} = relationship_fixture(ctx, now)
    clear_relationship_nodes(ctx, users)
    ctx.pull |> Ecto.Changeset.change(draft: true) |> Repo.update!()
    mapping = Repo.get!(MirrorResourceState, ctx.issue_mapping.id)

    snapshot =
      Map.merge(mapping.confirmed_snapshot, %{
        "label_github_ids" => [332],
        "assignee_github_ids" => [442]
      })

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(snapshot)

    mapping
    |> Ecto.Changeset.change(confirmed_snapshot: snapshot, confirmed_fingerprint: fingerprint)
    |> Repo.update!()

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{labels: [332], users: [442], patches: 0, queries: 0, body: ctx.baseline["body"]}
         end}
      )

    relationship_provider(ctx, remote, now, :draft_only)

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(operation, now, relationship_options(ctx))

    assert Agent.get(remote, & &1.queries) == 0
    assert Agent.get(remote, & &1.patches) == 0
    assert Agent.get(remote, &Map.get(&1, :draft_writes)) == 1
    assert Agent.get(remote, &Map.get(&1, :label_pages)) == nil
    assert Agent.get(remote, &Map.get(&1, :user_gets)) == nil

    assert Repo.get_by!(MirrorResourceState,
             repository_mirror_id: ctx.base.id,
             resource_kind: :label,
             github_object_id: 332
           ).github_node_id == nil
  end

  test "exhausted mapped label inventory becomes a visible conflict without restarting", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, users} = relationship_fixture(ctx, now)
    clear_relationship_nodes(ctx, users)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :missing_inventory)
    opts = relationship_options(ctx)
    assert {:ok, _} = PullSyncWorker.process_operation(operation, now, opts)
    assert {:ok, _} = PullSyncWorker.process_operation(claim(operation.id, now), now, opts)
    current = Repo.get!(MirrorOperation, operation.id)

    if current.state == :effect_pending,
      do: PullSyncWorker.process_operation(claim(operation.id, now), now, opts)

    assert Repo.get!(MirrorOperation, operation.id).state == :failed
    assert Agent.get(remote, &Map.get(&1, :label_pages)) == [1]
    assert Agent.get(remote, & &1.patches) == 0

    assert Repo.get_by(ForgeMirrors.MirrorConflict,
             repository_mirror_id: ctx.base.id,
             state: :open
           )
  end

  test "wrong numeric user response never seeds a mapped relationship or writes metadata", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, users} = relationship_fixture(ctx, now)
    clear_relationship_nodes(ctx, users)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :wrong_user)
    _ = PullSyncWorker.process_operation(operation, now, relationship_options(ctx))
    assert Agent.get(remote, &Map.get(&1, :user_gets)) == [442]
    assert Repo.get!(ForgeAccounts.GitHubIdentity, users[442].id).github_node_id == nil
    refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: 999_442)
    assert Agent.get(remote, & &1.patches) == 0
    assert Repo.get!(MirrorOperation, operation.id).external_effect_marker["metadata_intent_id"]
  end

  defp relationship_options(ctx),
    do:
      options(ctx)
      |> Keyword.delete(:remote_relationships)
      |> Keyword.put(:relationship_client_options, transport_options(ctx, []))

  for mode <- [:revoked_user, :drift_user] do
    @mode mode
    test "#{mode} during numeric identity GET prevents seed and metadata mutation", ctx do
      now = DateTime.utc_now(:second)
      {operation, _, users} = relationship_fixture(ctx, now)
      clear_relationship_nodes(ctx, users)

      remote =
        start_supervised!(
          {Agent,
           fn ->
             %{
               labels: [331, 333],
               users: [441, 443],
               patches: 0,
               queries: 0,
               body: ctx.baseline["body"]
             }
           end}
        )

      relationship_provider(ctx, remote, now, @mode)
      _ = PullSyncWorker.process_operation(operation, now, relationship_options(ctx))
      assert Agent.get(remote, &Map.get(&1, :user_gets)) == [442]
      assert Repo.get!(ForgeAccounts.GitHubIdentity, users[442].id).github_node_id == nil
      assert Agent.get(remote, & &1.patches) == 0
      assert Repo.get!(MirrorOperation, operation.id).state != :completed
    end
  end

  defp clear_relationship_nodes(ctx, users) do
    users[442] |> Ecto.Changeset.change(github_node_id: nil) |> Repo.update!()

    for id <- [332, 333] do
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.base.id,
        resource_kind: :label,
        github_object_id: id
      )
      |> Ecto.Changeset.change(github_node_id: nil)
      |> Repo.update!()
    end
  end

  test "restored issue values with a newer issue timestamp cannot replay a lost effect", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, _} = relationship_fixture(ctx, now)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :lost_response)

    opts =
      options(ctx)
      |> Keyword.delete(:remote_relationships)
      |> Keyword.put(:relationship_client_options, transport_options(ctx, []))

    assert {:ok, %{state: :effect_pending}} =
             PullSyncWorker.process_operation(operation, now, opts)

    assert Agent.get(remote, & &1.patches) == 1

    Agent.update(
      remote,
      &Map.merge(&1, %{labels: [331, 333], users: [441, 443], issue_time: DateTime.add(now, 1)})
    )

    pending = Repo.get!(MirrorOperation, operation.id)

    assert {:ok, _} =
             PullSyncWorker.process_operation(
               claim(operation.id, pending.next_attempt_at),
               pending.next_attempt_at,
               opts
             )

    assert Agent.get(remote, & &1.patches) == 1
    assert Repo.get!(MirrorOperation, operation.id).state == :failed
  end

  test "restored paired values with newer issue time during GraphQL cannot start PATCH", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, _} = relationship_fixture(ctx, now)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :aba)

    opts =
      options(ctx)
      |> Keyword.delete(:remote_relationships)
      |> Keyword.put(:relationship_client_options, transport_options(ctx, []))

    assert {:ok, _} = PullSyncWorker.process_operation(operation, now, opts)
    assert Agent.get(remote, & &1.patches) == 0
    assert Repo.get!(MirrorOperation, operation.id).state == :failed
  end

  test "restored draft preimage with newer pull timestamp cannot replay conversion", ctx do
    now = DateTime.utc_now(:second)
    ctx.issue |> Ecto.Changeset.change(sync_version: 2) |> Repo.update!()
    ctx.pull |> Ecto.Changeset.change(draft: true) |> Repo.update!()
    operation = local_operation(ctx, 2, now)
    remote = start_supervised!({Agent, fn -> %{draft: false, pull_time: now, writes: 0} end})

    opts =
      options(ctx,
        get_pull: fn _, _, _, _, _ ->
          value = Agent.get(remote, & &1)
          {:ok, pull_json(Map.put(ctx.baseline, "draft", value.draft), value.pull_time)}
        end,
        get_pull_issue: fn _, _, _, _, _ -> {:ok, issue_json(ctx.baseline, now)} end,
        set_draft: fn _, _, true, _ ->
          Agent.update(remote, &%{&1 | draft: true, writes: &1.writes + 1})
          {:error, Error.new(:transport)}
        end
      )

    assert {:ok, %{state: :effect_pending}} =
             PullSyncWorker.process_operation(operation, now, opts)

    Agent.update(remote, &%{&1 | draft: false, pull_time: DateTime.add(now, 1)})
    pending = Repo.get!(MirrorOperation, operation.id)

    assert {:ok, _} =
             PullSyncWorker.process_operation(
               claim(operation.id, pending.next_attempt_at),
               pending.next_attempt_at,
               opts
             )

    assert Agent.get(remote, & &1.writes) == 1
    assert Repo.get!(MirrorOperation, operation.id).state == :failed
  end

  test "an exact effect target observed after relationship lookup confirms without PATCH", ctx do
    now = DateTime.utc_now(:second)
    {operation, _, _} = relationship_fixture(ctx, now)

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             labels: [331, 333],
             users: [441, 443],
             patches: 0,
             queries: 0,
             body: ctx.baseline["body"]
           }
         end}
      )

    relationship_provider(ctx, remote, now, :applied)

    opts =
      options(ctx)
      |> Keyword.delete(:remote_relationships)
      |> Keyword.put(:relationship_client_options, transport_options(ctx, []))

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(operation, now, opts)

    assert Agent.get(remote, & &1.queries) == 1
    assert Agent.get(remote, & &1.patches) == 0

    assert Repo.get!(MirrorResourceState, ctx.issue_mapping.id).confirmed_snapshot[
             "label_github_ids"
           ] == [332, 333]
  end

  defp relationship_fixture(ctx, now) do
    labels =
      Map.new([331, 332, 333], fn id ->
        label =
          Repo.insert!(%ForgeIssues.Label{
            repository_id: ctx.base.repository_id,
            name: "label-#{id}",
            normalized_name: "label-#{id}",
            color: "abcdef"
          })

        Repo.insert!(%MirrorResourceState{
          repository_mirror_id: ctx.base.id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: id,
          github_node_id: "L_#{id}",
          state: :confirmed
        })

        {id, label}
      end)

    users =
      Map.new([441, 442, 443], fn id ->
        {:ok, user} =
          ForgeAccounts.observe_github_identity(
            %{id: id, node_id: "U_#{id}", login: "old-#{id}"},
            now
          )

        {id, user}
      end)

    baseline =
      ctx.issue_mapping.confirmed_snapshot
      |> Map.put("label_github_ids", [331])
      |> Map.put("assignee_github_ids", [441])

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(baseline)

    ctx.issue_mapping
    |> Ecto.Changeset.change(confirmed_snapshot: baseline, confirmed_fingerprint: fingerprint)
    |> Repo.update!()

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: ctx.issue.id, label_id: labels[332].id})

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: ctx.issue.id,
      github_identity_id: users[442].id
    })

    issue = ctx.issue |> Ecto.Changeset.change(sync_version: 2) |> Repo.update!()
    {local_operation(ctx, issue.sync_version, now), labels, users}
  end

  defp relationship_provider(ctx, remote, now, mode) do
    Req.Test.stub(ctx.stub, fn conn ->
      current = Agent.get(remote, & &1)

      snapshot =
        ctx.baseline
        |> Map.put("body", current.body)
        |> Map.put("draft", Map.get(current, :draft, false))

      case {conn.method, conn.request_path} do
        {"GET", "/user/442"} ->
          Agent.update(remote, &Map.update(&1, :user_gets, [442], fn ids -> ids ++ [442] end))

          if mode == :revoked_user,
            do:
              Repo.get!(ForgeMirrors.OrganizationMirror, ctx.organization.id)
              |> Ecto.Changeset.change(state: :revoked)
              |> Repo.update!()

          if mode == :drift_user,
            do: Agent.update(remote, &%{&1 | body: "Third party during identity GET"})

          id = if mode == :wrong_user, do: 999_442, else: 442
          Req.Test.json(conn, %{"id" => id, "node_id" => "U_#{id}", "login" => "current-#{id}"})

        {"GET", "/repos/acme/project"} ->
          Req.Test.json(conn, %{
            "id" => 900,
            "node_id" => "R_900",
            "owner" => %{"id" => 12, "login" => "acme"},
            "name" => "project",
            "full_name" => "acme/project",
            "visibility" => "private",
            "default_branch" => "main",
            "has_issues" => true,
            "allow_merge_commit" => true,
            "fork" => false,
            "archived" => false
          })

        {"GET", "/repos/acme/project/labels"} ->
          query = URI.decode_query(conn.query_string)
          assert query["per_page"] == "100"
          page = String.to_integer(query["page"])

          Agent.update(
            remote,
            &Map.update(&1, :label_pages, [page], fn pages -> pages ++ [page] end)
          )

          ids = if page == 1, do: [331], else: [332, 333]

          conn =
            if page == 1 and mode != :missing_inventory,
              do:
                Plug.Conn.put_resp_header(
                  conn,
                  "link",
                  "<https://api.github.com/repos/acme/project/labels?page=2&per_page=100>; rel=\"next\""
                ),
              else: conn

          Req.Test.json(
            conn,
            Enum.map(
              ids,
              &%{
                "id" => &1,
                "node_id" => "L_#{&1}",
                "name" => "inventory-#{&1}",
                "color" => "abcdef",
                "description" => nil
              }
            )
          )

        {"GET", "/repos/acme/project/pulls/7"} ->
          Req.Test.json(conn, pull_json(snapshot, now))

        {"GET", "/repos/acme/project/issues/7"} ->
          issue =
            issue_json(snapshot, Map.get(current, :issue_time, now))
            |> Map.put(
              "labels",
              Enum.map(
                current.labels,
                &%{"id" => &1, "node_id" => "L_#{&1}", "name" => "current-label-#{&1}"}
              )
            )
            |> Map.put(
              "assignees",
              Enum.map(
                current.users,
                &%{"id" => &1, "node_id" => "U_#{&1}", "login" => "current-#{&1}"}
              )
            )

          Req.Test.json(conn, issue)

        {"POST", "/graphql"} ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn)

          if get_in(JSON.decode!(encoded), ["variables", "input"]) do
            assert get_in(JSON.decode!(encoded), ["variables", "input", "pullRequestId"]) ==
                     "PR_802"

            Agent.update(
              remote,
              &(&1 |> Map.put(:draft, true) |> Map.update(:draft_writes, 1, fn n -> n + 1 end))
            )

            Req.Test.json(conn, %{
              "data" => %{
                "convertPullRequestToDraft" => %{
                  "pullRequest" => %{"id" => "PR_802", "isDraft" => true}
                }
              }
            })
          else
            assert JSON.decode!(encoded)["variables"] == %{
                     "labels" => ["L_332", "L_333"],
                     "assignees" => ["U_442", "U_443"]
                   }

            Agent.update(remote, fn s ->
              %{
                s
                | queries: s.queries + 1,
                  body: if(mode == :drift, do: "Third party body", else: s.body)
              }
            end)

            if mode == :applied,
              do:
                Agent.update(
                  remote,
                  &Map.merge(&1, %{
                    labels: [332, 333],
                    users: [442, 443],
                    issue_time: DateTime.add(now, 1)
                  })
                )

            if mode == :aba,
              do: Agent.update(remote, &Map.put(&1, :issue_time, DateTime.add(now, 1)))

            Req.Test.json(conn, %{
              "data" => %{
                "labels" =>
                  Enum.map(
                    [332, 333],
                    &%{
                      "__typename" => "Label",
                      "id" => "L_#{&1}",
                      "name" => "current-label-#{&1}",
                      "repository" => %{"id" => "R_900"}
                    }
                  ),
                "assignees" =>
                  Enum.map(
                    [442, 443],
                    &%{"__typename" => "User", "id" => "U_#{&1}", "login" => "current-#{&1}"}
                  )
              }
            })
          end

        {"PATCH", "/repos/acme/project/issues/7"} ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn)
          attrs = JSON.decode!(encoded)
          assert attrs["labels"] == ["current-label-332", "current-label-333"]
          assert attrs["assignees"] == ["current-442", "current-443"]

          Agent.update(remote, fn s ->
            %{s | patches: s.patches + 1, labels: [332, 333], users: [442, 443]}
          end)

          Plug.Conn.send_resp(conn, 503, "lost after effect")

        route ->
          flunk("unexpected relationship route #{inspect(route)}")
      end
    end)
  end

  test "a mismatched base ref blocks an outbound provider effect", ctx do
    now = DateTime.utc_now(:second)
    replacement = commit!(ctx.base_path, "replacement")
    git!(ctx.base_path, ["update-ref", ctx.baseline["base_ref"], replacement])

    issue =
      ctx.issue
      |> ForgeIssues.Issue.update_changeset(%{title: "Untrusted outbound title"})
      |> Repo.update!()

    operation = local_operation(ctx, issue.sync_version, now)
    caller = self()

    Req.Test.stub(ctx.stub, fn _ ->
      send(caller, :provider_read)
      flunk("diverged local Git must prevent provider reads")
    end)

    result =
      PullSyncWorker.process_operation(
        operation,
        now,
        options(ctx,
          update_pull_issue: fn _, _, _, _, _, _ ->
            send(caller, :provider_effect)
            {:error, Error.new(:transport)}
          end
        )
      )

    assert {:ok,
            %{
              state: :pending,
              failure_class: "network",
              failure_detail: "required Git ref or commit is unavailable"
            }} = result

    refute_receive :provider_effect
    refute_received :provider_read
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
  end

  defp remote_operation(ctx, now) do
    ctx.organization
    |> operation_fixture(%{
      repository_mirror_id: ctx.base.id,
      kind: "sync.pull",
      cursor: %{
        "trigger" => "remote",
        "resource_kind" => "pull",
        "issue_kind" => "pull_request",
        "github_object_id" => 802,
        "github_number" => 7,
        "delivery_guid" => "pull-integration"
      },
      next_attempt_at: now
    })
    |> then(&claim(&1.id, now))
  end

  defp local_operation(ctx, sync_version, now) do
    ctx.organization
    |> operation_fixture(%{
      repository_mirror_id: ctx.base.id,
      kind: "sync.pull",
      cursor: %{
        "trigger" => "local",
        "resource_kind" => "pull",
        "issue_kind" => "pull_request",
        "issue_id" => ctx.issue.id,
        "repository_id" => ctx.base.repository_id,
        "sync_version" => sync_version,
        "outbox_event_id" => Ecto.UUID.generate()
      },
      next_attempt_at: now
    })
    |> then(&claim(&1.id, now))
  end

  defp claim(id, now) do
    {:ok, operations} =
      ForgeMirrors.claim_operations("pull-integration", now, 60, 100, ["sync.pull"])

    Enum.find(operations, &(&1.id == id)) || flunk("operation was not claimable")
  end

  defp unsupported_head_fixture(ctx, head_identity) do
    Repo.update!(Ecto.Changeset.change(ctx.pull, head_repository_id: nil))

    Repo.update!(
      Ecto.Changeset.change(ctx.mapping,
        state: :unsupported,
        provider_identity:
          Map.put(ctx.mapping.provider_identity, "head_repository", head_identity)
      )
    )
  end

  defp local_label_provider(ctx, state, now, recovery) do
    Req.Test.stub(ctx.stub, fn conn ->
      issue =
        Map.put(
          issue_json(ctx.baseline, now),
          "labels",
          Agent.get(state, &Map.get(&1, :labels, []))
        )

      case {conn.method, conn.request_path} do
        {"GET", "/repos/acme/project/pulls/7"} ->
          Req.Test.json(conn, pull_json(ctx.baseline, now))

        {"GET", "/repos/acme/project/issues/7"} ->
          Req.Test.json(conn, issue)

        {"POST", "/graphql"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert JSON.decode!(body)["variables"] == %{"labels" => ["LA_938"], "assignees" => []}

          Req.Test.json(conn, %{
            "data" => %{
              "labels" => [
                %{
                  "__typename" => "Label",
                  "id" => "LA_938",
                  "name" => "new-local-label",
                  "repository" => %{"id" => "R_900"}
                }
              ],
              "assignees" => []
            }
          })

        {"PATCH", "/repos/acme/project/issues/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert JSON.decode!(body)["labels"] == ["new-local-label"]

          labels = [
            %{
              "id" => 938,
              "node_id" => "LA_938",
              "name" => "new-local-label",
              "color" => "abcdef",
              "description" => "Local label"
            }
          ]

          Agent.update(
            state,
            &(&1 |> Map.put(:labels, labels) |> Map.update(:patches, 1, fn n -> n + 1 end))
          )

          Req.Test.json(conn, Map.put(issue, "labels", labels))

        {"GET", "/repos/acme/project"} ->
          marked =
            Repo.get_by(MirrorOperation,
              repository_mirror_id: ctx.base.id,
              state: :effect_pending
            )

          replaced =
            (recovery == :replaced_before_post and not is_nil(marked)) or
              (recovery == :replaced_after_post and Agent.get(state, & &1.posts) > 0)

          Req.Test.json(conn, %{
            "id" => if(replaced, do: 999_900, else: 900),
            "node_id" => if(replaced, do: "R_replaced", else: "R_900"),
            "name" => "project",
            "full_name" => "acme/project",
            "owner" => %{"id" => 12, "login" => "acme"},
            "visibility" => "private",
            "default_branch" => "main",
            "has_issues" => true,
            "allow_merge_commit" => true,
            "fork" => false,
            "archived" => false
          })

        {"GET", "/repos/acme/project/labels/new-local-label"} ->
          count =
            Agent.get_and_update(state, fn value ->
              {value.gets, %{value | gets: value.gets + 1}}
            end)

          if (count == 0 and recovery != :adopt) or recovery == :absent do
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
          else
            color = if recovery == :different, do: "000000", else: "abcdef"

            Req.Test.json(conn, %{
              "id" => 938,
              "node_id" => "LA_938",
              "name" => "new-local-label",
              "color" => color,
              "description" => "Local label"
            })
          end

        {"POST", "/repos/acme/project/labels"} ->
          assert Repo.get_by!(MirrorOperation,
                   repository_mirror_id: ctx.base.id,
                   state: :effect_pending
                 ).external_effect_marker["action"] == "create_remote_label"

          Agent.update(state, &%{&1 | posts: &1.posts + 1})

          if recovery in [:replaced_after_post, :created] do
            Req.Test.json(conn, %{
              "id" => 938,
              "node_id" => "LA_938",
              "name" => "new-local-label",
              "color" => "abcdef",
              "description" => "Local label"
            })
          else
            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"message" => "lost after label create"})
          end
      end
    end)
  end

  defp options(ctx, overrides \\ []) do
    defaults = [
      token_fetch: fn id, _scope ->
        assert id == ctx.organization.github_installation_id

        %InstallationToken{
          token: "integration-token",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600),
          permissions: %{"metadata" => "read", "pull_requests" => "write"}
        }
      end,
      remote_relationships: fn _, _, _ ->
        {:ok, %{labels: [], assignees: [], author: nil}}
      end,
      get_pull: fn token, owner, repository, number, opts ->
        PullClient.get_pull(token, owner, repository, number, transport_options(ctx, opts))
      end,
      get_pull_issue: fn token, owner, repository, number, opts ->
        IssueClient.get_pull_issue(
          token,
          owner,
          repository,
          number,
          transport_options(ctx, opts)
        )
      end,
      update_pull_issue: fn token, owner, repository, number, attrs, opts ->
        IssueClient.update_pull_issue(
          token,
          owner,
          repository,
          number,
          attrs,
          transport_options(ctx, opts)
        )
      end,
      set_draft: fn token, node_id, desired, opts ->
        PullClient.set_draft(token, node_id, desired, transport_options(ctx, opts))
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp transport_options(ctx, opts) do
    Keyword.merge(opts,
      plug: {Req.Test, ctx.stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    )
  end

  defp expect_observation(ctx, snapshot, updated_at) do
    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/pulls/7"
      Req.Test.json(conn, pull_json(snapshot, updated_at))
    end)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/7"
      Req.Test.json(conn, issue_json(snapshot, updated_at))
    end)
  end

  defp pull_json(snapshot, updated_at) do
    %{
      "id" => 802,
      "node_id" => "PR_802",
      "number" => 7,
      "title" => snapshot["title"],
      "body" => snapshot["body"],
      "state" => snapshot["state"],
      "draft" => snapshot["draft"],
      "user" => nil,
      "created_at" => DateTime.to_iso8601(@source_time),
      "updated_at" => DateTime.to_iso8601(updated_at),
      "closed_at" => nil,
      "merged" => false,
      "merged_at" => nil,
      "merge_commit_sha" => nil,
      "mergeable" => true,
      "rebaseable" => true,
      "mergeable_state" => "clean",
      "head" => %{
        "ref" => snapshot["head_ref"],
        "sha" => snapshot["head_sha"],
        "repo" => %{"id" => 901, "node_id" => "R_901", "full_name" => "acme/head"}
      },
      "base" => %{
        "ref" => snapshot["base_ref"],
        "sha" => snapshot["base_sha"],
        "repo" => %{"id" => 900, "node_id" => "R_900", "full_name" => "acme/project"}
      }
    }
  end

  defp issue_json(snapshot, updated_at) do
    %{
      "id" => 801,
      "node_id" => "I_801",
      "number" => 7,
      "title" => snapshot["title"],
      "body" => snapshot["body"],
      "state" => snapshot["state"],
      "state_reason" => snapshot["state_reason"],
      "labels" => [],
      "assignees" => [],
      "user" => nil,
      "created_at" => DateTime.to_iso8601(@source_time),
      "updated_at" => DateTime.to_iso8601(updated_at),
      "closed_at" => nil,
      "pull_request" => %{
        "url" => "https://api.github.com/repos/acme/project/pulls/7"
      }
    }
  end

  defp assert_confirmed(ctx, operation, snapshot, version) do
    assert %{state: :completed, external_effect_marker: nil} =
             Repo.get!(MirrorOperation, operation.id)

    mapping = Repo.get!(MirrorResourceState, ctx.mapping.id)
    assert mapping.state == :confirmed
    assert mapping.confirmed_snapshot == snapshot
    assert mapping.confirmed_local_version == version
    assert mapping.confirmed_merge_state == %{"merged_at" => nil, "merge_commit_sha" => nil}
    assert {:ok, mapping.confirmed_fingerprint} == ForgeMirrors.resource_fingerprint(snapshot)
  end

  defp initialize_branch!(repository_id, ref) do
    repository = Repo.get!(ForgeRepos.Repository, repository_id)

    repository =
      repository
      |> Ecto.Changeset.change(%{
        storage_path: "pull-sync-integration/#{Ecto.UUID.generate()}.git"
      })
      |> Repo.update!()

    path = ForgeRepos.absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, ^path} = GitCore.init_bare(path)
    oid = commit!(path, ref)
    git!(path, ["update-ref", ref, oid])
    {path, oid}
  end

  defp commit!(path, message) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    git!(path, ["commit-tree", tree, "-m", message])
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Pull Sync Test"},
      {"GIT_AUTHOR_EMAIL", "pull-sync@example.test"},
      {"GIT_COMMITTER_NAME", "Pull Sync Test"},
      {"GIT_COMMITTER_EMAIL", "pull-sync@example.test"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true)

    String.trim(output)
  end
end
