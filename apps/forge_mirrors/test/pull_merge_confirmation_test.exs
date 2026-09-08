defmodule ForgeMirrors.PullMergeConfirmationTest do
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

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(local.fields)
    mapping |> Changeset.change(confirmed_fingerprint: fingerprint) |> Repo.update!()

    issue_snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => []
      })

    {:ok, issue_fingerprint} = ForgeMirrors.resource_fingerprint(issue_snapshot)

    issue_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: binding.id,
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

    %{
      issue_mapping: issue_mapping,
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

  alias ForgeMirrors.PullMergeConfirmation, as: Confirmation

  test "exact current paired metadata confirms the actual version and base atomically", c do
    {operation, intent} = marked(c)
    observation = observation(c, intent)

    assert {:ok, result} =
             Repo.transaction(fn ->
               assert :ok = Confirmation.authorize(operation, c.now, intent, observation)
               actual = merge_locally(c, intent)

               assert {:ok, result} =
                        Confirmation.confirm(operation, c.now, intent, observation, actual)

               result
             end)

    assert result.operation.state == :completed
    assert result.operation.external_effect_marker == nil
    assert result.operation.lease_owner == nil

    for mapping <- [result.pull_resource_state, result.issue_resource_state] do
      assert mapping.confirmed_local_version == c.expected.local_version + 1
      assert mapping.lock_version == 2
    end

    ref =
      Repo.get_by!(MirrorRefState, repository_mirror_id: c.binding.id, ref_name: c.pull.base_ref)

    assert ref.confirmed_oid == intent.merge_oid
    assert ref.last_local_oid == intent.merge_oid
    assert ref.last_remote_oid == intent.merge_oid
    assert ref.lock_version == 2
    assert Repo.get!(ForgePulls.MergeOperation, intent.id).state == :merge_written
  end

  test "authorization and confirmation require the enclosing SQL transaction", c do
    {operation, intent} = marked(c)
    observation = observation(c, intent)

    assert {:error, :transaction_required} =
             Confirmation.authorize(operation, c.now, intent, observation)

    assert {:error, :transaction_required} =
             Confirmation.confirm(operation, c.now, intent, observation, %{})
  end

  test "a remote ref at M without merged pull metadata cannot authorize completion", c do
    {operation, intent} = marked(c)

    for observation <- [
          %{remote_base_oid: intent.merge_oid},
          put_in(observation(c, intent), [:pull, :confirmed_snapshot, "state"], "open"),
          put_in(observation(c, intent), [:pull, :confirmed_merge_state, "merged_at"], nil),
          put_in(observation(c, intent), [:remote_base_oid], String.duplicate("e", 40)),
          put_in(observation(c, intent), [:pull, :github_object_id], 111)
        ] do
      assert {:ok, {:error, _}} =
               Repo.transaction(fn ->
                 Confirmation.authorize(operation, c.now, intent, observation)
               end)
    end

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).external_effect_marker
  end

  test "newer differing metadata retains original mapping baselines and merge marker", c do
    {operation, intent} = marked(c)
    observation = observation(c, intent)
    actual = merge_locally(c, intent, "Newer local title")

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               Confirmation.confirm(operation, c.now, intent, observation, actual)
             end)

    assert Repo.get!(MirrorResourceState, c.mapping.id).confirmed_local_version ==
             c.expected.local_version

    assert Repo.get!(MirrorResourceState, c.issue_mapping.id).confirmed_local_version ==
             c.expected.local_version

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).external_effect_marker
  end

  test "newer matching metadata confirms its actual version", c do
    {operation, intent} = marked(c)
    actual = merge_locally(c, intent, "Newer local title")
    observation = observation(c, intent)
    observation = put_in(observation, [:pull, :confirmed_snapshot, "title"], "Newer local title")
    observation = put_in(observation, [:issue, :confirmed_snapshot, "title"], "Newer local title")

    assert {:ok, {:ok, result}} =
             Repo.transaction(fn ->
               Confirmation.confirm(operation, c.now, intent, observation, actual)
             end)

    assert result.pull_resource_state.confirmed_local_version == actual.local_version
    assert result.issue_resource_state.confirmed_local_version == actual.local_version
  end

  test "a supplied historical projection cannot hide actual differing metadata", c do
    {operation, intent} = marked(c)
    actual = merge_locally(c, intent)

    c.issue
    |> Changeset.change(
      title: "Changed after supplied projection",
      sync_version: actual.local_version + 1
    )
    |> Repo.update!()

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               Confirmation.confirm(operation, c.now, intent, observation(c, intent), actual)
             end)
  end

  test "outer callback rollback restores pair ref operation and local aggregate", c do
    {operation, intent} = marked(c)

    assert {:error, :later_callback_failed} =
             Repo.transaction(fn ->
               actual = merge_locally(c, intent)

               assert {:ok, _} =
                        Confirmation.confirm(
                          operation,
                          c.now,
                          intent,
                          observation(c, intent),
                          actual
                        )

               Repo.rollback(:later_callback_failed)
             end)

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).state == :effect_pending
    assert Repo.get!(MirrorResourceState, c.mapping.id).confirmed_snapshot == c.expected.fields
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
  end

  test "mapping fingerprint drift invalidates context", c do
    {operation, _intent} = marked(c)
    assert {:ok, _} = Confirmation.context(operation, c.now)
    c.mapping |> Changeset.change(confirmed_fingerprint: "bad") |> Repo.update!()
    assert {:error, _} = Confirmation.context(operation, c.now)
  end

  test "installation rebind cannot inherit the old merge intent", c do
    {operation, _intent} = marked(c)

    c.organization
    |> Changeset.change(github_installation_id: c.organization.github_installation_id + 100_000)
    |> Repo.update!()

    assert {:error, _} = Confirmation.context(operation, c.now)
  end

  test "revoked permissions and expired lease reject authorization", c do
    {operation, intent} = marked(c)

    assert {:ok, {:error, _}} =
             Repo.transaction(fn ->
               Confirmation.authorize(
                 operation,
                 DateTime.add(operation.lease_expires_at, 1),
                 intent,
                 observation(c, intent)
               )
             end)

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: c.organization.github_installation_id
      )

    installation
    |> Changeset.change(permissions: Map.put(installation.permissions, "contents", "read"))
    |> Repo.update!()

    assert {:error, _} = Confirmation.context(operation, c.now)
  end

  test "confirmed ref drift invalidates the original eligibility proof", c do
    {operation, _intent} = marked(c)

    ref =
      Repo.get_by!(MirrorRefState, repository_mirror_id: c.binding.id, ref_name: c.pull.base_ref)

    ref |> Changeset.change(lock_version: ref.lock_version + 1) |> Repo.update!()
    assert {:error, _} = Confirmation.context(operation, c.now)
  end

  test "active mirror version refresh preserves immutable eligibility", c do
    {operation, _intent} = marked(c)

    c.organization
    |> Changeset.change(lock_version: c.organization.lock_version + 1)
    |> Repo.update!()

    c.binding |> Changeset.change(lock_version: c.binding.lock_version + 1) |> Repo.update!()
    assert {:ok, _} = Confirmation.context(operation, c.now)
  end

  test "paired issue identity substitution is rejected", c do
    {operation, _intent} = marked(c)
    c.issue_mapping |> Changeset.change(github_node_id: "I_SUBSTITUTED") |> Repo.update!()
    assert {:error, _} = Confirmation.context(operation, c.now)
  end

  test "legacy nil fingerprints derive from exact snapshots without changing baselines", c do
    {operation, intent} = marked(c)

    for mapping <- [c.mapping, c.issue_mapping] do
      mapping |> Changeset.change(confirmed_fingerprint: nil) |> Repo.update!()
    end

    assert {:ok, _} = Confirmation.context(operation, c.now)
    assert Repo.get!(MirrorResourceState, c.issue_mapping.id).confirmed_fingerprint == nil
    actual = merge_locally(c, intent)

    assert {:ok, {:ok, result}} =
             Repo.transaction(fn ->
               Confirmation.confirm(operation, c.now, intent, observation(c, intent), actual)
             end)

    assert is_binary(result.pull_resource_state.confirmed_fingerprint)
    assert is_binary(result.issue_resource_state.confirmed_fingerprint)
  end

  test "an unresolved merge divergence cannot complete even when the remote later reaches M", c do
    {operation, intent} = marked(c)

    Repo.insert!(%ForgeMirrors.MirrorConflict{
      organization_mirror_id: c.organization.id,
      repository_mirror_id: c.binding.id,
      resource_kind: "pull_merge",
      resource_identity: to_string(intent.id),
      conflict_kind: "git_divergence",
      baseline_snapshot: %{"oid" => intent.expected_base_oid},
      local_snapshot: %{"oid" => intent.merge_oid},
      remote_snapshot: %{"oid" => String.duplicate("e", 40)},
      state: :open
    })

    assert {:error, _} = Confirmation.context(operation, c.now)
    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).external_effect_marker
  end

  test "successful exact confirmation clears obsolete retry diagnostics", c do
    {operation, intent} = marked(c)

    operation =
      operation
      |> Changeset.change(
        failure_class: "network",
        failure_disposition: :retry,
        failure_detail: "old retry"
      )
      |> Repo.update!()

    actual = merge_locally(c, intent)

    assert {:ok, {:ok, result}} =
             Repo.transaction(fn ->
               Confirmation.confirm(operation, c.now, intent, observation(c, intent), actual)
             end)

    assert result.operation.failure_class == nil
    assert result.operation.failure_disposition == nil
    assert result.operation.failure_detail == nil
  end

  test "regressed observations and extra metadata keys are rejected", c do
    {operation, intent} = marked(c)

    for observation <- [
          put_in(observation(c, intent), [:issue, :remote_updated_at], DateTime.add(c.now, -1)),
          put_in(observation(c, intent), [:pull, :confirmed_snapshot, "extra"], true),
          put_in(observation(c, intent), [:issue, :confirmed_snapshot, "label_github_ids"], [2, 1]),
          put_in(observation(c, intent), [:pull, :provider_base_oid], String.duplicate("f", 40)),
          put_in(observation(c, intent), [:issue, :provider_state_reason], "not_planned"),
          put_in(observation(c, intent), [:pull, :confirmed_merge_state, "merged_at"], "invalid")
        ] do
      assert {:ok, {:error, _}} =
               Repo.transaction(fn ->
                 Confirmation.authorize(operation, c.now, intent, observation)
               end)
    end
  end

  test "competing merge titles record authentic paired evidence without advancing baselines", c do
    {operation, intent} = marked(c)
    c.issue |> Changeset.change(title: "Local title", sync_version: 2) |> Repo.update!()
    remote = observation(c, intent)
    remote = put_in(remote, [:pull, :confirmed_snapshot, "title"], "Remote title")
    remote = put_in(remote, [:issue, :confirmed_snapshot, "title"], "Remote title")

    assert {:ok, yielded} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_kind: "pull_merge",
        resource_identity: to_string(intent.id)
      )

    assert conflict.conflict_kind == "concurrent_edit"

    assert conflict.baseline_snapshot == %{
             "pull" => c.expected.fields,
             "issue" => c.issue_mapping.confirmed_snapshot
           }

    assert conflict.local_snapshot["pull"]["title"] == "Local title"
    assert conflict.local_snapshot["issue"]["title"] == "Local title"

    assert conflict.remote_snapshot == %{
             "pull" => remote.pull.confirmed_snapshot,
             "issue" => remote.issue.confirmed_snapshot
           }

    assert yielded.failure_disposition == :conflict
    assert yielded.external_effect_marker == operation.external_effect_marker
    assert yielded.lease_owner == nil
    assert yielded.state == :effect_pending
    assert Repo.get!(MirrorResourceState, c.mapping.id).confirmed_snapshot == c.expected.fields
    assert Repo.get!(ForgePulls.MergeOperation, intent.id).state == :merge_written

    assert {:error, _} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    assert Repo.get!(ForgeMirrors.MirrorConflict, conflict.id).lock_version == 1
  end

  test "a newer local draft against the merged provider records a durable draft conflict", c do
    {operation, intent} = marked(c)
    c.pull |> Changeset.change(draft: true) |> Repo.update!()
    c.issue |> Changeset.change(sync_version: 2) |> Repo.update!()

    assert {:ok, _} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               observation(c, intent)
             )

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_identity: to_string(intent.id),
        resource_kind: "pull_merge"
      )

    assert conflict.conflict_kind == "merged_draft_conflict"
    assert conflict.local_snapshot["pull"]["draft"] == true
    assert conflict.remote_snapshot["pull"]["draft"] == false
  end

  test "matching and one-sided metadata cannot be classified as a conflict by a caller", c do
    {operation, intent} = marked(c)
    remote = observation(c, intent)

    assert {:error, :merge_metadata_not_conflicting} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    changed = put_in(remote, [:pull, :confirmed_snapshot, "title"], "Remote only")
    changed = put_in(changed, [:issue, :confirmed_snapshot, "title"], "Remote only")

    assert {:error, :merge_metadata_not_conflicting} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               changed
             )

    c.issue |> Changeset.change(title: "Local only", sync_version: 2) |> Repo.update!()

    assert {:error, :merge_metadata_not_conflicting} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    assert {:error, _} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               Map.put(changed, :classification, :concurrent_edit)
             )

    refute Repo.exists?(ForgeMirrors.MirrorConflict)

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).lease_owner ==
             operation.lease_owner
  end

  test "conflict recording rejects stale lease and revoked authorization without writes", c do
    {operation, intent} = marked(c)
    c.issue |> Changeset.change(title: "Local", sync_version: 2) |> Repo.update!()
    remote = observation(c, intent)
    remote = put_in(remote, [:pull, :confirmed_snapshot, "title"], "Remote")
    remote = put_in(remote, [:issue, :confirmed_snapshot, "title"], "Remote")

    assert {:error, _} =
             Confirmation.record_metadata_conflict(
               %{operation | lease_owner: "stale"},
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: c.organization.github_installation_id
      )

    installation
    |> Changeset.change(permissions: Map.put(installation.permissions, "contents", "read"))
    |> Repo.update!()

    assert {:error, _} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    refute Repo.exists?(ForgeMirrors.MirrorConflict)

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).external_effect_marker ==
             operation.external_effect_marker
  end

  test "newer local closure reasons cannot be overwritten by merge finalization", c do
    {operation, intent} = marked(c)
    remote = observation(c, intent)

    c.issue
    |> Changeset.change(state: :closed, state_reason: :not_planned, sync_version: 2)
    |> Repo.update!()

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               Confirmation.authorize(operation, c.now, intent, remote)
             end)

    assert {:ok, _} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               remote
             )

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_kind: "pull_merge",
        resource_identity: to_string(intent.id)
      )

    assert conflict.conflict_kind == "merged_state_conflict"
    assert conflict.local_snapshot["issue"]["state_reason"] == "not_planned"
  end

  test "explicit local reopening is incompatible but unchanged open state permits finalization",
       c do
    {operation, intent} = marked(c)
    remote = observation(c, intent)

    assert {:ok, :ok} =
             Repo.transaction(fn -> Confirmation.authorize(operation, c.now, intent, remote) end)

    c.issue |> Changeset.change(state_reason: :reopened, sync_version: 2) |> Repo.update!()

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn -> Confirmation.authorize(operation, c.now, intent, remote) end)
  end

  test "current local draft conflict does not require a synthetic version increment", c do
    {operation, intent} = marked(c)
    c.pull |> Changeset.change(draft: true) |> Repo.update!()

    assert {:ok, _} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               observation(c, intent)
             )
  end

  test "conflict classification locks issue and pull before reading the current projection", c do
    {operation, intent} = marked(c)
    owner = self()
    handler = "merge-conflict-locks-#{operation.id}"

    :telemetry.attach(
      handler,
      [:fornacast, :repo, :query],
      fn _, _, metadata, _ -> send(owner, {:query, metadata.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :merge_metadata_not_conflicting} =
             Confirmation.record_metadata_conflict(
               operation,
               c.now,
               DateTime.add(c.now, 1),
               observation(c, intent)
             )

    queries = collect_queries([])

    issue_lock =
      Enum.find_index(
        queries,
        &(String.contains?(&1, "FROM \"issues\"") and String.contains?(&1, "FOR UPDATE"))
      )

    pull_lock =
      Enum.find_index(
        queries,
        &(String.contains?(&1, "FROM \"pull_requests\"") and
            not String.contains?(&1, "FROM \"issues\"") and String.contains?(&1, "FOR UPDATE"))
      )

    assert is_integer(issue_lock) and is_integer(pull_lock)
    assert issue_lock < pull_lock
  end

  defp collect_queries(acc) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp observation(c, intent) do
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
        provider_state_reason: nil,
        confirmed_snapshot:
          Map.merge(Map.take(fields, ~w(title body state state_reason)), %{
            "label_github_ids" => [],
            "assignee_github_ids" => []
          }),
        remote_updated_at: c.now
      }
    }
  end

  defp merge_locally(c, intent, title \\ "Merge") do
    c.issue
    |> Changeset.change(
      state: :closed,
      state_reason: :completed,
      title: title,
      sync_version: c.expected.local_version + 1
    )
    |> Repo.update!()

    c.pull
    |> Changeset.change(
      base_sha: intent.merge_oid,
      merged_at: c.now,
      merge_commit_sha: intent.merge_oid
    )
    |> Repo.update!()

    {:ok, actual} = ForgePulls.sync_projection(c.binding.repository_id, :pull, c.pull.id)
    actual
  end

  defp marked(c) do
    assert {:ok, %{reserved: intent}} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(
               :reserved,
               c.operation,
               c.now,
               c.expected,
               ForgePulls.append_prepare_coordinated_merge(Multi.new(), :intent, c.request)
             )
             |> Repo.transaction()

    intent =
      intent
      |> Changeset.change(
        state: :merge_written,
        merge_tree_oid: String.duplicate("c", 40),
        merge_oid: String.duplicate("d", 40)
      )
      |> Repo.update!()

    assert {:ok, operation} =
             PullMergeBoundary.mark(c.operation, c.now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => intent.merge_tree_oid,
               "merge_oid" => intent.merge_oid
             })

    {operation, intent}
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
