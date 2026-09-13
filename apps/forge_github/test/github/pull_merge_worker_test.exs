defmodule ForgeGitHub.PullMergeWorkerTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeGitHub.{Error, InstallationToken, PullMergeWorker}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary,
    PullMetadataIntent
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
        "pull_requests" => "write",
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

  test "a prepared intent is written and reloaded before any remote push", c do
    c.intent
    |> Changeset.change(state: :prepared, merge_tree_oid: nil, merge_oid: nil)
    |> Repo.update!()

    opts =
      Keyword.put(options(c, c.base), :push_remote, fn _, _, [update], _ ->
        written = Repo.get!(ForgePulls.MergeOperation, c.intent.id)
        assert written.state == :merge_written
        assert is_binary(written.merge_tree_oid)
        assert is_binary(written.merge_oid)
        assert update.proposed_oid == written.merge_oid
        :ok
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(c.operation, c.now, opts)
    assert pending.state == :effect_pending

    written = Repo.get!(ForgePulls.MergeOperation, c.intent.id)
    assert pending.external_effect_marker["merge_oid"] == written.merge_oid
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

  test "newer local metadata is durably marked but never falsely confirmed by the merge", c do
    paired_issue_mapping(c)
    marked = mark(c)
    c.issue |> ForgeIssues.Issue.update_changeset(%{title: "Newer local title"}) |> Repo.update!()

    opts =
      Keyword.put(merged_options(c), :update_pull_issue, fn _, _, _, _, _, _ ->
        {:error, :timeout}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending
    assert pending.external_effect_marker["phase"] == "metadata_issue_pending"
    assert is_integer(pending.external_effect_marker["metadata_intent_id"])
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Newer local title"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :open
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written

    mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :pull, local_resource_id: c.pull.id)

    assert mapping.confirmed_snapshot["title"] == "Merge"
    assert mapping.confirmed_snapshot["base_sha"] == c.base
  end

  test "remote-only title and body apply atomically with merge and actual paired version", c do
    issue_mapping = paired_issue_mapping(c)
    marked = mark(c)
    before = Repo.get!(ForgeIssues.Issue, c.issue.id).sync_version
    opts = merged_options(c, "Updated remotely")

    opts =
      Enum.reduce([:get_pull, :get_pull_issue], opts, fn key, acc ->
        fetch = Keyword.fetch!(acc, key)

        Keyword.put(acc, key, fn a, b, d, e, f ->
          {:ok, response} = fetch.(a, b, d, e, f)
          {:ok, Map.put(response, "body", "Remote body")}
        end)
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
    issue = Repo.get!(ForgeIssues.Issue, c.issue.id)
    assert {issue.title, issue.body, issue.state} == {"Updated remotely", "Remote body", :closed}
    assert issue.sync_version == before + 2

    pull_mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :pull, local_resource_id: c.pull.id)

    issue_mapping = Repo.get!(MirrorResourceState, issue_mapping.id)
    assert pull_mapping.confirmed_local_version == issue.sync_version
    assert issue_mapping.confirmed_local_version == issue.sync_version
    assert pull_mapping.confirmed_snapshot["title"] == issue.title
    assert issue_mapping.confirmed_snapshot["body"] == issue.body
    assert pull_mapping.confirmed_snapshot["base_sha"] == c.intent.merge_oid
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :completed
  end

  test "known remote relationship additions merge while retaining unmanaged local assignees", c do
    paired_issue_mapping(c)
    {label, identity} = known_relationships(c)

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: c.issue.id,
      user_id: c.issue.author_user_id
    })

    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        {:ok, raw} = fetch.(a, b, d, e, f)

        {:ok,
         Map.merge(raw, %{
           "labels" => [remote_import_label(800, "L_800", "known")],
           "assignees" => [%{"id" => 801, "node_id" => "U_801", "login" => "known"}]
         })}
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
    assert {:ok, actual} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)
    assert actual.label_ids == [label.id]
    assert %{kind: :github_identity, id: identity.id} in actual.assignee_refs
    assert %{kind: :local_user, id: c.issue.author_user_id} in actual.assignee_refs

    mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :issue, local_resource_id: c.issue.id)

    assert mapping.confirmed_snapshot["label_github_ids"] == [800]
    assert mapping.confirmed_snapshot["assignee_github_ids"] == [801]
    assert mapping.confirmed_local_version == actual.local_version
  end

  test "unknown remote assignees are authenticated from the merged issue before local confirmation",
       c do
    paired_issue_mapping(c)

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: c.issue.id,
      user_id: c.issue.author_user_id
    })

    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      opts
      |> Keyword.put(:get_pull_issue, fn a, b, d, e, f ->
        {:ok, raw} = fetch.(a, b, d, e, f)

        {:ok,
         Map.put(raw, "assignees", [
           %{"id" => 899, "node_id" => "U_899", "login" => "new-merge-user"}
         ])}
      end)
      |> Keyword.put(:get_relationship_user, fn _, _, _ ->
        flunk("the authenticated merged issue already contains the complete assignee profile")
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed

    identity = Repo.get_by!(ForgeAccounts.GitHubIdentity, github_user_id: 899)
    assert identity.github_node_id == "U_899"
    assert identity.login == "new-merge-user"

    assert {:ok, actual} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)
    assert %{kind: :github_identity, id: identity.id} in actual.assignee_refs
    assert %{kind: :local_user, id: c.issue.author_user_id} in actual.assignee_refs

    mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :issue, local_resource_id: c.issue.id)

    assert mapping.confirmed_snapshot["assignee_github_ids"] == [899]
    assert mapping.confirmed_local_version == actual.local_version
  end

  test "a dangling label mapping cannot authorize an unknown merge assignee observation", c do
    paired_issue_mapping(c)

    Repo.insert!(
      MirrorResourceState.persistence_changeset(%MirrorResourceState{}, %{
        repository_mirror_id: c.binding.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: System.unique_integer([:positive]) + 9_000_000_000,
        github_object_id: 898,
        github_node_id: "L_898",
        confirmed_snapshot: %{},
        state: :confirmed
      })
    )

    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        {:ok, raw} = fetch.(a, b, d, e, f)

        {:ok,
         Map.merge(raw, %{
           "labels" => [remote_import_label(898, "L_898", "dangling")],
           "assignees" => [
             %{"id" => 899, "node_id" => "U_899", "login" => "must-not-persist"}
           ]
         })}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending
    refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: 899)
    assert_unfinished(c)
  end

  test "an unknown merge label is imported one claim before the paired assignee and merge", c do
    paired_issue_mapping(c)
    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        {:ok, raw} = fetch.(a, b, d, e, f)

        {:ok,
         Map.merge(raw, %{
           "labels" => [remote_import_label(898, "L_898", "observed")],
           "assignees" => [
             %{"id" => 899, "node_id" => "U_899", "login" => "observed-user"}
           ]
         })}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending
    assert pending.lease_owner == nil
    refute Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: 899)

    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: c.binding.id,
        resource_kind: :label,
        github_object_id: 898
      )

    label = Repo.get!(ForgeIssues.Label, mapping.local_resource_id)
    assert {label.name, label.color, label.description} == {"observed", "abcdef", "remote"}
    assert_unfinished(c)

    pending = reclaim(pending, c.now, "merge-unknown-relationships")
    assert {:ok, completed} = PullMergeWorker.process_operation(pending, c.now, opts)
    assert completed.state == :completed

    identity = Repo.get_by!(ForgeAccounts.GitHubIdentity, github_user_id: 899)
    assert {:ok, actual} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)
    assert actual.label_ids == [label.id]
    assert actual.assignee_refs == [%{kind: :github_identity, id: identity.id}]
  end

  test "live merge ref drift prevents unknown label import", c do
    paired_issue_mapping(c)
    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        result = fetch.(a, b, d, e, f)
        git!(c.path, ["update-ref", "refs/heads/main", c.head])

        with {:ok, raw} <- result do
          {:ok, Map.put(raw, "labels", [remote_import_label(898, "L_898", "observed")])}
        end
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             github_object_id: 898
           )

    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :open
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written
    refute Repo.get!(MirrorOperation, c.operation.id).state == :completed
  end

  test "an already advanced local merge ref remains eligible for unknown label import", c do
    paired_issue_mapping(c)
    marked = mark(c)
    git!(c.path, ["update-ref", "refs/heads/main", c.intent.merge_oid])
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        with {:ok, raw} <- fetch.(a, b, d, e, f) do
          {:ok, Map.put(raw, "labels", [remote_import_label(898, "L_898", "observed")])}
        end
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending
    assert pending.lease_owner == nil

    assert Repo.get_by!(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             github_object_id: 898
           )

    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written
  end

  test "multiple unknown merge labels are imported in provider order across claims", c do
    paired_issue_mapping(c)
    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        with {:ok, raw} <- fetch.(a, b, d, e, f) do
          {:ok,
           Map.put(raw, "labels", [
             remote_import_label(899, "L_899", "second"),
             remote_import_label(898, "L_898", "first")
           ])}
        end
      end)

    assert {:ok, first} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert Repo.get_by(MirrorResourceState, github_object_id: 898, resource_kind: :label)
    refute Repo.get_by(MirrorResourceState, github_object_id: 899, resource_kind: :label)

    first = reclaim(first, c.now, "merge-unknown-label-second")
    assert {:ok, second} = PullMergeWorker.process_operation(first, c.now, opts)
    assert Repo.get_by(MirrorResourceState, github_object_id: 899, resource_kind: :label)
    assert_unfinished(c)

    second = reclaim(second, c.now, "merge-unknown-label-complete")
    assert {:ok, completed} = PullMergeWorker.process_operation(second, c.now, opts)
    assert completed.state == :completed
  end

  test "live head ref drift prevents unknown label import", c do
    paired_issue_mapping(c)
    marked = mark(c)
    git!(c.path, ["update-ref", "refs/heads/feature", c.base])
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        with {:ok, raw} <- fetch.(a, b, d, e, f) do
          {:ok, Map.put(raw, "labels", [remote_import_label(898, "L_898", "observed")])}
        end
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.state == :effect_pending

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             github_object_id: 898
           )

    assert Repo.get!(ForgePulls.PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written
  end

  test "relationship node drift after initial observation cannot be acknowledged by merge", c do
    paired_issue_mapping(c)
    {label, _identity} = known_relationships(c)
    marked = mark(c)
    opts = merged_options(c)
    fetch = Keyword.fetch!(opts, :get_pull_issue)

    opts =
      Keyword.put(opts, :get_pull_issue, fn a, b, d, e, f ->
        {:ok, raw} = fetch.(a, b, d, e, f)

        {:ok,
         Map.merge(raw, %{
           "labels" => [remote_import_label(800, "L_800", "known")],
           "assignees" => [%{"id" => 801, "node_id" => "U_801", "login" => "known"}]
         })}
      end)

    handler = "merge-relationship-drift-#{marked.id}"
    owner = self()

    :telemetry.attach(
      handler,
      [:fornacast, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner and not Process.get(handler, false) and
             String.starts_with?(
               metadata.query,
               "SELECT g0.\"github_user_id\", g0.\"github_node_id\" FROM"
             ) and
             String.contains?(metadata.query, "FROM \"github_identities\"") do
          Process.put(handler, true)

          Repo.get_by!(MirrorResourceState, resource_kind: :label, local_resource_id: label.id)
          |> Changeset.change(github_node_id: "L_changed")
          |> Repo.update!()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert Process.get(handler)
    assert pending.state == :effect_pending
    assert pending.external_effect_marker == marked.external_effect_marker
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :open
    assert Repo.get!(ForgePulls.MergeOperation, c.intent.id).state == :merge_written
  end

  test "known remote relationship removals use the unchanged paired baseline", c do
    mapping = paired_issue_mapping(c)
    {label, identity} = known_relationships(c)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: c.issue.id,
      github_identity_id: identity.id
    })

    mapping
    |> Changeset.change(
      confirmed_snapshot:
        Map.merge(
          mapping.confirmed_snapshot,
          %{"label_github_ids" => [800], "assignee_github_ids" => [801]}
        )
    )
    |> Repo.update!()

    marked = mark(c)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, merged_options(c))
    assert completed.state == :completed
    assert {:ok, actual} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)
    assert actual.label_ids == []
    assert actual.assignee_refs == []
    assert Repo.get!(MirrorResourceState, mapping.id).confirmed_snapshot["label_github_ids"] == []
  end

  test "remote-only metadata also completes when local ref and snapshot already recovered to M",
       c do
    paired_issue_mapping(c)
    marked = mark(c)
    git!(c.path, ["update-ref", "refs/heads/main", c.intent.merge_oid])

    assert {:ok, _} =
             ForgePulls.SnapshotRefresh.persist(
               c.pull,
               Map.put(
                 Map.take(c.pull, [:base_ref, :head_ref, :base_sha, :head_sha]),
                 :base_sha,
                 c.intent.merge_oid
               )
             )

    assert {:ok, completed} =
             PullMergeWorker.process_operation(
               marked,
               c.now,
               merged_options(c, "Remote after recovery")
             )

    assert completed.state == :completed
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).title == "Remote after recovery"
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

  test "local-only title and body are durably marked before the exact issue patch", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title", body: "Local body"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      scalar_effect_options(c, provider, fn token, attrs ->
        stored = Repo.get!(MirrorOperation, marked.id)
        assert stored.state == :effect_pending
        assert stored.external_effect_marker["phase"] == "metadata_issue_pending"
        assert token == "metadata-write"
        assert attrs == %{"body" => "Local body", "title" => "Local title"}

        intent =
          Repo.get!(PullMetadataIntent, stored.external_effect_marker["metadata_intent_id"])

        assert intent.payload["expected_remote_issue"]["title"] == "Merge"
        assert intent.payload["target_issue"]["title"] == "Local title"

        Agent.update(provider, &Map.merge(&1, %{title: "Local title", body: "Local body"}))
        {:ok, %{"untrusted" => true}}
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
    assert Agent.get(provider, & &1.issue_reads) >= 2
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :closed
  end

  test "metadata mutation token is base-only with exact write scope", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      scalar_effect_options(c, provider, fn _, _ ->
        Agent.update(provider, &Map.put(&1, :title, "Local title"))
        {:ok, %{}}
      end)
      |> Keyword.put(:token_fetch, fn _, scope ->
        token =
          case scope.permissions do
            %{"metadata" => "read", "pull_requests" => "write"} = permissions
            when map_size(permissions) == 2 ->
              assert scope.repository_ids == [c.binding.github_repository_id]
              "metadata-write"

            _ ->
              "observation"
          end

        %InstallationToken{
          token: token,
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
  end

  test "merge-owned mapped relationship additions use fresh names in one durable issue effect",
       c do
    paired_issue_mapping(c)
    {label, identity} = known_relationships(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local relationship title"})
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: c.issue.id,
      github_identity_id: identity.id
    })

    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn labels, assignees ->
          assert labels == [
                   %{github_object_id: 800, github_node_id: "L_800"}
                 ]

          assert assignees == [
                   %{github_user_id: 801, github_node_id: "U_801"}
                 ]

          {:ok,
           %{
             labels: [%{github_object_id: 800, github_node_id: "L_800", name: "fresh-label"}],
             assignees: [
               %{github_user_id: 801, github_node_id: "U_801", login: "fresh-user"}
             ]
           }}
        end,
        fn _, attrs ->
          assert attrs == %{
                   "assignees" => ["fresh-user"],
                   "labels" => ["fresh-label"],
                   "title" => "Local relationship title"
                 }

          Agent.update(provider, fn state ->
            %{
              state
              | title: "Local relationship title",
                labels: [remote_label()],
                assignees: [remote_assignee()]
            }
          end)

          {:ok, %{}}
        end
      )

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
    assert Repo.aggregate(PullMetadataIntent, :count) == 1
  end

  test "merge-owned local label is durably created before its membership patch", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn labels, [] ->
          assert labels == [
                   %{github_object_id: 880, github_node_id: "L_880"}
                 ]

          {:ok,
           %{
             labels: [
               %{github_object_id: 880, github_node_id: "L_880", name: "merge-local"}
             ],
             assignees: []
           }}
        end,
        fn _, attrs ->
          assert attrs == %{"labels" => ["merge-local"]}
          send(self(), :relationship_patch)

          Agent.update(
            provider,
            &%{&1 | labels: [remote_import_label(880, "L_880", "merge-local")]}
          )

          {:ok, %{}}
        end
      )
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, attrs, _ ->
        assert attrs == %{
                 "name" => "merge-local",
                 "color" => "abcdef",
                 "description" => "remote"
               }

        send(self(), :merge_label_created)
        {:ok, remote_import_label(880, "L_880", "merge-local")}
      end)

    assert {:ok, after_label} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :merge_label_created

    assert %MirrorResourceState{
             github_object_id: 880,
             github_node_id: "L_880",
             local_resource_id: local_label_id,
             state: :confirmed
           } =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: c.binding.id,
               resource_kind: :label,
               local_resource_id: label.id
             )

    assert local_label_id == label.id
    assert after_label.external_effect_marker["phase"] == "remote_cas_pending"
    refute_received :relationship_patch

    after_label = reclaim(after_label, c.now, "merge-local-label-membership")
    assert {:ok, completed} = PullMergeWorker.process_operation(after_label, c.now, opts)
    assert_received :relationship_patch
    assert completed.state == :completed
  end

  test "merge-owned local label adopts an exact provider label without creating it", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn labels, [] ->
          assert labels == [%{github_object_id: 880, github_node_id: "L_880"}]

          {:ok,
           %{
             labels: [
               %{github_object_id: 880, github_node_id: "L_880", name: "merge-local"}
             ],
             assignees: []
           }}
        end,
        fn _, attrs ->
          assert attrs == %{"labels" => ["merge-local"]}
          send(self(), :adopted_label_membership_patch)

          Agent.update(
            provider,
            &%{&1 | labels: [remote_import_label(880, "L_880", "merge-local")]}
          )

          {:ok, %{}}
        end
      )
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        {:ok, remote_import_label(880, "L_880", "merge-local")}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        flunk("an exact provider label must be adopted without POST")
      end)

    assert {:ok, after_label} = PullMergeWorker.process_operation(marked, c.now, opts)

    assert %MirrorResourceState{github_object_id: 880, local_resource_id: id} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: c.binding.id,
               resource_kind: :label,
               local_resource_id: label.id
             )

    assert id == label.id
    assert after_label.external_effect_marker["phase"] == "remote_cas_pending"
    refute_received :adopted_label_membership_patch

    after_label = reclaim(after_label, c.now, "merge-local-label-adopt-membership")
    assert {:ok, completed} = PullMergeWorker.process_operation(after_label, c.now, opts)
    assert_received :adopted_label_membership_patch
    assert completed.state == :completed
  end

  test "merge-owned local label recovers a lost create response with GET only", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, label_created?} = Agent.start_link(fn -> false end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn labels, [] ->
          assert labels == [%{github_object_id: 880, github_node_id: "L_880"}]

          {:ok,
           %{
             labels: [
               %{github_object_id: 880, github_node_id: "L_880", name: "merge-local"}
             ],
             assignees: []
           }}
        end,
        fn _, attrs ->
          assert attrs == %{"labels" => ["merge-local"]}
          send(self(), :recovered_label_membership_patch)

          Agent.update(
            provider,
            &%{&1 | labels: [remote_import_label(880, "L_880", "merge-local")]}
          )

          {:ok, %{}}
        end
      )
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        if Agent.get(label_created?, & &1),
          do: {:ok, remote_import_label(880, "L_880", "merge-local")},
          else: {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        send(self(), :merge_label_create_attempt)
        Agent.update(label_created?, fn _ -> true end)
        {:error, Error.new(:timeout)}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :merge_label_create_attempt
    assert pending.external_effect_marker["phase"] == "metadata_label_pending"
    refute_received :recovered_label_membership_patch

    pending = reclaim(pending, c.now, "merge-local-label-create-recovery")

    recovery_opts =
      Keyword.put(opts, :create_label, fn _, _, _, _, _ ->
        flunk("marked label recovery must never repeat POST")
      end)

    assert {:ok, after_label} = PullMergeWorker.process_operation(pending, c.now, recovery_opts)
    refute_received :merge_label_create_attempt
    refute_received :recovered_label_membership_patch
    assert after_label.external_effect_marker["phase"] == "remote_cas_pending"

    assert %MirrorResourceState{github_object_id: 880, local_resource_id: id} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: c.binding.id,
               resource_kind: :label,
               local_resource_id: label.id
             )

    assert id == label.id

    after_label = reclaim(after_label, c.now, "merge-local-label-recovered-membership")
    assert {:ok, completed} = PullMergeWorker.process_operation(after_label, c.now, recovery_opts)
    assert_received :recovered_label_membership_patch
    assert completed.state == :completed
  end

  test "merge-owned local label recovery records an absent create as a conflict", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("a missing label recovery must not resolve membership names") end,
        fn _, _ -> flunk("a missing label recovery must not patch issue membership") end
      )
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        send(self(), :ambiguous_label_create_attempt)
        {:error, Error.new(:timeout)}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :ambiguous_label_create_attempt
    pending = reclaim(pending, c.now, "merge-local-label-absent-recovery")

    recovery_opts =
      Keyword.put(opts, :create_label, fn _, _, _, _, _ ->
        flunk("marked absent recovery must never repeat POST")
      end)

    assert {:ok, conflicted} = PullMergeWorker.process_operation(pending, c.now, recovery_opts)
    assert conflicted.failure_disposition == :conflict
    assert conflicted.failure_detail == "ambiguous_label_create"
    assert conflicted.external_effect_marker["phase"] == "metadata_label_pending"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: label.id
           )

    conflicted = reclaim(conflicted, c.now, "merge-local-label-open-conflict")

    blocked_opts =
      recovery_opts
      |> Keyword.put(:get_label, fn _, _, _, _, _ ->
        flunk("an unresolved label conflict must stop provider access")
      end)

    assert {:ok, blocked} = PullMergeWorker.process_operation(conflicted, c.now, blocked_opts)
    assert blocked.failure_disposition == :conflict
    assert blocked.external_effect_marker["phase"] == "metadata_label_pending"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: label.id
           )
  end

  test "merge-owned label recovery records a provider identity collision", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, remote_created?} = Agent.start_link(fn -> false end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("identity conflict must stop relationship resolution") end,
        fn _, _ -> flunk("identity conflict must stop metadata mutation") end
      )
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        if Agent.get(remote_created?, & &1),
          do: {:ok, remote_import_label(880, "L_880", "merge-local")},
          else: {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        Agent.update(remote_created?, fn _ -> true end)
        {:error, Error.new(:timeout)}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.external_effect_marker["phase"] == "metadata_label_pending"

    collision =
      %ForgeIssues.Label{repository_id: c.repository.id}
      |> ForgeIssues.Label.changeset(%{
        name: "collision",
        normalized_name: "collision",
        color: "123456"
      })
      |> Repo.insert!()

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: collision.id,
      github_object_id: 999,
      github_node_id: "L_880",
      confirmed_snapshot: %{},
      state: :confirmed
    })
    |> Repo.insert!()

    pending = reclaim(pending, c.now, "merge-local-label-identity-conflict")

    recovery_opts =
      Keyword.put(opts, :create_label, fn _, _, _, _, _ ->
        flunk("marked identity-conflict recovery must never repeat POST")
      end)

    assert {:ok, conflicted} = PullMergeWorker.process_operation(pending, c.now, recovery_opts)
    assert conflicted.failure_disposition == :conflict
    assert conflicted.failure_detail == "label_identity_conflict"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: label.id
           )
  end

  test "merge-owned label recovery records deleted local evidence without provider mutation", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("deleted evidence must stop relationship resolution") end,
        fn _, _ -> flunk("deleted evidence must stop metadata mutation") end
      )
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        {:error, Error.new(:timeout)}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.external_effect_marker["phase"] == "metadata_label_pending"

    Repo.delete_all(
      from membership in ForgeIssues.IssueLabel,
        where: membership.issue_id == ^c.issue.id and membership.label_id == ^label.id
    )

    Repo.delete!(label)
    pending = reclaim(pending, c.now, "merge-local-label-deleted-evidence")

    recovery_opts =
      opts
      |> Keyword.put(:get_label, fn _, _, _, _, _ ->
        flunk("deleted marked evidence must conflict before provider label access")
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        flunk("deleted marked evidence must never repeat POST")
      end)

    assert {:ok, conflicted} = PullMergeWorker.process_operation(pending, c.now, recovery_opts)
    assert conflicted.failure_disposition == :conflict
    assert conflicted.failure_detail == "label_metadata_conflict"
  end

  test "a newer local label waits for an applied merge metadata effect and restores its marker",
       c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "First local edit"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, local_label_id} = Agent.start_link(fn -> nil end)

    first =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("the first scalar effect has no relationship nodes") end,
        fn _, attrs ->
          assert attrs == %{"title" => "First local edit"}

          Agent.update(provider, &%{&1 | title: "First local edit"})
          label = assigned_unmapped_label(c, "metadata-local")
          Agent.update(local_label_id, fn _ -> label.id end)
          edit_issue(c, %{body: "newer local edit"})
          send(self(), :first_metadata_effect_applied)
          {:error, Error.new(:timeout)}
        end
      )

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
    assert_received :first_metadata_effect_applied
    assert pending.external_effect_marker["phase"] == "metadata_issue_pending"

    pending = reclaim(pending, c.now, "merge-metadata-local-label")

    recovery =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("label creation must precede the next membership patch") end,
        fn _, _ -> flunk("the already-applied metadata effect must not be repeated") end
      )
      |> Keyword.put(:get_label, fn _, _, _, "metadata-local", _ ->
        {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, attrs, _ ->
        assert attrs == %{
                 "name" => "metadata-local",
                 "color" => "abcdef",
                 "description" => "remote"
               }

        send(self(), :metadata_local_label_created)
        {:ok, remote_import_label(881, "L_881", "metadata-local")}
      end)

    assert {:ok, after_label} = PullMergeWorker.process_operation(pending, c.now, recovery)
    assert_received :metadata_local_label_created
    assert after_label.external_effect_marker["phase"] == "metadata_issue_pending"
    refute_received :first_metadata_effect_applied

    assert %MirrorResourceState{github_object_id: 881, local_resource_id: id} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: c.binding.id,
               resource_kind: :label,
               local_resource_id: Agent.get(local_label_id, & &1)
             )

    assert id == Agent.get(local_label_id, & &1)
  end

  test "a newer local label retries the prior metadata preimage before label creation", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "First local edit"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, local_label_id} = Agent.start_link(fn -> nil end)
    {:ok, prior_effect_applied?} = Agent.start_link(fn -> false end)

    first =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("the first scalar effect has no relationship nodes") end,
        fn _, attrs ->
          assert attrs == %{"title" => "First local edit"}
          label = assigned_unmapped_label(c, "metadata-local")
          Agent.update(local_label_id, fn _ -> label.id end)
          edit_issue(c, %{body: "newer local edit"})
          {:error, Error.new(:timeout)}
        end
      )

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
    assert pending.external_effect_marker["phase"] == "metadata_issue_pending"
    pending = reclaim(pending, c.now, "merge-metadata-preimage-before-label")

    recovery =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("label creation must precede the next membership patch") end,
        fn _, attrs ->
          assert attrs == %{"title" => "First local edit"}
          Agent.update(provider, &%{&1 | title: "First local edit"})
          Agent.update(prior_effect_applied?, fn _ -> true end)
          send(self(), :prior_metadata_preimage_applied)
          {:ok, %{}}
        end
      )
      |> Keyword.put(:get_label, fn _, _, _, "metadata-local", _ ->
        assert Agent.get(prior_effect_applied?, & &1)
        {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, attrs, _ ->
        assert Agent.get(prior_effect_applied?, & &1)
        assert attrs["name"] == "metadata-local"
        send(self(), :post_preimage_label_created)
        {:ok, remote_import_label(882, "L_882", "metadata-local")}
      end)

    assert {:ok, after_label} = PullMergeWorker.process_operation(pending, c.now, recovery)
    assert_received :post_preimage_label_created
    assert after_label.external_effect_marker["phase"] == "metadata_issue_pending"

    assert %MirrorResourceState{github_object_id: 882} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: c.binding.id,
               resource_kind: :label,
               local_resource_id: Agent.get(local_label_id, & &1)
             )
  end

  test "a third metadata state conflicts before inspecting a newer local label", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "First local edit"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, local_label_id} = Agent.start_link(fn -> nil end)

    first =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("the first scalar effect has no relationship nodes") end,
        fn _, attrs ->
          assert attrs == %{"title" => "First local edit"}
          label = assigned_unmapped_label(c, "metadata-local")
          Agent.update(local_label_id, fn _ -> label.id end)
          edit_issue(c, %{body: "newer local edit"})
          Agent.update(provider, &%{&1 | title: "Third provider state"})
          {:error, Error.new(:timeout)}
        end
      )

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
    pending = reclaim(pending, c.now, "merge-metadata-third-state-before-label")

    recovery =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("ambiguous metadata must stop relationship resolution") end,
        fn _, _ -> flunk("ambiguous metadata must not be patched") end
      )
      |> Keyword.put(:get_label, fn _, _, _, _, _ ->
        flunk("ambiguous metadata must stop before provider label access")
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        flunk("ambiguous metadata must stop before label POST")
      end)

    assert {:ok, conflicted} = PullMergeWorker.process_operation(pending, c.now, recovery)
    assert conflicted.failure_disposition == :conflict
    assert conflicted.failure_detail == "ambiguous_external_effect"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: Agent.get(local_label_id, & &1)
           )
  end

  test "provider drift during label lookup cannot persist a stale namespace conflict", c do
    paired_issue_mapping(c)
    marked = mark(c)
    _label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, remote_base} = Agent.start_link(fn -> c.intent.merge_oid end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("provider drift must stop relationship resolution") end,
        fn _, _ -> flunk("provider drift must stop metadata mutation") end
      )

    observe_ref = Keyword.fetch!(opts, :observe_ref)

    opts =
      opts
      |> Keyword.put(:observe_ref, fn token, owner, repository, identity, ref, request_options ->
        if ref == "refs/heads/main" do
          {:ok,
           %{
             repository: identity,
             ref_name: ref,
             oid: Agent.get(remote_base, & &1)
           }}
        else
          observe_ref.(token, owner, repository, identity, ref, request_options)
        end
      end)
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        Agent.update(remote_base, fn _ -> c.base end)

        {:ok,
         remote_import_label(880, "L_880", "merge-local")
         |> Map.put("color", "000000")}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        flunk("a present provider namespace must never be created")
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.failure_disposition == :retry

    refute Repo.get_by(ForgeMirrors.MirrorConflict,
             resource_kind: "pull_merge",
             resource_identity: to_string(c.intent.id),
             conflict_kind: "label_namespace_collision"
           )

    assert_unfinished(c)
  end

  test "write-token revocation stops merge label provider access", c do
    paired_issue_mapping(c)
    marked = mark(c)
    label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("revoked authority must stop relationship resolution") end,
        fn _, _ -> flunk("revoked authority must stop metadata mutation") end
      )
      |> Keyword.put(:token_fetch, fn _, scope ->
        if scope.permissions == %{"metadata" => "read", "pull_requests" => "write"} do
          Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
            github_installation_id: c.organization.github_installation_id
          )
          |> Changeset.change(state: :revoked)
          |> Repo.update!()
        end

        %InstallationToken{
          token: "test-credential",
          expires_at: DateTime.add(c.now, 3600),
          permissions: scope.permissions
        }
      end)
      |> Keyword.put(:get_relationship_repository, fn _, _, _ ->
        flunk("revocation after token acquisition must stop repository access")
      end)
      |> Keyword.put(:get_label, fn _, _, _, _, _ ->
        flunk("revocation after token acquisition must stop label access")
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        flunk("revocation after token acquisition must stop label creation")
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert pending.external_effect_marker == marked.external_effect_marker

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: label.id
           )
  end

  test "authority lost in post-mark repository validation stops label POST", c do
    paired_issue_mapping(c)
    marked = mark(c)
    _label = assigned_unmapped_label(c, "merge-local")
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    {:ok, repository_reads} = Agent.start_link(fn -> 0 end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ -> flunk("label identity must be confirmed before relationship resolution") end,
        fn _, _ -> flunk("label identity must be confirmed before metadata mutation") end
      )
      |> Keyword.put(:get_relationship_repository, fn _, _, _ ->
        read = Agent.get_and_update(repository_reads, &{&1 + 1, &1 + 1})

        if read == 3 do
          Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
            github_installation_id: c.organization.github_installation_id
          )
          |> Changeset.change(state: :revoked)
          |> Repo.update!()
        end

        {:ok,
         %{
           github_object_id: c.binding.github_repository_id,
           github_node_id: c.binding.github_node_id
         }}
      end)
      |> Keyword.put(:get_label, fn _, _, _, "merge-local", _ ->
        {:error, Error.new(:not_found)}
      end)
      |> Keyword.put(:create_label, fn _, _, _, _, _ ->
        flunk("authority lost after marking must stop label POST")
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert Agent.get(repository_reads, & &1) == 3
    assert pending.external_effect_marker["phase"] == "metadata_label_pending"
  end

  test "missing assignee and label nodes are authenticated one per claim before merge metadata patch",
       c do
    paired_issue_mapping(c)
    {label, identity} = known_relationships(c)

    Repo.update_all(
      from(m in MirrorResourceState,
        where: m.resource_kind == :label and m.local_resource_id == ^label.id
      ),
      set: [github_node_id: nil]
    )

    Repo.update_all(from(i in ForgeAccounts.GitHubIdentity, where: i.id == ^identity.id),
      set: [github_node_id: nil]
    )

    marked = mark(c)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: c.issue.id,
      github_identity_id: identity.id
    })

    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ ->
          {:ok,
           %{
             labels: [%{github_object_id: 800, github_node_id: "L_800", name: "fresh-label"}],
             assignees: [
               %{github_user_id: 801, github_node_id: "U_801", login: "fresh-user"}
             ]
           }}
        end,
        fn _, _ ->
          send(self(), :relationship_patch)

          Agent.update(provider, fn state ->
            %{state | labels: [remote_label()], assignees: [remote_assignee()]}
          end)

          {:ok, %{}}
        end
      )
      |> Keyword.put(:get_relationship_user, fn _, 801, _ ->
        send(self(), :assignee_proof)

        {:ok,
         %ForgeGitHub.User{
           id: 801,
           login: "fresh-user",
           node_id: "U_801",
           name: nil,
           avatar_url: nil,
           html_url: nil
         }}
      end)
      |> Keyword.put(:list_relationship_labels, fn _, _, _, 1, _ ->
        send(self(), :label_proof)

        {:ok,
         %{
           labels: [
             %{
               "id" => 800,
               "node_id" => "L_800",
               "name" => "fresh-label",
               "color" => "112233",
               "description" => nil
             }
           ],
           next_cursor: nil
         }}
      end)

    assert {:ok, after_user} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :assignee_proof
    refute_received :label_proof
    refute_received :relationship_patch

    after_user = reclaim(after_user, c.now, "merge-label-proof")
    assert {:ok, after_label} = PullMergeWorker.process_operation(after_user, c.now, opts)
    assert_received :label_proof
    refute_received :relationship_patch

    after_label = reclaim(after_label, c.now, "merge-relationship-patch")
    assert {:ok, completed} = PullMergeWorker.process_operation(after_label, c.now, opts)
    assert_received :relationship_patch
    assert completed.state == :completed
  end

  test "merge-owned relationship removals patch explicit empty sets without node lookup", c do
    issue_mapping = paired_issue_mapping(c)
    {label, identity} = known_relationships(c)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})

    Repo.insert!(%ForgeIssues.IssueAssignee{
      issue_id: c.issue.id,
      github_identity_id: identity.id
    })

    issue_mapping
    |> Changeset.change(
      confirmed_snapshot:
        Map.merge(issue_mapping.confirmed_snapshot, %{
          "label_github_ids" => [800],
          "assignee_github_ids" => [801]
        })
    )
    |> Repo.update!()

    marked = mark(c)
    Repo.delete_all(from(l in ForgeIssues.IssueLabel, where: l.issue_id == ^c.issue.id))
    Repo.delete_all(from(a in ForgeIssues.IssueAssignee, where: a.issue_id == ^c.issue.id))

    {:ok, provider} =
      Agent.start_link(fn ->
        %{provider_state(c) | labels: [remote_label()], assignees: [remote_assignee()]}
      end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ ->
          flunk("empty relationship targets do not require GraphQL resolution")
        end,
        fn _, attrs ->
          assert attrs == %{"assignees" => [], "labels" => []}
          Agent.update(provider, &%{&1 | labels: [], assignees: []})
          {:ok, %{}}
        end
      )
      |> Keyword.put(:get_relationship_user, fn _, _, _ -> flunk("unexpected user lookup") end)
      |> Keyword.put(:list_relationship_labels, fn _, _, _, _, _ ->
        flunk("unexpected label inventory")
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
  end

  test "exhausted merge label proof becomes a visible conflict without metadata patch", c do
    paired_issue_mapping(c)
    {label, _identity} = known_relationships(c)

    Repo.update_all(
      from(m in MirrorResourceState,
        where: m.resource_kind == :label and m.local_resource_id == ^label.id
      ),
      set: [github_node_id: nil]
    )

    marked = mark(c)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      relationship_effect_options(
        c,
        provider,
        fn _, _ ->
          flunk("unavailable labels cannot be resolved")
        end,
        fn _, _ ->
          flunk("unavailable labels cannot be patched")
        end
      )
      |> Keyword.put(:list_relationship_labels, fn _, _, _, 1, _ ->
        {:ok, %{labels: [], next_cursor: nil}}
      end)

    assert {:ok, scanned} = PullMergeWorker.process_operation(marked, c.now, opts)
    scanned = reclaim(scanned, c.now, "merge-label-exhausted")
    assert {:ok, conflicted} = PullMergeWorker.process_operation(scanned, c.now, opts)
    assert conflicted.failure_disposition == :conflict
    assert conflicted.failure_detail == "relationship_unavailable"
    assert conflicted.external_effect_marker["phase"] == "metadata_issue_pending"

    conflict =
      Repo.get_by!(ForgeMirrors.MirrorConflict,
        resource_kind: "pull_merge",
        resource_identity: to_string(c.intent.id),
        state: :open
      )

    assert conflict.conflict_kind == "relationship_unavailable"
    assert conflict.remote_snapshot["missing_label_github_ids"] == [800]
  end

  test "applied relationship patch after timeout is confirmed without a second patch", c do
    paired_issue_mapping(c)
    {label, _identity} = known_relationships(c)
    marked = mark(c)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    resolver = fn _, _ ->
      {:ok,
       %{
         labels: [%{github_object_id: 800, github_node_id: "L_800", name: "fresh-label"}],
         assignees: []
       }}
    end

    first =
      relationship_effect_options(c, provider, resolver, fn _, attrs ->
        assert attrs == %{"labels" => ["fresh-label"]}
        Agent.update(provider, &%{&1 | labels: [remote_label()]})
        send(self(), :relationship_patch_timeout)
        {:error, :timeout}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
    assert_received :relationship_patch_timeout
    pending = reclaim(pending, c.now, "merge-relationship-timeout")

    retry =
      relationship_effect_options(c, provider, resolver, fn _, _ ->
        flunk("applied relationship effect must not be patched twice")
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(pending, c.now, retry)
    assert completed.state == :completed
  end

  test "third relationship state after an ambiguous write becomes a conflict without retry", c do
    paired_issue_mapping(c)
    {label, _identity} = known_relationships(c)
    other = additional_known_label(c, 802)
    marked = mark(c)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    resolver = fn labels, _ ->
      {:ok,
       %{
         labels:
           Enum.map(labels, fn label ->
             %{
               github_object_id: label.github_object_id,
               github_node_id: label.github_node_id,
               name: "fresh-label"
             }
           end),
         assignees: []
       }}
    end

    first =
      relationship_effect_options(c, provider, resolver, fn _, _ -> {:error, :timeout} end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)

    Agent.update(provider, fn state ->
      %{state | labels: [remote_label(other.github_object_id, other.github_node_id)]}
    end)

    pending = reclaim(pending, c.now, "merge-relationship-third-state")

    retry =
      relationship_effect_options(c, provider, resolver, fn _, _ ->
        flunk("third relationship state must not retry PATCH")
      end)
      |> Keyword.put(:push_remote, fn _, _, _, _ -> flunk("metadata recovery retried Git") end)

    assert {:ok, conflict} = PullMergeWorker.process_operation(pending, c.now, retry)
    assert conflict.failure_disposition == :conflict
    assert conflict.failure_detail == "ambiguous_external_effect"
    assert conflict.external_effect_marker["phase"] == "metadata_issue_pending"
  end

  test "an unknown label in a third metadata state becomes a conflict without import or replay",
       c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    first = scalar_effect_options(c, provider, fn _, _ -> {:error, :timeout} end)
    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)

    Agent.update(provider, fn state ->
      %{state | labels: [remote_import_label(898, "L_898", "third-state")]}
    end)

    pending = reclaim(pending, c.now, "merge-unknown-label-third-state")

    retry =
      scalar_effect_options(c, provider, fn _, _ ->
        flunk("ambiguous metadata must not retry PATCH")
      end)
      |> Keyword.put(:push_remote, fn _, _, _, _ -> flunk("metadata recovery retried Git") end)

    assert {:ok, conflict} = PullMergeWorker.process_operation(pending, c.now, retry)
    assert conflict.failure_disposition == :conflict
    assert conflict.failure_detail == "ambiguous_external_effect"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             github_object_id: 898
           )
  end

  test "mixed local title and remote body converge without overwriting the remote body", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title"})
    {:ok, provider} = Agent.start_link(fn -> %{provider_state(c) | body: "Remote body"} end)

    opts =
      scalar_effect_options(c, provider, fn _, attrs ->
        assert attrs == %{"title" => "Local title"}
        Agent.update(provider, &Map.put(&1, :title, attrs["title"]))
        send(self(), :mixed_scalar_patch)
        {:ok, %{}}
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :mixed_scalar_patch
    refute_received :mixed_scalar_patch
    assert completed.state == :completed
    assert Repo.aggregate(PullMetadataIntent, :count) == 1
    issue = Repo.get!(ForgeIssues.Issue, c.issue.id)
    assert {issue.title, issue.body} == {"Local title", "Remote body"}
  end

  test "an applied metadata patch after timeout is observed without a second patch", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      scalar_effect_options(c, provider, fn _, _ ->
        Agent.update(provider, &Map.put(&1, :title, "Local title"))
        send(self(), :metadata_patch)
        {:error, :timeout}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert_received :metadata_patch
    reclaimed = reclaim(pending, c.now, "metadata-timeout-recovery")

    opts = Keyword.put(opts, :update_pull_issue, fn _, _, _, _, _, _ -> flunk("second patch") end)
    assert {:ok, completed} = PullMergeWorker.process_operation(reclaimed, c.now, opts)
    assert completed.state == :completed
  end

  test "exact metadata preimage with retained timestamps safely retries without a Git push", c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    first =
      scalar_effect_options(c, provider, fn _, _ ->
        send(self(), :first_metadata_patch)
        {:error, :timeout}
      end)

    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
    assert_received :first_metadata_patch
    reclaimed = reclaim(pending, c.now, "metadata-preimage-recovery")

    retry =
      scalar_effect_options(c, provider, fn _, _ ->
        Agent.update(provider, &Map.put(&1, :title, "Local title"))
        send(self(), :retried_metadata_patch)
        {:ok, %{}}
      end)
      |> Keyword.put(:push_remote, fn _, _, _, _ -> flunk("metadata recovery retried Git") end)

    assert {:ok, completed} = PullMergeWorker.process_operation(reclaimed, c.now, retry)
    assert_received :retried_metadata_patch
    assert completed.state == :completed
  end

  test "third metadata state records ambiguity without patch", c do
    {reclaimed, provider} = pending_scalar_effect(c, "metadata-third-state")
    Agent.update(provider, &Map.put(&1, :title, "Third title"))
    assert_ambiguous_effect(c, reclaimed, provider)
  end

  test "metadata preimage with changed timestamp records ABA ambiguity without patch", c do
    {reclaimed, provider} = pending_scalar_effect(c, "metadata-aba")
    Agent.update(provider, &Map.put(&1, :issue_updated_at, DateTime.add(c.now, 1)))
    assert_ambiguous_effect(c, reclaimed, provider)
  end

  for endpoint <- [:pull, :issue] do
    test "regressed #{endpoint} timestamp on the applied metadata target records ambiguity", c do
      paired_issue_mapping(c)
      marked = mark(c)
      edit_issue(c, %{title: "Local title"})
      marked_at = DateTime.add(c.now, 2)

      {:ok, provider} =
        Agent.start_link(fn ->
          provider_state(c)
          |> Map.put(:pull_updated_at, marked_at)
          |> Map.put(:issue_updated_at, marked_at)
        end)

      first = scalar_effect_options(c, provider, fn _, _ -> {:error, :timeout} end)
      assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
      reclaimed = reclaim(pending, c.now, "metadata-regressed-#{unquote(endpoint)}")

      Agent.update(provider, fn state ->
        state = Map.put(state, :title, "Local title")

        case unquote(endpoint) do
          :pull -> Map.put(state, :pull_updated_at, DateTime.add(c.now, 1))
          :issue -> Map.put(state, :issue_updated_at, DateTime.add(c.now, 1))
        end
      end)

      assert_ambiguous_effect(c, reclaimed, provider)
    end
  end

  for change <- [:revoked, :lost_lease] do
    test "#{change} during metadata recovery read-token fetch prevents all provider access", c do
      {reclaimed, provider} = pending_scalar_effect(c, "metadata-read-token-#{unquote(change)}")

      opts =
        scalar_effect_options(c, provider, fn _, _ ->
          flunk("metadata mutation after lost authority")
        end)
        |> Keyword.put(:observe_ref, fn _, _, _, _, _, _ ->
          flunk("provider read after lost authority")
        end)
        |> Keyword.put(:get_pull, fn _, _, _, _, _ -> flunk("pull read after lost authority") end)
        |> Keyword.put(:get_pull_issue, fn _, _, _, _, _ ->
          flunk("issue read after lost authority")
        end)
        |> Keyword.put(:token_fetch, fn _, scope ->
          if scope.permissions["contents"] == "read" do
            case unquote(change) do
              :revoked ->
                Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
                  github_installation_id: c.organization.github_installation_id
                )
                |> Changeset.change(state: :revoked)
                |> Repo.update!()

              :lost_lease ->
                Repo.get!(MirrorOperation, reclaimed.id)
                |> Changeset.change(lease_owner: "stolen-during-read-token")
                |> Repo.update!()
            end
          end

          %InstallationToken{
            token: "credential",
            expires_at: DateTime.add(c.now, 3600),
            permissions: scope.permissions
          }
        end)

      result = PullMergeWorker.process_operation(reclaimed, c.now, opts)

      case result do
        {:ok, pending} ->
          assert pending.state == :effect_pending

        {:error, reason} ->
          assert reason in [:credential_revoked, :lost_lease, :stale_merge_identity]
      end

      assert Repo.get!(MirrorOperation, reclaimed.id).external_effect_marker["phase"] ==
               "metadata_issue_pending"
    end
  end

  for change <- [:revoked, :lost_lease] do
    test "#{change} after metadata marking prevents provider mutation", c do
      paired_issue_mapping(c)
      marked = mark(c)
      edit_issue(c, %{title: "Local title"})
      {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

      opts =
        scalar_effect_options(c, provider, fn _, _ -> flunk("revoked capability mutated") end)
        |> Keyword.put(:token_fetch, fn _, scope ->
          if scope.permissions == %{"metadata" => "read", "pull_requests" => "write"} do
            case unquote(change) do
              :revoked ->
                Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
                  github_installation_id: c.organization.github_installation_id
                )
                |> Changeset.change(state: :revoked)
                |> Repo.update!()

              :lost_lease ->
                Repo.get!(MirrorOperation, marked.id)
                |> Changeset.change(lease_owner: "stolen-after-mark")
                |> Repo.update!()
            end
          end

          %InstallationToken{
            token: "credential",
            expires_at: DateTime.add(c.now, 3600),
            permissions: scope.permissions
          }
        end)

      result = PullMergeWorker.process_operation(marked, c.now, opts)

      if unquote(change) == :lost_lease do
        assert {:error, reason} = result
        assert reason in [:lost_lease, :stale_merge_identity]
      else
        assert {:ok, _pending} = result
      end

      persisted = Repo.get!(MirrorOperation, marked.id)
      assert persisted.state == :effect_pending
      assert persisted.external_effect_marker["phase"] == "metadata_issue_pending"
    end
  end

  for change <- [:revoked, :lost_lease] do
    test "#{change} after metadata PATCH prevents all confirmation provider reads", c do
      paired_issue_mapping(c)
      marked = mark(c)
      edit_issue(c, %{title: "Local title"})
      {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
      base = scalar_effect_options(c, provider, fn _, _ -> {:ok, %{}} end)
      observe_ref = Keyword.fetch!(base, :observe_ref)
      get_pull = Keyword.fetch!(base, :get_pull)
      get_issue = Keyword.fetch!(base, :get_pull_issue)

      opts =
        base
        |> Keyword.put(:observe_ref, fn a, b, d, e, f, g ->
          if Agent.get(provider, & &1.post_patch?),
            do: flunk("confirmation provider read after lost authority"),
            else: observe_ref.(a, b, d, e, f, g)
        end)
        |> Keyword.put(:get_pull, fn a, b, d, e, f ->
          if Agent.get(provider, & &1.post_patch?),
            do: flunk("confirmation provider read after lost authority"),
            else: get_pull.(a, b, d, e, f)
        end)
        |> Keyword.put(:get_pull_issue, fn a, b, d, e, f ->
          if Agent.get(provider, & &1.post_patch?),
            do: flunk("confirmation provider read after lost authority"),
            else: get_issue.(a, b, d, e, f)
        end)
        |> Keyword.put(:update_pull_issue, fn _, _, _, _, attrs, _ ->
          Agent.update(provider, fn state ->
            state
            |> Map.put(:title, attrs["title"])
            |> Map.put(:post_patch?, true)
          end)

          case unquote(change) do
            :revoked ->
              Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
                github_installation_id: c.organization.github_installation_id
              )
              |> Changeset.change(state: :revoked)
              |> Repo.update!()

            :lost_lease ->
              Repo.get!(MirrorOperation, marked.id)
              |> Changeset.change(lease_owner: "stolen-after-patch")
              |> Repo.update!()
          end

          {:ok, %{"untrusted" => true}}
        end)

      result = PullMergeWorker.process_operation(marked, c.now, opts)

      case result do
        {:ok, pending} ->
          assert pending.state == :effect_pending

        {:error, reason} ->
          assert reason in [:credential_revoked, :lost_lease, :stale_merge_identity]
      end

      persisted = Repo.get!(MirrorOperation, marked.id)
      assert persisted.external_effect_marker["phase"] == "metadata_issue_pending"
    end
  end

  test "newer local metadata after target observation creates sequence two and confirms actual version",
       c do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local A"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)

    opts =
      scalar_effect_options(c, provider, fn _, attrs ->
        Agent.update(provider, &Map.put(&1, :title, attrs["title"]))

        if attrs["title"] == "Local A" do
          edit_issue(c, %{title: "Local C"})
        end

        {:ok, %{}}
      end)

    assert {:ok, completed} = PullMergeWorker.process_operation(marked, c.now, opts)
    assert completed.state == :completed
    assert Agent.get(provider, & &1.title) == "Local C"

    assert Repo.all(
             from i in PullMetadataIntent,
               where: i.operation_id == ^marked.id,
               order_by: i.sequence,
               select: i.sequence
           ) == [1, 2]

    issue = Repo.get!(ForgeIssues.Issue, c.issue.id)

    mapping =
      Repo.get_by!(MirrorResourceState, resource_kind: :pull, local_resource_id: c.pull.id)

    assert mapping.confirmed_local_version == issue.sync_version
    assert mapping.confirmed_snapshot["title"] == "Local C"
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

  defp known_relationships(c) do
    label =
      Repo.insert!(
        ForgeIssues.Label.changeset(
          %ForgeIssues.Label{repository_id: c.repository.id},
          %{name: "known", normalized_name: "known", color: "112233"}
        )
      )

    Repo.insert!(
      MirrorResourceState.persistence_changeset(%MirrorResourceState{}, %{
        repository_mirror_id: c.binding.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: label.id,
        github_object_id: 800,
        github_node_id: "L_800",
        confirmed_snapshot: %{},
        state: :confirmed
      })
    )

    identity =
      Repo.insert!(
        ForgeAccounts.GitHubIdentity.observed_changeset(
          %ForgeAccounts.GitHubIdentity{},
          %{github_user_id: 801, github_node_id: "U_801", login: "known"}
        )
      )

    {label, identity}
  end

  defp additional_known_label(c, github_object_id) do
    label =
      Repo.insert!(
        ForgeIssues.Label.changeset(
          %ForgeIssues.Label{repository_id: c.repository.id},
          %{
            name: "known-#{github_object_id}",
            normalized_name: "known-#{github_object_id}",
            color: "445566"
          }
        )
      )

    Repo.insert!(
      MirrorResourceState.persistence_changeset(%MirrorResourceState{}, %{
        repository_mirror_id: c.binding.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: label.id,
        github_object_id: github_object_id,
        github_node_id: "L_#{github_object_id}",
        confirmed_snapshot: %{},
        state: :confirmed
      })
    )
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

  defp assigned_unmapped_label(c, name) do
    label =
      %ForgeIssues.Label{repository_id: c.repository.id}
      |> ForgeIssues.Label.changeset(%{
        name: name,
        normalized_name: name,
        color: "abcdef",
        description: "remote"
      })
      |> Repo.insert!()

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})
    label
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

  defp edit_issue(c, attrs) do
    c.issue
    |> Repo.reload!()
    |> ForgeIssues.Issue.update_changeset(attrs)
    |> Repo.update!()
  end

  defp provider_state(c) do
    %{
      title: "Merge",
      body: nil,
      labels: [],
      assignees: [],
      pull_updated_at: c.now,
      issue_updated_at: c.now,
      issue_reads: 0,
      post_patch?: false
    }
  end

  defp scalar_effect_options(c, provider, update) do
    base = merged_options(c)
    get_pull = Keyword.fetch!(base, :get_pull)
    get_issue = Keyword.fetch!(base, :get_pull_issue)

    base
    |> Keyword.put(:token_fetch, fn _, scope ->
      token =
        if scope.permissions == %{"metadata" => "read", "pull_requests" => "write"},
          do: "metadata-write",
          else: "observation"

      %InstallationToken{
        token: token,
        expires_at: DateTime.add(c.now, 3600),
        permissions: scope.permissions
      }
    end)
    |> Keyword.put(:get_pull, fn a, b, d, e, f ->
      {:ok, raw} = get_pull.(a, b, d, e, f)
      state = Agent.get(provider, & &1)

      {:ok,
       raw
       |> Map.put("title", state.title)
       |> Map.put("body", state.body)
       |> Map.put("updated_at", DateTime.to_iso8601(state.pull_updated_at))}
    end)
    |> Keyword.put(:get_pull_issue, fn a, b, d, e, f ->
      {:ok, raw} = get_issue.(a, b, d, e, f)

      state =
        Agent.get_and_update(provider, &{&1, Map.update!(&1, :issue_reads, fn n -> n + 1 end)})

      {:ok,
       raw
       |> Map.put("title", state.title)
       |> Map.put("body", state.body)
       |> Map.put("labels", state.labels)
       |> Map.put("assignees", state.assignees)
       |> Map.put("updated_at", DateTime.to_iso8601(state.issue_updated_at))}
    end)
    |> Keyword.put(:update_pull_issue, fn token, _, _, _, attrs, _ -> update.(token, attrs) end)
  end

  defp relationship_effect_options(c, provider, resolve, update) do
    scalar_effect_options(c, provider, update)
    |> Keyword.put(:get_relationship_repository, fn _, _, _ ->
      {:ok,
       %{
         github_object_id: c.binding.github_repository_id,
         github_node_id: c.binding.github_node_id
       }}
    end)
    |> Keyword.put(:resolve_relationships, fn _, repository, labels, assignees, _ ->
      assert repository == %{
               github_object_id: c.binding.github_repository_id,
               github_node_id: c.binding.github_node_id
             }

      resolve.(labels, assignees)
    end)
  end

  defp remote_label,
    do: remote_import_label(800, "L_800", "fresh-label")

  defp remote_label(id, node),
    do: remote_import_label(id, node, "fresh-label")

  defp remote_import_label(id, node, name),
    do: %{
      "id" => id,
      "node_id" => node,
      "name" => name,
      "color" => "ABCDEF",
      "description" => "remote"
    }

  defp remote_assignee,
    do: %{"id" => 801, "node_id" => "U_801", "login" => "fresh-user"}

  defp reclaim(pending, now, owner) do
    pending |> Changeset.change(next_attempt_at: now) |> Repo.update!()
    {:ok, claimed} = ForgeMirrors.claim_operations(owner, now, 60, 100, ["merge.pull"])
    Enum.find(claimed, &(&1.id == pending.id))
  end

  defp pending_scalar_effect(c, owner) do
    paired_issue_mapping(c)
    marked = mark(c)
    edit_issue(c, %{title: "Local title"})
    {:ok, provider} = Agent.start_link(fn -> provider_state(c) end)
    first = scalar_effect_options(c, provider, fn _, _ -> {:error, :timeout} end)
    assert {:ok, pending} = PullMergeWorker.process_operation(marked, c.now, first)
    {reclaim(pending, c.now, owner), provider}
  end

  defp assert_ambiguous_effect(c, reclaimed, provider) do
    opts = scalar_effect_options(c, provider, fn _, _ -> flunk("ambiguous effect retried") end)
    assert {:ok, conflict} = PullMergeWorker.process_operation(reclaimed, c.now, opts)
    assert conflict.failure_disposition == :conflict
    assert conflict.failure_detail == "ambiguous_external_effect"
    assert conflict.external_effect_marker["phase"] == "metadata_issue_pending"
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
