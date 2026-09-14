defmodule ForgeGitHub.IssueSyncIntegrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Multi
  alias ForgeGitHub.{InstallationToken, InventoryWorker, IssueClient, IssueSyncWorker, Repository}
  alias ForgeIssues.Issue

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    MirrorWebhookDelivery,
    OrganizationMirror,
    OutboxDispatcher
  }

  alias Fornacast.{DomainOutboxEvent, Repo}

  @base %{
    "title" => "Baseline",
    "body" => "Baseline body",
    "state" => "open",
    "state_reason" => nil,
    "label_github_ids" => [],
    "assignee_github_ids" => []
  }
  @source_time ~U[2026-09-01 00:00:00Z]

  setup {Req.Test, :verify_on_exit!}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture(%{capabilities: %{"issues" => "enabled"}})

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: organization.github_installation_id
    )
    |> Ecto.Changeset.change(permissions: %{"issues" => "write", "metadata" => "read"})
    |> Repo.update!()

    binding = repository_mirror_fixture(organization, %{github_full_name: "acme/project"})
    repository = Repo.get!(ForgeRepos.Repository, binding.repository_id)
    owner = organization_owner_fixture(organization)
    organization_account = ForgeAccounts.get_account(organization.organization_id)
    {:ok, identity} = ForgeAccounts.observe_github_identity(user_json(), @source_time)

    {:ok, %{issue: issue}} =
      Multi.new()
      |> ForgeIssues.import_identity_multi(
        :issue,
        repository,
        identity,
        :issue,
        Map.merge(Map.take(@base, ~w(title body state state_reason)), %{
          "number" => 7,
          "inserted_at" => @source_time,
          "updated_at" => @source_time
        })
      )
      |> Repo.transaction()

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(@base)

    mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: binding.id,
        resource_kind: :issue,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: issue.id,
        github_object_id: 700,
        github_node_id: "I_700",
        github_number: 7,
        confirmed_snapshot: @base,
        confirmed_fingerprint: fingerprint,
        confirmed_local_version: 1,
        confirmed_remote_updated_at: @source_time,
        state: :confirmed
      })
      |> Repo.insert!()

    %{
      organization: organization,
      binding: binding,
      repository: repository,
      owner: owner,
      owner_slug: organization_account.username,
      issue: issue,
      mapping: mapping,
      identity: identity,
      stub: {__MODULE__, System.unique_integer([:positive])}
    }
  end

  test "a real inbound issue edit atomically advances its domain version and baseline without echo",
       ctx do
    target = Map.put(@base, "title", "Edited on GitHub")
    now = DateTime.utc_now(:second)
    operation = remote_operation(ctx, now)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/7"
      Req.Test.json(conn, issue_json(target, now))
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))
    assert %{title: "Edited on GitHub", sync_version: 2} = Repo.get!(Issue, ctx.issue.id)
    assert_confirmed(ctx, operation, target, 2)
    assert [event] = issue_events(ctx)
    assert event.origin == :github
    assert event.causation_id == "integration-delivery"

    assert {:ok, event.event_id, {:ignored, :non_local_event}} ==
             dispatch_until(event.event_id, "inbound-no-echo", DateTime.utc_now(:second))

    assert Repo.aggregate(
             from(o in MirrorOperation, where: o.repository_mirror_id == ^ctx.binding.id),
             :count
           ) == 1

    assert Repo.get!(DomainOutboxEvent, event.id).state == :completed
  end

  test "full inventory repairs intentionally omitted issue and comment deliveries through real workers",
       ctx do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    observed_at = DateTime.add(DateTime.utc_now(:second), 10)

    target =
      @base
      |> Map.put("title", "Changed on GitHub without a webhook")
      |> Map.put("label_github_ids", [333])
      |> Map.put("assignee_github_ids", [801])

    label = %{
      "id" => 333,
      "node_id" => "LA_333",
      "name" => "reconciled-label",
      "color" => "aabbcc",
      "description" => "Discovered during reconciliation"
    }

    assignee = %{
      "id" => 801,
      "node_id" => "U_801",
      "login" => "reconciled-assignee",
      "type" => "User"
    }

    remote_issue =
      target
      |> issue_json(observed_at)
      |> Map.put("labels", [label])
      |> Map.put("assignees", [assignee])

    {:ok, %{comment: comment}} =
      Multi.new()
      |> ForgeIssues.import_comment_multi(:comment, ctx.issue, ctx.identity, %{
        "body" => "Removed on GitHub without a webhook",
        "inserted_at" => @source_time,
        "updated_at" => @source_time
      })
      |> Repo.transaction()

    {:ok, comment_fingerprint} = ForgeMirrors.resource_fingerprint(%{"body" => comment.body})

    comment_mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: ctx.binding.id,
        resource_kind: :issue_comment,
        local_resource_type: "ForgeIssues.Comment",
        local_resource_id: comment.id,
        github_object_id: 900,
        github_node_id: "IC_900",
        github_number: 7,
        confirmed_snapshot: %{"body" => comment.body},
        confirmed_fingerprint: comment_fingerprint,
        confirmed_local_version: 1,
        confirmed_remote_updated_at: @source_time,
        state: :confirmed
      })
      |> Repo.insert!()

    github_repository = %Repository{
      id: ctx.binding.github_repository_id,
      node_id: ctx.binding.github_node_id,
      owner_id: ctx.organization.github_account_id,
      name: ctx.repository.slug,
      full_name: ctx.binding.github_full_name,
      owner_login: ctx.organization.github_account_login,
      description: ctx.repository.description,
      visibility: ctx.repository.visibility,
      default_branch: ctx.repository.default_branch,
      has_issues: true,
      allow_merge_commit: true,
      fork: false,
      archived: false,
      updated_at: observed_at
    }

    assert Repo.aggregate(
             from(operation in MirrorOperation,
               where: operation.organization_mirror_id == ^ctx.organization.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^ctx.organization.id
             ),
             :count
           ) == 0

    assert {:ok, inventory} =
             ForgeMirrors.schedule_reconciliation(ctx.owner, ctx.organization, observed_at)

    assert {:ok, [{inventory_id, {:ok, %{operation: %{state: :completed}}}}]} =
             InventoryWorker.run_once("omitted-issue-comment-inventory",
               now: fn -> observed_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1,
               token_fetch: Keyword.fetch!(options(ctx), :token_fetch),
               page_fetch: fn "integration-token", 1, _ ->
                 {:ok, %{repositories: [github_repository], next_cursor: nil}}
               end
             )

    assert inventory_id == inventory.id

    marker = "inventory-operation:#{inventory.id}"

    sweep_children =
      Repo.all(
        from operation in MirrorOperation,
          where:
            operation.organization_mirror_id == ^ctx.organization.id and
              operation.kind != "finalize.organization.reconciliation" and
              fragment("?->>'inventory_reconciliation_sweep' = ?", operation.cursor, ^marker),
          select: operation.kind
      )

    assert Enum.sort(sweep_children) == [
             "reconcile.repository.git",
             "reconcile.repository.issue_comments",
             "reconcile.repository.issues",
             "reconcile.repository.metadata"
           ]

    assert Repo.get!(OrganizationMirror, ctx.organization.id).last_reconciled_at == nil

    assert {:ok, [{_id, {:ok, %{status: :waiting}}}]} =
             InventoryWorker.run_once("omitted-issue-comment-finalizer-waiting",
               now: fn -> observed_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    assert {:ok, [git_operation]} =
             ForgeMirrors.claim_operations(
               "omitted-issue-comment-git-scaffolding",
               observed_at,
               60,
               1,
               ["reconcile.repository.git"]
             )

    assert {:ok, %{state: :completed}} =
             ForgeMirrors.complete_operation(git_operation, observed_at)

    Req.Test.stub(ctx.stub, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/repos/acme/project/issues" ->
          Req.Test.json(conn, [remote_issue])

        "/repos/acme/project/issues/comments" ->
          Req.Test.json(conn, [])

        "/repos/acme/project/issues/7" ->
          Req.Test.json(conn, remote_issue)

        "/repos/acme/project/issues/comments/900" ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})

        "/repos/acme/project" ->
          Req.Test.json(conn, %{
            "id" => ctx.binding.github_repository_id,
            "node_id" => ctx.binding.github_node_id,
            "name" => ctx.repository.slug,
            "full_name" => ctx.binding.github_full_name,
            "owner" => %{"id" => ctx.organization.github_account_id, "login" => "acme"},
            "visibility" => "private",
            "default_branch" => ctx.repository.default_branch,
            "has_issues" => true,
            "allow_merge_commit" => true,
            "fork" => false,
            "archived" => false
          })

        path ->
          flunk("unexpected GitHub request path: #{path}")
      end
    end)

    worker_options =
      options(ctx) ++
        [
          now: fn -> observed_at end,
          task_supervisor: task_supervisor,
          max_concurrency: 1,
          batch_size: 1
        ]

    for {{owner, expected_kind}, offset} <-
          [
            {"omitted-issue-remote", "reconcile.repository.issues"},
            {"omitted-issue-mapped", "reconcile.repository.issues"},
            {"omitted-comment-remote", "reconcile.repository.issue_comments"},
            {"omitted-comment-mapped", "reconcile.repository.issue_comments"}
          ]
          |> Enum.with_index(1) do
      assert {:ok, [{operation_id, {:ok, _result}}]} =
               IssueSyncWorker.run_once(
                 owner,
                 Keyword.put(worker_options, :now, fn -> DateTime.add(observed_at, offset) end)
               )

      assert Repo.get!(MirrorOperation, operation_id).kind == expected_kind
    end

    assert {:ok, [metadata_operation]} =
             ForgeMirrors.claim_operations(
               "omitted-issue-comment-metadata-scaffolding",
               observed_at,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, %{state: :completed}} =
             ForgeMirrors.complete_operation(metadata_operation, observed_at)

    assert {:drained, claimed_kinds} =
             Enum.reduce_while(5..16, [], fn offset, claimed_kinds ->
               case IssueSyncWorker.run_once(
                      "omitted-issue-comment-child-#{offset}",
                      Keyword.put(worker_options, :now, fn ->
                        DateTime.add(observed_at, offset)
                      end)
                    ) do
                 {:ok, []} ->
                   {:halt, {:drained, claimed_kinds}}

                 {:ok, [{operation_id, {:ok, _result}}]} ->
                   kind = Repo.get!(MirrorOperation, operation_id).kind
                   assert kind in ["sync.issue", "sync.issue_comment"]
                   {:cont, [kind | claimed_kinds]}

                 result ->
                   flunk("unexpected issue reconciliation result: #{inspect(result)}")
               end
             end)

    assert "sync.issue" in claimed_kinds
    assert "sync.issue_comment" in claimed_kinds

    assert %{title: "Changed on GitHub without a webhook"} = Repo.get!(Issue, ctx.issue.id)

    assert {:ok, %{assignee_refs: [%{kind: :github_identity, id: assignee_identity_id}]}} =
             ForgeIssues.sync_projection(ctx.repository.id, :issue, ctx.issue.id)

    assert %{github_user_id: 801, github_node_id: "U_801", login: "reconciled-assignee"} =
             Repo.get!(ForgeAccounts.GitHubIdentity, assignee_identity_id)

    assert %ForgeIssues.IssueAssignee{
             user_id: nil,
             github_identity_id: ^assignee_identity_id
           } = Repo.get_by!(ForgeIssues.IssueAssignee, issue_id: ctx.issue.id)

    assert %{"assignee_github_ids" => [801]} =
             Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot

    assert [] ==
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^ctx.organization.id and
                     operation.kind in ["sync.issue", "sync.issue_comment"] and
                     operation.state != :completed,
                 select: {operation.kind, operation.state}
             )

    assert Repo.get(ForgeIssues.Comment, comment.id) == nil

    assert %{state: :deleted} = Repo.get!(MirrorResourceState, comment_mapping.id)

    assert %ForgeIssues.Label{name: "reconciled-label"} =
             Repo.get_by!(ForgeIssues.Label,
               repository_id: ctx.repository.id,
               name: "reconciled-label"
             )

    assert Enum.all?(
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^ctx.organization.id and
                     operation.kind != "finalize.organization.reconciliation" and
                     fragment(
                       "?->>'inventory_reconciliation_sweep' = ?",
                       operation.cursor,
                       ^marker
                     )
             ),
             &(&1.state == :completed)
           )

    finalizer_retry_at = DateTime.add(observed_at, 17)

    assert {:ok, [{_id, {:ok, %{status: :completed}}}]} =
             InventoryWorker.run_once("omitted-issue-comment-finalizer-completed",
               now: fn -> finalizer_retry_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    assert Repo.get!(OrganizationMirror, ctx.organization.id).last_reconciled_at == observed_at

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^ctx.organization.id
             ),
             :count
           ) == 0
  end

  test "a real local outbox edit reaches GitHub only after its effect marker and confirms the same version",
       ctx do
    target = Map.put(@base, "body", "Edited locally")

    assert {:ok, local} =
             ForgeIssues.update(
               ctx.owner,
               ctx.owner_slug,
               ctx.repository.slug,
               7,
               %{body: target["body"]},
               %{}
             )

    assert local.sync_version == 2
    now = DateTime.utc_now(:second)
    id = dispatch_issue_event(ctx, "outbound-events", now)
    operation = claim(id, now)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, issue_json(@base, @source_time))
    end)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/project/issues/7"

      assert %{
               state: :effect_pending,
               external_effect_marker: %{"action" => "update_remote_issue"}
             } = Repo.get!(MirrorOperation, id)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body)["body"] == target["body"]
      Req.Test.json(conn, issue_json(target, now))
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))
    assert_confirmed(ctx, operation, target, 2)
    assert Repo.get!(Issue, ctx.issue.id).sync_version == 2
    assert [%{origin: :fornacast}] = issue_events(ctx)
  end

  test "a local label is created under a durable marker before the issue relationship is sent",
       ctx do
    labels = ForgeIssues.list_labels(ctx.repository)
    label = Enum.find(labels, &(&1.name == "bug"))
    assert label

    assert {:ok, _} =
             ForgeIssues.update(
               ctx.owner,
               ctx.owner_slug,
               ctx.repository.slug,
               7,
               %{labels: [label.name]},
               %{}
             )

    now = DateTime.utc_now(:second)
    id = dispatch_issue_event(ctx, "local-label", now)
    operation = claim(id, now)

    remote_label = %{
      "id" => 444,
      "node_id" => "LA_444",
      "name" => label.name,
      "color" => label.color,
      "description" => label.description
    }

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/labels/bug"
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/acme/project/labels"

      assert %{
               state: :effect_pending,
               external_effect_marker: %{"action" => "create_remote_label"}
             } =
               Repo.get!(MirrorOperation, id)

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(remote_label)
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))
    assert %{state: :pending, external_effect_marker: nil} = Repo.get!(MirrorOperation, id)

    assert %{local_resource_id: local_id, confirmed_local_version: 1} =
             Repo.get_by!(MirrorResourceState,
               repository_mirror_id: ctx.binding.id,
               resource_kind: :label,
               github_object_id: 444
             )

    assert local_id == label.id

    operation = claim(id, now)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, issue_json(@base, @source_time))
    end)

    target = Map.put(@base, "label_github_ids", [444])

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "PATCH"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body)["labels"] == ["bug"]
      Req.Test.json(conn, Map.put(issue_json(target, now), "labels", [remote_label]))
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))
    assert_confirmed(ctx, operation, target, 2)
  end

  test "local edits during the provider write survive confirmation of the proven older common base",
       ctx do
    target = Map.put(@base, "body", "Sent local edit")

    {:ok, _} =
      ForgeIssues.update(
        ctx.owner,
        ctx.owner_slug,
        ctx.repository.slug,
        7,
        %{body: target["body"]},
        %{}
      )

    now = DateTime.utc_now(:second)
    id = dispatch_issue_event(ctx, "outbound-race", now)
    operation = claim(id, now)
    Req.Test.expect(ctx.stub, &Req.Test.json(&1, issue_json(@base, @source_time)))

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "PATCH"

      assert {:ok, %{sync_version: 3}} =
               ForgeIssues.update(
                 ctx.owner,
                 ctx.owner_slug,
                 ctx.repository.slug,
                 7,
                 %{title: "Newer unsent edit"},
                 %{}
               )

      Req.Test.json(conn, issue_json(target, now))
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))
    assert_confirmed(ctx, operation, target, 2)

    assert %{title: "Newer unsent edit", body: "Sent local edit", sync_version: 3} =
             Repo.get!(Issue, ctx.issue.id)

    assert Enum.any?(issue_events(ctx), &(&1.state == :pending))
  end

  test "a previously unmapped GitHub issue creates a local identity and permanent mapping together",
       ctx do
    now = DateTime.utc_now(:second)
    target = @base |> Map.put("title", "New GitHub issue") |> Map.put("label_github_ids", [333])
    operation = remote_operation(ctx, now, 701, 8)

    Req.Test.expect(ctx.stub, 2, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/8"

      Req.Test.json(
        conn,
        Map.merge(issue_json(target, now), %{
          "id" => 701,
          "node_id" => "I_701",
          "number" => 8,
          "labels" => [
            %{
              "id" => 333,
              "node_id" => "LA_333",
              "name" => "remote-new-label",
              "color" => "aabbcc",
              "description" => "Imported with issue"
            }
          ]
        })
      )
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))

    assert %{state: :pending} = Repo.get!(MirrorOperation, operation.id)

    label_mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :label,
        github_object_id: 333
      )

    assert Repo.get!(ForgeIssues.Label, label_mapping.local_resource_id).name ==
             "remote-new-label"

    assert label_mapping.confirmed_local_version == 1
    operation = claim(operation.id, now)
    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))

    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :issue,
        github_object_id: 701
      )

    issue = Repo.get!(Issue, mapping.local_resource_id)
    assert issue.number == 8
    assert issue.title == target["title"]
    assert issue.author_github_identity_id == ctx.issue.author_github_identity_id
    assert issue.author_user_id == nil
    assert_confirmed(%{ctx | mapping: mapping}, operation, target, 1)
  end

  test "a PR conversation comment keeps local and provider numbers distinct with pulls-only policy",
       ctx do
    now = DateTime.utc_now(:second)

    ctx.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "disabled", "pulls" => "enabled"})
    |> Repo.update!()

    issue = ctx.issue |> Ecto.Changeset.change(kind: :pull_request, number: 70) |> Repo.update!()
    assert issue.number != ctx.mapping.github_number

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: ctx.repository.id,
        head_repository_id: ctx.repository.id,
        head_ref: "refs/heads/topic",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    ctx.mapping
    |> Map.from_struct()
    |> Map.drop([:id, :__meta__, :inserted_at, :updated_at])
    |> Map.merge(%{
      resource_kind: :pull,
      local_resource_type: "ForgePulls.PullRequest",
      local_resource_id: pull.id,
      github_object_id: 1700,
      github_node_id: "PR_1700",
      provider_identity: comment_parent_identity(ctx, 700, "I_700", 7)
    })
    |> then(&MirrorResourceState.persistence_changeset(%MirrorResourceState{}, &1))
    |> Repo.insert!()

    operation =
      operation_fixture(ctx.organization, %{
        repository_mirror_id: ctx.binding.id,
        kind: "sync.issue_comment",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "issue_comment",
          "issue_kind" => "pull_request",
          "github_object_id" => 900,
          "github_issue_id" => 700,
          "github_number" => 7,
          "delivery_guid" => "pr-comment"
        },
        next_attempt_at: now
      })
      |> then(&claim(&1.id, now, "sync.issue_comment"))

    assert {:ok, %{parent_issue_id: parent_id, github_issue_id: 700}} =
             ForgeMirrors.resource_operation_context(operation)

    assert parent_id == issue.id

    Repo.get!(ForgeMirrors.OrganizationMirror, ctx.organization.id)
    |> Ecto.Changeset.change(capabilities: %{"issues" => "enabled", "pulls" => "disabled"})
    |> Repo.update!()

    assert {:error, :invalid_transition} = ForgeMirrors.resource_operation_context(operation)

    Repo.get!(ForgeMirrors.OrganizationMirror, ctx.organization.id)
    |> Ecto.Changeset.change(capabilities: %{"issues" => "disabled", "pulls" => "enabled"})
    |> Repo.update!()

    # An omitted hint (full collection reconciliation) must derive the same locked parent kind.
    operation =
      operation
      |> Ecto.Changeset.change(cursor: Map.delete(operation.cursor, "issue_kind"))
      |> Repo.update!()

    assert {:ok, %{github_issue_id: 700}} = ForgeMirrors.resource_operation_context(operation)

    companion =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :pull,
        github_object_id: 1700
      )

    companion |> Ecto.Changeset.change(github_object_id: 700) |> Repo.update!()
    assert {:ok, %{github_issue_id: 700}} = ForgeMirrors.resource_operation_context(operation)

    Repo.get!(MirrorResourceState, companion.id)
    |> Ecto.Changeset.change(github_object_id: 1700)
    |> Repo.update!()

    Repo.get!(MirrorResourceState, companion.id)
    |> Ecto.Changeset.change(provider_identity: nil)
    |> Repo.update!()

    assert {:error, :identity_conflict} = ForgeMirrors.resource_operation_context(operation)

    Repo.get!(MirrorResourceState, companion.id)
    |> Ecto.Changeset.change(provider_identity: comment_parent_identity(ctx, 1700, "PR_1700", 7))
    |> Repo.update!()

    assert {:error, :identity_conflict} = ForgeMirrors.resource_operation_context(operation)

    Repo.get!(MirrorResourceState, companion.id)
    |> Ecto.Changeset.change(provider_identity: comment_parent_identity(ctx, 700, "I_700", 7))
    |> Repo.update!()

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/comments/900"

      Req.Test.json(conn, %{
        "id" => 900,
        "node_id" => "IC_900",
        "body" => "PR conversation",
        "user" => user_json(),
        "issue_url" => "https://api.github.com/repos/acme/project/issues/7",
        "created_at" => DateTime.to_iso8601(@source_time),
        "updated_at" => DateTime.to_iso8601(now)
      })
    end)

    worker_options =
      Keyword.update!(options(ctx), :token_fetch, fn fetch ->
        fn id, request ->
          assert request.permissions == %{"pull_requests" => "write", "metadata" => "read"}
          %{fetch.(id, request) | permissions: request.permissions}
        end
      end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, worker_options)

    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :issue_comment,
        github_object_id: 900
      )

    assert %{issue_id: ^parent_id, body: "PR conversation"} =
             Repo.get!(ForgeIssues.Comment, mapping.local_resource_id)

    assert Repo.get!(MirrorOperation, operation.id).state == :completed

    assert {:ok, local_comment} =
             ForgeIssues.create_comment(
               ctx.owner,
               ctx.owner_slug,
               ctx.repository.slug,
               issue.number,
               %{body: "Local PR conversation"},
               %{}
             )

    local_event =
      Repo.get_by!(DomainOutboxEvent,
        aggregate_type: "issue_comment",
        aggregate_id: to_string(local_comment.id),
        event_type: "issue_comment.created"
      )

    assert local_event.payload["issue_kind"] == "pull_request"

    Repo.get!(ForgeMirrors.OrganizationMirror, ctx.organization.id)
    |> Ecto.Changeset.change(capabilities: single_metadata_capability(:issue))
    |> Repo.update!()

    assert {:ok, {:ignored, :capability_disabled}} =
             ForgeMirrors.materialize_outbox_event(local_event)

    refute Repo.exists?(
             from o in MirrorOperation,
               where: o.repository_mirror_id == ^ctx.binding.id and o.state == :failed
           )

    Repo.get!(ForgeMirrors.OrganizationMirror, ctx.organization.id)
    |> Ecto.Changeset.change(capabilities: single_metadata_capability(:pull_request))
    |> Repo.update!()

    local_now = DateTime.utc_now(:second)

    assert {:ok, _, {:materialized, [local_operation_id]}} =
             dispatch_until(local_event.event_id, "pr-comment-outbox", local_now)

    assert :ok =
             ForgeIssues.delete_comment(
               ctx.owner,
               ctx.owner_slug,
               ctx.repository.slug,
               local_comment.id,
               %{}
             )

    local_operation = claim(local_operation_id, local_now, "sync.issue_comment")

    assert {:ok,
            %{
              parent_issue_id: ^parent_id,
              github_issue_id: 700,
              local_deleted: true,
              local_version: 2
            }} = ForgeMirrors.resource_operation_context(local_operation)
  end

  for enabled_kind <- [:issue, :pull_request] do
    test "shared comment sweeps exclude policy-disabled parents with #{enabled_kind} enabled",
         ctx do
      enabled_kind = unquote(enabled_kind)
      now = DateTime.utc_now(:second)

      org =
        ctx.organization
        |> Ecto.Changeset.change(capabilities: single_metadata_capability(enabled_kind))
        |> Repo.update!()

      insert_pull_parent(ctx, now)

      sweep =
        operation_fixture(org, %{
          repository_mirror_id: ctx.binding.id,
          kind: "reconcile.repository.issue_comments",
          next_attempt_at: now,
          cursor: %{
            "trigger" => "reconcile",
            "resource_kind" => "issue_comment",
            "since" => "1970-01-01T00:00:00Z",
            "page" => 1,
            "sweep_id" => Ecto.UUID.generate()
          }
        })

      sweep = claim(sweep.id, now, sweep.kind)

      observations =
        for {id, number} <- [{900, 7}, {901, 8}],
            do: %{
              github_object_id: id,
              github_number: number,
              github_issue_id: nil,
              remote_updated_at: now
            }

      assert {:ok, %{operations: [child], operation: pending}} =
               ForgeMirrors.record_resource_reconciliation_page(
                 sweep,
                 :issue_comment,
                 observations,
                 nil,
                 now
               )

      assert child.cursor["github_object_id"] == enabled_comment_id(enabled_kind)
      assert child.cursor["issue_kind"] == Atom.to_string(enabled_kind)
      assert pending.checkpoint["phase"] == "mapped"
      sweep = claim(sweep.id, now, sweep.kind)

      assert {:ok, %{operation: %{state: :completed}}} =
               ForgeMirrors.record_resource_reconciliation_page(
                 sweep,
                 :issue_comment,
                 [],
                 nil,
                 now
               )
    end
  end

  test "only proven external read-only PR parents are excluded from a shared sweep", ctx do
    now = DateTime.utc_now(:second)

    ctx.organization
    |> Ecto.Changeset.change(capabilities: single_metadata_capability(:pull_request))
    |> Repo.update!()

    pull = insert_pull_parent(ctx, now)

    companion =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :pull,
        github_object_id: 1701
      )

    Repo.get!(MirrorResourceState, companion.id)
    |> Ecto.Changeset.change(state: :unsupported)
    |> Repo.update!()

    sweep =
      operation_fixture(ctx.organization, %{
        repository_mirror_id: ctx.binding.id,
        kind: "reconcile.repository.issue_comments",
        next_attempt_at: now,
        cursor: %{
          "trigger" => "reconcile",
          "resource_kind" => "issue_comment",
          "since" => "1970-01-01T00:00:00Z",
          "page" => 1,
          "sweep_id" => Ecto.UUID.generate()
        }
      })

    sweep = claim(sweep.id, now, sweep.kind)

    observation = %{
      github_object_id: 901,
      github_number: 8,
      github_issue_id: nil,
      remote_updated_at: now
    }

    # A represented but unconfirmed/unsupported head must not become an exclusion.
    assert {:error, :identity_conflict} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :issue_comment,
               [observation],
               nil,
               now
             )

    assert Repo.get!(MirrorOperation, sweep.id).checkpoint == %{}

    pull |> Ecto.Changeset.change(head_repository_id: nil) |> Repo.update!()

    companion
    |> Ecto.Changeset.change(state: :unsupported, provider_identity: nil)
    |> Repo.update!()

    assert {:error, :identity_conflict} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :issue_comment,
               [observation],
               nil,
               now
             )

    Repo.get!(MirrorResourceState, companion.id)
    |> Ecto.Changeset.change(
      state: :unsupported,
      provider_identity: comment_parent_identity(ctx, 701, "NODE_701", 8)
    )
    |> Repo.update!()

    assert {:ok, %{operations: [], operation: pending}} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :issue_comment,
               [observation],
               nil,
               now
             )

    assert pending.checkpoint["phase"] == "mapped"
  end

  test "an undiscovered comment parent does not hold its sweep ahead of parent discovery", ctx do
    now = DateTime.utc_now(:second)

    ctx.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "enabled", "pulls" => "enabled"})
    |> Repo.update!()

    insert_pull_parent(ctx, now)

    Repo.get_by!(MirrorResourceState,
      repository_mirror_id: ctx.binding.id,
      resource_kind: :pull,
      github_object_id: 1701
    )
    |> Ecto.Changeset.change(state: :pending)
    |> Repo.update!()

    sweep =
      operation_fixture(ctx.organization, %{
        repository_mirror_id: ctx.binding.id,
        kind: "reconcile.repository.issue_comments",
        next_attempt_at: now,
        cursor: %{
          "trigger" => "reconcile",
          "resource_kind" => "issue_comment",
          "since" => "1970-01-01T00:00:00Z",
          "page" => 1,
          "sweep_id" => Ecto.UUID.generate()
        }
      })

    sweep = claim(sweep.id, now, sweep.kind)

    observation = %{
      github_object_id: 990,
      github_number: 99,
      github_issue_id: nil,
      remote_updated_at: now
    }

    pending_parent = %{observation | github_object_id: 991, github_number: 8}

    assert {:ok, %{operations: [child, pending_child]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :issue_comment,
               [observation, pending_parent],
               nil,
               now
             )

    assert pending_child.cursor["github_number"] == 8
    sweep = claim(sweep.id, now, sweep.kind)

    assert {:ok, %{operation: %{state: :completed}}} =
             ForgeMirrors.record_resource_reconciliation_page(sweep, :issue_comment, [], nil, now)

    child = claim(child.id, now, child.kind)
    assert {:error, :parent_mapping_missing} = ForgeMirrors.resource_operation_context(child)
    assert Repo.get!(MirrorOperation, child.id).state == :processing

    child
    |> Ecto.Changeset.change(
      state: :completed,
      completed_at: now,
      lease_owner: nil,
      lease_expires_at: nil
    )
    |> Repo.update!()

    pending_child = claim(pending_child.id, now, pending_child.kind)

    assert {:error, :parent_mapping_missing} =
             ForgeMirrors.resource_operation_context(pending_child)
  end

  test "represented cross-head PR comments wait for the exact active head binding", ctx do
    now = DateTime.utc_now(:second)

    ctx.organization
    |> Ecto.Changeset.change(capabilities: single_metadata_capability(:pull_request))
    |> Repo.update!()

    pull = insert_pull_parent(ctx, now)
    head = repository_mirror_fixture(ctx.organization)
    pull |> Ecto.Changeset.change(head_repository_id: head.repository_id) |> Repo.update!()

    companion =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :pull,
        github_object_id: 1701
      )

    identity =
      Map.put(companion.provider_identity, "head_repository", %{
        "id" => head.github_repository_id,
        "node_id" => head.github_node_id
      })

    companion |> Ecto.Changeset.change(provider_identity: identity) |> Repo.update!()
    head |> Ecto.Changeset.change(state: :discovered) |> Repo.update!()

    operation =
      operation_fixture(ctx.organization, %{
        repository_mirror_id: ctx.binding.id,
        kind: "sync.issue_comment",
        next_attempt_at: now,
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "issue_comment",
          "github_object_id" => 901,
          "github_issue_id" => 701,
          "github_number" => 8
        }
      })

    operation = claim(operation.id, now, operation.kind)
    assert {:error, :pull_head_not_ready} = ForgeMirrors.resource_operation_context(operation)

    Repo.get!(ForgeMirrors.RepositoryMirror, head.id)
    |> Ecto.Changeset.change(state: :active)
    |> Repo.update!()

    assert {:ok, %{github_issue_id: 701}} = ForgeMirrors.resource_operation_context(operation)
    marker = %{"action" => "update_remote_comment", "github_object_id" => 901}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(operation, now, marker)

    Repo.get!(ForgeMirrors.RepositoryMirror, head.id)
    |> Ecto.Changeset.change(github_node_id: "wrong-node")
    |> Repo.update!()

    assert {:error, :pull_head_not_ready} = ForgeMirrors.resource_operation_context(marked)
    assert {:ok, deferred} = IssueSyncWorker.process_operation(marked, now, options(ctx))
    assert deferred.state == :effect_pending
    assert deferred.external_effect_marker == marker
    assert deferred.checkpoint == marked.checkpoint
    assert deferred.lease_owner == nil
    assert deferred.failure_detail == "resource_context_unavailable"
  end

  test "a new remote conversation comment binds to the mapped local parent with a github-origin event",
       ctx do
    now = DateTime.utc_now(:second)

    operation =
      operation_fixture(ctx.organization, %{
        repository_mirror_id: ctx.binding.id,
        kind: "sync.issue_comment",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "issue_comment",
          "github_object_id" => 900,
          "github_issue_id" => 700,
          "github_number" => 7,
          "delivery_guid" => "comment-delivery"
        },
        next_attempt_at: now
      })

    operation = claim(operation.id, now, "sync.issue_comment")

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/comments/900"

      Req.Test.json(conn, %{
        "id" => 900,
        "node_id" => "IC_900",
        "body" => "Remote conversation",
        "user" => user_json(),
        "issue_url" => "https://api.github.com/repos/acme/project/issues/7",
        "created_at" => DateTime.to_iso8601(@source_time),
        "updated_at" => DateTime.to_iso8601(now)
      })
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))

    mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: ctx.binding.id,
        resource_kind: :issue_comment,
        github_object_id: 900
      )

    comment = Repo.get!(ForgeIssues.Comment, mapping.local_resource_id)
    assert comment.issue_id == ctx.issue.id
    assert comment.author_github_identity_id == ctx.issue.author_github_identity_id
    assert comment.body == "Remote conversation"
    assert_confirmed(%{ctx | mapping: mapping}, operation, %{"body" => "Remote conversation"}, 1)

    assert %{origin: :github, causation_id: "comment-delivery"} =
             Repo.get_by!(DomainOutboxEvent,
               aggregate_type: "issue_comment",
               aggregate_id: to_string(comment.id)
             )
  end

  for access <- [:confirmed, :denied, :wrong_repository, :missed_webhook] do
    @tag deletion_access: access
    test "mapped comment deletion requires repository access proof: #{access}", ctx do
      access = ctx.deletion_access
      identity = Repo.get!(ForgeAccounts.GitHubIdentity, ctx.issue.author_github_identity_id)

      {:ok, %{comment: comment}} =
        Multi.new()
        |> ForgeIssues.import_comment_multi(:comment, ctx.issue, identity, %{
          "body" => "Original comment",
          "inserted_at" => @source_time,
          "updated_at" => @source_time
        })
        |> Repo.transaction()

      snapshot = %{"body" => comment.body}
      {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(snapshot)

      mapping =
        %MirrorResourceState{}
        |> MirrorResourceState.persistence_changeset(%{
          repository_mirror_id: ctx.binding.id,
          resource_kind: :issue_comment,
          local_resource_type: "ForgeIssues.Comment",
          local_resource_id: comment.id,
          github_object_id: 900,
          github_node_id: "IC_900",
          github_number: 7,
          confirmed_snapshot: snapshot,
          confirmed_fingerprint: fingerprint,
          confirmed_local_version: 1,
          confirmed_remote_updated_at: @source_time,
          state: :confirmed
        })
        |> Repo.insert!()

      now = DateTime.utc_now(:second)

      operation =
        if access == :missed_webhook do
          sweep =
            operation_fixture(ctx.organization, %{
              repository_mirror_id: ctx.binding.id,
              kind: "reconcile.repository.issue_comments",
              cursor: %{
                "trigger" => "reconcile",
                "since" => "1970-01-01T00:00:00Z",
                "page" => 1,
                "sweep_id" => Ecto.UUID.generate()
              },
              next_attempt_at: now
            })

          Req.Test.expect(ctx.stub, fn conn ->
            assert conn.method == "GET"
            assert conn.request_path == "/repos/acme/project/issues/comments"
            Req.Test.json(conn, [])
          end)

          for phase <- [:remote, :mapped] do
            leased = claim(sweep.id, now, sweep.kind)
            assert {:ok, _} = IssueSyncWorker.process_operation(leased, now, options(ctx))

            if phase == :remote do
              assert %{state: :pending, checkpoint: %{"phase" => "mapped"}} =
                       Repo.get!(MirrorOperation, sweep.id)
            end
          end

          assert Repo.get!(MirrorOperation, sweep.id).state == :completed

          Repo.get_by!(MirrorOperation,
            repository_mirror_id: ctx.binding.id,
            kind: "sync.issue_comment"
          )
        else
          operation_fixture(ctx.organization, %{
            repository_mirror_id: ctx.binding.id,
            kind: "sync.issue_comment",
            cursor: %{
              "trigger" => "remote",
              "resource_kind" => "issue_comment",
              "github_object_id" => 900,
              "github_issue_id" => 700,
              "github_number" => 7,
              "delivery_guid" => "deleted-comment-delivery"
            },
            next_attempt_at: now
          })
        end

      operation = claim(operation.id, now, "sync.issue_comment")

      Req.Test.expect(ctx.stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme/project/issues/comments/900"
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      Req.Test.expect(ctx.stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme/project"

        if access == :denied do
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
        else
          id = ctx.binding.github_repository_id + if(access == :wrong_repository, do: 1, else: 0)

          Req.Test.json(conn, %{
            "id" => id,
            "node_id" => "R_#{id}",
            "name" => "project",
            "full_name" => "acme/project",
            "owner" => %{"id" => 42, "login" => "acme"},
            "visibility" => "private",
            "default_branch" => "main",
            "has_issues" => true,
            "allow_merge_commit" => true,
            "fork" => false,
            "archived" => false
          })
        end
      end)

      result = IssueSyncWorker.process_operation(operation, now, options(ctx))

      if access in [:confirmed, :missed_webhook] do
        assert {:ok, _} = result
        assert Repo.get(ForgeIssues.Comment, comment.id) == nil

        assert %{state: :completed, external_effect_marker: nil} =
                 Repo.get!(MirrorOperation, operation.id)

        assert %{state: :deleted, confirmed_local_version: 2} =
                 Repo.get!(MirrorResourceState, mapping.id)

        assert %{origin: :github, event_type: "issue_comment.deleted"} =
                 Repo.get_by!(DomainOutboxEvent,
                   aggregate_type: "issue_comment",
                   aggregate_id: to_string(comment.id)
                 )
      else
        assert {:ok, %{state: :failed}} = result
        assert Repo.get!(ForgeIssues.Comment, comment.id).body == "Original comment"
        assert Repo.get!(MirrorResourceState, mapping.id).state == :confirmed

        refute Repo.exists?(
                 from e in DomainOutboxEvent,
                   where:
                     e.aggregate_type == "issue_comment" and
                       e.aggregate_id == ^to_string(comment.id)
               )
      end
    end
  end

  defp comment_parent_identity(ctx, id, node, number) do
    repository = %{
      "id" => ctx.binding.github_repository_id,
      "node_id" => ctx.binding.github_node_id
    }

    %{
      "github_issue_object_id" => id,
      "github_issue_node_id" => node,
      "github_number" => number,
      "head_repository" => repository,
      "base_repository" => repository
    }
  end

  defp insert_pull_parent(ctx, now) do
    issue =
      Repo.insert!(%Issue{
        repository_id: ctx.repository.id,
        number: 8,
        kind: :pull_request,
        title: "PR",
        author_user_id: ctx.owner.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: ctx.repository.id,
        head_repository_id: ctx.repository.id,
        head_ref: "refs/heads/topic",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    for {kind, type, local_id, provider_id} <- [
          {:issue, "ForgeIssues.Issue", issue.id, 701},
          {:pull, "ForgePulls.PullRequest", pull.id, 1701}
        ] do
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: ctx.binding.id,
        resource_kind: kind,
        local_resource_type: type,
        local_resource_id: local_id,
        github_object_id: provider_id,
        github_node_id: "NODE_#{provider_id}",
        github_number: 8,
        state: :confirmed,
        confirmed_local_version: 1,
        confirmed_remote_updated_at: now,
        provider_identity: if(kind == :pull, do: comment_parent_identity(ctx, 701, "NODE_701", 8))
      })
      |> Repo.insert!()
    end

    pull
  end

  defp single_metadata_capability(:issue), do: %{"issues" => "enabled", "pulls" => "disabled"}

  defp single_metadata_capability(:pull_request),
    do: %{"issues" => "disabled", "pulls" => "enabled"}

  defp enabled_comment_id(:issue), do: 900
  defp enabled_comment_id(:pull_request), do: 901

  defp remote_operation(ctx, now, github_id \\ 700, number \\ 7) do
    operation =
      operation_fixture(ctx.organization, %{
        repository_mirror_id: ctx.binding.id,
        kind: "sync.issue",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "issue",
          "issue_kind" => "issue",
          "github_object_id" => github_id,
          "github_number" => number,
          "delivery_guid" => "integration-delivery"
        },
        next_attempt_at: now
      })

    claim(operation.id, now)
  end

  defp issue_events(ctx),
    do:
      Repo.all(
        from e in DomainOutboxEvent,
          where: e.aggregate_type == "issue" and e.aggregate_id == ^to_string(ctx.issue.id),
          order_by: e.id
      )

  defp dispatch_issue_event(ctx, owner, now) do
    [event] = issue_events(ctx)

    assert {:ok, _, {:materialized, [id]}} =
             dispatch_until(event.event_id, owner, now)

    id
  end

  defp dispatch_until(target_id, owner, now) do
    # Real dispatcher batches may contain committed events from other test suites.
    # Claims/acks here remain inside this test's sandbox transaction.
    batches = div(Repo.aggregate(DomainOutboxEvent, :count), 25) + 1

    result =
      Enum.reduce_while(1..batches, nil, fn _, _ ->
        assert {:ok, results} = OutboxDispatcher.dispatch_once(owner, now)

        case Enum.find(results, fn
               {_, event_id, _} -> event_id == target_id
               _ -> false
             end) do
          nil -> {:cont, nil}
          found -> {:halt, found}
        end
      end)

    assert result,
           "fixture outbox event #{target_id} was not reached in #{batches} bounded batches"

    result
  end

  defp claim(id, now, kind \\ "sync.issue") do
    {:ok, operations} = ForgeMirrors.claim_operations("integration-worker", now, 60, 100, [kind])
    Enum.find(operations, &(&1.id == id)) || flunk("operation was not claimable")
  end

  defp assert_confirmed(ctx, operation, snapshot, version) do
    assert %{state: :completed, external_effect_marker: nil} =
             Repo.get!(MirrorOperation, operation.id)

    mapping = Repo.get!(MirrorResourceState, ctx.mapping.id)
    assert mapping.state == :confirmed
    assert mapping.confirmed_snapshot == snapshot
    assert mapping.confirmed_local_version == version
    assert {:ok, mapping.confirmed_fingerprint} == ForgeMirrors.resource_fingerprint(snapshot)
  end

  defp options(ctx) do
    [
      token_fetch: fn id, _ ->
        assert id == ctx.organization.github_installation_id

        %InstallationToken{
          token: "integration-token",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
          permissions: %{"issues" => "write", "metadata" => "read"}
        }
      end,
      get_issue: fn token, owner, repository, number, opts ->
        IssueClient.get_issue(token, owner, repository, number, transport_options(ctx, opts))
      end,
      get_comment: fn token, owner, repository, id, opts ->
        IssueClient.get_comment(token, owner, repository, id, transport_options(ctx, opts))
      end,
      get_repository: fn token, owner, repository, opts ->
        ForgeGitHub.Client.repository(token, owner, repository, transport_options(ctx, opts))
      end,
      list_issues: fn token, owner, repository, since, page, opts ->
        IssueClient.list_updated_issues_page(
          token,
          owner,
          repository,
          since,
          page,
          transport_options(ctx, opts)
        )
      end,
      list_comments: fn token, owner, repository, since, page, opts ->
        IssueClient.list_updated_comments_page(
          token,
          owner,
          repository,
          since,
          page,
          transport_options(ctx, opts)
        )
      end,
      get_label: fn token, owner, repository, name, opts ->
        ForgeGitHub.LabelClient.get_label(
          token,
          owner,
          repository,
          name,
          transport_options(ctx, opts)
        )
      end,
      create_label: fn token, owner, repository, attrs, opts ->
        ForgeGitHub.LabelClient.create_label(
          token,
          owner,
          repository,
          attrs,
          transport_options(ctx, opts)
        )
      end,
      update_issue: fn token, owner, repository, number, attrs, opts ->
        IssueClient.update_issue(
          token,
          owner,
          repository,
          number,
          attrs,
          transport_options(ctx, opts)
        )
      end
    ]
  end

  defp transport_options(ctx, opts),
    do:
      Keyword.merge(opts,
        plug: {Req.Test, ctx.stub},
        resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
      )

  defp user_json,
    do: %{"id" => 800, "node_id" => "U_800", "login" => "remote-author", "type" => "User"}

  defp issue_json(snapshot, updated_at),
    do:
      Map.merge(Map.take(snapshot, ~w(title body state state_reason)), %{
        "id" => 700,
        "node_id" => "I_700",
        "number" => 7,
        "user" => user_json(),
        "labels" => [],
        "assignees" => [],
        "created_at" => DateTime.to_iso8601(@source_time),
        "updated_at" => DateTime.to_iso8601(updated_at),
        "closed_at" => nil
      })
end
