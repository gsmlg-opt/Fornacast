defmodule ForgeMirrors.PullMergeRemoteAssigneeObservationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.{Changeset, Multi}
  alias ForgeAccounts.GitHubIdentity

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary,
    PullMergeRemoteAssigneeObservation
  }

  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    installation =
      Repo.get_by!(GitHubAppInstallation,
        github_installation_id: organization.github_installation_id
      )
      |> Changeset.change(
        permissions: %{
          "contents" => "write",
          "pull_requests" => "write",
          "issues" => "read",
          "metadata" => "read"
        }
      )
      |> Repo.update!()

    binding = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)
    now = DateTime.utc_now(:second)

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

    provider_identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => %{
        "id" => binding.github_repository_id,
        "node_id" => binding.github_node_id
      },
      "head_repository" => %{"id" => head.github_repository_id, "node_id" => head.github_node_id}
    }

    pull_mapping =
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
        provider_identity: provider_identity,
        state: :confirmed
      })
      |> Repo.insert!()

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(local.fields)
    pull_mapping |> Changeset.change(confirmed_fingerprint: fingerprint) |> Repo.update!()

    issue_snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => []
      })

    {:ok, issue_fingerprint} = ForgeMirrors.resource_fingerprint(issue_snapshot)

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

    queued =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "merge.pull",
        cursor: %{"issue_id" => issue.id, "pull_id" => pull.id},
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-remote-assignees", now, 60, 100, ["merge.pull"])

    operation = Enum.find(claimed, &(&1.id == queued.id))

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
      provider_identity: provider_identity,
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

    {operation, intent} = marked(operation, now, expected, request)

    next_id = (Repo.aggregate(GitHubIdentity, :max, :github_user_id) || 0) + 1

    %{
      installation: installation,
      intent: intent,
      now: now,
      operation: operation,
      profiles: [profile(next_id), profile(next_id + 1)]
    }
  end

  test "observes the exact authenticated batch without mutating or yielding the merge operation",
       c do
    assert {:ok, context} = PullMergeRemoteAssigneeObservation.context(c.operation, c.now)
    before = Repo.get!(MirrorOperation, c.operation.id)

    assert {:ok, %{operation: operation, identities: identities}} =
             PullMergeRemoteAssigneeObservation.observe(
               c.operation,
               c.now,
               expected(context),
               c.profiles,
               exact_validation()
             )

    assert Enum.map(identities, &{&1.github_user_id, &1.github_node_id}) ==
             Enum.map(c.profiles, &{&1.id, &1.node_id})

    assert operation == before
    assert Repo.get!(MirrorOperation, c.operation.id) == before
  end

  test "locks existing identities in provider order and preserves newer profile observations",
       c do
    [first, second] = c.profiles
    newer = DateTime.add(c.now, 30, :second)

    assert {:ok, existing} =
             ForgeAccounts.observe_github_identity(%{first | login: "newer"}, newer)

    owner = self()
    handler = "merge-remote-assignee-locks-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fornacast, :repo, :query],
      fn _, _, metadata, _ -> send(owner, {:identity_query, metadata.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, context} = PullMergeRemoteAssigneeObservation.context(c.operation, c.now)

    assert {:ok, _} =
             PullMergeRemoteAssigneeObservation.observe(
               c.operation,
               c.now,
               expected(context),
               [first, second],
               exact_validation()
             )

    assert Repo.get!(GitHubIdentity, existing.id).login == "newer"

    assert Enum.any?(queries([]), fn query ->
             String.contains?(query, "FROM \"github_identities\"") and
               String.contains?(query, "ORDER BY") and
               String.contains?(query, "FOR UPDATE NOWAIT")
           end)
  end

  test "rejects malformed, duplicate, substituted and colliding batches atomically", c do
    [first, second] = c.profiles
    assert {:ok, context} = PullMergeRemoteAssigneeObservation.context(c.operation, c.now)
    assert {:ok, collision} = ForgeAccounts.observe_github_identity(second, c.now)

    invalid_batches = [
      [Map.put(first, :extra, true)],
      [%{first | node_id: ""}],
      [first, %{first | login: "duplicate"}],
      [first, %{second | node_id: first.node_id}],
      [%{first | id: second.id}],
      [%{first | node_id: collision.github_node_id}]
    ]

    for profiles <- invalid_batches do
      assert {:error, reason} =
               PullMergeRemoteAssigneeObservation.observe(
                 c.operation,
                 c.now,
                 expected(context),
                 profiles,
                 exact_validation()
               )

      assert reason in [:invalid_identity_observation, :identity_conflict]
      refute Repo.get_by(GitHubIdentity, github_user_id: first.id)
    end
  end

  test "stale proof, lost lease and lost installation capability cannot persist observations",
       c do
    [first | _] = c.profiles
    assert {:ok, context} = PullMergeRemoteAssigneeObservation.context(c.operation, c.now)

    stale = put_in(expected(context).marker["merge_oid"], String.duplicate("f", 40))

    assert {:error, :stale_relationship_proof} =
             PullMergeRemoteAssigneeObservation.observe(
               c.operation,
               c.now,
               stale,
               [first],
               exact_validation()
             )

    c.installation
    |> Changeset.change(permissions: %{"metadata" => "read"})
    |> Repo.update!()

    assert {:error, :permission_missing} =
             PullMergeRemoteAssigneeObservation.observe(
               c.operation,
               c.now,
               expected(context),
               [first],
               exact_validation()
             )

    refute Repo.get_by(GitHubIdentity, github_user_id: first.id)

    c.installation
    |> Changeset.change(
      permissions: %{
        "contents" => "write",
        "pull_requests" => "write",
        "issues" => "read",
        "metadata" => "read"
      }
    )
    |> Repo.update!()

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1, :second)]
    )

    assert {:error, :lost_lease} =
             PullMergeRemoteAssigneeObservation.observe(
               c.operation,
               c.now,
               expected(context),
               [first],
               exact_validation()
             )

    refute Repo.get_by(GitHubIdentity, github_user_id: first.id)
  end

  test "relationship validation failures and successful proof drift roll the batch back", c do
    [first | _] = c.profiles
    assert {:ok, context} = PullMergeRemoteAssigneeObservation.context(c.operation, c.now)
    counter = {__MODULE__, self(), :validation_count}

    for {second_result, expected_error} <- [
          {{:error, :merge_metadata_unconfirmed}, :merge_metadata_unconfirmed},
          {{:ok, %{label_identity: :changed}}, :stale_relationship_proof}
        ] do
      Process.put(counter, 0)

      validation = fn ->
        count = Process.get(counter, 0) + 1
        Process.put(counter, count)

        if count == 1,
          do: {:ok, %{label_identity: :exact}},
          else: second_result
      end

      assert {:error, ^expected_error} =
               PullMergeRemoteAssigneeObservation.observe(
                 c.operation,
                 c.now,
                 expected(context),
                 [first],
                 validation
               )

      refute Repo.get_by(GitHubIdentity, github_user_id: first.id)
      assert Repo.get!(MirrorOperation, c.operation.id) == c.operation
    end
  end

  defp expected(context),
    do: Map.take(context, [:marker, :coordinator_intent, :metadata_intent])

  defp exact_validation, do: fn -> {:ok, %{label_identity: :exact}} end

  defp profile(id),
    do: %{
      id: id,
      node_id: "U_remote_#{id}",
      login: "remote-#{id}",
      name: nil,
      avatar_url: nil,
      html_url: nil
    }

  defp queries(acc) do
    receive do
      {:identity_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp marked(operation, now, expected, request) do
    assert {:ok, %{reserved: intent}} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(
               :reserved,
               operation,
               now,
               expected,
               ForgePulls.append_prepare_coordinated_merge(Multi.new(), :intent, request)
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
             PullMergeBoundary.mark(operation, now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => intent.merge_tree_oid,
               "merge_oid" => intent.merge_oid
             })

    {operation, intent}
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
