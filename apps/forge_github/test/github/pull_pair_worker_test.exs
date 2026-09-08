defmodule ForgeGitHub.PullPairWorkerTest do
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

  test "remote-only label addition atomically confirms both snapshots and local sets" do
    operation = operation(:processing)

    remote =
      Map.put(github_issue(@base), "labels", [%{"id" => 77, "node_id" => "L_77", "name" => "bug"}])

    opts =
      pair_options(operation, [],
        get_pull_issue: fn _, _, _, _, _ -> {:ok, remote} end,
        remote_relationships: fn _, _, _ ->
          {:ok,
           %{
             labels: [%{github_object_id: 77, local_label_id: 9, name: "bug"}],
             assignees: [],
             author: nil
           }}
        end,
        confirm_pair: fn _, _, expected, confirmation, request ->
          assert expected.pair.issue.snapshot == issue_snapshot([])
          assert confirmation.issue_snapshot == issue_snapshot([77])
          assert confirmation.issue_remote_updated_at == ~U[2026-09-08 07:00:00Z]
          assert confirmation.confirmed_local_version == 4
          assert request.local_label_ids == [9]
          assert request.assignee_refs == []

          assert request.expected_relationships == %{
                   label_ids: [],
                   managed_assignee_identity_ids: []
                 }

          assert request.action == :update
          {:ok, :paired}
        end
      )

    assert {:ok, :paired} = PullSyncWorker.process_operation(operation, @now, opts)
  end

  test "unchanged pair uses paired observation rather than scalar completion" do
    operation = operation(:processing)

    opts =
      pair_options(operation, [],
        confirm_pair: fn _, _, _, confirmation, request ->
          assert request.action == :observe
          assert confirmation.issue_snapshot == issue_snapshot([])
          assert confirmation.confirmed_local_version == 3
          {:ok, :paired}
        end
      )

    assert {:ok, :paired} = PullSyncWorker.process_operation(operation, @now, opts)
  end

  test "outbound sets require durable full-set admission before any provider effect" do
    operation = operation(:processing)
    parent = self()

    opts =
      pair_options(operation, [77],
        mark_pair_effect: fn ^operation, @now, pair, marker, payload ->
          assert pair.issue.snapshot == issue_snapshot([])
          assert marker["action"] == "update_remote_pull_issue"
          assert payload["expected_remote_issue"] == issue_snapshot([])
          assert payload["expected_local_issue"] == issue_snapshot([77])
          assert payload["target_issue"] == issue_snapshot([77])
          send(parent, :full_set_admission)
          {:error, :busy}
        end,
        retry: fn _, _, _, _, _ -> {:ok, :deferred} end,
        fail: fn _, _, _, _ -> flunk("busy admission must not terminally fail") end
      )

    assert {:ok, :deferred} = PullSyncWorker.process_operation(operation, @now, opts)
    assert_received :full_set_admission
    refute_received {:effect_marked, _}
  end

  test "paired context never falls back when local relationship projection is absent" do
    operation = operation(:processing)

    opts =
      pair_options(operation, [],
        local_observe: fn _ -> {:ok, local_pull(@base, 3)} end,
        retry: fn _, _, _, _, _ -> {:ok, :rejected} end,
        fail: fn _, _, _, _ -> {:ok, :rejected} end
      )

    assert {:ok, :rejected} = PullSyncWorker.process_operation(operation, @now, opts)
  end

  defp pair_options(operation, labels, overrides) do
    local =
      Map.merge(local_pull(@base, 3), %{
        issue_snapshot: issue_snapshot(labels),
        relationship_preimage: %{
          label_ids: if(labels == [], do: [], else: [9]),
          managed_assignee_identity_ids: []
        },
        label_catalog: %{77 => %{name: "bug", local_label_id: 9}},
        assignee_catalog: %{}
      })

    sync =
      Map.put(context(nil), :pair, %{
        pull: %{snapshot: @base},
        issue: %{snapshot: issue_snapshot([])}
      })

    options(
      operation,
      Keyword.merge(
        [
          context: fn _ -> {:ok, sync} end,
          local_observe: fn _ -> {:ok, local} end,
          confirm: fn _, _, _, _, _ -> flunk("canonical pair used scalar confirmation") end,
          confirm_pair: fn _, _, _, _, _ -> flunk("unexpected paired confirmation") end
        ],
        overrides
      )
    )
  end

  defp issue_snapshot(labels),
    do:
      @base
      |> Map.take(~w(title body state state_reason))
      |> Map.merge(%{"label_github_ids" => labels, "assignee_github_ids" => []})

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

  defp mark_effect(parent, operation) do
    fn ^operation, @now, marker ->
      send(parent, {:effect_marked, marker["action"]})
      {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
    end
  end
end
