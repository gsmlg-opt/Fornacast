defmodule ForgeGitHub.IssueSyncIntegrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Multi
  alias ForgeGitHub.{InstallationToken, IssueClient, IssueSyncWorker}
  alias ForgeIssues.Issue
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, OutboxDispatcher}
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

    assert {:ok, results} =
             OutboxDispatcher.dispatch_once("inbound-no-echo", DateTime.utc_now(:second))

    assert {:ok, event.event_id, {:ignored, :non_local_event}} in results

    assert Repo.aggregate(
             from(o in MirrorOperation, where: o.repository_mirror_id == ^ctx.binding.id),
             :count
           ) == 1

    assert Repo.get!(DomainOutboxEvent, event.id).state == :completed
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
    target = Map.put(@base, "title", "New GitHub issue")
    operation = remote_operation(ctx, now, 701, 8)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/8"

      Req.Test.json(
        conn,
        Map.merge(issue_json(target, now), %{"id" => 701, "node_id" => "I_701", "number" => 8})
      )
    end)

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

  test "a mapped remote comment deletion atomically retains its tombstone and emits no echo",
       ctx do
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

    operation = claim(operation.id, now, "sync.issue_comment")

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/comments/900"
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:ok, _} = IssueSyncWorker.process_operation(operation, now, options(ctx))
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
  end

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
    {:ok, results} = OutboxDispatcher.dispatch_once(owner, now)

    assert {:ok, _, {:materialized, [id]}} =
             Enum.find(results, fn
               {:ok, event_id, _} -> event_id == event.event_id
               _ -> false
             end)

    id
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
