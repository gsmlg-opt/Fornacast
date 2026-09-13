defmodule ForgeMirrors.PullMergeLabelProofTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.{Changeset, Multi}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary,
    PullMergeLabelProof,
    PullMergeMetadataEffects,
    PullMetadataIntent
  }

  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: organization.github_installation_id
      )

    installation
    |> Changeset.change(
      permissions: %{
        "contents" => "write",
        "pull_requests" => "write",
        "issues" => "read",
        "metadata" => "read"
      }
    )
    |> Repo.update!()

    base = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)
    now = DateTime.utc_now(:second)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Merge",
        body: "original",
        author_user_id: actor.id
      })

    mappings =
      for index <- 1..2 do
        label =
          Repo.insert!(%ForgeIssues.Label{
            repository_id: base.repository_id,
            name: "label#{index}",
            normalized_name: "label#{index}",
            color: "abcdef"
          })

        Repo.insert!(%ForgeIssues.IssueLabel{issue_id: issue.id, label_id: label.id})

        Repo.insert!(%MirrorResourceState{
          repository_mirror_id: base.id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: 8_000 + index,
          state: :confirmed,
          confirmed_local_version: label.sync_version,
          confirmed_snapshot: %{
            "name" => label.name,
            "color" => label.color,
            "description" => nil
          },
          confirmed_remote_updated_at: now
        })
      end

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: head.repository_id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    for {mirror, ref, oid} <- [
          {base, pull.base_ref, pull.base_sha},
          {head, pull.head_ref, pull.head_sha}
        ] do
      Repo.insert!(%MirrorRefState{
        repository_mirror_id: mirror.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: now
      })
    end

    {:ok, local} = ForgePulls.sync_projection(base.repository_id, :pull, pull.id)

    identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => %{"id" => base.github_repository_id, "node_id" => base.github_node_id},
      "head_repository" => %{"id" => head.github_repository_id, "node_id" => head.github_node_id}
    }

    pull_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: base.id,
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

    {:ok, pull_fingerprint} = ForgeMirrors.resource_fingerprint(local.fields)
    pull_mapping |> Changeset.change(confirmed_fingerprint: pull_fingerprint) |> Repo.update!()

    label_ids = Enum.map(mappings, & &1.github_object_id)

    issue_snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => label_ids,
        "assignee_github_ids" => []
      })

    {:ok, issue_fingerprint} = ForgeMirrors.resource_fingerprint(issue_snapshot)

    issue_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: base.id,
        resource_kind: :issue,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: issue.id,
        github_object_id: 901,
        github_node_id: "I_901",
        github_number: 7,
        confirmed_local_version: local.local_version,
        confirmed_remote_updated_at: now,
        confirmed_snapshot: issue_snapshot,
        confirmed_fingerprint: issue_fingerprint,
        state: :confirmed
      })

    operation =
      operation_fixture(organization, %{
        repository_mirror_id: base.id,
        kind: "merge.pull",
        cursor: %{"issue_id" => issue.id, "pull_id" => pull.id},
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-label-proof", now, 60, 100, ["merge.pull"])

    operation = Enum.find(claimed, &(&1.id == operation.id))

    {:ok, proof} =
      PullEligibility.check(
        base.id,
        head.repository_id,
        Map.take(pull, [:base_ref, :head_ref, :base_sha, :head_sha])
      )

    expected = %{
      pull_id: pull.id,
      issue_id: issue.id,
      local_version: local.local_version,
      fields: local.fields,
      provider_identity: identity,
      resource_state_lock_version: pull_mapping.lock_version,
      pull_eligibility_proof: json(proof)
    }

    signature = %{
      "name" => actor.username,
      "email" => actor.email,
      "seconds" => 1_750_000_000,
      "offset_minutes" => 0
    }

    request = %{
      repository_id: base.repository_id,
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

    c = %{
      organization: organization,
      installation: installation,
      base: base,
      head: head,
      issue: issue,
      issue_mapping: issue_mapping,
      mappings: mappings,
      now: now,
      operation: operation,
      expected: expected,
      request: request
    }

    {:ok, effect} = metadata_effect(c)
    Map.put(c, :effect, effect)
  end

  test "one bounded page seeds numeric matches, preserves baselines, and releases the lease", c do
    [first, second] = c.mappings
    assert {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)
    assert context.status == :scanning
    assert length(context.targets) == 2

    assert {:ok, %{operation: yielded, status: :scanning}} =
             seed(c, context, [label(first)], 2)

    updated = Repo.get!(MirrorResourceState, first.id)
    assert updated.github_node_id == label_node(first)
    assert updated.lock_version == first.lock_version + 1

    assert Map.drop(Map.from_struct(updated), [:github_node_id, :lock_version, :updated_at]) ==
             Map.drop(Map.from_struct(first), [:github_node_id, :lock_version, :updated_at])

    assert Repo.get!(MirrorResourceState, second.id).github_node_id == nil
    assert yielded.external_effect_marker == c.effect.operation.external_effect_marker
    assert yielded.state == :effect_pending
    assert yielded.lease_owner == nil
    assert Repo.get!(PullMetadataIntent, c.effect.intent.id) == c.effect.intent
    assert {:error, :lost_lease} = seed(c, context, [label(second)], nil)

    reclaimed = reclaim(yielded, c.now, "merge-label-page-2")
    assert {:ok, resumed} = PullMergeLabelProof.context(reclaimed, c.now)
    assert resumed.checkpoint["page"] == 2

    assert {:ok, %{status: :ready}} =
             seed(
               %{c | effect: %{c.effect | operation: reclaimed}},
               resumed,
               [label(second)],
               nil
             )
  end

  test "an exhausted inventory is unavailable and never restarts", c do
    {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)
    assert {:ok, %{operation: yielded, status: :unavailable}} = seed(c, context, [], nil)
    reclaimed = reclaim(yielded, c.now, "merge-label-exhausted")
    assert {:ok, unavailable} = PullMergeLabelProof.context(reclaimed, c.now)
    assert unavailable.status == :unavailable
    assert unavailable.checkpoint["complete"]

    assert {:error, :label_inventory_complete} =
             seed(%{c | effect: %{c.effect | operation: reclaimed}}, unavailable, [], 2)
  end

  test "known nodes are ready without inventory and org-wide collisions are rejected", c do
    Enum.each(c.mappings, fn mapping ->
      Repo.update_all(from(m in MirrorResourceState, where: m.id == ^mapping.id),
        set: [github_node_id: label_node(mapping)]
      )
    end)

    assert {:ok, %{status: :ready}} = PullMergeLabelProof.context(c.effect.operation, c.now)

    other = repository_mirror_fixture(c.organization)

    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: other.id,
      resource_kind: :label,
      github_object_id: 99_999,
      github_node_id: label_node(hd(c.mappings)),
      state: :pending
    })

    assert {:error, :identity_conflict} = PullMergeLabelProof.context(c.effect.operation, c.now)
  end

  test "repository substitution and node collision cannot seed or advance", c do
    {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)
    [first | _] = c.mappings

    wrong_repo =
      page(c, [label(first)], nil)
      |> put_in([:repository, :github_node_id], "R_wrong")

    assert {:error, :identity_conflict} =
             PullMergeLabelProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               wrong_repo,
               &yield_operation/4
             )

    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: c.head.id,
      resource_kind: :label,
      github_object_id: 99_998,
      github_node_id: label_node(first),
      state: :confirmed
    })

    assert {:error, :identity_conflict} = seed(c, context, [label(first)], nil)
    assert Repo.get!(MirrorResourceState, first.id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.effect.operation.id).checkpoint ==
             c.effect.operation.checkpoint
  end

  test "stale marker, targets, checkpoint, or mapping version rolls back the page", c do
    {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)

    for stale <- [
          put_in(expected(context), [:marker, "metadata_intent_hash"], "stale"),
          Map.put(expected(context), :targets, tl(context.targets)),
          put_in(expected(context), [:checkpoint, "page"], 2)
        ] do
      assert {:error, :stale_label_proof} =
               PullMergeLabelProof.seed(
                 c.effect.operation,
                 c.now,
                 stale,
                 page(c, Enum.map(c.mappings, &label/1), nil),
                 &yield_operation/4
               )
    end

    [first | _] = c.mappings

    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^first.id),
      inc: [lock_version: 1]
    )

    assert {:error, :stale_label_proof} = seed(c, context, Enum.map(c.mappings, &label/1), nil)
    assert Enum.all?(c.mappings, &is_nil(Repo.get!(MirrorResourceState, &1.id).github_node_id))
  end

  test "malformed or non-sequential pages cannot progress", c do
    {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)
    [first | _] = c.mappings

    for page <- [
          page(c, [Map.put(label(first), "node_id", " padded")], nil),
          page(c, [label(first), label(first)], nil),
          page(c, Enum.map(1..101, &%{"id" => &1, "node_id" => "L_#{&1}"}), nil),
          page(c, [], 3)
        ] do
      assert {:error, :invalid_label_page} =
               PullMergeLabelProof.seed(
                 c.effect.operation,
                 c.now,
                 expected(context),
                 page,
                 &yield_operation/4
               )
    end
  end

  test "a fabricated yield result cannot commit seeded nodes", c do
    {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)

    fake_yield = fn operation, checkpoint, _retry_at, _now ->
      {:ok,
       %{
         operation
         | checkpoint: checkpoint,
           state: :effect_pending,
           lease_owner: nil,
           lease_expires_at: nil
       }}
    end

    assert {:error, :invalid_transition} =
             PullMergeLabelProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               page(c, Enum.map(c.mappings, &label/1), nil),
               fake_yield
             )

    assert Enum.all?(c.mappings, &is_nil(Repo.get!(MirrorResourceState, &1.id).github_node_id))
    assert Repo.get!(MirrorOperation, c.effect.operation.id).lease_owner == "merge-label-proof"
  end

  test "expired lease, revoked installation, and installation substitution are rejected", c do
    {:ok, context} = PullMergeLabelProof.context(c.effect.operation, c.now)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.effect.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} = seed(c, context, Enum.map(c.mappings, &label/1), nil)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.effect.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, 60)]
    )

    c.installation |> Changeset.change(state: :revoked) |> Repo.update!()

    assert {:error, :credential_revoked} =
             seed(c, context, Enum.map(c.mappings, &label/1), nil)

    c.installation |> Repo.reload!() |> Changeset.change(state: :active) |> Repo.update!()
    replacement = c.organization.github_installation_id + 100_000

    Repo.update_all(from(o in ForgeMirrors.OrganizationMirror, where: o.id == ^c.organization.id),
      set: [github_installation_id: replacement]
    )

    assert {:error, :credential_revoked} =
             seed(c, context, Enum.map(c.mappings, &label/1), nil)

    assert Enum.all?(c.mappings, &is_nil(Repo.get!(MirrorResourceState, &1.id).github_node_id))
  end

  defp metadata_effect(c) do
    {:ok, %{reserved: merge_intent}} =
      Multi.new()
      |> PullMergeBoundary.append_prepare(
        :reserved,
        c.operation,
        c.now,
        c.expected,
        ForgePulls.append_prepare_coordinated_merge(Multi.new(), :intent, c.request)
      )
      |> Repo.transaction()

    merge_intent =
      merge_intent
      |> Changeset.change(
        state: :merge_written,
        merge_tree_oid: String.duplicate("c", 40),
        merge_oid: String.duplicate("d", 40)
      )
      |> Repo.update!()

    {:ok, operation} =
      PullMergeBoundary.mark(c.operation, c.now, nil, %{
        "phase" => "remote_cas_pending",
        "merge_operation_id" => merge_intent.id,
        "merge_tree_oid" => merge_intent.merge_tree_oid,
        "merge_oid" => merge_intent.merge_oid
      })

    version = c.expected.local_version + 1
    c.issue |> Changeset.change(title: "Local title", sync_version: version) |> Repo.update!()

    remote_issue =
      c.issue_mapping.confirmed_snapshot
      |> Map.put("state", "closed")
      |> Map.put("state_reason", "completed")

    target = Map.put(remote_issue, "title", "Local title")
    observation = observation(c, merge_intent, remote_issue)

    PullMergeMetadataEffects.mark(
      operation,
      c.now,
      merge_intent,
      observation,
      version,
      target
    )
  end

  defp observation(c, intent, issue_snapshot) do
    fields =
      Map.merge(c.expected.fields, %{
        "state" => "closed",
        "state_reason" => "completed",
        "base_sha" => intent.merge_oid
      })

    %{
      remote_base_oid: intent.merge_oid,
      pull: %{
        github_object_id: 902,
        github_node_id: "PR_902",
        github_number: 7,
        provider_base_oid: intent.expected_base_oid,
        provider_identity: c.expected.provider_identity,
        confirmed_snapshot: fields,
        confirmed_merge_state: %{
          "merged_at" => DateTime.to_iso8601(c.now),
          "merge_commit_sha" => intent.merge_oid
        },
        remote_updated_at: c.now
      },
      issue: %{
        github_object_id: 901,
        github_node_id: "I_901",
        github_number: 7,
        provider_state_reason: "completed",
        confirmed_snapshot: issue_snapshot,
        remote_updated_at: c.now
      }
    }
  end

  defp expected(context), do: Map.take(context, [:marker, :targets, :checkpoint])

  defp seed(c, context, labels, next) do
    PullMergeLabelProof.seed(
      c.effect.operation,
      c.now,
      expected(context),
      page(c, labels, next),
      &yield_operation/4
    )
  end

  defp page(c, labels, next) do
    %{
      labels: labels,
      next_cursor: next,
      repository: %{
        github_object_id: c.base.github_repository_id,
        github_node_id: c.base.github_node_id
      }
    }
  end

  defp label(mapping) do
    %{
      "id" => mapping.github_object_id,
      "node_id" => label_node(mapping),
      "name" => "label-#{mapping.github_object_id}",
      "color" => "abcdef",
      "description" => nil
    }
  end

  defp label_node(mapping), do: "L_#{mapping.github_object_id}"

  defp yield_operation(operation, checkpoint, retry_at, now) do
    operation
    |> Changeset.change(
      checkpoint: checkpoint,
      next_attempt_at: retry_at,
      lease_owner: nil,
      lease_expires_at: nil,
      updated_at: now
    )
    |> Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp reclaim(operation, now, owner) do
    {:ok, claimed} = ForgeMirrors.claim_operations(owner, now, 60, 100, ["merge.pull"])
    Enum.find(claimed, &(&1.id == operation.id))
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
