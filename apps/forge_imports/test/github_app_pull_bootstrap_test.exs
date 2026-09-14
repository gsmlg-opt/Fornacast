defmodule ForgeImports.GitHubAppPullBootstrapTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.{Changeset, Multi}
  alias ForgeGitHub.{InstallationToken, InstallationTokenBroker}
  alias ForgeImports.GitHub.MetadataImporter

  alias ForgeImports.{
    ImportAttempt,
    ObjectMapping,
    PageCheckpoint,
    Persistence,
    RepositoryItem,
    RepositoryWorker
  }

  alias ForgeMirrors.MirrorResourceState
  alias ForgeReleases.Release
  alias Fornacast.Repo

  @scope %{permissions: %{"contents" => "read", "issues" => "read", "pull_requests" => "read"}}
  @fixtures Path.join(__DIR__, "fixtures/github")

  @tag :tmp_dir
  test "installation checkout imports and publishes full multibyte pull bodies", %{
    tmp_dir: tmp_dir
  } do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)

    suffix = System.unique_integer([:positive])
    now = DateTime.utc_now(:second)

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "app-pull-#{suffix}",
        email: "app-pull-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, organization} =
      ForgeAccounts.create_organization(
        actor,
        %{username: "app-pull-org-#{suffix}", display_name: "App pull bootstrap"}
      )

    installation_id = 9_700_000_000 + suffix
    account_id = 9_800_000_000 + suffix

    {:ok, _} =
      ForgeMirrors.observe_github_app_installation(%{
        github_installation_id: installation_id,
        github_account_id: account_id,
        github_account_login: "octocat",
        account_type: :organization,
        repository_selection: :all,
        permissions: @scope.permissions,
        state: :active,
        last_verified_at: now
      })

    {:ok, run} =
      Persistence.insert_run(%{
        actor_user_id: actor.id,
        source_kind: :organization,
        credential_source: :github_app,
        source_owner_github_id: account_id,
        source_owner_login: "octocat",
        destination_organization_action: :existing,
        destination_organization_id: organization.id,
        destination_organization_slug: organization.username,
        destination_organization_status: :clean,
        selected_count: 1,
        state: :running,
        request_metadata: %{}
      })

    {:ok, mirror} =
      ForgeMirrors.create_organization_mirror(actor, %{
        organization_id: organization.id,
        provider: "github",
        github_installation_id: installation_id,
        github_account_id: account_id,
        github_account_login: "octocat",
        bootstrap_import_run_id: run.id
      })

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(actor, mirror, :ready_to_bootstrap)

    {:ok, mirror} =
      ForgeMirrors.update_organization_mirror(actor, mirror, %{
        capabilities: %{
          "git" => "enabled",
          "issues" => "enabled",
          "pulls" => "enabled",
          "releases" => "enabled"
        }
      })

    {:ok, mirror} = ForgeMirrors.transition_organization_mirror(actor, mirror, :bootstrapping)

    {:ok, binding} =
      ForgeMirrors.bind_repository(actor, %{
        organization_mirror_id: mirror.id,
        github_repository_id: 1_296_269,
        github_node_id: "R_repo",
        github_full_name: "octocat/Hello-World"
      })

    {item, shadow, base, head} = staged_item(run, organization, now)
    body = String.duplicate("😀", 65_536)

    pull =
      fixture("pull_same_repo.json")
      |> Map.merge(%{
        "node_id" => "PR_app_pull",
        "body" => body,
        "state" => "open",
        "merged" => false,
        "merged_at" => nil,
        "merged_by" => nil,
        "merge_commit_sha" => nil,
        "closed_at" => nil
      })
      |> put_in(["base", "sha"], base)
      |> put_in(["head", "sha"], head)

    pull =
      Enum.reduce(["base", "head"], pull, fn side, payload ->
        update_in(payload, [side, "repo"], fn repository ->
          Map.merge(repository, %{
            "node_id" => "R_repo",
            "full_name" => "octocat/Hello-World",
            "owner" => %{"id" => account_id, "login" => "octocat"}
          })
        end)
      end)

    issue =
      fixture("issues_page.json")
      |> hd()
      |> Map.merge(%{
        "id" => 302,
        "node_id" => "I_app_pull",
        "number" => 7,
        "title" => pull["title"],
        "body" => body,
        "state" => "open",
        "state_reason" => nil,
        "created_at" => pull["created_at"],
        "updated_at" => pull["updated_at"],
        "closed_at" => nil,
        "labels" => [],
        "assignees" => [],
        "pull_request" => %{"url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"}
      })

    release = %{
      "id" => 501,
      "node_id" => "RE_bootstrap",
      "url" => "https://api.github.com/repos/octocat/Hello-World/releases/501",
      "tag_name" => "v1.0.0",
      "name" => "Version 1",
      "body" => "Release notes",
      "draft" => false,
      "prerelease" => false,
      "target_commitish" => "main",
      "published_at" => "2026-08-28T00:00:00Z",
      "created_at" => "2026-08-27T00:00:00Z",
      "updated_at" => "2026-08-28T00:00:00Z",
      "author" => %{"id" => account_id, "node_id" => "U_release", "login" => "octocat"},
      "assets" => []
    }

    stub = {__MODULE__, suffix}
    parent = self()

    Req.Test.stub(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer app-pull-test-token"]
      send(parent, {:app_request, conn.request_path})

      case conn.request_path do
        "/repos/octocat/Hello-World/labels" ->
          Req.Test.json(conn, [])

        "/repos/octocat/Hello-World/issues" ->
          Req.Test.json(conn, [issue])

        "/repos/octocat/Hello-World/issues/7" ->
          Req.Test.json(conn, issue)

        "/repos/octocat/Hello-World/issues/7/comments" ->
          Req.Test.json(conn, [])

        "/repos/octocat/Hello-World/pulls/7" ->
          Req.Test.json(conn, pull)

        "/repos/octocat/Hello-World/releases" ->
          case conn.query_string |> URI.decode_query() |> Map.fetch!("page") do
            "1" ->
              Repo.update_all(
                from(candidate in RepositoryItem, where: candidate.id == ^item.id),
                set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), 10)]
              )

              conn
              |> Plug.Conn.put_resp_header(
                "link",
                "<https://api.github.com/repos/octocat/Hello-World/releases?page=2&per_page=100>; rel=\"next\""
              )
              |> Req.Test.json([release])

            "2" ->
              Req.Test.json(conn, [])
          end

        _ ->
          Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)

    broker =
      broker(
        fn fetched_id, scope ->
          send(parent, {:installation_checkout, fetched_id, scope})

          %InstallationToken{
            token: "app-pull-test-token",
            expires_at: DateTime.add(now, 3_600),
            permissions: @scope.permissions
          }
        end,
        suffix
      )

    result =
      RepositoryWorker.stage(item.id,
        owner: "app-pull-bootstrap",
        lease_seconds: 60,
        token_broker: broker,
        token_scope: @scope,
        client_options: [
          plug: {Req.Test, stub},
          resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
        ]
      )

    assert {:ok, %RepositoryItem{state: :ready_to_publish} = ready} = result

    assert_receive {:installation_checkout, ^installation_id, @scope}
    assert_receive {:app_request, "/repos/octocat/Hello-World/pulls/7"}
    assert_receive {:app_request, "/repos/octocat/Hello-World/issues/7"}

    mapping =
      Repo.get_by!(ObjectMapping, repository_item_id: item.id, object_kind: "pull_request")

    local = Repo.get_by!(ForgeIssues.Issue, repository_id: shadow.id, number: 7)
    assert local.body == body
    assert mapping.source_evidence["github_issue_object_id"] == 302
    refute inspect(mapping.source_evidence) =~ "app-pull-test-token"

    assert {:ok, buffered_release, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(
               %{
                 organization_mirror_id: nil,
                 delivery_guid: Ecto.UUID.generate(),
                 hook_id: System.unique_integer([:positive, :monotonic]),
                 event: "release",
                 action: "edited",
                 installation_id: installation_id,
                 github_repository_id: item.github_repository_id,
                 signature_version: "sha256",
                 raw_payload: JSON.encode!(%{"action" => "edited"})
               },
               :pending_unsupported
             )

    assert {:ok, %{repository: published}} =
             ForgeImports.publish_repository(actor, ready.id, %{
               "request_id" => "app-pull-publish-#{suffix}",
               "user_agent" => "app-pull-test",
               "ip_address" => "127.0.0.1"
             })

    assert published.id == shadow.id

    pull_state =
      Repo.get_by!(MirrorResourceState, repository_mirror_id: binding.id, resource_kind: :pull)

    issue_state =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: binding.id,
        resource_kind: :issue,
        local_resource_id: local.id
      )

    assert pull_state.confirmed_snapshot["body"] == body
    assert issue_state.confirmed_snapshot["body"] == body
    assert pull_state.provider_identity["github_issue_object_id"] == issue_state.github_object_id
    assert pull_state.confirmed_local_version == local.sync_version
    assert pull_state.state == :confirmed

    imported_release = Repo.get_by!(Release, repository_id: shadow.id, tag_name: "v1.0.0")

    release_state =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: binding.id,
        resource_kind: :release,
        local_resource_id: imported_release.id
      )

    assert release_state.state == :pending
    assert release_state.github_object_id == 501
    assert release_state.github_node_id == "RE_bootstrap"
    assert release_state.provider_identity == nil
    assert release_state.confirmed_local_version == nil
    assert release_state.confirmed_remote_updated_at == nil
    assert release_state.confirmed_fingerprint == nil
    assert release_state.confirmed_snapshot == nil

    assert %{state: :pending, organization_mirror_id: organization_mirror_id} =
             Repo.get!(ForgeMirrors.MirrorWebhookDelivery, buffered_release.id)

    assert organization_mirror_id == mirror.id
  end

  @tag :tmp_dir
  test "disabled release capability skips bootstrap release requests and data", %{
    tmp_dir: tmp_dir
  } do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)

    suffix = System.unique_integer([:positive])
    now = DateTime.utc_now(:second)

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "app-release-disabled-#{suffix}",
        email: "app-release-disabled-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, organization} =
      ForgeAccounts.create_organization(
        actor,
        %{username: "app-release-disabled-org-#{suffix}", display_name: "Disabled release import"}
      )

    installation_id = 9_710_000_000 + suffix
    account_id = 9_810_000_000 + suffix

    {:ok, run} =
      Persistence.insert_run(%{
        actor_user_id: actor.id,
        source_kind: :organization,
        credential_source: :github_app,
        source_owner_github_id: account_id,
        source_owner_login: "octocat",
        destination_organization_action: :existing,
        destination_organization_id: organization.id,
        destination_organization_slug: organization.username,
        destination_organization_status: :clean,
        selected_count: 1,
        state: :running,
        request_metadata: %{}
      })

    {:ok, mirror} =
      ForgeMirrors.create_organization_mirror(actor, %{
        organization_id: organization.id,
        provider: "github",
        github_installation_id: installation_id,
        github_account_id: account_id,
        github_account_login: "octocat",
        bootstrap_import_run_id: run.id
      })

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(actor, mirror, :ready_to_bootstrap)

    {:ok, mirror} =
      ForgeMirrors.update_organization_mirror(actor, mirror, %{
        capabilities: %{"git" => "enabled", "issues" => "enabled", "pulls" => "enabled"}
      })

    {:ok, mirror} = ForgeMirrors.transition_organization_mirror(actor, mirror, :bootstrapping)

    {:ok, _binding} =
      ForgeMirrors.bind_repository(actor, %{
        organization_mirror_id: mirror.id,
        github_repository_id: 1_296_269,
        github_node_id: "R_disabled_release",
        github_full_name: "octocat/Hello-World"
      })

    {item, shadow, _base, _head} = staged_item(run, organization, now)
    stub = {__MODULE__, "disabled-release-#{suffix}"}

    Req.Test.stub(stub, fn _conn ->
      flunk("disabled release capability must not issue a GitHub request")
    end)

    assert :ok =
             MetadataImporter.stage_phase(item, :releases,
               credential_checkout: fn _callback ->
                 flunk("disabled release capability must not check out a credential")
               end,
               client_options: [
                 plug: {Req.Test, stub},
                 resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
               ]
             )

    assert Repo.get_by!(PageCheckpoint,
             repository_item_id: item.id,
             resource_kind: "releases",
             page_key: "__terminal_v1__"
           )

    refute Repo.get_by(Release, repository_id: shadow.id)
  end

  defp staged_item(run, organization, now) do
    {:ok, item} =
      Persistence.insert_repository_item(%{
        import_run_id: run.id,
        github_repository_id: 1_296_269,
        source_full_name: "octocat/Hello-World",
        source_name: "Hello-World",
        source_observed_at: now,
        selected: true,
        destination_owner_id: organization.id,
        destination_slug: "hello-world",
        destination_visibility: :private,
        state: :queued,
        attempt_count: 1,
        source_metadata: %{
          "default_branch" => "main",
          "visibility" => "private",
          "description" => nil,
          "has_issues" => true,
          "allow_merge_commit" => true,
          "fork" => false,
          "archived" => false
        }
      })

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, organization.id, %{
        item_id: item.id,
        generation: 1
      })
      |> Repo.transaction()

    path = ForgeRepos.absolute_storage_path(shadow)
    File.mkdir_p!(Path.dirname(path))
    {:ok, ^path} = GitCore.init_bare(path)
    tree = git(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git(path, ["commit-tree", tree, "-m", "base"])
    head = git(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    git(path, ["update-ref", "refs/heads/main", base])
    git(path, ["update-ref", "refs/heads/feature", head])
    git(path, ["update-ref", "refs/tags/v1.0.0", base])

    item =
      item
      |> Changeset.change(
        state: :git_staged,
        hidden_repository_id: shadow.id,
        staged_storage_path: path,
        source_git: %{
          "empty" => false,
          "default_branch" => "main",
          "refs" => 2,
          "bytes" => 512,
          "lfs_detected" => false,
          "submodules_detected" => false,
          "scan_truncated" => false
        },
        checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"}
      )
      |> Repo.update!()

    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: now
    })
    |> Repo.insert!()

    {item, shadow, base, head}
  end

  defp broker(fetcher, suffix) do
    supervisor =
      start_supervised!({Task.Supervisor, name: Module.concat(__MODULE__, "Tasks#{suffix}")})

    name = Module.concat(__MODULE__, "Broker#{suffix}")

    start_supervised!(%{
      id: name,
      start:
        {InstallationTokenBroker, :start_link,
         [[name: name, task_supervisor: supervisor, fetcher: fetcher]]}
    })
  end

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp git(path, args) do
    {output, 0} =
      System.cmd(
        "git",
        [
          "--git-dir=#{path}",
          "-c",
          "user.name=App Bootstrap",
          "-c",
          "user.email=app-bootstrap@example.test" | args
        ],
        stderr_to_stdout: true
      )

    String.trim(output)
  end
end
