defmodule ForgeMirrors.PullSyncPersistenceTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeMirrors.{MirrorResourceState, MirrorRefState, PullEligibility}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    binding = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: binding.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Base",
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
        last_confirmed_at: DateTime.utc_now(:second)
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

    merge = %{"merged_at" => nil, "merge_commit_sha" => nil}

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
        confirmed_local_version: issue.sync_version,
        confirmed_remote_updated_at: DateTime.utc_now(:second),
        confirmed_snapshot: local.fields,
        confirmed_merge_state: merge,
        provider_identity: identity,
        state: :confirmed
      })
      |> Repo.insert!()

    now = DateTime.utc_now(:second)

    operation =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "sync.pull",
        cursor: %{
          "trigger" => "local",
          "issue_kind" => "pull_request",
          "issue_id" => issue.id,
          "sync_version" => issue.sync_version
        },
        next_attempt_at: now
      })

    {:ok, operations} =
      ForgeMirrors.claim_operations("pull-persistence", now, 60, 100, ["sync.pull"])

    operation = Enum.find(operations, &(&1.id == operation.id))

    {:ok, proof} =
      PullEligibility.check(binding.id, head.repository_id, %{
        head_ref: pull.head_ref,
        base_ref: pull.base_ref,
        head_sha: pull.head_sha,
        base_sha: pull.base_sha
      })

    proof = proof |> JSON.encode!() |> JSON.decode!()

    %{
      organization: organization,
      binding: binding,
      head: head,
      issue: issue,
      pull: pull,
      mapping: mapping,
      operation: operation,
      now: now,
      local: local,
      identity: identity,
      merge: merge,
      proof: proof
    }
  end

  test "context resolves canonical issue cursor to pull mapping and separate baselines", c do
    assert {:ok, context} = ForgeMirrors.resource_operation_context(c.operation)
    assert context.resource_kind == :pull
    assert context.local_resource_id == c.pull.id
    assert context.issue_id == c.issue.id
    assert context.local_version == c.issue.sync_version
    assert context.provider_identity == c.identity
    assert context.confirmed_merge_state == c.merge
  end

  test "unknown canonical issue cursor cannot borrow a valid remote pull mapping", c do
    cursor =
      Map.merge(c.operation.cursor, %{
        "issue_id" => c.issue.id + 9_000_000,
        "github_object_id" => 902
      })

    operation = c.operation |> Changeset.change(cursor: cursor) |> Repo.update!()
    assert {:error, _} = ForgeMirrors.resource_operation_context(operation)
  end

  test "a different represented local pull cannot borrow a valid remote pull mapping", c do
    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: c.binding.repository_id,
        number: 8,
        kind: :pull_request,
        title: "Other",
        author_user_id: c.issue.author_user_id
      })

    Repo.insert!(%ForgePulls.PullRequest{
      issue_id: issue.id,
      repository_id: c.binding.repository_id,
      head_repository_id: c.head.repository_id,
      head_ref: c.pull.head_ref,
      base_ref: c.pull.base_ref,
      head_sha: c.pull.head_sha,
      base_sha: c.pull.base_sha
    })

    cursor = Map.merge(c.operation.cursor, %{"issue_id" => issue.id, "github_object_id" => 902})
    operation = c.operation |> Changeset.change(cursor: cursor) |> Repo.update!()
    assert {:error, _} = ForgeMirrors.resource_operation_context(operation)
  end

  test "real domain apply and mirror confirmation commit together", c do
    {expected, confirmation} = confirmation(c)

    request = %{
      repository_id: c.binding.repository_id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      action: :update,
      expected_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.local.merge_state,
      fields: confirmation.confirmed_snapshot,
      provenance: %{origin: :github}
    }

    callback = &ForgePulls.append_sync_apply(&1, :resource, request)

    assert {:ok, result} =
             ForgeMirrors.confirm_pull_operation(
               c.operation,
               c.now,
               expected,
               confirmation,
               callback
             )

    assert result.operation.state == :completed
    assert result.resource_state.local_resource_type == "ForgePulls.PullRequest"
    assert result.resource_state.confirmed_snapshot["title"] == "Remote"
    assert result.resource_state.confirmed_merge_state == c.merge
    assert result.resource_state.provider_identity == c.identity
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version == c.local.local_version + 1
  end

  test "revoked head eligibility blocks effects and confirmation before domain mutation", c do
    c.head |> Changeset.change(inventory_included: false) |> Repo.update!()
    assert {:error, _} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker(c))
    {expected, confirmation} = confirmation(c)

    assert {:error, :ineligible_pull} =
             ForgeMirrors.confirm_pull_operation(
               c.operation,
               c.now,
               expected,
               confirmation,
               fn multi -> Multi.run(multi, :resource, fn _, _ -> flunk("must not apply") end) end
             )

    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Base"
  end

  test "stale ref proof and distinct provider identity substitutions fail closed", c do
    assert {:error, _} =
             ForgeMirrors.mark_external_effect(c.operation, c.now, %{
               marker(c)
               | "pull_eligibility_proof" => put_in(c.proof, ["head", "ref_lock_version"], 999)
             })

    {expected, confirmation} = confirmation(c)
    forged = %{confirmation | provider_identity: %{c.identity | "github_issue_object_id" => 999}}

    assert {:error, _} =
             ForgeMirrors.confirm_pull_operation(c.operation, c.now, expected, forged, fn _ ->
               flunk("must not apply")
             end)
  end

  test "provider identity is write once and bounded outside mutable snapshot", c do
    changeset =
      MirrorResourceState.persistence_changeset(c.mapping, %{
        provider_identity: %{c.identity | "github_issue_object_id" => 999}
      })

    refute changeset.valid?

    refute MirrorResourceState.persistence_changeset(c.mapping, %{
             confirmed_merge_state: %{"x" => String.duplicate("x", 20_000)}
           }).valid?
  end

  test "valid effect proof is durable and an intervening local edit keeps the older proven baseline",
       c do
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker(c))

    c.issue
    |> Changeset.change(title: "Newer local", sync_version: c.issue.sync_version + 1)
    |> Repo.update!()

    {expected, confirmation} = confirmation(c)
    expected = %{expected | effect_marker: marked.external_effect_marker}

    confirmation = %{
      confirmation
      | confirmed_snapshot: c.local.fields,
        confirmed_local_version: c.local.local_version
    }

    observe = %{
      repository_id: c.binding.repository_id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      minimum_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.local.merge_state
    }

    assert {:ok, result} =
             ForgeMirrors.confirm_pull_operation(
               marked,
               c.now,
               expected,
               confirmation,
               &ForgePulls.append_sync_observe(&1, :resource, observe)
             )

    assert result.resource.local_version == c.local.local_version + 1
    assert result.resource_state.confirmed_local_version == c.local.local_version
    assert result.resource_state.confirmed_snapshot == c.local.fields
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Newer local"
  end

  test "failed domain transaction rolls back aggregate and mapping confirmation", c do
    {expected, confirmation} = confirmation(c)

    request = %{
      repository_id: c.binding.repository_id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      action: :update,
      expected_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.local.merge_state,
      fields: confirmation.confirmed_snapshot,
      provenance: %{origin: :github}
    }

    callback = fn multi ->
      multi
      |> ForgePulls.append_sync_apply(:resource, request)
      |> Multi.error(:failure, :deliberate)
    end

    assert {:error, :deliberate} =
             ForgeMirrors.confirm_pull_operation(
               c.operation,
               c.now,
               expected,
               confirmation,
               callback
             )

    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Base"
    assert Repo.get!(MirrorResourceState, c.mapping.id).lock_version == c.mapping.lock_version
  end

  test "metadata confirmation cannot retarget refs under an unrelated proof", c do
    {expected, confirmation} = confirmation(c)

    confirmation = %{
      confirmation
      | confirmed_snapshot: %{confirmation.confirmed_snapshot | "base_ref" => "refs/heads/other"}
    }

    assert {:error, _} =
             ForgeMirrors.confirm_pull_operation(
               c.operation,
               c.now,
               expected,
               confirmation,
               fn _ -> flunk("no ref coordinator") end
             )
  end

  test "effect marking rejects a changed scalar preimage even when ref proof is unchanged", c do
    c.issue
    |> Changeset.change(title: "Changed", sync_version: c.issue.sync_version + 1)
    |> Repo.update!()

    assert {:error, _} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker(c))
  end

  test "effect marking checks the full fingerprint even at an unchanged version", c do
    c.pull |> Changeset.change(draft: true) |> Repo.update!()
    assert {:error, _} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker(c))
  end

  test "a competing confirmed baseline fences an earlier outbound decision", c do
    c.mapping
    |> Changeset.change(
      lock_version: c.mapping.lock_version + 1,
      confirmed_snapshot: %{c.local.fields | "title" => "Competing baseline"}
    )
    |> Repo.update!()

    assert {:error, _} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker(c))
  end

  test "PostgreSQL rejects non-object pull metadata independently of changesets", c do
    for field <- ["provider_identity", "confirmed_merge_state"] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 "UPDATE mirror_resource_states SET #{field} = '[]'::jsonb WHERE id = $1",
                 [c.mapping.id],
                 mode: :savepoint
               )
    end
  end

  test "effect confirmation cannot substitute the marker's proven local snapshot", c do
    {:ok, marked} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker(c))
    {expected, confirmation} = confirmation(c)

    expected = %{
      expected
      | effect_marker: marked.external_effect_marker,
        expected_fields: %{c.local.fields | "title" => "Substitute"}
    }

    confirmation = %{
      confirmation
      | confirmed_snapshot: c.local.fields,
        confirmed_local_version: c.local.local_version
    }

    observe = %{
      repository_id: c.binding.repository_id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      expected_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.local.merge_state
    }

    assert {:error, _} =
             ForgeMirrors.confirm_pull_operation(
               marked,
               c.now,
               expected,
               confirmation,
               &ForgePulls.append_sync_observe(&1, :resource, observe)
             )
  end

  test "confirmation rejects an older real domain projection than its claimed baseline", c do
    {expected, confirmation} = confirmation(c)
    confirmation = %{confirmation | confirmed_snapshot: c.local.fields}

    observe = %{
      repository_id: c.binding.repository_id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      expected_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.local.merge_state
    }

    assert {:error, :invalid_projection} =
             ForgeMirrors.confirm_pull_operation(
               c.operation,
               c.now,
               expected,
               confirmation,
               &ForgePulls.append_sync_observe(&1, :resource, observe)
             )

    assert Repo.get!(MirrorResourceState, c.mapping.id).confirmed_local_version ==
             c.local.local_version
  end

  test "projection validation ties the canonical issue to the mapped pull", c do
    {expected, confirmation} = confirmation(c)

    confirmation = %{
      confirmation
      | confirmed_snapshot: c.local.fields,
        confirmed_local_version: c.local.local_version
    }

    assert {:error, :invalid_projection} =
             ForgeMirrors.PullResourceBoundary.projection(
               %{c.local | issue_id: c.issue.id + 1},
               expected,
               confirmation
             )
  end

  test "legacy nil provider identity is initialized from correlated observations exactly once",
       c do
    Repo.update_all(from(s in MirrorResourceState, where: s.id == ^c.mapping.id),
      set: [provider_identity: nil]
    )

    {expected, confirmation} = confirmation(c)
    expected = %{expected | provider_identity: nil}

    confirmation = %{
      confirmation
      | confirmed_snapshot: c.local.fields,
        confirmed_local_version: c.local.local_version
    }

    observe = %{
      repository_id: c.binding.repository_id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      expected_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.local.merge_state
    }

    assert {:ok, result} =
             ForgeMirrors.confirm_pull_operation(
               c.operation,
               c.now,
               expected,
               confirmation,
               &ForgePulls.append_sync_observe(&1, :resource, observe)
             )

    assert result.resource_state.provider_identity == c.identity
  end

  defp confirmation(c) do
    expected = %{
      resource_state_lock_version: c.mapping.lock_version,
      local_resource_id: c.pull.id,
      expected_local_version: c.local.local_version,
      expected_fields: c.local.fields,
      expected_merge_state: c.merge,
      provider_identity: c.identity,
      pull_eligibility_proof: c.proof,
      github_object_id: 902,
      effect_marker: nil
    }

    confirmation = %{
      github_object_id: 902,
      github_node_id: "PR_902",
      github_number: 7,
      remote_updated_at: c.now,
      confirmed_local_version: c.local.local_version + 1,
      confirmed_snapshot: %{c.local.fields | "title" => "Remote"},
      confirmed_merge_state: c.merge,
      provider_identity: c.identity,
      state: :confirmed
    }

    {expected, confirmation}
  end

  defp marker(c) do
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(c.local.fields)

    %{
      "action" => "update_remote_pull_issue",
      "github_object_id" => 902,
      "proposed_fingerprint" => fingerprint,
      "github_node_id" => "PR_902",
      "github_number" => 7,
      "expected_local_version" => c.local.local_version,
      "resource_state_lock_version" => c.mapping.lock_version,
      "expected_local_fingerprint" => fingerprint,
      "provider_identity" => c.identity,
      "pull_eligibility_proof" => c.proof,
      "expected_merge_state" => c.merge
    }
  end
end
