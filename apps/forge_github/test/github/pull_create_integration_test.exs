defmodule ForgeGitHub.PullCreateIntegrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeGitHub.{InstallationToken, PullSyncWorker}
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, MirrorResourceState, PullCreationIntent}
  alias ForgeMirrors.MirrorConflict

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base =
      repository_mirror_fixture(org, %{
        github_full_name: "acme/base",
        github_repository_id: 900,
        github_node_id: "R_900"
      })

    head =
      repository_mirror_fixture(org, %{
        github_full_name: "acme/head",
        github_repository_id: 901,
        github_node_id: "R_901"
      })

    {base_path, base_sha} = branch!(base.repository_id, "refs/heads/main")
    {head_path, head_sha} = branch!(head.repository_id, "refs/heads/feature")

    on_exit(fn ->
      File.rm_rf!(base_path)
      File.rm_rf!(head_path)
    end)

    actor = organization_owner_fixture(org)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 31,
        kind: :pull_request,
        title: "Outbound",
        body: "Original desired body",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        repository_id: base.repository_id,
        issue_id: issue.id,
        head_repository_id: head.repository_id,
        base_ref: "refs/heads/main",
        head_ref: "refs/heads/feature",
        base_sha: base_sha,
        head_sha: head_sha,
        draft: true
      })

    now = DateTime.utc_now(:second)

    for {binding, ref, oid} <- [{base, pull.base_ref, base_sha}, {head, pull.head_ref, head_sha}] do
      Repo.insert!(%MirrorRefState{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        state: :confirmed,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        last_confirmed_at: now
      })
    end

    event =
      %DomainOutboxEvent{}
      |> DomainOutboxEvent.record_changeset(%{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "issue",
        aggregate_id: to_string(issue.id),
        event_type: "issue.created",
        origin: :fornacast,
        payload: %{
          "repository_id" => base.repository_id,
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "issue_kind" => "pull_request",
          "sync_version" => issue.sync_version
        }
      })
      |> Repo.insert!()

    {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)
    stub = {__MODULE__, System.unique_integer([:positive])}

    options = [
      client_options: [
        plug: {Req.Test, stub},
        resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
      ],
      token_fetch: fn id, %{permissions: permissions} ->
        assert id == org.github_installation_id

        %InstallationToken{
          token: "integration-token",
          expires_at: DateTime.add(now, 3600),
          permissions: permissions
        }
      end
    ]

    %{
      org: org,
      base: base,
      head: head,
      issue: issue,
      pull: pull,
      now: now,
      operation: operation,
      stub: stub,
      options: options,
      base_path: base_path
    }
  end

  test "real intent, HTTP effects, local fences and paired mappings preserve a newer local edit",
       c do
    stub_provider(c)
    assert {:ok, _} = process(c)
    first = Repo.get!(MirrorOperation, c.operation.id)
    assert first.state == :effect_pending
    assert first.external_effect_marker["phase"] == "identified"
    assert Repo.aggregate(PullCreationIntent, :count) == 1
    assert Repo.aggregate(MirrorResourceState, :count) == 0
    assert Process.get(:create_posts) == 1

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [body: "Newer local body", sync_version: c.issue.sync_version + 1]
    )

    assert {:ok, _} = process(c)
    assert Repo.get!(MirrorOperation, c.operation.id).state == :completed
    assert Process.get(:create_posts) == 1
    assert Process.get(:create_patches) == 1
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).body == "Newer local body"

    mappings =
      Repo.all(from(m in MirrorResourceState, where: m.repository_mirror_id == ^c.base.id))

    assert Enum.sort(Enum.map(mappings, & &1.resource_kind)) == [:issue, :pull]

    assert Enum.all?(
             mappings,
             &(&1.github_number == 7 and &1.confirmed_local_version == c.issue.sync_version)
           )

    assert Enum.all?(mappings, &(&1.confirmed_snapshot["body"] == c.issue.body))
    assert Repo.aggregate(ForgeIssues.Issue, :count) == 1
    assert Repo.aggregate(ForgePulls.PullRequest, :count) == 1
  end

  test "missing assignee nodes seed across claims without another POST or metadata PATCH", c do
    identities =
      for id <- [4201, 4202] do
        {:ok, identity} =
          ForgeAccounts.observe_github_identity(%{id: id, login: "old-#{id}"}, c.now)

        Repo.insert!(%ForgeIssues.IssueAssignee{
          issue_id: c.issue.id,
          github_identity_id: identity.id
        })

        identity
      end

    stub_provider(c, seed_assignees: true)
    assert {:ok, _} = process(c)
    marked = Repo.get!(MirrorOperation, c.operation.id)
    intent = Repo.get_by!(PullCreationIntent, pull_id: c.pull.id)
    assert intent.payload["issue_snapshot"]["assignee_github_ids"] == [4201, 4202]

    for {identity, index} <- Enum.with_index(identities, 1) do
      assert {:ok, _} = process(c)
      saved = Repo.get!(MirrorOperation, c.operation.id)
      assert saved.state == :effect_pending and is_nil(saved.lease_owner)
      assert saved.external_effect_marker == marked.external_effect_marker
      assert saved.checkpoint == marked.checkpoint

      assert Repo.get!(ForgeAccounts.GitHubIdentity, identity.id).github_node_id ==
               "U_#{identity.github_user_id}"

      assert Process.get(:identity_gets) == index
      assert Process.get(:create_posts) == 1
      assert is_nil(Process.get(:create_patches))
      assert Repo.aggregate(MirrorResourceState, :count) == 0
    end

    assert {:ok, _} = process(c)
    assert Process.get(:relationship_queries) == 1
    assert Process.get(:identity_gets) == 2
    assert Process.get(:create_posts) == 1
    assert Process.get(:create_patches) == 1
    assert Process.get(:patched_assignees) == ["current-4201", "current-4202"]
    assert Repo.get!(MirrorOperation, c.operation.id).state == :completed
  end

  test "missing label node scans across claims and uses a fresh second rename for cleanup", c do
    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.base.repository_id,
        name: "old-label",
        normalized_name: "old-label",
        color: "abcdef"
      })

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})
    snapshot = %{"name" => label.name, "color" => label.color, "description" => nil}
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(snapshot)

    mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.base.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: label.id,
        github_object_id: 4301,
        state: :confirmed,
        confirmed_local_version: 1,
        confirmed_snapshot: snapshot,
        confirmed_fingerprint: fingerprint
      })

    stub_provider(c, seed_labels: true)
    assert {:ok, _} = process(c)
    marked = Repo.get!(MirrorOperation, c.operation.id)
    intent = Repo.get_by!(PullCreationIntent, pull_id: c.pull.id)
    assert intent.payload["issue_snapshot"]["label_github_ids"] == [4301]

    for page <- [1, 2] do
      assert {:ok, _} = process(c)
      saved = Repo.get!(MirrorOperation, c.operation.id)
      assert saved.state == :effect_pending and is_nil(saved.lease_owner)
      assert saved.external_effect_marker == marked.external_effect_marker

      assert saved.checkpoint["pull_creation_recovery"] ==
               marked.checkpoint["pull_creation_recovery"]

      assert Process.get(:label_pages) == Enum.to_list(1..page)
      assert Process.get(:create_posts) == 1
      assert is_nil(Process.get(:create_patches))
      current_mapping = Repo.get!(MirrorResourceState, mapping.id)
      assert current_mapping.github_node_id == if(page == 1, do: nil, else: "L_4301")
      assert current_mapping.confirmed_snapshot == snapshot
      assert current_mapping.confirmed_fingerprint == fingerprint
      assert current_mapping.confirmed_local_version == 1
      assert Repo.get!(ForgeIssues.Label, label.id).name == "old-label"
      assert Repo.aggregate(MirrorResourceState, :count) == 1
    end

    assert {:ok, _} = process(c)
    assert Process.get(:relationship_queries) == 1
    assert Process.get(:patched_labels) == ["current-label"]
    assert Process.get(:create_posts) == 1
    assert Process.get(:create_patches) == 1
    assert Repo.get!(MirrorOperation, c.operation.id).state == :completed

    assert Repo.get_by!(MirrorResourceState,
             repository_mirror_id: c.base.id,
             resource_kind: :issue
           ).confirmed_snapshot["label_github_ids"] == [4301]
  end

  test "exhausted label inventory becomes a visible conflict without cleanup or another scan",
       c do
    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.base.repository_id,
        name: "missing",
        normalized_name: "missing",
        color: "abcdef"
      })

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})
    snapshot = %{"name" => label.name, "color" => label.color, "description" => nil}
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(snapshot)

    mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.base.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: label.id,
        github_object_id: 4301,
        state: :confirmed,
        confirmed_local_version: 1,
        confirmed_snapshot: snapshot,
        confirmed_fingerprint: fingerprint
      })

    stub_provider(c, seed_labels: true, empty_labels: true)

    assert {:ok, _} = process(c)
    marker = Repo.get!(MirrorOperation, c.operation.id).external_effect_marker
    assert {:ok, _} = process(c)

    assert Repo.get!(MirrorOperation, c.operation.id).checkpoint["pull_creation_label_nodes"][
             "complete"
           ]

    assert {:ok, _} = process(c)
    failed = Repo.get!(MirrorOperation, c.operation.id)
    assert failed.state == :failed and failed.failure_disposition == :conflict
    assert failed.checkpoint["conflicted_effect_marker"] == marker
    conflict = Repo.get_by!(MirrorConflict, repository_mirror_id: c.base.id)
    assert conflict.remote_snapshot["reason"] == "missing_labels"
    assert conflict.remote_snapshot["missing_label_github_ids"] == [4301]
    assert Process.get(:label_pages) == [1]
    assert Process.get(:create_posts) == 1
    assert is_nil(Process.get(:create_patches))
    assert is_nil(Process.get(:relationship_queries))
    assert Repo.get!(MirrorResourceState, mapping.id).confirmed_snapshot == snapshot
    assert Repo.aggregate(MirrorResourceState, :count) == 1
  end

  test "missing live local ref prevents intent and provider POST", c do
    git!(c.base_path, ["update-ref", "-d", c.pull.base_ref])
    stub_provider(c)
    _result = process(c)
    assert Repo.aggregate(PullCreationIntent, :count) == 0
    assert is_nil(Process.get(:create_posts))
    assert Repo.aggregate(MirrorResourceState, :count) == 0
  end

  test "lost create response recovers across claims without another POST", c do
    stub_provider(c, ambiguous_create: true)
    assert {:ok, _} = process(c)
    pending = Repo.get!(MirrorOperation, c.operation.id)
    assert pending.external_effect_marker["phase"] == "unresolved"
    assert Process.get(:create_posts) == 1

    assert {:ok, _} = process(c, 31)
    scanned = Repo.get!(MirrorOperation, c.operation.id)
    assert scanned.checkpoint["pull_creation_recovery"]["complete"]
    assert scanned.checkpoint["pull_creation_recovery"]["candidate"]["github_object_id"] == 700
    assert {:ok, _} = process(c, 32)

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker["phase"] ==
             "identified"

    assert {:ok, _} = process(c, 33)
    assert Repo.get!(MirrorOperation, c.operation.id).state == :completed
    assert Process.get(:create_posts) == 1
    assert Process.get(:create_patches) == 1
    assert Repo.aggregate(PullCreationIntent, :count) == 1
    assert Repo.aggregate(MirrorResourceState, :count) == 2
  end

  test "an empty completed recovery scan becomes a visible conflict and retains creation evidence",
       c do
    stub_provider(c, ambiguous_create: true, empty_scan: true)
    assert {:ok, _} = process(c)
    marker = Repo.get!(MirrorOperation, c.operation.id).external_effect_marker
    assert {:ok, _} = process(c, 31)
    assert {:ok, _} = process(c, 32)
    failed = Repo.get!(MirrorOperation, c.operation.id)
    assert failed.state == :failed
    assert failed.failure_disposition == :conflict
    assert failed.checkpoint["conflicted_effect_marker"] == marker
    assert failed.checkpoint["pull_creation_recovery"]["complete"]
    conflict = Repo.get_by!(MirrorConflict, repository_mirror_id: c.base.id)
    assert conflict.state == :open
    assert conflict.remote_snapshot["reason"] == "zero_complete_scan"
    assert Process.get(:create_posts) == 1
    assert is_nil(Process.get(:create_patches))
    assert Repo.aggregate(PullCreationIntent, :count) == 1
    assert Repo.aggregate(MirrorResourceState, :count) == 0
  end

  defp process(c, offset \\ 0) do
    now = DateTime.add(DateTime.utc_now(:second), offset)

    {:ok, operations} =
      ForgeMirrors.claim_operations("create-integration", now, 120, 100, ["sync.pull"])

    operation =
      Enum.find(operations, &(&1.id == c.operation.id)) || flunk("creation is not claimable")

    PullSyncWorker.process_operation(operation, now, c.options)
  end

  defp stub_provider(c, options \\ []) do
    Req.Test.stub(c.stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/graphql"} ->
          labels? = Keyword.get(options, :seed_labels, false)
          assert labels? or Keyword.get(options, :seed_assignees, false)
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert JSON.decode!(body)["variables"] == %{
                   "labels" => if(labels?, do: ["L_4301"], else: []),
                   "assignees" => if(labels?, do: [], else: ["U_4201", "U_4202"])
                 }

          Process.put(:relationship_queries, Process.get(:relationship_queries, 0) + 1)

          Req.Test.json(conn, %{
            "data" => %{
              "labels" =>
                if(labels?,
                  do: [
                    %{
                      "__typename" => "Label",
                      "id" => "L_4301",
                      "name" => "current-label",
                      "repository" => %{"id" => "R_900"}
                    }
                  ],
                  else: []
                ),
              "assignees" =>
                Enum.map(if(labels?, do: [], else: [4201, 4202]), fn id ->
                  %{"__typename" => "User", "id" => "U_#{id}", "login" => "current-#{id}"}
                end)
            }
          })

        {"GET", "/repos/acme/base/labels"} ->
          assert Keyword.get(options, :seed_labels, false)
          query = URI.decode_query(conn.query_string)
          assert query["per_page"] == "100"
          page = String.to_integer(query["page"])
          Process.put(:label_pages, Process.get(:label_pages, []) ++ [page])

          case {Keyword.get(options, :empty_labels, false), page} do
            {true, 1} ->
              Req.Test.json(conn, [])

            {false, 1} ->
              conn
              |> Plug.Conn.put_resp_header(
                "link",
                "<https://api.github.com/repos/acme/base/labels?page=2&per_page=100>; rel=\"next\""
              )
              |> Req.Test.json([
                %{
                  "id" => 4399,
                  "node_id" => "L_4399",
                  "name" => "unrelated",
                  "color" => "abcdef",
                  "description" => nil
                }
              ])

            {false, 2} ->
              Req.Test.json(conn, [
                %{
                  "id" => 4301,
                  "node_id" => "L_4301",
                  "name" => "renamed-label",
                  "color" => "abcdef",
                  "description" => nil
                }
              ])

            _ ->
              flunk("unexpected label page #{page}")
          end

        {"GET", "/user/" <> id} ->
          assert Keyword.get(options, :seed_assignees, false)
          Process.put(:identity_gets, Process.get(:identity_gets, 0) + 1)

          Req.Test.json(conn, %{
            "id" => String.to_integer(id),
            "node_id" => "U_#{id}",
            "login" => "renamed-#{id}"
          })

        {"GET", "/repos/acme/base"} ->
          Req.Test.json(conn, repository(c.base))

        {"GET", "/repos/acme/head"} ->
          Req.Test.json(conn, repository(c.head))

        {"GET", "/repos/acme/base/git/ref/heads/main"} ->
          Req.Test.json(conn, reference(c.pull.base_ref, c.pull.base_sha))

        {"GET", "/repos/acme/head/git/ref/heads/feature"} ->
          Req.Test.json(conn, reference(c.pull.head_ref, c.pull.head_sha))

        {"POST", "/repos/acme/base/pulls"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          attrs = JSON.decode!(body)
          Process.put(:create_body, attrs["body"])
          Process.put(:create_posts, Process.get(:create_posts, 0) + 1)

          if Keyword.get(options, :ambiguous_create, false),
            do: Plug.Conn.send_resp(conn, 503, "response lost after provider creation"),
            else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(pull(c))

        {"PATCH", "/repos/acme/base/issues/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          attrs = JSON.decode!(body)
          Process.put(:create_body, attrs["body"])
          Process.put(:create_patches, Process.get(:create_patches, 0) + 1)
          Process.put(:patched_assignees, attrs["assignees"])
          Process.put(:patched_labels, attrs["labels"])

          Process.put(
            :create_labels,
            Enum.map(attrs["labels"] || [], fn name ->
              %{"id" => 4301, "node_id" => "L_4301", "name" => name}
            end)
          )

          Process.put(
            :create_assignees,
            Enum.map(attrs["assignees"] || [], fn login ->
              id = login |> String.split("-") |> List.last() |> String.to_integer()
              %{"id" => id, "node_id" => "U_#{id}", "login" => login}
            end)
          )

          Req.Test.json(conn, issue(c))

        {"GET", "/repos/acme/base/pulls/7"} ->
          Req.Test.json(conn, pull(c))

        {"GET", "/repos/acme/base/pulls"} ->
          Req.Test.json(
            conn,
            if(Keyword.get(options, :empty_scan, false), do: [], else: [pull(c)])
          )

        {"GET", "/repos/acme/base/issues/7"} ->
          Req.Test.json(conn, issue(c))

        other ->
          flunk("unexpected provider request #{inspect(other)}")
      end
    end)
  end

  defp pull(c),
    do: %{
      "id" => 700,
      "node_id" => "PR_700",
      "number" => 7,
      "title" => c.issue.title,
      "body" => Process.get(:create_body),
      "state" => "open",
      "draft" => true,
      "user" => user(),
      "created_at" => "2026-09-08T00:00:00Z",
      "updated_at" => "2026-09-08T00:00:01Z",
      "closed_at" => nil,
      "merged_at" => nil,
      "merge_commit_sha" => nil,
      "merged" => false,
      "mergeable" => true,
      "rebaseable" => true,
      "mergeable_state" => "clean",
      "base" => %{
        "ref" => "main",
        "sha" => c.pull.base_sha,
        "repo" => %{"id" => 900, "node_id" => "R_900", "full_name" => "acme/base"}
      },
      "head" => %{
        "ref" => "feature",
        "sha" => c.pull.head_sha,
        "repo" => %{"id" => 901, "node_id" => "R_901", "full_name" => "acme/head"}
      }
    }

  defp issue(c),
    do: %{
      "id" => 800,
      "node_id" => "I_800",
      "number" => 7,
      "title" => c.issue.title,
      "body" => Process.get(:create_body),
      "state" => "open",
      "state_reason" => nil,
      "labels" => Process.get(:create_labels, []),
      "assignees" => Process.get(:create_assignees, []),
      "user" => user(),
      "closed_at" => nil,
      "created_at" => "2026-09-08T00:00:00Z",
      "updated_at" => "2026-09-08T00:00:01Z",
      "pull_request" => %{
        "url" => "https://api.github.com/repos/acme/base/pulls/7",
        "html_url" => "https://github.com/acme/base/pull/7",
        "diff_url" => "https://github.com/acme/base/pull/7.diff",
        "patch_url" => "https://github.com/acme/base/pull/7.patch"
      }
    }

  defp repository(binding) do
    [owner, name] = String.split(binding.github_full_name, "/")

    %{
      "id" => binding.github_repository_id,
      "node_id" => binding.github_node_id,
      "owner" => %{"id" => 12, "login" => owner},
      "name" => name,
      "full_name" => binding.github_full_name,
      "description" => nil,
      "visibility" => "private",
      "default_branch" => "main",
      "has_issues" => true,
      "allow_merge_commit" => true,
      "fork" => false,
      "archived" => false,
      "html_url" => "https://github.com/#{binding.github_full_name}",
      "updated_at" => "2026-09-08T00:00:00Z",
      "pushed_at" => "2026-09-08T00:00:00Z"
    }
  end

  defp reference(ref, oid),
    do: %{"ref" => ref, "node_id" => "REF_test", "object" => %{"type" => "commit", "sha" => oid}}

  defp user, do: %{"id" => 99, "node_id" => "U_99", "login" => "octocat"}

  defp branch!(id, ref) do
    repository =
      Repo.get!(ForgeRepos.Repository, id)
      |> Ecto.Changeset.change(
        storage_path: "pull-create-integration/#{Ecto.UUID.generate()}.git"
      )
      |> Repo.update!()

    path = ForgeRepos.absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, ^path} = GitCore.init_bare(path)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    oid = git!(path, ["commit-tree", tree, "-m", ref])
    git!(path, ["update-ref", ref, oid])
    {path, oid}
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Create Test"},
      {"GIT_AUTHOR_EMAIL", "create@example.test"},
      {"GIT_COMMITTER_NAME", "Create Test"},
      {"GIT_COMMITTER_EMAIL", "create@example.test"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true)

    String.trim(output)
  end
end
