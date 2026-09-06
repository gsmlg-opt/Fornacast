defmodule ForgeGitHub.IssueSyncWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, InstallationToken, IssueSyncWorker}
  alias ForgeMirrors.MirrorOperation

  @now ~U[2026-09-07 08:00:00Z]
  @base %{
    "title" => "base title",
    "body" => "base body",
    "state" => "open",
    "state_reason" => nil,
    "label_github_ids" => [11],
    "assignee_github_ids" => [21]
  }

  test "applies an inbound issue update and confirms provenance in one transaction callback" do
    parent = self()
    operation = operation("sync.issue", :processing)
    remote = Map.put(@base, "title", "remote title")

    options =
      options(operation,
        local_observe: fn _context -> {:ok, local_issue(@base, 3)} end,
        get_issue: fn "ephemeral", "acme", "project", 7, request_options ->
          assert request_options[:gate_key] == {:github_installation, 44}
          {:ok, github_issue(remote)}
        end,
        confirm: fn ^operation, @now, expected, confirmation, domain_request ->
          assert expected.expected_local_version == 3
          assert expected.observed_remote_updated_at == ~U[2026-09-07 07:00:00Z]
          assert confirmation.confirmed_snapshot == remote
          assert confirmation.confirmed_local_version == 4
          assert domain_request.action == :update
          assert domain_request.expected_local_version == 3
          assert domain_request.fields["title"] == "remote title"
          assert domain_request.provenance.origin == :github
          assert domain_request.provenance.causation_id == "delivery-1"
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :confirmed
    refute_received :effect_marked
  end

  test "marks an outbound issue update before the provider effect and confirms the old common base" do
    parent = self()
    operation = operation("sync.issue", :processing)
    local = Map.put(@base, "body", "local body")

    options =
      options(operation,
        local_observe: fn _context -> {:ok, local_issue(local, 4)} end,
        mark_effect: mark_effect(parent, operation),
        update_issue: fn "ephemeral", "acme", "project", 7, attrs, request_options ->
          assert request_options[:gate_key] == {:github_installation, 44}
          assert attrs["body"] == "local body"
          send(parent, :remote_updated)
          {:ok, github_issue(local, updated_at: "2026-09-07T08:00:01Z")}
        end,
        confirm: fn marked, @now, expected, confirmation, domain_request ->
          assert marked.state == :effect_pending
          assert expected.effect_marker["action"] == "update_remote_issue"
          assert confirmation.confirmed_snapshot == local
          assert confirmation.confirmed_local_version == 4
          assert domain_request.action == :observe
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)

    assert collect_events(3) == [
             {:effect_marked, "update_remote_issue"},
             :remote_updated,
             :confirmed
           ]
  end

  test "merges independent label and assignee additions and applies both sides" do
    parent = self()
    operation = operation("sync.issue", :processing)

    local =
      @base
      |> Map.put("label_github_ids", [11, 12])
      |> Map.put("assignee_github_ids", [21])

    remote =
      @base
      |> Map.put("label_github_ids", [11])
      |> Map.put("assignee_github_ids", [21, 22])

    merged =
      @base
      |> Map.put("label_github_ids", [11, 12])
      |> Map.put("assignee_github_ids", [21, 22])

    options =
      options(operation,
        local_observe: fn _context ->
          {:ok,
           local_issue(local, 4,
             label_catalog: %{
               11 => %{name: "base", local_label_id: 101},
               12 => %{name: "local", local_label_id: 102}
             },
             assignee_catalog: %{21 => %{login: "base"}}
           )}
        end,
        get_issue: fn _, _, _, _, _ ->
          {:ok,
           github_issue(remote,
             labels: [github_label(11, "base")],
             assignees: [github_user(21, "base"), github_user(22, "remote")]
           )}
        end,
        remote_relationships: fn _context, raw, @now ->
          labels = raw["labels"]
          assignees = raw["assignees"]

          {:ok,
           %{
             labels:
               Enum.map(labels, fn label ->
                 %{
                   local_label_id: label["id"] + 90,
                   github_object_id: label["id"],
                   name: label["name"]
                 }
               end),
             assignees:
               Enum.map(assignees, fn assignee ->
                 %{
                   ref:
                     if(assignee["id"] == 21,
                       do: %{kind: :local_user, id: 201},
                       else: %{kind: :github_identity, id: 202}
                     ),
                   github_user_id: assignee["id"],
                   login: assignee["login"]
                 }
               end),
             author: %{github_identity_id: 301}
           }}
        end,
        mark_effect: mark_effect(parent, operation),
        update_issue: fn _, _, _, _, attrs, _ ->
          assert attrs["labels"] == ["base", "local"]
          assert attrs["assignees"] == ["base", "remote"]
          send(parent, :remote_updated)
          {:ok, github_issue(merged, updated_at: "2026-09-07T08:00:01Z")}
        end,
        confirm: fn _, _, _, confirmation, domain_request ->
          assert confirmation.confirmed_snapshot == merged
          assert domain_request.action == :update
          assert domain_request.local_label_ids == [101, 102]

          assert domain_request.assignee_refs == [
                   %{kind: :local_user, id: 201},
                   %{kind: :github_identity, id: 202}
                 ]

          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)

    assert collect_events(3) == [
             {:effect_marked, "update_remote_issue"},
             :remote_updated,
             :confirmed
           ]
  end

  test "records incompatible concurrent scalar edits without writing either side" do
    parent = self()
    operation = operation("sync.issue", :processing)
    local = Map.put(@base, "title", "local")
    remote = Map.put(@base, "title", "remote")

    options =
      options(operation,
        local_observe: fn _ -> {:ok, local_issue(local, 4)} end,
        get_issue: fn _, _, _, _, _ -> {:ok, github_issue(remote)} end,
        conflict: fn ^operation, @now, "concurrent_edit", @base, ^local, ^remote ->
          send(parent, :conflicted)
          {:ok, :conflicted}
        end,
        mark_effect: fn _, _, _ -> flunk("conflict marked an external effect") end,
        update_issue: fn _, _, _, _, _, _ -> flunk("conflict wrote GitHub") end,
        confirm: fn _, _, _, _, _ -> flunk("conflict confirmed") end
      )

    assert {:ok, :conflicted} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :conflicted
  end

  test "effect-pending update confirms an already-applied postcondition without replay" do
    parent = self()
    proposed = Map.put(@base, "body", "new")
    marker = effect_marker("update_remote_issue", @base, proposed)
    operation = operation("sync.issue", :effect_pending, marker)

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 4)} end,
        get_issue: fn _, _, _, _, _ ->
          {:ok, github_issue(proposed, updated_at: "2026-09-07T08:00:01Z")}
        end,
        update_issue: fn _, _, _, _, _, _ -> flunk("applied effect was replayed") end,
        confirm: fn ^operation, @now, expected, confirmation, domain_request ->
          assert expected.effect_marker == marker
          assert confirmation.confirmed_snapshot == proposed
          assert domain_request.action == :observe
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :confirmed
  end

  test "effect-pending update retries only when the exact recorded precondition remains" do
    parent = self()
    proposed = Map.put(@base, "body", "new")
    marker = effect_marker("update_remote_issue", @base, proposed)
    operation = operation("sync.issue", :effect_pending, marker)

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 4)} end,
        mark_effect: fn _, _, _ -> flunk("existing marker was replaced") end,
        update_issue: fn _, _, _, _, attrs, _ ->
          assert attrs["body"] == "new"
          send(parent, :remote_updated)
          {:ok, github_issue(proposed, updated_at: "2026-09-07T08:00:01Z")}
        end,
        confirm: fn _, _, _, _, _ -> {:ok, :confirmed} end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :remote_updated
  end

  test "effect-pending update fails closed when neither recorded pre nor postcondition is observed" do
    parent = self()
    proposed = Map.put(@base, "body", "new")
    divergent = Map.put(@base, "body", "other")
    marker = effect_marker("update_remote_issue", @base, proposed)
    operation = operation("sync.issue", :effect_pending, marker)

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(marker)} end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 4)} end,
        get_issue: fn _, _, _, _, _ ->
          {:ok, github_issue(divergent, updated_at: "2026-09-07T08:00:02Z")}
        end,
        conflict: fn ^operation,
                     @now,
                     "ambiguous_external_effect",
                     @base,
                     ^proposed,
                     ^divergent ->
          send(parent, :conflicted)
          {:ok, :conflicted}
        end,
        update_issue: fn _, _, _, _, _, _ -> flunk("ambiguous effect was replayed") end
      )

    assert {:ok, :conflicted} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :conflicted
  end

  test "an ambiguous issue create scans one full-list page per claim and retains no body" do
    parent = self()
    proposed = Map.put(@base, "title", "created")
    correlation_id = "e7e9e395-b50f-4d28-bca9-9fa20e05e6af"
    marker = create_marker("create_remote_issue", proposed, correlation_id)
    operation = operation("sync.issue", :effect_pending, marker)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(marker, github_object_id: nil, github_number: nil)}
        end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 1)} end,
        list_issues: fn "ephemeral", "acme", "project", ~U[1970-01-01 00:00:00Z], nil, opts ->
          assert opts[:gate_key] == {:github_installation, 44}
          {:ok, %{issues: [github_issue(@base)], next_cursor: 2}}
        end,
        checkpoint: fn ^operation, checkpoint, @now, nil, @now ->
          assert checkpoint == %{"recovery" => %{"match" => nil, "page" => 2}}
          refute inspect(checkpoint) =~ "base body"
          send(parent, :checkpointed)
          {:ok, %{operation | lease_owner: nil, lease_expires_at: nil}}
        end,
        create_issue: fn _, _, _, _, _ -> flunk("create retried before full scan") end
      )

    assert {:ok, %MirrorOperation{}} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :checkpointed
  end

  test "an ambiguous create resumes from its persisted provider page" do
    parent = self()
    proposed = Map.put(@base, "title", "created")
    correlation_id = "e7e9e395-b50f-4d28-bca9-9fa20e05e6af"
    marker = create_marker("create_remote_issue", proposed, correlation_id)
    checkpoint = %{"recovery" => %{"page" => 2, "match" => nil}}
    operation = operation("sync.issue", :effect_pending, marker, checkpoint)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(marker, github_object_id: nil, github_number: nil)}
        end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 1)} end,
        list_issues: fn _, _, _, ~U[1970-01-01 00:00:00Z], page, _ ->
          assert page == 2
          send(parent, :page_two_fetched)
          {:ok, %{issues: [], next_cursor: 3}}
        end,
        checkpoint: fn ^operation, next_checkpoint, @now, nil, @now ->
          assert next_checkpoint == %{"recovery" => %{"match" => nil, "page" => 3}}
          {:ok, operation}
        end,
        create_issue: fn _, _, _, _, _ -> flunk("create retried before terminal page") end
      )

    assert {:ok, %MirrorOperation{}} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :page_two_fetched
  end

  test "a completed create scan with one marker refetches and adopts exactly one immutable identity" do
    parent = self()
    proposed = Map.put(@base, "title", "created")
    correlation_id = "e7e9e395-b50f-4d28-bca9-9fa20e05e6af"
    marker = create_marker("create_remote_issue", proposed, correlation_id)

    checkpoint = %{
      "recovery" => %{
        "complete" => true,
        "match" => %{
          "github_object_id" => 501,
          "github_number" => 9,
          "remote_updated_at" => "2026-09-07T08:00:01Z"
        }
      }
    }

    operation = operation("sync.issue", :effect_pending, marker, checkpoint)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(marker, github_object_id: nil, github_number: nil)}
        end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 1)} end,
        get_issue: fn _, _, _, 9, _ ->
          {:ok,
           github_issue(proposed,
             id: 501,
             number: 9,
             body: proposed["body"] <> "\n\n<!-- fornacast:sync:v1:#{correlation_id} -->",
             updated_at: "2026-09-07T08:00:01Z"
           )}
        end,
        confirm: fn ^operation, @now, _expected, confirmation, domain_request ->
          assert confirmation.github_object_id == 501
          assert confirmation.github_number == 9
          assert confirmation.confirmed_snapshot == proposed
          assert domain_request.action == :observe
          send(parent, :adopted)
          {:ok, :confirmed}
        end,
        create_issue: fn _, _, _, _, _ -> flunk("recovered create duplicated") end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :adopted
  end

  test "zero matches after the complete create scan performs one create with the persisted marker" do
    parent = self()
    proposed = Map.put(@base, "title", "created")
    correlation_id = "e7e9e395-b50f-4d28-bca9-9fa20e05e6af"
    marker = create_marker("create_remote_issue", proposed, correlation_id)
    checkpoint = %{"recovery" => %{"complete" => true, "match" => nil}}
    operation = operation("sync.issue", :effect_pending, marker, checkpoint)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(marker, github_object_id: nil, github_number: nil)}
        end,
        local_observe: fn _ -> {:ok, local_issue(proposed, 1)} end,
        create_issue: fn _, _, _, attrs, _ ->
          assert String.ends_with?(
                   attrs["body"],
                   "<!-- fornacast:sync:v1:#{correlation_id} -->"
                 )

          send(parent, :created)

          {:ok,
           github_issue(proposed,
             id: 501,
             number: 9,
             body: attrs["body"],
             updated_at: "2026-09-07T08:00:01Z"
           )}
        end,
        confirm: fn _, _, _, confirmation, _ ->
          assert confirmation.confirmed_snapshot == proposed
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :created
  end

  test "provider timeout after a marked write preserves effect_pending recovery state" do
    parent = self()
    operation = operation("sync.issue", :processing)
    local = Map.put(@base, "body", "local")

    options =
      options(operation,
        local_observe: fn _ -> {:ok, local_issue(local, 4)} end,
        mark_effect: mark_effect(parent, operation),
        update_issue: fn _, _, _, _, _, _ -> {:error, Error.new(:timeout)} end,
        checkpoint: fn marked, checkpoint, retry_at, "network", @now ->
          assert marked.state == :effect_pending
          assert checkpoint == %{}
          assert DateTime.after?(retry_at, @now)
          send(parent, :recovery_retained)
          {:ok, %{marked | lease_owner: nil, lease_expires_at: nil}}
        end,
        retry: fn _, _, _, _, _ -> flunk("ambiguous write cleared its marker") end
      )

    assert {:ok, %MirrorOperation{state: :effect_pending}} =
             IssueSyncWorker.process_operation(operation, @now, options)

    assert collect_events(2) == [
             {:effect_marked, "update_remote_issue"},
             :recovery_retained
           ]
  end

  test "applies an inbound comment edit using the immutable comment identity" do
    parent = self()
    operation = operation("sync.issue_comment", :processing)
    baseline = %{"body" => "base comment"}
    target = %{"body" => "remote comment"}

    options =
      options(operation,
        context: fn ^operation -> {:ok, comment_context(baseline)} end,
        local_observe: fn _ -> {:ok, local_comment(baseline, 3)} end,
        get_comment: fn _, _, _, 601, _ -> {:ok, github_comment(target)} end,
        confirm: fn ^operation, @now, expected, confirmation, domain_request ->
          assert expected.github_object_id == 601
          assert confirmation.github_object_id == 601
          assert confirmation.github_number == 7
          assert confirmation.confirmed_snapshot == target
          assert confirmation.confirmed_local_version == 4
          assert domain_request.action == :update
          assert domain_request.fields == target
          send(parent, :comment_confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :comment_confirmed
  end

  test "creates a remote comment only after persisting its correlation marker" do
    parent = self()
    operation = operation("sync.issue_comment", :processing)
    snapshot = %{"body" => "local comment"}

    options =
      options(operation,
        context: fn ^operation ->
          {:ok,
           comment_context(:missing,
             github_object_id: nil,
             github_node_id: nil,
             confirmed_remote_updated_at: nil
           )}
        end,
        local_observe: fn _ -> {:ok, local_comment(snapshot, 1)} end,
        get_comment: fn _, _, _, _, _ -> flunk("unmapped comment was fetched") end,
        mark_effect: mark_effect(parent, operation),
        create_comment: fn _, _, _, 7, attrs, _ ->
          assert String.starts_with?(attrs["body"], "local comment")
          assert attrs["body"] =~ "<!-- fornacast:sync:v1:"
          send(parent, :comment_created)
          {:ok, github_comment(snapshot, body: attrs["body"])}
        end,
        confirm: fn marked, @now, _expected, confirmation, domain_request ->
          assert marked.external_effect_marker["action"] == "create_remote_comment"
          assert confirmation.github_object_id == 601
          assert confirmation.confirmed_snapshot == snapshot
          assert domain_request.action == :observe
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)

    assert collect_events(2) == [
             {:effect_marked, "create_remote_comment"},
             :comment_created
           ]
  end

  test "a mapped comment 404 applies a local tombstone without replaying a provider effect" do
    parent = self()
    operation = operation("sync.issue_comment", :processing)
    baseline = %{"body" => "base comment"}

    options =
      options(operation,
        context: fn ^operation -> {:ok, comment_context(baseline)} end,
        local_observe: fn _ -> {:ok, local_comment(baseline, 3)} end,
        get_comment: fn _, _, _, 601, _ -> {:error, Error.new(:not_found)} end,
        confirm: fn ^operation, @now, _expected, confirmation, domain_request ->
          assert confirmation.state == :deleted
          assert confirmation.confirmed_local_version == 4
          assert domain_request.action == :delete
          assert domain_request.expected_local_version == 3
          send(parent, :comment_deleted_locally)
          {:ok, :confirmed}
        end,
        delete_comment: fn _, _, _, _, _ -> flunk("remote deletion was replayed") end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)
    assert_received :comment_deleted_locally
  end

  test "a local comment tombstone deletes GitHub and confirms from durable tombstone metadata" do
    parent = self()
    operation = operation("sync.issue_comment", :processing)
    baseline = %{"body" => "base comment"}

    options =
      options(operation,
        context: fn ^operation ->
          {:ok,
           comment_context(baseline,
             trigger: :local,
             local_deleted: true,
             local_version: 4
           )}
        end,
        local_observe: fn _ -> flunk("hard-deleted comment was queried") end,
        get_comment: fn _, _, _, 601, _ -> {:ok, github_comment(baseline)} end,
        mark_effect: mark_effect(parent, operation),
        delete_comment: fn _, _, _, 601, _ ->
          send(parent, :comment_deleted_remotely)
          :ok
        end,
        confirm: fn marked, @now, _expected, confirmation, domain_request ->
          assert marked.external_effect_marker["action"] == "delete_remote_comment"
          assert confirmation.state == :deleted
          assert confirmation.confirmed_local_version == 4
          assert domain_request.action == :none

          assert domain_request.projection == %{
                   repository_id: 10,
                   resource_kind: :issue_comment,
                   local_resource_id: 200,
                   local_resource_type: "ForgeIssues.Comment",
                   local_version: 4,
                   deleted: true
                 }

          send(parent, :comment_tombstone_confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = IssueSyncWorker.process_operation(operation, @now, options)

    assert collect_events(3) == [
             {:effect_marked, "delete_remote_comment"},
             :comment_deleted_remotely,
             :comment_tombstone_confirmed
           ]
  end

  test "a reconciliation claim fetches and records exactly one provider page" do
    parent = self()
    operation = reconciliation_operation("reconcile.repository.issues")

    options =
      options(operation,
        context: fn ^operation ->
          {:ok,
           context(nil,
             trigger: :reconcile,
             resource_kind: :issue,
             page: 2,
             since: ~U[1970-01-01 00:00:00Z]
           )}
        end,
        list_issues: fn _, _, _, ~U[1970-01-01 00:00:00Z], 2, _ ->
          send(parent, :page_fetched)
          {:ok, %{issues: [github_issue(@base)], next_cursor: 3}}
        end,
        record_page: fn ^operation, :issue, observations, 3, @now ->
          assert [%{github_object_id: 501, github_number: 7}] = observations
          send(parent, :page_recorded)
          {:ok, %{operation | state: :pending}}
        end,
        local_observe: fn _ -> flunk("sweep tried to mutate a resource") end
      )

    assert {:ok, %MirrorOperation{state: :pending}} =
             IssueSyncWorker.process_operation(operation, @now, options)

    assert collect_events(2) == [:page_fetched, :page_recorded]
  end

  defp options(operation, overrides) do
    defaults = [
      context: fn ^operation -> {:ok, context(operation.external_effect_marker)} end,
      token_fetch: fn 44, %{permissions: %{"issues" => "write", "metadata" => "read"}} ->
        %InstallationToken{
          token: "ephemeral",
          expires_at: DateTime.add(@now, 3_600),
          permissions: %{"issues" => "write", "metadata" => "read"}
        }
      end,
      local_observe: fn _ -> {:ok, local_issue(@base, 3)} end,
      get_issue: fn _, _, _, _, _ -> {:ok, github_issue(@base)} end,
      get_comment: fn _, _, _, _, _ -> {:error, Error.new(:not_found)} end,
      list_issues: fn _, _, _, _, _, _ -> {:ok, %{issues: [], next_cursor: nil}} end,
      list_comments: fn _, _, _, _, _, _ -> {:ok, %{comments: [], next_cursor: nil}} end,
      remote_relationships: fn _context, raw, _now ->
        labels = raw["labels"] || []
        assignees = raw["assignees"] || []

        {:ok,
         %{
           labels:
             Enum.map(labels, fn label ->
               %{
                 local_label_id: label["id"] + 90,
                 github_object_id: label["id"],
                 name: label["name"]
               }
             end),
           assignees:
             Enum.map(assignees, fn user ->
               %{
                 ref: %{kind: :github_identity, id: user["id"] + 180},
                 github_user_id: user["id"],
                 login: user["login"]
               }
             end),
           author: %{github_identity_id: 301}
         }}
      end,
      mark_effect: mark_effect(self(), operation),
      replace_effect: fn _, _, _, _ -> flunk("unexpected effect replacement") end,
      checkpoint: fn _, _, _, _, _ -> flunk("unexpected checkpoint") end,
      create_issue: fn _, _, _, _, _ -> flunk("unexpected issue create") end,
      update_issue: fn _, _, _, _, _, _ -> flunk("unexpected issue update") end,
      create_comment: fn _, _, _, _, _, _ -> flunk("unexpected comment create") end,
      update_comment: fn _, _, _, _, _, _ -> flunk("unexpected comment update") end,
      delete_comment: fn _, _, _, _, _ -> flunk("unexpected comment delete") end,
      confirm: fn _, _, _, _, _ -> {:ok, :confirmed} end,
      conflict: fn _, _, _, _, _, _ -> {:ok, :conflicted} end,
      record_page: fn _, _, _, _, _ -> flunk("unexpected reconciliation page") end,
      retry: fn operation, _, _, _, _ -> {:ok, %{operation | state: :pending}} end,
      fail: fn operation, _, _, _ -> {:ok, %{operation | state: :failed}} end,
      correlation_id: fn -> "e7e9e395-b50f-4d28-bca9-9fa20e05e6af" end,
      fingerprint: fn snapshot -> {:ok, fingerprint(snapshot)} end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp operation(kind, state, marker \\ nil, checkpoint \\ %{}) do
    %MirrorOperation{
      id: 1,
      organization_mirror_id: 2,
      repository_mirror_id: 3,
      kind: kind,
      dedupe_key: "issue-sync-test",
      state: state,
      cursor: %{},
      checkpoint: checkpoint,
      external_effect_marker: marker,
      attempt_count: 1,
      next_attempt_at: @now,
      lease_owner: "issue-sync-test",
      lease_expires_at: DateTime.add(@now, 60),
      lock_version: 2
    }
  end

  defp reconciliation_operation(kind), do: operation(kind, :processing)

  defp context(marker, overrides \\ []) do
    Map.merge(
      %{
        trigger: :remote,
        resource_kind: :issue,
        repository_id: 10,
        repository_mirror_id: 3,
        github_installation_id: 44,
        remote_owner: "acme",
        remote_repository: "project",
        local_resource_id: 100,
        github_object_id: 501,
        github_node_id: "I_501",
        github_number: 7,
        github_issue_id: nil,
        baseline: @base,
        confirmed_local_version: 3,
        confirmed_remote_updated_at: ~U[2026-09-07 07:00:00Z],
        resource_state_lock_version: 1,
        effect_marker: marker,
        provenance: %{
          delivery_guid: "delivery-1",
          outbox_event_id: nil,
          causation_id: nil,
          correlation_id: nil
        }
      },
      Map.new(overrides)
    )
  end

  defp local_issue(snapshot, version, options \\ []) do
    label_catalog =
      Keyword.get(options, :label_catalog, %{11 => %{name: "base", local_label_id: 101}})

    assignee_catalog =
      Keyword.get(options, :assignee_catalog, %{
        21 => %{login: "base", ref: %{kind: :local_user, id: 201}}
      })

    %{
      presence: :present,
      resource_kind: :issue,
      local_resource_id: 100,
      local_resource_type: "ForgeIssues.Issue",
      local_version: version,
      snapshot: snapshot,
      label_catalog: label_catalog,
      assignee_catalog: assignee_catalog
    }
  end

  defp local_comment(snapshot, version) do
    %{
      presence: :present,
      resource_kind: :issue_comment,
      local_resource_id: 200,
      local_resource_type: "ForgeIssues.Comment",
      local_version: version,
      snapshot: snapshot,
      label_catalog: %{},
      assignee_catalog: %{}
    }
  end

  defp comment_context(baseline, overrides \\ []) do
    context(nil,
      trigger: :remote,
      resource_kind: :issue_comment,
      local_resource_id: 200,
      github_object_id: 601,
      github_node_id: "IC_601",
      github_number: 7,
      github_issue_id: 501,
      parent_issue_id: 100,
      baseline: baseline,
      confirmed_local_version: 3,
      confirmed_remote_updated_at: ~U[2026-09-07 07:00:00Z]
    )
    |> Map.merge(Map.new(overrides))
  end

  defp github_issue(snapshot, options \\ []) do
    labels =
      Keyword.get(
        options,
        :labels,
        Enum.map(
          snapshot["label_github_ids"],
          &github_label(&1, if(&1 == 11, do: "base", else: "label-#{&1}"))
        )
      )

    assignees =
      Keyword.get(
        options,
        :assignees,
        Enum.map(
          snapshot["assignee_github_ids"],
          &github_user(&1, if(&1 == 21, do: "base", else: "user-#{&1}"))
        )
      )

    %{
      "id" => Keyword.get(options, :id, 501),
      "node_id" => "I_501",
      "number" => Keyword.get(options, :number, 7),
      "title" => snapshot["title"],
      "body" => Keyword.get(options, :body, snapshot["body"]),
      "state" => snapshot["state"],
      "state_reason" => snapshot["state_reason"],
      "labels" => labels,
      "assignees" => assignees,
      "user" => github_user(31, "author"),
      "created_at" => "2026-09-01T00:00:00Z",
      "updated_at" => Keyword.get(options, :updated_at, "2026-09-07T07:00:00Z"),
      "closed_at" => nil
    }
  end

  defp github_comment(snapshot, options \\ []) do
    %{
      "id" => 601,
      "node_id" => "IC_601",
      "issue_number" => 7,
      "body" => Keyword.get(options, :body, snapshot["body"]),
      "user" => github_user(31, "author"),
      "created_at" => "2026-09-01T00:00:00Z",
      "updated_at" => Keyword.get(options, :updated_at, "2026-09-07T07:00:00Z")
    }
  end

  defp github_label(id, name), do: %{"id" => id, "node_id" => "L_#{id}", "name" => name}

  defp github_user(id, login),
    do: %{"id" => id, "node_id" => "U_#{id}", "login" => login}

  defp mark_effect(parent, operation) do
    fn ^operation, @now, marker ->
      send(parent, {:effect_marked, marker["action"]})
      {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
    end
  end

  defp effect_marker(action, expected, proposed) do
    %{
      "v" => 1,
      "action" => action,
      "resource_kind" => "issue",
      "local_resource_id" => 100,
      "expected_local_version" => 4,
      "expected_local_fingerprint" => fingerprint(proposed),
      "expected_remote_updated_at" => "2026-09-07T07:00:00Z",
      "expected_remote_fingerprint" => fingerprint(expected),
      "proposed_fingerprint" => fingerprint(proposed),
      "github_object_id" => 501
    }
  end

  defp create_marker(action, proposed, correlation_id) do
    %{
      "v" => 1,
      "action" => action,
      "resource_kind" => "issue",
      "local_resource_id" => 100,
      "expected_local_version" => 1,
      "expected_local_fingerprint" => fingerprint(proposed),
      "expected_remote_updated_at" => nil,
      "proposed_fingerprint" => fingerprint(proposed),
      "correlation_id" => correlation_id,
      "recovery_since" => "1970-01-01T00:00:00Z"
    }
  end

  defp fingerprint(snapshot) do
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(snapshot)
    fingerprint
  end

  defp collect_events(count),
    do:
      Enum.map(1..count, fn _ ->
        receive do
          event -> event
        end
      end)
end
