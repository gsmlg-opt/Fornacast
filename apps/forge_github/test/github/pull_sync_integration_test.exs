defmodule ForgeGitHub.PullSyncIntegrationTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{Error, InstallationToken, IssueClient, PullClient, PullSyncWorker}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState
  }

  alias ForgePulls.PullRequest
  alias Fornacast.Repo

  @source_time ~U[2026-09-01 00:00:00Z]
  @base %{
    "title" => "Baseline",
    "body" => "Baseline body",
    "state" => "open",
    "state_reason" => nil,
    "draft" => false,
    "head_ref" => "refs/heads/feature",
    "head_sha" => nil,
    "base_ref" => "refs/heads/main",
    "base_sha" => nil
  }

  setup {Req.Test, :verify_on_exit!}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base =
      repository_mirror_fixture(organization, %{
        github_full_name: "acme/project",
        github_repository_id: 900,
        github_node_id: "R_900"
      })

    head =
      repository_mirror_fixture(organization, %{
        github_full_name: "acme/head",
        github_repository_id: 901,
        github_node_id: "R_901"
      })

    {base_path, base_sha} = initialize_branch!(base.repository_id, @base["base_ref"])
    {head_path, head_sha} = initialize_branch!(head.repository_id, @base["head_ref"])
    baseline = @base |> Map.put("base_sha", base_sha) |> Map.put("head_sha", head_sha)

    on_exit(fn ->
      File.rm_rf!(base_path)
      File.rm_rf!(head_path)
    end)

    actor = organization_owner_fixture(organization)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: baseline["title"],
        body: baseline["body"],
        state: :open,
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: head.repository_id,
        draft: false,
        head_ref: baseline["head_ref"],
        head_sha: baseline["head_sha"],
        base_ref: baseline["base_ref"],
        base_sha: baseline["base_sha"],
        mergeable_state: :unknown
      })

    for {binding, ref, oid} <- [
          {base, baseline["base_ref"], baseline["base_sha"]},
          {head, baseline["head_ref"], baseline["head_sha"]}
        ] do
      %MirrorRefState{}
      |> MirrorRefState.persistence_changeset(%{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: @source_time
      })
      |> Repo.insert!()
    end

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(baseline)

    identity = %{
      "github_issue_object_id" => 801,
      "github_issue_node_id" => "I_801",
      "github_number" => 7,
      "head_repository" => %{"id" => 901, "node_id" => "R_901"},
      "base_repository" => %{"id" => 900, "node_id" => "R_900"}
    }

    mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: base.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 802,
        github_node_id: "PR_802",
        github_number: 7,
        confirmed_local_version: issue.sync_version,
        confirmed_remote_updated_at: @source_time,
        confirmed_snapshot: baseline,
        confirmed_fingerprint: fingerprint,
        confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
        provider_identity: identity,
        state: :confirmed
      })
      |> Repo.insert!()

    %{
      organization: organization,
      base: base,
      head: head,
      issue: issue,
      pull: pull,
      mapping: mapping,
      baseline: baseline,
      base_path: base_path,
      head_path: head_path,
      stub: {__MODULE__, System.unique_integer([:positive])}
    }
  end

  test "real inbound pull metadata and draft observation commits with its mirror baseline", ctx do
    now = DateTime.utc_now(:second)
    target = ctx.baseline |> Map.put("title", "GitHub title") |> Map.put("draft", true)
    operation = remote_operation(ctx, now)

    expect_observation(ctx, target, now)

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    assert %{title: "GitHub title", sync_version: 2} =
             Repo.get!(ForgeIssues.Issue, ctx.issue.id)

    assert %{draft: true} = Repo.get!(PullRequest, ctx.pull.id)
    assert_confirmed(ctx, operation, target, 2)
  end

  test "real outbound issue and draft effects use distinct durable markers before confirmation",
       ctx do
    now = DateTime.utc_now(:second)
    target = ctx.baseline |> Map.put("title", "Local title") |> Map.put("draft", true)

    issue =
      ctx.issue
      |> ForgeIssues.Issue.update_changeset(%{title: target["title"]})
      |> Repo.update!()

    ctx.pull
    |> PullRequest.update_changeset(%{draft: true})
    |> Repo.update!()

    operation = local_operation(ctx, issue.sync_version, now)
    expect_observation(ctx, ctx.baseline, @source_time)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/repos/acme/project/issues/7"

      assert %{
               state: :effect_pending,
               external_effect_marker: %{"action" => "update_remote_pull_issue"}
             } = Repo.get!(MirrorOperation, operation.id)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body)["title"] == target["title"]
      Req.Test.json(conn, issue_json(target, now))
    end)

    after_issue = Map.put(target, "draft", false)
    expect_observation(ctx, after_issue, now)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"

      assert %{
               state: :effect_pending,
               external_effect_marker: %{"action" => "set_remote_pull_draft"}
             } = Repo.get!(MirrorOperation, operation.id)

      Req.Test.json(conn, %{
        "data" => %{
          "convertPullRequestToDraft" => %{
            "pullRequest" => %{"id" => "PR_802", "isDraft" => true}
          }
        }
      })
    end)

    expect_observation(ctx, target, now)

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    assert_confirmed(ctx, operation, target, 2)
  end

  test "a pending disjoint effect survives GET failure and confirms its preimage after a newer edit",
       ctx do
    now = DateTime.utc_now(:second)
    old_local = Map.put(ctx.baseline, "title", "Sent title")
    remote_before = Map.put(ctx.baseline, "body", "Remote body")
    postcondition = Map.put(remote_before, "title", "Sent title")

    issue =
      ctx.issue
      |> ForgeIssues.Issue.update_changeset(%{title: old_local["title"]})
      |> Repo.update!()

    operation = local_operation(ctx, issue.sync_version, now)
    remote = start_supervised!({Agent, fn -> remote_before end})

    first_options =
      options(ctx,
        get_pull: fn _, _, _, _, _ -> {:ok, pull_json(Agent.get(remote, & &1), now)} end,
        get_pull_issue: fn _, _, _, _, _ ->
          {:ok, issue_json(Agent.get(remote, & &1), now)}
        end,
        update_pull_issue: fn _, _, _, _, _, _ ->
          Agent.update(remote, fn _ -> postcondition end)
          {:error, Error.new(:transport)}
        end
      )

    assert {:ok, %{state: :effect_pending}} =
             PullSyncWorker.process_operation(operation, now, first_options)

    pending = Repo.get!(MirrorOperation, operation.id)
    marker = pending.external_effect_marker
    assert marker["action"] == "update_remote_pull_issue"

    pending = claim(operation.id, pending.next_attempt_at)

    failed_get_options =
      options(ctx,
        get_pull: fn _, _, _, _, _ -> {:error, Error.new(:transport)} end
      )

    assert {:ok, %{state: :effect_pending, external_effect_marker: ^marker}} =
             PullSyncWorker.process_operation(
               pending,
               pending.next_attempt_at,
               failed_get_options
             )

    still_pending = Repo.get!(MirrorOperation, operation.id)
    assert still_pending.external_effect_marker == marker

    newer_issue =
      issue
      |> ForgeIssues.Issue.update_changeset(%{state: :closed, state_reason: :completed})
      |> Repo.update!()

    pending = claim(operation.id, still_pending.next_attempt_at)

    recovery_options =
      options(ctx,
        get_pull: fn _, _, _, _, _ -> {:ok, pull_json(postcondition, now)} end,
        get_pull_issue: fn _, _, _, _, _ -> {:ok, issue_json(postcondition, now)} end,
        update_pull_issue: fn _, _, _, _, _, _ -> flunk("proven effect was replayed") end
      )

    assert {:ok, %{operation: %{state: :completed}}} =
             PullSyncWorker.process_operation(
               pending,
               pending.next_attempt_at,
               recovery_options
             )

    assert %{sync_version: 3, title: "Sent title", body: "Baseline body", state: :closed} =
             Repo.get!(ForgeIssues.Issue, newer_issue.id)

    assert_confirmed(ctx, operation, postcondition, 2)
  end

  test "a removed cross-repository head ref blocks inbound confirmation", ctx do
    now = DateTime.utc_now(:second)
    git!(ctx.head_path, ["update-ref", "-d", ctx.baseline["head_ref"]])

    target = Map.put(ctx.baseline, "title", "Untrusted inbound title")
    operation = remote_operation(ctx, now)
    expect_observation(ctx, target, now)

    assert {:ok,
            %{
              state: :pending,
              failure_class: "network",
              failure_detail: "required Git ref or commit is unavailable"
            }} =
             PullSyncWorker.process_operation(operation, now, options(ctx))

    assert %{title: "Baseline", sync_version: 1} = Repo.get!(ForgeIssues.Issue, ctx.issue.id)
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
  end

  test "a mismatched base ref blocks an outbound provider effect", ctx do
    now = DateTime.utc_now(:second)
    replacement = commit!(ctx.base_path, "replacement")
    git!(ctx.base_path, ["update-ref", ctx.baseline["base_ref"], replacement])

    issue =
      ctx.issue
      |> ForgeIssues.Issue.update_changeset(%{title: "Untrusted outbound title"})
      |> Repo.update!()

    operation = local_operation(ctx, issue.sync_version, now)
    expect_observation(ctx, ctx.baseline, @source_time)
    caller = self()

    result =
      PullSyncWorker.process_operation(
        operation,
        now,
        options(ctx,
          update_pull_issue: fn _, _, _, _, _, _ ->
            send(caller, :provider_effect)
            {:error, Error.new(:transport)}
          end
        )
      )

    assert {:ok,
            %{
              state: :pending,
              failure_class: "network",
              failure_detail: "required Git ref or commit is unavailable"
            }} = result

    refute_receive :provider_effect
    assert Repo.get!(MirrorResourceState, ctx.mapping.id).confirmed_snapshot == ctx.baseline
  end

  defp remote_operation(ctx, now) do
    ctx.organization
    |> operation_fixture(%{
      repository_mirror_id: ctx.base.id,
      kind: "sync.pull",
      cursor: %{
        "trigger" => "remote",
        "resource_kind" => "pull",
        "issue_kind" => "pull_request",
        "github_object_id" => 802,
        "github_number" => 7,
        "delivery_guid" => "pull-integration"
      },
      next_attempt_at: now
    })
    |> then(&claim(&1.id, now))
  end

  defp local_operation(ctx, sync_version, now) do
    ctx.organization
    |> operation_fixture(%{
      repository_mirror_id: ctx.base.id,
      kind: "sync.pull",
      cursor: %{
        "trigger" => "local",
        "resource_kind" => "pull",
        "issue_kind" => "pull_request",
        "issue_id" => ctx.issue.id,
        "repository_id" => ctx.base.repository_id,
        "sync_version" => sync_version,
        "outbox_event_id" => Ecto.UUID.generate()
      },
      next_attempt_at: now
    })
    |> then(&claim(&1.id, now))
  end

  defp claim(id, now) do
    {:ok, operations} =
      ForgeMirrors.claim_operations("pull-integration", now, 60, 100, ["sync.pull"])

    Enum.find(operations, &(&1.id == id)) || flunk("operation was not claimable")
  end

  defp options(ctx, overrides \\ []) do
    defaults = [
      token_fetch: fn id, _scope ->
        assert id == ctx.organization.github_installation_id

        %InstallationToken{
          token: "integration-token",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600),
          permissions: %{"metadata" => "read", "pull_requests" => "write"}
        }
      end,
      remote_relationships: fn _, _, _ ->
        {:ok, %{labels: [], assignees: [], author: nil}}
      end,
      get_pull: fn token, owner, repository, number, opts ->
        PullClient.get_pull(token, owner, repository, number, transport_options(ctx, opts))
      end,
      get_pull_issue: fn token, owner, repository, number, opts ->
        IssueClient.get_pull_issue(
          token,
          owner,
          repository,
          number,
          transport_options(ctx, opts)
        )
      end,
      update_pull_issue: fn token, owner, repository, number, attrs, opts ->
        IssueClient.update_pull_issue(
          token,
          owner,
          repository,
          number,
          attrs,
          transport_options(ctx, opts)
        )
      end,
      set_draft: fn token, node_id, desired, opts ->
        PullClient.set_draft(token, node_id, desired, transport_options(ctx, opts))
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp transport_options(ctx, opts) do
    Keyword.merge(opts,
      plug: {Req.Test, ctx.stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    )
  end

  defp expect_observation(ctx, snapshot, updated_at) do
    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/pulls/7"
      Req.Test.json(conn, pull_json(snapshot, updated_at))
    end)

    Req.Test.expect(ctx.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/acme/project/issues/7"
      Req.Test.json(conn, issue_json(snapshot, updated_at))
    end)
  end

  defp pull_json(snapshot, updated_at) do
    %{
      "id" => 802,
      "node_id" => "PR_802",
      "number" => 7,
      "title" => snapshot["title"],
      "body" => snapshot["body"],
      "state" => snapshot["state"],
      "draft" => snapshot["draft"],
      "user" => nil,
      "created_at" => DateTime.to_iso8601(@source_time),
      "updated_at" => DateTime.to_iso8601(updated_at),
      "closed_at" => nil,
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

  defp issue_json(snapshot, updated_at) do
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
      "created_at" => DateTime.to_iso8601(@source_time),
      "updated_at" => DateTime.to_iso8601(updated_at),
      "closed_at" => nil,
      "pull_request" => %{
        "url" => "https://api.github.com/repos/acme/project/pulls/7"
      }
    }
  end

  defp assert_confirmed(ctx, operation, snapshot, version) do
    assert %{state: :completed, external_effect_marker: nil} =
             Repo.get!(MirrorOperation, operation.id)

    mapping = Repo.get!(MirrorResourceState, ctx.mapping.id)
    assert mapping.state == :confirmed
    assert mapping.confirmed_snapshot == snapshot
    assert mapping.confirmed_local_version == version
    assert mapping.confirmed_merge_state == %{"merged_at" => nil, "merge_commit_sha" => nil}
    assert {:ok, mapping.confirmed_fingerprint} == ForgeMirrors.resource_fingerprint(snapshot)
  end

  defp initialize_branch!(repository_id, ref) do
    repository = Repo.get!(ForgeRepos.Repository, repository_id)

    repository =
      repository
      |> Ecto.Changeset.change(%{
        storage_path: "pull-sync-integration/#{Ecto.UUID.generate()}.git"
      })
      |> Repo.update!()

    path = ForgeRepos.absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, ^path} = GitCore.init_bare(path)
    oid = commit!(path, ref)
    git!(path, ["update-ref", ref, oid])
    {path, oid}
  end

  defp commit!(path, message) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    git!(path, ["commit-tree", tree, "-m", message])
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Pull Sync Test"},
      {"GIT_AUTHOR_EMAIL", "pull-sync@example.test"},
      {"GIT_COMMITTER_NAME", "Pull Sync Test"},
      {"GIT_COMMITTER_EMAIL", "pull-sync@example.test"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true)

    String.trim(output)
  end
end
