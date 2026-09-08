defmodule ForgeGitHub.PullSyncWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{InstallationToken, PullSyncWorker}
  alias ForgeMirrors.MirrorOperation

  @now ~U[2026-09-08 08:00:00Z]
  @head_sha String.duplicate("a", 40)
  @base_sha String.duplicate("b", 40)
  @base %{
    "title" => "Base",
    "body" => "Body",
    "state" => "open",
    "state_reason" => nil,
    "draft" => false,
    "head_ref" => "refs/heads/feature",
    "head_sha" => @head_sha,
    "base_ref" => "refs/heads/main",
    "base_sha" => @base_sha
  }

  test "routes a pull-head reconciliation page without provider or mapped pull observation" do
    operation = %MirrorOperation{kind: "reconcile.repository.pull_heads", state: :processing}

    assert {:ok, :page_recorded} =
             PullSyncWorker.process_operation(operation, @now,
               reconcile_pull_heads: fn ^operation, @now -> {:ok, :page_recorded} end,
               context: fn _ -> flunk("page must not load a pull context") end,
               token_fetch: fn _, _ -> flunk("page must not request a token") end
             )
  end

  test "routes both first creation and recovery without observing a mapped pull" do
    for state <- [:processing, :effect_pending] do
      operation = operation(state)

      sync = %{
        mode: :outbound_create,
        phase: if(state == :processing, do: :unmarked, else: :recovery)
      }

      options = [
        context: fn ^operation -> {:ok, sync} end,
        outbound_create: fn ^operation, @now, ^sync, _options -> {:ok, :creation_routed} end,
        local_observe: fn _ -> flunk("an unmapped pull entered mapped observation") end,
        token_fetch: fn _, _ -> flunk("parent must delegate creation token handling") end,
        retry: fn _, _, _, _, _ -> {:error, :unexpected_retry} end,
        fail: fn _, _, _, _ -> {:error, :unexpected_failure} end
      ]

      assert {:ok, :creation_routed} = PullSyncWorker.process_operation(operation, @now, options)
    end
  end

  test "only explicitly unmarked outbound errors use the original processing capability" do
    operation = operation(:processing)

    options = [
      context: fn _ -> {:ok, %{mode: :outbound_create}} end,
      outbound_create: fn _, _, _, _ -> {:unmarked_error, :busy} end,
      retry: fn ^operation, @now, _, "network", _ -> {:ok, :unmarked_retry} end
    ]

    assert {:ok, :unmarked_retry} = PullSyncWorker.process_operation(operation, @now, options)
    options = Keyword.put(options, :outbound_create, fn _, _, _, _ -> {:error, :lost_lease} end)
    assert {:error, :lost_lease} = PullSyncWorker.process_operation(operation, @now, options)
  end

  test "applies mapped inbound metadata and draft state in the atomic confirmation" do
    parent = self()
    operation = operation(:processing)
    remote = @base |> Map.put("title", "Remote") |> Map.put("draft", true)

    options =
      options(operation,
        get_pull: fn _, _, _, _, _ -> {:ok, github_pull(remote)} end,
        get_pull_issue: fn _, _, _, _, _ -> {:ok, github_issue(remote)} end,
        retry: fn _, _, _, failure_class, _ ->
          flunk("inbound update retried as #{inspect(failure_class)}")
        end,
        fail: fn _, _, failure_class, detail ->
          flunk("inbound update failed as #{inspect({failure_class, detail})}")
        end,
        confirm: fn ^operation, @now, expected, confirmation, domain_request ->
          assert expected.expected_fields == @base
          assert expected.expected_merge_state == persisted_merge_state()
          assert expected.provider_identity == provider_identity()
          assert expected.pull_eligibility_proof == json_proof()
          assert confirmation.confirmed_snapshot == remote
          assert confirmation.confirmed_local_version == 4
          assert confirmation.provider_identity == provider_identity()
          assert confirmation.confirmed_merge_state == persisted_merge_state()
          assert domain_request.action == :update
          assert domain_request.expected_local_version == 3
          assert domain_request.expected_fields == @base
          assert domain_request.expected_merge_state == %{merged_at: nil, merge_commit_sha: nil}
          assert domain_request.fields == remote
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = PullSyncWorker.process_operation(operation, @now, options)
    assert_received :confirmed
    refute_received :effect_marked
  end

  test "marks and proves a canonical issue metadata effect before confirming" do
    parent = self()
    operation = operation(:processing)
    local = Map.put(@base, "body", "Local")

    options =
      options(operation,
        local_observe: fn _ -> {:ok, local_pull(local, 4)} end,
        get_pull: fn _, _, _, _, _ ->
          snapshot = if Process.get(:issue_effect), do: local, else: @base
          {:ok, github_pull(snapshot)}
        end,
        get_pull_issue: fn _, _, _, _, _ ->
          snapshot = if Process.get(:issue_effect), do: local, else: @base
          {:ok, github_issue(snapshot, updated_at: effect_updated_at(snapshot))}
        end,
        mark_effect: mark_effect(parent, operation),
        update_pull_issue: fn _, _, _, 7, attrs, request_options ->
          assert request_options[:gate_key] == {:github_installation, 44}
          assert attrs == Map.take(local, ~w(title body state state_reason))
          Process.put(:issue_effect, true)
          send(parent, :provider_issue_updated)
          {:ok, github_issue(local, updated_at: "2026-09-08T08:00:01Z")}
        end,
        confirm: fn marked, @now, expected, confirmation, domain_request ->
          assert marked.state == :effect_pending
          assert expected.effect_marker["action"] == "update_remote_pull_issue"
          assert confirmation.confirmed_snapshot == local
          assert confirmation.confirmed_local_version == 4
          assert domain_request.action == :observe
          assert domain_request.expected_local_version == 4
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = PullSyncWorker.process_operation(operation, @now, options)

    assert collect_events(3) == [
             {:effect_marked, "update_remote_pull_issue"},
             :provider_issue_updated,
             :confirmed
           ]
  end

  test "draft conversion is a separately marked GraphQL effect" do
    parent = self()
    operation = operation(:processing)
    local = Map.put(@base, "draft", true)

    options =
      options(operation,
        local_observe: fn _ -> {:ok, local_pull(local, 4)} end,
        get_pull: fn _, _, _, _, _ ->
          snapshot = if Process.get(:draft_effect), do: local, else: @base
          {:ok, github_pull(snapshot)}
        end,
        get_pull_issue: fn _, _, _, _, _ -> {:ok, github_issue(@base)} end,
        mark_effect: mark_effect(parent, operation),
        set_draft: fn _, "PR_802", true, request_options ->
          assert request_options[:gate_key] == {:github_installation, 44}
          Process.put(:draft_effect, true)
          send(parent, :provider_draft_updated)
          {:ok, %{"id" => "PR_802", "isDraft" => true}}
        end,
        confirm: fn marked, _, _, confirmation, _ ->
          assert marked.external_effect_marker["action"] == "set_remote_pull_draft"
          assert confirmation.confirmed_snapshot == local
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = PullSyncWorker.process_operation(operation, @now, options)

    assert collect_events(3) == [
             {:effect_marked, "set_remote_pull_draft"},
             :provider_draft_updated,
             :confirmed
           ]
  end

  test "effect recovery confirms an observed postcondition without replaying after a newer local edit" do
    parent = self()
    sent = Map.put(@base, "title", "Sent")
    marker = effect_marker("update_remote_pull_issue", local_pull(sent, 4), @base, sent)
    operation = operation(:effect_pending, marker)
    newer = Map.put(sent, "body", "Newer local edit")

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_pull(newer, 5)} end,
        get_pull: fn _, _, _, _, _ -> {:ok, github_pull(sent)} end,
        get_pull_issue: fn _, _, _, _, _ ->
          {:ok, github_issue(sent, updated_at: "2026-09-08T08:00:01Z")}
        end,
        update_pull_issue: fn _, _, _, _, _, _ -> flunk("applied effect was replayed") end,
        confirm: fn ^operation, @now, expected, confirmation, domain_request ->
          assert expected.expected_local_version == 4
          assert expected.effect_marker == marker
          assert confirmation.confirmed_local_version == 4
          assert confirmation.confirmed_snapshot == sent
          assert domain_request.action == :observe
          assert domain_request.minimum_local_version == 4
          assert domain_request.expected_fields == sent
          send(parent, :recovered)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = PullSyncWorker.process_operation(operation, @now, options)
    assert_received :recovered
  end

  test "effect recovery reconstructs a disjoint merge preimage after a newer local edit" do
    parent = self()
    old_local = Map.put(@base, "title", "Sent title")
    remote_before = Map.put(@base, "body", "Remote body")
    postcondition = remote_before |> Map.put("title", "Sent title")

    marker =
      effect_marker(
        "update_remote_pull_issue",
        local_pull(old_local, 4),
        remote_before,
        postcondition
      )

    operation = operation(:effect_pending, marker)
    newer = Map.put(old_local, "draft", true)

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_pull(newer, 5)} end,
        get_pull: fn _, _, _, _, _ -> {:ok, github_pull(postcondition)} end,
        get_pull_issue: fn _, _, _, _, _ ->
          {:ok, github_issue(postcondition, updated_at: "2026-09-08T08:00:01Z")}
        end,
        confirm: fn ^operation, @now, expected, confirmation, domain_request ->
          assert expected.expected_fields == old_local
          assert confirmation.confirmed_snapshot == postcondition
          assert domain_request.minimum_local_version == 4
          assert domain_request.expected_fields == old_local
          send(parent, :reconstructed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = PullSyncWorker.process_operation(operation, @now, options)
    assert_received :reconstructed
  end

  test "transient observation failure keeps an unresolved effect marker" do
    parent = self()
    proposed = Map.put(@base, "title", "Sent")
    marker = effect_marker("update_remote_pull_issue", local_pull(proposed, 4), @base, proposed)
    operation = operation(:effect_pending, marker)

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_pull(proposed, 4)} end,
        get_pull: fn _, _, _, _, _ -> {:error, ForgeGitHub.Error.new(:transport)} end,
        checkpoint: fn ^operation, %{}, retry_at, "network", @now ->
          assert DateTime.after?(retry_at, @now)
          assert operation.external_effect_marker == marker
          send(parent, :marker_preserved)
          {:ok, %{operation | next_attempt_at: retry_at}}
        end,
        retry: fn _, _, _, _, _ -> flunk("unresolved marker used ordinary retry") end
      )

    assert {:ok, %MirrorOperation{external_effect_marker: ^marker}} =
             PullSyncWorker.process_operation(operation, @now, options)

    assert_received :marker_preserved
  end

  test "effect recovery checkpoints a required Git availability failure without clearing its marker" do
    parent = self()
    proposed = Map.put(@base, "title", "Sent")
    marker = effect_marker("update_remote_pull_issue", local_pull(proposed, 4), @base, proposed)
    operation = operation(:effect_pending, marker)

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_pull(proposed, 4)} end,
        git_availability: fn _ -> {:error, :required_ref_unavailable} end,
        checkpoint: fn ^operation,
                       %{"failure_reason" => "required_ref_unavailable"},
                       retry_at,
                       "network",
                       @now ->
          assert DateTime.after?(retry_at, @now)
          assert operation.external_effect_marker == marker
          send(parent, :git_failure_preserved)
          {:ok, %{operation | next_attempt_at: retry_at}}
        end,
        retry: fn _, _, _, _, _ -> flunk("unresolved marker used ordinary retry") end
      )

    assert {:ok, %MirrorOperation{external_effect_marker: ^marker}} =
             PullSyncWorker.process_operation(operation, @now, options)

    assert_received :git_failure_preserved
  end

  test "repository identity substitution conflicts before either side is mutated" do
    parent = self()
    operation = operation(:processing)

    options =
      options(operation,
        get_pull: fn _, _, _, _, _ ->
          pull = put_in(github_pull(@base), ["head", "repo", "id"], 999)
          {:ok, pull}
        end,
        remote_relationships: fn _, _, _ ->
          send(parent, :unsafe_attribution)
          {:ok, %{labels: [], assignees: [], author: nil}}
        end,
        conflict: fn ^operation, @now, "pull_identity_mismatch", @base, @base, @base ->
          send(parent, :conflicted)
          {:ok, :conflicted}
        end,
        mark_effect: fn _, _, _ -> flunk("identity mismatch marked an effect") end,
        confirm: fn _, _, _, _, _ -> flunk("identity mismatch confirmed") end
      )

    assert {:ok, :conflicted} = PullSyncWorker.process_operation(operation, @now, options)
    assert_received :conflicted
    refute_received :unsafe_attribution
  end

  test "paired identity, ref and scalar rejection precedes attribution", _ do
    parent = self()
    operation = operation(:processing)

    observations = [
      {github_pull(@base), Map.put(github_issue(@base), "id", 999)},
      {put_in(github_pull(@base), ["head", "sha"], String.duplicate("c", 40)),
       github_issue(@base)},
      {github_pull(@base), Map.put(github_issue(@base), "title", "Incoherent")}
    ]

    for {pull, issue} <- observations do
      opts =
        options(operation,
          get_pull: fn _, _, _, _, _ -> {:ok, pull} end,
          get_pull_issue: fn _, _, _, _, _ -> {:ok, issue} end,
          remote_relationships: fn _, _, _ ->
            send(parent, :unsafe_attribution)
            {:ok, %{labels: [], assignees: [], author: nil}}
          end,
          conflict: fn _, _, _, _, _, _ -> {:ok, :rejected} end,
          retry: fn _, _, _, _, _ -> {:ok, :rejected} end,
          fail: fn _, _, _, _ -> {:ok, :rejected} end,
          confirm: fn _, _, _, _, _ -> flunk("rejected observation confirmed") end
        )

      assert {:ok, :rejected} = PullSyncWorker.process_operation(operation, @now, opts)
      refute_received :unsafe_attribution
    end
  end

  defp options(operation, overrides) do
    defaults = [
      context: fn ^operation -> {:ok, context(operation.external_effect_marker)} end,
      token_fetch: fn 44, %{permissions: %{"metadata" => "read", "pull_requests" => "write"}} ->
        %InstallationToken{
          token: "ephemeral",
          expires_at: DateTime.add(@now, 3_600),
          permissions: %{"metadata" => "read", "pull_requests" => "write"}
        }
      end,
      local_observe: fn _ -> {:ok, local_pull(@base, 3)} end,
      get_pull: fn _, _, _, _, _ -> {:ok, github_pull(@base)} end,
      get_pull_issue: fn _, _, _, _, _ -> {:ok, github_issue(@base)} end,
      remote_relationships: fn _, _, _ ->
        {:ok, %{labels: [], assignees: [], author: nil}}
      end,
      eligibility: fn 3, 11, refs ->
        assert refs == %{
                 base_ref: @base["base_ref"],
                 base_sha: @base["base_sha"],
                 head_ref: @base["head_ref"],
                 head_sha: @base["head_sha"]
               }

        {:ok, eligibility_proof()}
      end,
      git_availability: fn _proof -> :ok end,
      update_pull_issue: fn _, _, _, _, _, _ -> flunk("unexpected issue effect") end,
      set_draft: fn _, _, _, _ -> flunk("unexpected draft effect") end,
      mark_effect: mark_effect(self(), operation),
      replace_effect: fn _, _, _, _ -> flunk("unexpected replacement effect") end,
      checkpoint: fn _, _, _, _, _ -> flunk("unexpected effect checkpoint") end,
      confirm: fn _, _, _, _, _ -> {:ok, :confirmed} end,
      conflict: fn _, _, _, _, _, _ -> {:ok, :conflicted} end,
      retry: fn operation, _, _, _, _ -> {:ok, %{operation | state: :pending}} end,
      fail: fn operation, _, _, _ -> {:ok, %{operation | state: :failed}} end,
      fingerprint: &ForgeMirrors.resource_fingerprint/1
    ]

    Keyword.merge(defaults, overrides)
  end

  defp operation(state, marker \\ nil) do
    %MirrorOperation{
      id: 1,
      organization_mirror_id: 2,
      repository_mirror_id: 3,
      kind: "sync.pull",
      dedupe_key: "pull-sync-test",
      state: state,
      cursor: %{},
      checkpoint: %{},
      external_effect_marker: marker,
      attempt_count: 1,
      next_attempt_at: @now,
      lease_owner: "pull-sync-test",
      lease_expires_at: DateTime.add(@now, 60),
      lock_version: 2
    }
  end

  defp context(marker) do
    %{
      trigger: :remote,
      resource_kind: :pull,
      repository_id: 10,
      repository_mirror_id: 3,
      github_installation_id: 44,
      github_repository_id: 900,
      remote_owner: "acme",
      remote_repository: "project",
      local_resource_id: 100,
      issue_id: 200,
      github_object_id: 802,
      github_node_id: "PR_802",
      github_number: 7,
      baseline: @base,
      confirmed_local_version: 3,
      confirmed_remote_updated_at: ~U[2026-09-08 07:00:00Z],
      confirmed_merge_state: persisted_merge_state(),
      provider_identity: provider_identity(),
      resource_state_lock_version: 1,
      effect_marker: marker,
      provenance: %{
        delivery_guid: "delivery-1",
        outbox_event_id: nil,
        causation_id: nil,
        correlation_id: nil
      }
    }
  end

  defp local_pull(snapshot, version) do
    %{
      presence: :present,
      resource_kind: :pull,
      repository_id: 10,
      local_resource_id: 100,
      local_resource_type: "ForgePulls.PullRequest",
      local_version: version,
      issue_id: 200,
      issue_number: 7,
      head_repository_id: 11,
      snapshot: snapshot,
      merge_state: local_merge_state(),
      coordinator: %{
        status: :unsupported,
        mergeable: nil,
        rebaseable: nil,
        mergeable_state: nil
      },
      relationship_snapshot: nil
    }
  end

  defp github_pull(snapshot) do
    %{
      "id" => 802,
      "node_id" => "PR_802",
      "number" => 7,
      "title" => snapshot["title"],
      "body" => snapshot["body"],
      "state" => snapshot["state"],
      "draft" => snapshot["draft"],
      "created_at" => "2026-09-01T00:00:00Z",
      "updated_at" => effect_updated_at(snapshot),
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

  defp github_issue(snapshot, options \\ []) do
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
      "created_at" => "2026-09-01T00:00:00Z",
      "updated_at" => Keyword.get(options, :updated_at, effect_updated_at(snapshot)),
      "closed_at" => nil,
      "pull_request" => %{
        "url" => "https://api.github.com/repos/acme/project/pulls/7"
      }
    }
  end

  defp effect_updated_at(snapshot) do
    if snapshot == @base, do: "2026-09-08T07:00:00Z", else: "2026-09-08T08:00:01Z"
  end

  defp provider_identity do
    %{
      "github_issue_object_id" => 801,
      "github_issue_node_id" => "I_801",
      "github_number" => 7,
      "head_repository" => %{"id" => 901, "node_id" => "R_901"},
      "base_repository" => %{"id" => 900, "node_id" => "R_900"}
    }
  end

  defp local_merge_state,
    do: %{merged: false, merged_at: nil, merge_commit_sha: nil}

  defp persisted_merge_state,
    do: %{"merged_at" => nil, "merge_commit_sha" => nil}

  defp eligibility_proof do
    %{
      organization_mirror_id: 2,
      organization_lock_version: 1,
      github_installation_id: 44,
      base: %{
        repository_mirror_id: 3,
        repository_id: 10,
        github_repository_id: 900,
        repository_generation: 1,
        mirror_lock_version: 1,
        ref_lock_version: 1,
        ref: @base["base_ref"],
        oid: @base["base_sha"]
      },
      head: %{
        repository_mirror_id: 4,
        repository_id: 11,
        github_repository_id: 901,
        repository_generation: 1,
        mirror_lock_version: 1,
        ref_lock_version: 1,
        ref: @base["head_ref"],
        oid: @base["head_sha"]
      }
    }
  end

  defp json_proof, do: eligibility_proof() |> JSON.encode!() |> JSON.decode!()

  defp mark_effect(parent, operation) do
    fn ^operation, @now, marker ->
      send(parent, {:effect_marked, marker["action"]})
      {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
    end
  end

  defp effect_marker(action, local, remote, proposed) do
    {:ok, local_fingerprint} = ForgeMirrors.resource_fingerprint(local.snapshot)
    {:ok, remote_fingerprint} = ForgeMirrors.resource_fingerprint(remote)
    {:ok, proposed_fingerprint} = ForgeMirrors.resource_fingerprint(proposed)

    %{
      "v" => 1,
      "action" => action,
      "resource_kind" => "pull",
      "local_resource_id" => local.local_resource_id,
      "expected_local_version" => local.local_version,
      "expected_local_fingerprint" => local_fingerprint,
      "expected_remote_updated_at" => "2026-09-08T07:00:00Z",
      "expected_remote_fingerprint" => remote_fingerprint,
      "proposed_fingerprint" => proposed_fingerprint,
      "local_changed_fields" =>
        @base
        |> Map.keys()
        |> Enum.filter(&(&1 in ~w(title body state state_reason draft)))
        |> Enum.filter(&(@base[&1] != local.snapshot[&1]))
        |> Enum.sort(),
      "expected_local_draft" => local.snapshot["draft"],
      "github_object_id" => 802,
      "github_node_id" => "PR_802",
      "github_number" => 7,
      "resource_state_lock_version" => 1,
      "provider_identity" => provider_identity(),
      "pull_eligibility_proof" => json_proof(),
      "expected_merge_state" => persisted_merge_state()
    }
  end

  defp collect_events(count), do: collect_events(count, [])
  defp collect_events(0, events), do: Enum.reverse(events)

  defp collect_events(count, events) do
    receive do
      event -> collect_events(count - 1, [event | events])
    after
      100 -> Enum.reverse(events)
    end
  end
end
