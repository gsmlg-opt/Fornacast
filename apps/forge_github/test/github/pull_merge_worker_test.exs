defmodule ForgeGitHub.PullMergeWorkerTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.{Changeset, Multi}
  alias ForgeGitHub.{InstallationToken, PullMergeWorker}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary
  }

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

    actor = organization_owner_fixture(organization)
    owner = Repo.get!(ForgeAccounts.User, organization.organization_id)

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{
        name: "merge-worker",
        slug: "merge-worker",
        visibility: :private
      })

    binding = repository_mirror_fixture(organization, %{repository_id: repository.id})
    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    git!(path, ["update-ref", "refs/heads/main", base])
    git!(path, ["update-ref", "refs/heads/feature", head])

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: repository.id,
        number: 7,
        kind: :pull_request,
        title: "Merge",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: repository.id,
        head_repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: head,
        base_sha: base
      })

    now = DateTime.utc_now(:second)

    for {ref, oid} <- [{pull.base_ref, base}, {pull.head_ref, head}] do
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

    remote_repository = %{
      "id" => binding.github_repository_id,
      "node_id" => binding.github_node_id
    }

    identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => remote_repository,
      "head_repository" => remote_repository
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

    {:ok, claimed} = ForgeMirrors.claim_operations("merge-worker", now, 60, 100, ["merge.pull"])
    operation = Enum.find(claimed, &(&1.id == operation.id))

    {:ok, proof} =
      PullEligibility.check(
        binding.id,
        repository.id,
        Map.take(pull, [:base_ref, :head_ref, :base_sha, :head_sha])
      )

    expected = %{
      pull_id: pull.id,
      issue_id: issue.id,
      local_version: local.local_version,
      fields: local.fields,
      provider_identity: identity,
      resource_state_lock_version: mapping.lock_version,
      pull_eligibility_proof: Jason.decode!(Jason.encode!(proof))
    }

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
      expected_local_version: local.local_version,
      expected_fields: local.fields,
      expected_merge_state: local.merge_state,
      expected_head_repository_id: repository.id,
      coordinator_operation_id: operation.id,
      actor_user_id: actor.id,
      request_id: "merge-#{operation.id}",
      commit_intent: %{"message" => "Merge", "author" => signature, "committer" => signature}
    }

    domain = Multi.new() |> ForgePulls.append_prepare_coordinated_merge(:intent, request)

    {:ok, %{intent: intent}} =
      Multi.new()
      |> PullMergeBoundary.append_prepare(:intent, operation, now, expected, domain)
      |> Repo.transaction()

    {:ok, intent} =
      ForgePulls.write_coordinated_merge(intent.id, operation.id,
        authorize: &PullMergeBoundary.authorize(operation, now, &1)
      )

    %{
      operation: operation,
      intent: intent,
      now: now,
      binding: binding,
      organization: organization,
      repository: repository,
      path: path,
      base: base,
      head: head,
      pull: pull,
      issue: issue,
      remote_repository: remote_repository
    }
  end

  test "exact CAS is durably marked before pushing and success leaves the PR open", c do
    opts =
      Keyword.put(options(c, c.base), :push_remote, fn _, _, [update], _ ->
        stored = Repo.get!(MirrorOperation, c.operation.id)
        assert stored.state == :effect_pending
        assert stored.external_effect_marker["merge_oid"] == c.intent.merge_oid
        assert update.ref == "refs/heads/main"
        assert update.expected_oid == c.base
        assert update.proposed_oid == c.intent.merge_oid
        send(self(), :pushed)
        :ok
      end)

    assert {:ok, _} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert_received :pushed
    assert_unfinished(c)
  end

  test "remote M is observed without a second push", c do
    marked = mark(c)

    assert {:ok, _} =
             PullMergeWorker.process_operation(marked, c.now, options(c, c.intent.merge_oid))

    assert_unfinished(c)
  end

  test "third remote OID produces a durable conflict without overwrite", c do
    marked = mark(c)

    assert {:ok, _} =
             PullMergeWorker.process_operation(
               marked,
               c.now,
               options(c, String.duplicate("f", 40))
             )

    assert Repo.get!(MirrorOperation, marked.id).state == :effect_pending
    assert Repo.get!(MirrorOperation, marked.id).failure_disposition == :conflict
    assert_unfinished(c)
  end

  test "changed local head cannot push", c do
    git!(c.path, ["update-ref", "refs/heads/feature", c.base])
    assert {:error, _} = PullMergeWorker.process_operation(c.operation, c.now, options(c, c.base))
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  test "lost lease cannot reach provider or push", c do
    c.operation |> Changeset.change(lease_owner: "another-worker") |> Repo.update!()

    opts =
      Keyword.put(options(c, c.base), :token_fetch, fn _, _ ->
        flunk("lost owner fetched credentials")
      end)

    assert {:error, :lost_lease} = PullMergeWorker.process_operation(c.operation, c.now, opts)
  end

  test "revoked installation cannot push", c do
    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: c.organization.github_installation_id
    )
    |> Changeset.change(state: :revoked)
    |> Repo.update!()

    assert {:error, _} = PullMergeWorker.process_operation(c.operation, c.now, options(c, c.base))
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  for change <- [:closed, :different_pull, :changed_head, :different_issue, :draft] do
    test "provider #{change} cannot push", c do
      opts = options(c, c.base)
      key = if unquote(change) == :different_issue, do: :get_pull_issue, else: :get_pull
      original = Keyword.fetch!(opts, key)

      opts =
        Keyword.put(opts, key, fn a, b, d, e, f ->
          {:ok, observed} = original.(a, b, d, e, f)

          changed =
            case unquote(change) do
              :closed -> Map.put(observed, "state", "closed")
              :changed_head -> put_in(observed, ["head", "sha"], c.base)
              :draft -> Map.put(observed, "draft", true)
              _ -> Map.put(observed, "id", 999_999)
            end

          {:ok, changed}
        end)

      assert {:error, _} = PullMergeWorker.process_operation(c.operation, c.now, opts)
      assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
    end
  end

  test "timeout after remote application recovers M with no second push", c do
    opts =
      Keyword.put(options(c, c.base), :push_remote, fn _, _, _, _ ->
        send(self(), :one_push)
        {:error, :timeout}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert_received :one_push
    assert pending.state == :effect_pending
    pending |> Changeset.change(next_attempt_at: c.now) |> Repo.update!()

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-recovery", c.now, 60, 100, ["merge.pull"])

    recovered = Enum.find(claimed, &(&1.id == pending.id))

    assert {:ok, observed} =
             PullMergeWorker.process_operation(recovered, c.now, options(c, c.intent.merge_oid))

    assert observed.checkpoint["merge_observation"]["confirmation_ready"]
    refute_received :one_push
    assert_unfinished(c)
  end

  test "LFS incomplete checkpoints before any Git push and yields the lease", c do
    c.organization
    |> Changeset.change(capabilities: Map.put(c.organization.capabilities, "lfs", "enabled"))
    |> Repo.update!()

    opts = options(c, c.base)
    assert {:ok, checkpointed} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert is_binary(checkpointed.checkpoint["scan_key"])
    assert checkpointed.checkpoint["direction"] == "outbound"
    assert checkpointed.checkpoint["merge_preparation"]["merge_operation_id"] == c.intent.id
    assert checkpointed.external_effect_marker == nil
    assert checkpointed.lease_owner == nil
    assert_unfinished(c)
  end

  test "remote head is rechecked after LFS preparation before a new push", c do
    c.organization
    |> Changeset.change(capabilities: Map.put(c.organization.capabilities, "lfs", "enabled"))
    |> Repo.update!()

    opts = options(c, c.base)
    observer = Keyword.fetch!(opts, :observe_ref)

    opts =
      opts
      |> Keyword.put(:lfs_gate, fn _, _, :outbound, _, _, _, _ ->
        Process.put(:merge_lfs_finished, true)
        :ok
      end)
      |> Keyword.put(:observe_ref, fn a, b, d, e, ref, f ->
        {:ok, observed} = observer.(a, b, d, e, ref, f)

        if ref == "refs/heads/feature" and Process.get(:merge_lfs_finished),
          do: {:ok, %{observed | oid: c.base}},
          else: {:ok, observed}
      end)

    assert {:error, :changed_remote_refs} =
             PullMergeWorker.process_operation(c.operation, c.now, opts)

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  test "actual push uses a token restricted to the immutable base repository", c do
    opts =
      options(c, c.base)
      |> Keyword.put(:token_fetch, fn _, scope ->
        restricted = scope[:repository_ids] == [c.binding.github_repository_id]
        token = if restricted, do: "base-only", else: "observation"

        %InstallationToken{
          token: token,
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)
      |> Keyword.put(:push_remote, fn _, token, _, _ ->
        assert token == "base-only"
        :ok
      end)

    assert {:ok, _} = PullMergeWorker.process_operation(c.operation, c.now, opts)
  end

  test "revocation after marking and during push credential fetch prevents the push", c do
    opts =
      Keyword.put(options(c, c.base), :token_fetch, fn _, scope ->
        if scope.permissions["contents"] == "write" and
             Repo.get!(MirrorOperation, c.operation.id).state == :effect_pending do
          assert Repo.get!(MirrorOperation, c.operation.id).state == :effect_pending

          Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
            github_installation_id: c.organization.github_installation_id
          )
          |> Changeset.change(state: :revoked)
          |> Repo.update!()
        end

        %InstallationToken{
          token: "credential",
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert pending.state == :effect_pending
    assert pending.lease_owner == nil
    assert_unfinished(c)
  end

  test "observations use a read-only token restricted to represented repositories", c do
    opts =
      Keyword.put(options(c, c.base), :token_fetch, fn _, scope ->
        assert scope.repository_ids == [c.binding.github_repository_id]
        assert scope.permissions["contents"] == "read"
        {:error, :test_observation_stop}
      end)

    assert {:error, :test_observation_stop} =
             PullMergeWorker.process_operation(c.operation, c.now, opts)
  end

  test "LFS publication receives only the base-scoped write credential", c do
    c.organization
    |> Changeset.change(capabilities: Map.put(c.organization.capabilities, "lfs", "enabled"))
    |> Repo.update!()

    opts =
      options(c, c.base)
      |> Keyword.put(:token_fetch, fn _, scope ->
        token =
          if scope[:repository_ids] == [c.binding.github_repository_id] and
               scope.permissions["contents"] == "write", do: "base-write", else: "read"

        %InstallationToken{
          token: token,
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)
      |> Keyword.put(:lfs_gate, fn _, _, :outbound, _, token, _, _ ->
        assert token == "base-write"
        {:error, :lfs_missing}
      end)

    assert {:error, :lfs_missing} = PullMergeWorker.process_operation(c.operation, c.now, opts)
  end

  test "remote B recovery retries the identical recorded merge", c do
    marked = mark(c)

    opts =
      Keyword.put(options(c, c.base), :push_remote, fn _, _, [update], _ ->
        assert update.expected_oid == c.base
        assert update.proposed_oid == c.intent.merge_oid

        assert Repo.get!(MirrorOperation, marked.id).external_effect_marker ==
                 marked.external_effect_marker

        send(self(), :same_merge_retry)
        :ok
      end)

    assert {:ok, _} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :same_merge_retry
    assert_unfinished(c)
  end

  test "lease expiring during push token acquisition prevents transport", c do
    opts =
      Keyword.put(options(c, c.base), :token_fetch, fn _, scope ->
        stored = Repo.get!(MirrorOperation, c.operation.id)

        if stored.state == :effect_pending do
          stored |> Changeset.change(lease_expires_at: DateTime.add(c.now, -1)) |> Repo.update!()
        end

        %InstallationToken{
          token: "credential",
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)

    assert {:error, reason} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert reason in [:lost_lease, :stale_merge_identity]

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker["merge_oid"] ==
             c.intent.merge_oid

    assert_unfinished(c)
  end

  test "transport heartbeat rechecks installation authority", c do
    opts =
      Keyword.put(options(c, c.base), :push_remote, fn _, _, _, transport_options ->
        heartbeat = Keyword.fetch!(transport_options, :heartbeat)
        assert heartbeat.() == :ok

        Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
          github_installation_id: c.organization.github_installation_id
        )
        |> Changeset.change(state: :revoked)
        |> Repo.update!()

        assert heartbeat.() == :error
        {:error, :heartbeat_failed}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert pending.state == :effect_pending
    assert pending.lease_owner == nil
    assert_unfinished(c)
  end

  test "revocation during LFS token acquisition prevents entering LFS", c do
    c.organization
    |> Changeset.change(capabilities: Map.put(c.organization.capabilities, "lfs", "enabled"))
    |> Repo.update!()

    opts =
      options(c, c.base)
      |> Keyword.put(:token_fetch, fn _, scope ->
        if scope.permissions["contents"] == "write" do
          Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
            github_installation_id: c.organization.github_installation_id
          )
          |> Changeset.change(state: :revoked)
          |> Repo.update!()
        end

        %InstallationToken{
          token: "credential",
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)
      |> Keyword.put(:lfs_gate, fn _, _, _, _, _, _, _ ->
        flunk("LFS entered after revoked token mint")
      end)

    assert {:error, _} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  test "LFS receives a live authority callback that rejects subsequent work after revocation",
       c do
    c.organization
    |> Changeset.change(capabilities: Map.put(c.organization.capabilities, "lfs", "enabled"))
    |> Repo.update!()

    opts =
      options(c, c.base)
      |> Keyword.put(:lfs_gate, fn _, _, _, _, _, _, lfs_options ->
        authorize = Keyword.fetch!(lfs_options, :authorize)
        assert authorize.() == :ok

        Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
          github_installation_id: c.organization.github_installation_id
        )
        |> Changeset.change(state: :revoked)
        |> Repo.update!()

        assert {:error, _} = authorize.()
        authorize.()
      end)

    assert {:error, _} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  defp options(c, remote_base) do
    [
      token_fetch: fn _, _ ->
        %InstallationToken{
          token: "test-credential",
          expires_at: DateTime.add(c.now, 3600),
          permissions: %{}
        }
      end,
      observe_ref: fn _, _, _, identity, ref, _ ->
        {:ok,
         %{
           repository: identity,
           ref_name: ref,
           oid: if(ref == "refs/heads/main", do: remote_base, else: c.head)
         }}
      end,
      get_pull: fn _, _, _, _, _ ->
        {:ok,
         %{
           "id" => 902,
           "node_id" => "PR_902",
           "number" => 7,
           "state" => "open",
           "draft" => false,
           "merged" => false,
           "merged_at" => nil,
           "head" => %{"ref" => "feature", "sha" => c.head, "repo" => c.remote_repository},
           "base" => %{"ref" => "main", "sha" => remote_base, "repo" => c.remote_repository}
         }}
      end,
      get_pull_issue: fn _, _, _, _, _ ->
        {:ok, %{"id" => 901, "node_id" => "I_901", "number" => 7, "state" => "open"}}
      end,
      push_remote: fn _, _, _, _ -> flunk("unexpected remote push") end
    ]
  end

  test "confirmed provider merge atomically finalizes the local result and paired baselines", c do
    issue_mapping = paired_issue_mapping(c)
    marked = mark(c)
    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, merged_options(c))
    assert completed.state == :completed
    assert completed.external_effect_marker == nil
    assert completed.lease_owner == nil
    assert {:ok, oid} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert oid == c.intent.merge_oid
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :completed
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merge_commit_sha == oid
    issue = Repo.get!(ForgeIssues.Issue, c.issue.id)
    assert issue.state == :closed

    pull_mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :pull, local_resource_id: c.pull.id)

    issue_mapping = Repo.get!(MirrorResourceState, issue_mapping.id)
    assert pull_mapping.confirmed_local_version == issue.sync_version
    assert issue_mapping.confirmed_local_version == issue.sync_version
    assert pull_mapping.confirmed_snapshot["base_sha"] == oid
    assert pull_mapping.confirmed_merge_state["merge_commit_sha"] == oid
    assert issue_mapping.confirmed_snapshot["state"] == "closed"

    ref =
      Repo.get_by!(MirrorRefState,
        repository_mirror_id: c.binding.id,
        ref_name: "refs/heads/main"
      )

    assert {ref.confirmed_oid, ref.last_local_oid, ref.last_remote_oid} == {oid, oid, oid}
  end

  test "newer local metadata is never falsely confirmed by the merge", c do
    paired_issue_mapping(c)
    marked = mark(c)
    c.issue |> ForgeIssues.Issue.update_changeset(%{title: "Newer local title"}) |> Repo.update!()
    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, merged_options(c))
    assert pending.state == :effect_pending
    assert pending.external_effect_marker == marked.external_effect_marker
    assert pending.failure_detail == "merge_metadata_unconfirmed"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Newer local title"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :open
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written

    mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :pull, local_resource_id: c.pull.id)

    assert mapping.confirmed_snapshot["title"] == "Merge"
    assert mapping.confirmed_snapshot["base_sha"] == c.base
  end

  test "incompatible concurrent merge metadata records authentic conflict snapshots", c do
    paired_issue_mapping(c)
    marked = mark(c)
    c.issue |> ForgeIssues.Issue.update_changeset(%{title: "Local title"}) |> Repo.update!()

    assert {:ok, pending} =
             PullMergeWorker.process_operation(marked, c.now, merged_options(c, "Remote title"))

    assert pending.failure_disposition == :conflict
    assert pending.external_effect_marker == marked.external_effect_marker
    assert pending.lease_owner == nil

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_kind: "pull_merge",
        resource_identity: to_string(c.intent.id),
        state: :open
      )

    assert conflict.conflict_kind == "concurrent_edit"
    assert conflict.baseline_snapshot["pull"]["title"] == "Merge"
    assert conflict.local_snapshot["pull"]["title"] == "Local title"
    assert conflict.remote_snapshot["pull"]["title"] == "Remote title"
    assert conflict.baseline_snapshot["pull"]["base_sha"] == c.base
    assert conflict.remote_snapshot["pull"]["base_sha"] == c.intent.merge_oid
    assert_unfinished(c)
  end

  test "a newer local draft request after remote merge becomes a durable conflict", c do
    paired_issue_mapping(c)
    marked = mark(c)
    c.pull |> Changeset.change(draft: true) |> Repo.update!()

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, merged_options(c))
    assert pending.failure_disposition == :conflict
    assert pending.external_effect_marker == marked.external_effect_marker

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_kind: "pull_merge",
        resource_identity: to_string(c.intent.id),
        state: :open
      )

    assert conflict.conflict_kind == "merged_draft_conflict"
    assert conflict.local_snapshot["pull"]["draft"]
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).draft
    assert_unfinished(c)
  end

  test "a newer incompatible local closure is not overwritten by the merged result", c do
    paired_issue_mapping(c)
    marked = mark(c)

    c.issue
    |> ForgeIssues.Issue.update_changeset(%{state: :closed, state_reason: :not_planned})
    |> Repo.update!()

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, merged_options(c))
    assert pending.failure_disposition == :conflict

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_kind: "pull_merge",
        resource_identity: to_string(c.intent.id),
        state: :open
      )

    assert conflict.conflict_kind == "merged_state_conflict"
    assert conflict.local_snapshot["issue"]["state_reason"] == "not_planned"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state_reason == :not_planned
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written
  end

  test "newer metadata actually represented on both sides confirms its real final version", c do
    paired_issue_mapping(c)
    marked = mark(c)

    c.issue
    |> ForgeIssues.Issue.update_changeset(%{title: "Shared newer title"})
    |> Repo.update!()

    assert {:ok, completed} =
             PullMergeWorker.process_operation(
               marked,
               c.now,
               merged_options(c, "Shared newer title")
             )

    assert completed.state == :completed
    issue = Repo.get!(ForgeIssues.Issue, c.issue.id)

    mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :pull, local_resource_id: c.pull.id)

    assert mapping.confirmed_snapshot["title"] == issue.title
    assert mapping.confirmed_local_version == issue.sync_version
  end

  test "a different provider merge commit cannot finalize the reserved merge", c do
    paired_issue_mapping(c)
    marked = mark(c)
    opts = merged_options(c)
    read_pull = opts[:get_pull]

    opts =
      Keyword.put(opts, :get_pull, fn a, b, d, e, f ->
        {:ok, pull} = read_pull.(a, b, d, e, f)
        {:ok, Map.put(pull, "merge_commit_sha", c.head)}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending
    assert_unfinished(c)
  end

  test "confirmation recovers an already advanced local ref and refreshed snapshot", c do
    paired_issue_mapping(c)
    marked = mark(c)
    git!(c.path, ["update-ref", "refs/heads/main", c.intent.merge_oid])

    attrs =
      Map.put(
        Map.take(c.pull, [:base_ref, :base_sha, :head_ref, :head_sha]),
        :base_sha,
        c.intent.merge_oid
      )

    assert {:ok, _} = ForgePulls.SnapshotRefresh.persist(c.pull, attrs)
    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, merged_options(c))
    assert completed.state == :completed
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merge_commit_sha == c.intent.merge_oid
  end

  test "revocation after provider observation retains the unresolved merge without local effects",
       c do
    paired_issue_mapping(c)
    marked = mark(c)
    opts = merged_options(c)
    read_issue = opts[:get_pull_issue]

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        result = read_issue.(a, b, d, e, f)

        Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
          github_installation_id: c.organization.github_installation_id
        )
        |> Changeset.change(state: :revoked)
        |> Repo.update!()

        result
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.external_effect_marker == marked.external_effect_marker
    assert_unfinished(c)
  end

  defp paired_issue_mapping(c) do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :issue,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: c.issue.id,
      github_object_id: 901,
      github_node_id: "I_901",
      github_number: 7,
      confirmed_local_version: c.issue.sync_version,
      confirmed_remote_updated_at: c.now,
      confirmed_snapshot: %{
        "title" => "Merge",
        "body" => nil,
        "state" => "open",
        "state_reason" => nil,
        "label_github_ids" => [],
        "assignee_github_ids" => []
      },
      state: :confirmed
    })
    |> Repo.insert!()
  end

  defp merged_options(c, title \\ "Merge") do
    now = DateTime.to_iso8601(c.now)
    repo = Map.put(c.remote_repository, "full_name", c.binding.github_full_name)

    options(c, c.intent.merge_oid)
    |> Keyword.put(:get_pull, fn _, _, _, _, _ ->
      {:ok,
       %{
         "id" => 902,
         "node_id" => "PR_902",
         "number" => 7,
         "title" => title,
         "body" => nil,
         "state" => "closed",
         "draft" => false,
         "merged" => true,
         "merged_at" => now,
         "merge_commit_sha" => c.intent.merge_oid,
         "created_at" => now,
         "updated_at" => now,
         "mergeable" => nil,
         "rebaseable" => nil,
         "mergeable_state" => "unknown",
         "head" => %{"ref" => "feature", "sha" => c.head, "repo" => repo},
         "base" => %{"ref" => "main", "sha" => c.base, "repo" => repo}
       }}
    end)
    |> Keyword.put(:get_pull_issue, fn _, _, _, _, _ ->
      {:ok,
       %{
         "id" => 901,
         "node_id" => "I_901",
         "number" => 7,
         "title" => title,
         "body" => nil,
         "state" => "closed",
         "state_reason" => nil,
         "labels" => [],
         "assignees" => [],
         "user" => nil,
         "created_at" => now,
         "updated_at" => now
       }}
    end)
  end

  defp mark(c) do
    {:ok, operation} =
      PullMergeBoundary.mark(c.operation, c.now, nil, %{
        "phase" => "remote_cas_pending",
        "merge_operation_id" => c.intent.id,
        "merge_tree_oid" => c.intent.merge_tree_oid,
        "merge_oid" => c.intent.merge_oid
      })

    operation
  end

  defp assert_unfinished(c) do
    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :open
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written
    refute Repo.get!(MirrorOperation, c.operation.id).state == :completed
    assert {:ok, c.base} == GitCore.exact_ref(c.path, "refs/heads/main")
  end

  defp git!(path, args) do
    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args],
        env: [
          {"GIT_AUTHOR_NAME", "Merge Fixture"},
          {"GIT_AUTHOR_EMAIL", "merge@example.test"},
          {"GIT_COMMITTER_NAME", "Merge Fixture"},
          {"GIT_COMMITTER_EMAIL", "merge@example.test"}
        ]
      )

    String.trim(output)
  end
end
