defmodule ForgeMirrors.RemotePullLabelTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.Multi
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    binding = repository_mirror_fixture(org)
    now = DateTime.utc_now(:second)

    op =
      operation_fixture(org, %{
        repository_mirror_id: binding.id,
        kind: "sync.pull",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "pull",
          "github_object_id" => 1700,
          "github_number" => 7
        },
        checkpoint: %{"discovery" => "preserved"},
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("remote-pull-label", now, 120, 100, ["sync.pull"])

    op = Enum.find(claimed, &(&1.id == op.id))

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^op.id),
      set: [checkpoint: %{"discovery" => "preserved"}]
    )

    op = Repo.get!(MirrorOperation, op.id)
    fields = %{"name" => "discovery", "color" => "abcdef", "description" => nil}

    expected = %{
      resource_state_lock_version: :missing,
      local_label_id: nil,
      expected_local_version: nil,
      expected_local_fingerprint: nil,
      github_object_id: 500,
      effect_marker: nil
    }

    confirmation = %{
      github_object_id: 500,
      github_node_id: "LA_500",
      confirmed_snapshot: fields,
      confirmed_local_version: nil
    }

    request = %{
      repository_id: binding.repository_id,
      fields: fields,
      provenance: %{origin: :github}
    }

    %{
      org: org,
      binding: binding,
      op: op,
      now: now,
      expected: expected,
      confirmation: confirmation,
      request: request
    }
  end

  test "one imported label is mapped and same parent yields without a child operation", c do
    count = Repo.aggregate(MirrorOperation, :count)
    assert {:ok, result} = confirm(c)
    assert result.operation.state == :pending
    assert result.operation.id == c.op.id
    assert result.operation.cursor == c.op.cursor
    assert result.operation.checkpoint == c.op.checkpoint
    assert result.operation.lease_owner == nil
    assert result.resource_state.resource_kind == :label
    assert result.resource_state.github_object_id == 500
    assert result.resource_state.confirmed_local_version == 1
    assert Repo.aggregate(MirrorOperation, :count) == count
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.binding.repository_id)

    assert {:ok, claimed} =
             ForgeMirrors.claim_operations("remote-pull-label-next", c.now, 120, 100, [
               "sync.pull"
             ])

    reclaimed = Enum.find(claimed, &(&1.id == c.op.id))
    assert {:ok, %{mode: :inbound_create}} = ForgeMirrors.remote_pull_creation_context(reclaimed)
  end

  test "compatible existing label is adopted at actual version without a duplicate", c do
    {:ok, %{resource: label}} =
      Multi.new()
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> Repo.transaction()

    Repo.update_all(from(l in "repository_labels", where: l.id == ^label.local_resource_id),
      set: [sync_version: 2]
    )

    assert {:ok, result} = confirm(c)
    assert result.resource_state.local_resource_id == label.local_resource_id
    assert result.resource_state.confirmed_local_version == 2

    assert Repo.aggregate(
             from(l in "repository_labels", where: l.repository_id == ^c.binding.repository_id),
             :count
           ) == 1
  end

  test "fake projection cannot create a mapping without an actual label", c do
    callback = fn multi ->
      Multi.put(multi, :resource, %{
        repository_id: c.binding.repository_id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: 999_999_999,
        local_version: 1,
        fields: c.request.fields
      })
    end

    assert {:error, :invalid_projection} = confirm(c, callback)

    refute Repo.exists?(
             from m in MirrorResourceState, where: m.repository_mirror_id == ^c.binding.id
           )
  end

  test "two valid label imports cannot leave an unmapped extra label", c do
    callback = fn multi ->
      multi
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> ForgeIssues.append_sync_label_import(:orphan, %{
        c.request
        | fields: %{c.request.fields | "name" => "extra"}
      })
    end

    assert {:error, :invalid_projection} = confirm(c, callback)

    refute Repo.exists?(
             from l in "repository_labels", where: l.repository_id == ^c.binding.repository_id
           )
  end

  test "callback cannot create an unrelated canonical issue while importing its prerequisite",
       c do
    actor = organization_owner_fixture(c.org)
    repository = Repo.get!(ForgeRepos.Repository, c.binding.repository_id)

    callback = fn multi ->
      multi
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> ForgeIssues.insert_numbered_identity(:unrelated, repository, actor, :issue, %{
        title: "unrelated"
      })
    end

    assert {:error, :invalid_projection} = confirm(c, callback)
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.binding.repository_id)

    refute Repo.exists?(
             from l in "repository_labels", where: l.repository_id == ^c.binding.repository_id
           )

    refute Repo.get(ForgeIssues.NumberSequence, c.binding.repository_id)
  end

  test "partial parent identity and local or effect-pending work fail before callback", c do
    callback = fn _ -> flunk("must not invoke label callback") end

    partial =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.binding.id,
        resource_kind: :issue,
        github_number: 7,
        github_object_id: 700,
        state: :pending
      })

    assert {:error, :identity_conflict} = confirm(c, callback)
    Repo.delete!(partial)

    for attrs <- [
          [cursor: Map.put(c.op.cursor, "trigger", "local")],
          [
            state: :effect_pending,
            external_effect_marker: %{"action" => "create_remote_pull"},
            effect_marked_at: c.now
          ]
        ] do
      Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id), set: attrs)
      assert {:error, _} = confirm(%{c | op: Repo.get!(MirrorOperation, c.op.id)}, callback)

      Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
        set: [
          cursor: c.op.cursor,
          state: :processing,
          external_effect_marker: nil,
          effect_marked_at: nil
        ]
      )
    end
  end

  test "revocation and lease loss inside callback roll back label and mapping", c do
    for action <- [:revoke, :expire] do
      callback = fn multi ->
        multi
        |> ForgeIssues.append_sync_label_import(:resource, c.request)
        |> Multi.run(:change_scope, fn repo, _ ->
          case action do
            :revoke ->
              repo.update_all(
                from(o in ForgeMirrors.OrganizationMirror, where: o.id == ^c.org.id),
                set: [state: :revoked]
              )

            :expire ->
              repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
                set: [lease_expires_at: DateTime.add(c.now, -1)]
              )
          end

          {:ok, :changed}
        end)
      end

      assert {:error, _} = confirm(c, callback)

      refute Repo.exists?(
               from l in "repository_labels", where: l.repository_id == ^c.binding.repository_id
             )

      refute Repo.exists?(
               from m in MirrorResourceState, where: m.repository_mirror_id == ^c.binding.id
             )
    end
  end

  test "mapped parent imports one label and yields without advancing either baseline", c do
    c = mapped(c)
    assert {:ok, result} = confirm(c)
    assert result.operation.id == c.op.id
    assert result.operation.state == :pending
    assert result.operation.cursor == c.op.cursor
    assert result.operation.checkpoint == c.op.checkpoint
    assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
    assert Repo.get!(MirrorResourceState, c.issue_mapping.id) == c.issue_mapping
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == 1
  end

  test "mapped label admission rejects changed paired mapping before callback", c do
    c = mapped(c)

    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^c.issue_mapping.id),
      inc: [lock_version: 1]
    )

    assert {:error, :stale_paired_mapping} = confirm(c, fn _ -> flunk("stale pair callback") end)
  end

  test "mapped label admission fences installation and ref evidence", c do
    c = mapped(c)

    for precondition <- [
          put_in(
            c.expected.pull_precondition,
            ["pull_eligibility_proof", "github_installation_id"],
            999_999_999
          ),
          put_in(
            c.expected.pull_precondition,
            ["pull_eligibility_proof", "head", "oid"],
            String.duplicate("c", 40)
          )
        ] do
      assert {:error, :ineligible_pull} =
               confirm(%{c | expected: %{c.expected | pull_precondition: precondition}}, fn _ ->
                 flunk("invalid proof callback")
               end)
    end
  end

  test "mapped label admission rejects scalar drift even at the same canonical version", c do
    c = mapped(c)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [title: "Changed without version"]
    )

    assert {:error, :stale_baseline} = confirm(c, fn _ -> flunk("stale scalar callback") end)

    refute Repo.exists?(
             from(l in ForgeIssues.Label, where: l.repository_id == ^c.binding.repository_id)
           )
  end

  test "mapped label callback lease loss rolls back import and preserves pair", c do
    c = mapped(c)

    callback = fn multi ->
      multi
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> Multi.run(:expire, fn repo, _ ->
        repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
          set: [lease_expires_at: DateTime.add(c.now, -1)]
        )

        {:ok, :expired}
      end)
    end

    assert {:error, :lost_lease} = confirm(c, callback)

    refute Repo.exists?(
             from(l in ForgeIssues.Label, where: l.repository_id == ^c.binding.repository_id)
           )

    assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
    assert Repo.get!(MirrorOperation, c.op.id).state == :processing
  end

  test "mapped prerequisite cannot clear a pending parent metadata effect", c do
    c = mapped(c)
    marker = %{"action" => "update_remote_pull_issue"}

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
      set: [state: :effect_pending, external_effect_marker: marker, effect_marked_at: c.now]
    )

    assert {:error, :invalid_transition} =
             confirm(%{c | op: Repo.get!(MirrorOperation, c.op.id)}, fn _ ->
               flunk("pending effect callback")
             end)

    assert Repo.get!(MirrorOperation, c.op.id).external_effect_marker == marker
  end

  for mode <- [:creation, :mapped] do
    test "#{mode} label import rejects another numeric identity bound to the same organization node",
         c do
      c = if unquote(mode) == :mapped, do: mapped(c), else: c
      other = repository_mirror_fixture(c.org)

      collision =
        Repo.insert!(%MirrorResourceState{
          repository_mirror_id: other.id,
          resource_kind: :label,
          github_object_id: 501,
          github_node_id: c.confirmation.github_node_id,
          state: :confirmed
        })

      assert {:error, :identity_conflict} =
               confirm(c, fn _ -> flunk("node collision must reject before import") end)

      assert Repo.get!(MirrorResourceState, collision.id) == collision

      refute Repo.exists?(
               from(l in ForgeIssues.Label, where: l.repository_id == ^c.binding.repository_id)
             )

      assert Repo.get!(MirrorOperation, c.op.id).state == :processing
    end
  end

  test "node collision appearing inside callback rolls back label and conflicting mapping", c do
    c = mapped(c)
    other = repository_mirror_fixture(c.org)

    callback = fn multi ->
      multi
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> Multi.run(:collision, fn repo, _ ->
        repo.insert(%MirrorResourceState{
          repository_mirror_id: other.id,
          resource_kind: :label,
          github_object_id: 501,
          github_node_id: c.confirmation.github_node_id,
          state: :confirmed
        })
      end)
    end

    assert {:error, :identity_conflict} = confirm(c, callback)

    refute Repo.exists?(
             from(l in ForgeIssues.Label, where: l.repository_id == ^c.binding.repository_id)
           )

    refute Repo.exists?(
             from(m in MirrorResourceState, where: m.repository_mirror_id == ^other.id)
           )
  end

  test "mapped local label effect retains small immutable evidence and confirms same parent", c do
    c = local_label(c)
    assert {:ok, marked} = mark_local_label(c)
    assert marked.operation.state == :effect_pending
    assert {:ok, recovered} = ForgeMirrors.mapped_pull_label_effect_context(marked.operation)
    assert recovered.resource == c.label_projection
    assert recovered.marker["proposed_snapshot"] == c.request.fields
    refute Map.has_key?(recovered.marker["paired_mapping_proof"]["pull"], "snapshot")
    expected = %{c.expected | effect_marker: recovered.marker}
    assert {:ok, confirmed} = confirm_local_label(c, marked.operation, expected)
    assert confirmed.operation.id == c.op.id
    assert confirmed.operation.state == :pending
    assert confirmed.operation.external_effect_marker == nil
    assert confirmed.resource_state.local_resource_id == c.label_projection.local_resource_id
    assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
    assert Repo.get!(MirrorResourceState, c.issue_mapping.id) == c.issue_mapping
  end

  test "mapped local label processing may adopt matching provider label without marking", c do
    c = local_label(c)
    assert {:ok, result} = confirm_local_label(c, c.op, c.expected)
    assert result.operation.state == :pending
    assert result.resource_state.confirmed_snapshot == c.request.fields
  end

  test "mapped local label mark rejects stale pair and incorrect retained snapshot", c do
    c = local_label(c)

    assert {:error, :stale_paired_mapping} =
             mark_local_label(%{
               c
               | expected: put_in(c.expected, [:pair, :issue, :lock_version], 999)
             })

    marker = put_in(c.label_marker, ["proposed_snapshot", "name"], "incorrect")
    assert {:error, :label_metadata_conflict} = mark_local_label(%{c | label_marker: marker})
    assert Repo.get!(MirrorOperation, c.op.id).state == :processing
  end

  test "mapped label recovery confirms original metadata while preserving newer local edits", c do
    c = local_label(c)
    {:ok, marked} = mark_local_label(c)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [title: "Later pull", sync_version: 2]
    )

    assert {:ok, recovered} = ForgeMirrors.mapped_pull_label_effect_context(marked.operation)
    assert recovered.marker == marked.operation.external_effect_marker

    Repo.update_all(
      from(l in ForgeIssues.Label, where: l.id == ^c.label_projection.local_resource_id),
      set: [description: "Later label", sync_version: 2]
    )

    assert {:ok, newer} = ForgeMirrors.mapped_pull_label_effect_context(marked.operation)
    assert newer.resource.local_version == 2
    expected = %{c.expected | effect_marker: recovered.marker}

    callback = fn multi ->
      ForgeIssues.append_sync_label_observe(multi, :resource, %{
        repository_id: c.binding.repository_id,
        local_resource_id: c.label_projection.local_resource_id,
        minimum_local_version: 1,
        expected_fields: c.label_projection.fields
      })
    end

    assert {:ok, confirmed} =
             ForgeMirrors.confirm_mapped_pull_label(
               marked.operation,
               c.now,
               expected,
               c.confirmation,
               callback
             )

    assert confirmed.resource_state.confirmed_local_version == 1
    assert confirmed.resource_state.confirmed_snapshot == c.request.fields

    assert Repo.get!(ForgeIssues.Label, c.label_projection.local_resource_id).description ==
             "Later label"

    assert Repo.get!(MirrorOperation, c.op.id).state == :pending
  end

  test "mapped label effect cannot be marked twice or recovered under a substituted ref proof",
       c do
    c = local_label(c)
    {:ok, marked} = mark_local_label(c)
    assert {:error, _} = mark_local_label(%{c | op: marked.operation})

    Repo.update_all(
      from(r in ForgeMirrors.MirrorRefState, where: r.repository_mirror_id == ^c.binding.id),
      set: [state: :conflicted]
    )

    assert {:error, :ineligible_pull} =
             ForgeMirrors.mapped_pull_label_effect_context(marked.operation)
  end

  test "mapped label finalization rejects colliding node and stale lease without mapping", c do
    c = local_label(c)
    {:ok, marked} = mark_local_label(c)
    expected = %{c.expected | effect_marker: marked.operation.external_effect_marker}
    other = repository_mirror_fixture(c.org)

    collision =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: other.id,
        resource_kind: :label,
        github_object_id: 501,
        github_node_id: c.confirmation.github_node_id,
        state: :confirmed
      })

    assert {:error, :identity_conflict} = confirm_local_label(c, marked.operation, expected)
    Repo.delete!(collision)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} = confirm_local_label(c, marked.operation, expected)

    refute Repo.exists?(
             from(m in MirrorResourceState,
               where: m.repository_mirror_id == ^c.binding.id and m.resource_kind == :label
             )
           )
  end

  test "mapped label mark cannot export a label removed from the canonical issue", c do
    c = local_label(c)
    Repo.delete_all(from(l in ForgeIssues.IssueLabel, where: l.issue_id == ^c.issue.id))
    assert {:error, :label_not_assigned} = mark_local_label(c)
    assert Repo.get!(MirrorOperation, c.op.id).state == :processing
  end

  test "mapped label recovery rejects a caller with substituted marker or state", c do
    c = local_label(c)
    {:ok, marked} = mark_local_label(c)

    for caller <- [
          %{
            marked.operation
            | external_effect_marker:
                Map.put(marked.operation.external_effect_marker, "label_name", "substituted")
          },
          %{marked.operation | state: :processing}
        ] do
      assert {:error, :invalid_label_effect} =
               ForgeMirrors.mapped_pull_label_effect_context(caller)
    end
  end

  test "mapped local label marker omits maximum-sized paired pull bodies", c do
    c = local_label(c)
    body = String.duplicate("😀", 65_536)
    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id), set: [body: body])

    for mapping <- [c.pull_mapping, c.issue_mapping] do
      Repo.update_all(from(m in MirrorResourceState, where: m.id == ^mapping.id),
        set: [confirmed_snapshot: Map.put(mapping.confirmed_snapshot, "body", body)]
      )
    end

    {:ok, sync} = ForgeMirrors.mapped_pull_pair_context(c.op)
    {:ok, hash} = ForgeMirrors.resource_fingerprint(sync.pair.pull.snapshot)

    expected = %{
      c.expected
      | pair: sync.pair,
        pull_precondition:
          Map.put(c.expected.pull_precondition, "expected_local_fingerprint", hash)
    }

    assert {:ok, marked} = mark_local_label(%{c | expected: expected})
    assert byte_size(JSON.encode!(marked.operation.external_effect_marker)) < 65_536
    refute String.contains?(JSON.encode!(marked.operation.external_effect_marker), "😀")
  end

  test "deleted marked local label is a visible metadata conflict, not a retryable lookup", c do
    c = local_label(c)
    {:ok, marked} = mark_local_label(c)
    Repo.delete_all(from(l in ForgeIssues.IssueLabel, where: l.issue_id == ^c.issue.id))

    Repo.delete_all(
      from(l in ForgeIssues.Label, where: l.id == ^c.label_projection.local_resource_id)
    )

    assert {:error, {:label_metadata_conflict, evidence}} =
             ForgeMirrors.mapped_pull_label_effect_context(marked.operation)

    assert evidence.operation.id == c.op.id
    assert evidence.marker == marked.operation.external_effect_marker
    assert evidence.resource == nil

    assert Repo.get!(MirrorOperation, c.op.id).external_effect_marker ==
             marked.operation.external_effect_marker
  end

  test "unversioned marked label drift returns verified conflict evidence", c do
    c = local_label(c)
    {:ok, marked} = mark_local_label(c)

    Repo.update_all(
      from(l in ForgeIssues.Label, where: l.id == ^c.label_projection.local_resource_id),
      set: [description: "Unversioned drift"]
    )

    assert {:error, {:label_metadata_conflict, evidence}} =
             ForgeMirrors.mapped_pull_label_effect_context(marked.operation)

    assert evidence.marker == marked.operation.external_effect_marker
    assert evidence.resource.fields["description"] == "Unversioned drift"
    assert evidence.sync.pair == c.expected.pair
  end

  defp local_label(c) do
    c = mapped(c)

    {:ok, %{resource: label}} =
      Multi.new()
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> Repo.transaction()

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.local_resource_id})
    {:ok, hash} = ForgeMirrors.resource_fingerprint(label.fields)

    expected =
      Map.merge(c.expected, %{
        local_label_id: label.local_resource_id,
        expected_local_version: label.local_version,
        expected_local_fingerprint: hash,
        github_object_id: nil
      })

    marker = %{
      "v" => 1,
      "action" => "create_remote_label",
      "resource_kind" => "label",
      "local_label_id" => label.local_resource_id,
      "expected_local_version" => label.local_version,
      "expected_local_fingerprint" => hash,
      "expected_remote_absent" => true,
      "label_name" => label.fields["name"],
      "proposed_fingerprint" => hash,
      "proposed_snapshot" => label.fields
    }

    Map.merge(c, %{label_projection: label, expected: expected, label_marker: marker})
  end

  defp observe_label(c, multi),
    do:
      ForgeIssues.append_sync_label_observe(multi, :resource, %{
        repository_id: c.binding.repository_id,
        local_resource_id: c.label_projection.local_resource_id,
        expected_local_version: c.label_projection.local_version,
        expected_fields: c.label_projection.fields
      })

  defp mark_local_label(c),
    do:
      ForgeMirrors.mark_mapped_pull_label_effect(
        c.op,
        c.now,
        c.expected,
        c.label_marker,
        &observe_label(c, &1)
      )

  defp confirm_local_label(c, operation, expected),
    do:
      ForgeMirrors.confirm_mapped_pull_label(
        operation,
        c.now,
        expected,
        c.confirmation,
        &observe_label(c, &1)
      )

  defp mapped(c) do
    actor = organization_owner_fixture(c.org)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: c.binding.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Mapped",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        repository_id: c.binding.repository_id,
        issue_id: issue.id,
        head_repository_id: c.binding.repository_id,
        head_ref: "refs/heads/topic",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    for {ref, oid} <- [{pull.head_ref, pull.head_sha}, {pull.base_ref, pull.base_sha}],
        do:
          Repo.insert!(%ForgeMirrors.MirrorRefState{
            repository_mirror_id: c.binding.id,
            ref_name: ref,
            ref_kind: :branch,
            state: :confirmed,
            confirmed_oid: oid,
            last_local_oid: oid,
            last_remote_oid: oid,
            last_confirmed_at: c.now
          })

    {:ok, local} = ForgePulls.sync_projection(c.binding.repository_id, :pull, pull.id)
    repository = %{"id" => c.binding.github_repository_id, "node_id" => c.binding.github_node_id}

    identity = %{
      "github_issue_object_id" => 1701,
      "github_issue_node_id" => "I_1701",
      "github_number" => 7,
      "base_repository" => repository,
      "head_repository" => repository
    }

    merge = %{"merged_at" => nil, "merge_commit_sha" => nil}

    pull_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.binding.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 1700,
        github_node_id: "PR_1700",
        github_number: 7,
        confirmed_snapshot: local.fields,
        confirmed_local_version: 1,
        confirmed_merge_state: merge,
        provider_identity: identity,
        state: :confirmed
      })

    snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => []
      })

    issue_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.binding.id,
        resource_kind: :issue,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: issue.id,
        github_object_id: 1701,
        github_node_id: "I_1701",
        github_number: 7,
        confirmed_snapshot: snapshot,
        confirmed_local_version: 1,
        state: :confirmed
      })

    {:ok, context} = ForgeMirrors.mapped_pull_pair_context(c.op)

    {:ok, proof} =
      ForgeMirrors.PullEligibility.check(
        c.binding.id,
        c.binding.repository_id,
        Map.take(pull, [:head_ref, :head_sha, :base_ref, :base_sha])
      )

    {:ok, hash} = ForgeMirrors.resource_fingerprint(local.fields)

    precondition = %{
      "github_object_id" => 1700,
      "github_node_id" => "PR_1700",
      "github_number" => 7,
      "resource_state_lock_version" => pull_mapping.lock_version,
      "expected_local_version" => 1,
      "expected_local_fingerprint" => hash,
      "provider_identity" => identity,
      "pull_eligibility_proof" => proof |> JSON.encode!() |> JSON.decode!(),
      "expected_merge_state" => merge
    }

    Map.merge(c, %{
      expected: Map.merge(c.expected, %{pair: context.pair, pull_precondition: precondition}),
      pull_mapping: pull_mapping,
      issue_mapping: issue_mapping,
      issue: issue
    })
  end

  defp confirm(c, callback \\ nil),
    do:
      ForgeMirrors.confirm_remote_pull_label(
        c.op,
        c.now,
        c.expected,
        c.confirmation,
        callback ||
          fn multi -> ForgeIssues.append_sync_label_import(multi, :resource, c.request) end
      )
end
