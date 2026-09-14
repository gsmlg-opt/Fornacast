defmodule FornacastAPI.PullMergeIntegrationTest do
  use FornacastAPI.ConnCase, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures
  import Ecto.Query

  alias Ecto.Changeset
  alias ForgeGitHub.{InstallationToken, IssueClient, PullClient, PullMergeWorker}
  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest}
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, MirrorResourceState}
  alias ForgeRepos.Repository
  alias Fornacast.AuditEvent

  @user_agent "fornacast-pull-merge-integration/1.0"

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: tmp_dir} do
    share_database!()

    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      try do
        unless postgres?() do
          Repo.delete_all(MergeOperation)
          Repo.delete_all(PullRequest)
        end
      after
        Application.put_env(:fornacast, :repo_storage_root, previous_root)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "a pull merged through the API is observable through smart HTTP", %{tmp_dir: tmp_dir} do
    owner = user("merge-owner")
    repository = repository(owner, "mergeable")
    fixture = divergent_repository!(repository, tmp_dir, :mergeable)
    {_key, secret} = pat(owner, ["public_repo"])
    previous_pushed_at = ~U[2000-01-01 00:00:00Z]

    repository
    |> Ecto.Changeset.change(last_pushed_at: previous_pushed_at)
    |> Repo.update!()

    created = create_pull(secret, owner, repository, "Merge feature")
    expected_head = created["head"]["sha"]
    assert expected_head == fixture.head_oid

    merged =
      api_conn(secret)
      |> put_json(pull_path(owner, repository, created["number"]) <> "/merge", %{
        "sha" => expected_head,
        "merge_method" => "merge"
      })
      |> json_response(200)

    assert %{
             "merged" => true,
             "message" => "Pull Request successfully merged",
             "sha" => merge_oid
           } = merged

    assert byte_size(merge_oid) == 40
    assert exact_ref(repository, "main") == merge_oid

    clone_path = Path.join(tmp_dir, "http-clone")
    port = start_git_http_server()

    git!([
      "clone",
      "--branch",
      "main",
      "http://127.0.0.1:#{port}/#{owner.username}/#{repository.slug}.git",
      clone_path
    ])

    assert git!(["-C", clone_path, "rev-parse", "HEAD"]) == merge_oid

    assert [^merge_oid, first_parent, second_parent] =
             clone_path
             |> git_commit_parents!(merge_oid)
             |> String.split()

    assert first_parent == fixture.base_oid
    assert second_parent == fixture.head_oid
    assert File.read!(Path.join(clone_path, "base.txt")) == "base\n"
    assert File.read!(Path.join(clone_path, "feature.txt")) == "feature\n"

    assert %Repository{last_pushed_at: %DateTime{} = pushed_at} =
             Repo.get!(Repository, repository.id)

    assert DateTime.after?(pushed_at, previous_pushed_at)
    assert %Issue{state: :closed, state_reason: :completed} = pull_issue!(repository, created)

    pull_body =
      api_conn(secret)
      |> get(pull_path(owner, repository, created["number"]))
      |> json_response(200)

    issue_body =
      api_conn(secret)
      |> get(issue_path(owner, repository, created["number"]))
      |> json_response(200)

    assert is_binary(pull_body["merged_at"])
    assert issue_body["pull_request"]["merged_at"] == pull_body["merged_at"]
  end

  @tag :tmp_dir
  test "a stale expected head leaves the base unchanged and returns no merge SHA", %{
    tmp_dir: tmp_dir
  } do
    owner = user("stale-owner")
    repository = repository(owner, "stale-head")
    fixture = divergent_repository!(repository, tmp_dir, :mergeable)
    {_key, secret} = pat(owner, ["public_repo"])
    created = create_pull(secret, owner, repository, "Stale head")
    expected_head = created["head"]["sha"]

    moved_head = advance_feature!(fixture.work_path)
    refute moved_head == expected_head

    response =
      api_conn(secret)
      |> put_json(pull_path(owner, repository, created["number"]) <> "/merge", %{
        "sha" => expected_head,
        "merge_method" => "merge"
      })

    body = json_response(response, 409)
    assert body["message"] == "Conflict"
    refute Map.has_key?(body, "sha")
    assert exact_ref(repository, "main") == fixture.base_oid
    assert Repo.get!(Repository, repository.id).last_pushed_at == nil
    assert %Issue{state: :open} = pull_issue!(repository, created)
    refute_merge_success!(repository, created)
  end

  @tag :tmp_dir
  test "a content conflict leaves the base unchanged and returns no merge SHA", %{
    tmp_dir: tmp_dir
  } do
    owner = user("conflict-owner")
    repository = repository(owner, "content-conflict")
    fixture = divergent_repository!(repository, tmp_dir, :conflict)
    {_key, secret} = pat(owner, ["public_repo"])
    created = create_pull(secret, owner, repository, "Conflicting change")

    response =
      api_conn(secret)
      |> put_json(pull_path(owner, repository, created["number"]) <> "/merge", %{
        "sha" => created["head"]["sha"],
        "merge_method" => "merge"
      })

    body = json_response(response, 405)
    assert body["message"] == "Pull Request is not mergeable"
    refute Map.has_key?(body, "sha")
    assert exact_ref(repository, "main") == fixture.base_oid
    assert Repo.get!(Repository, repository.id).last_pushed_at == nil
    assert %Issue{state: :open} = pull_issue!(repository, created)
    refute_merge_success!(repository, created)
  end

  @tag :tmp_dir
  test "a represented cross-repository merge survives an uncertain push and worker restart", %{
    tmp_dir: tmp_dir
  } do
    fixture = represented_cross_repository_pull!(tmp_dir)
    {_key, secret} = pat(fixture.actor, ["repo"])
    stub = {__MODULE__, System.unique_integer([:positive])}
    {:ok, provider} = Agent.start_link(fn -> %{merge_oid: nil, push_count: 0} end)
    Req.Test.stub(stub, &provider_response(&1, fixture, provider))

    worker_options = merge_worker_options(fixture, provider, stub, self())
    start_merge_worker!(worker_options, "api-cross-merge-first")

    merge_task =
      Task.async(fn ->
        api_conn(secret)
        |> put_json(pull_path(fixture.owner, fixture.base_repository, 7) <> "/merge", %{
          "sha" => fixture.head_oid,
          "merge_method" => "merge"
        })
      end)

    assert_receive {:provider_push, merge_oid}, 10_000
    assert remote_ref(fixture.provider_base_path, "refs/heads/main") == merge_oid
    assert remote_ref(fixture.provider_head_path, "refs/heads/feature/api") == fixture.head_oid
    assert eventually(fn -> pending_merge_released?(fixture.pull.id, merge_oid) end)

    stop_merge_worker!()
    start_merge_worker!(worker_options, "api-cross-merge-recovery")

    merged = merge_task |> Task.await(20_000) |> json_response(200)

    assert merged == %{
             "merged" => true,
             "message" => "Pull Request successfully merged",
             "sha" => merge_oid
           }

    assert Agent.get(provider, & &1.push_count) == 1
    assert exact_ref(fixture.base_repository, "main") == merge_oid
    assert exact_ref(fixture.head_repository, "feature/api") == fixture.head_oid
    assert remote_ref(fixture.provider_base_path, "refs/heads/main") == merge_oid
    assert remote_ref(fixture.provider_head_path, "refs/heads/feature/api") == fixture.head_oid

    assert [^merge_oid, first_parent, second_parent] =
             fixture.base_path
             |> git_commit_parents!(merge_oid)
             |> String.split()

    assert first_parent == fixture.base_oid
    assert second_parent == fixture.head_oid

    local_pull =
      api_conn(secret, "2022-11-28")
      |> get(pull_path(fixture.owner, fixture.base_repository, 7))
      |> json_response(200)

    assert local_pull["merge_commit_sha"] == merge_oid
    assert is_binary(local_pull["merged_at"])

    provider_options = provider_client_options(fixture, stub)

    assert {:ok, %{"merged" => true, "merge_commit_sha" => ^merge_oid}} =
             PullClient.get_pull(
               "api-cross-merge-credential",
               "acme",
               "api-cross-base",
               7,
               provider_options
             )

    assert {:ok, %{"state" => "closed"}} =
             IssueClient.get_pull_issue(
               "api-cross-merge-credential",
               "acme",
               "api-cross-base",
               7,
               provider_options
             )

    pull = Repo.get!(PullRequest, fixture.pull.id)
    issue = Repo.get!(Issue, fixture.issue.id)

    operation =
      Repo.get_by!(MirrorOperation,
        kind: "merge.pull",
        cursor: %{"pull_id" => pull.id, "issue_id" => issue.id}
      )

    intent = Repo.get_by!(MergeOperation, coordinator_operation_id: operation.id)

    assert pull.merge_commit_sha == merge_oid
    assert %DateTime{} = pull.merged_at
    assert issue.state == :closed
    assert issue.state_reason == :completed
    assert operation.state == :completed
    assert operation.external_effect_marker == nil
    assert intent.state == :completed
    assert intent.merge_oid == merge_oid

    pull_mapping =
      Repo.get_by!(MirrorResourceState,
        repository_mirror_id: fixture.base_binding.id,
        resource_kind: :pull,
        local_resource_id: pull.id
      )

    assert pull_mapping.confirmed_snapshot["base_sha"] == merge_oid
    assert pull_mapping.confirmed_merge_state["merge_commit_sha"] == merge_oid

    base_ref =
      Repo.get_by!(MirrorRefState,
        repository_mirror_id: fixture.base_binding.id,
        ref_name: "refs/heads/main"
      )

    head_ref =
      Repo.get_by!(MirrorRefState,
        repository_mirror_id: fixture.head_binding.id,
        ref_name: "refs/heads/feature/api"
      )

    assert {base_ref.confirmed_oid, base_ref.last_local_oid, base_ref.last_remote_oid} ==
             {merge_oid, merge_oid, merge_oid}

    assert {head_ref.confirmed_oid, head_ref.last_local_oid, head_ref.last_remote_oid} ==
             {fixture.head_oid, fixture.head_oid, fixture.head_oid}

    _fsck = git!(["--git-dir", fixture.base_path, "fsck", "--strict"])
    stop_merge_worker!()
    :ok = stop_supervised(:api_cross_merge_loop)
    :ok = stop_supervised(:api_cross_merge_tasks)
  end

  defp repository(owner, slug, overrides \\ %{}) do
    {:ok, repository} =
      ForgeRepos.create_repository(
        owner,
        Map.merge(
          %{
            name: slug,
            slug: slug,
            visibility: :public,
            default_branch: "main",
            has_issues: true,
            allow_merge_commit: true
          },
          overrides
        )
      )

    repository
  end

  defp represented_cross_repository_pull!(tmp_dir) do
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
    base_repository = repository(owner, "api-cross-base", %{visibility: :private})
    head_repository = repository(owner, "api-cross-head", %{visibility: :private})

    base_binding =
      repository_mirror_fixture(organization, %{
        repository_id: base_repository.id,
        github_full_name: "acme/api-cross-base"
      })

    head_binding =
      repository_mirror_fixture(organization, %{
        repository_id: head_repository.id,
        github_full_name: "contributor/api-cross-head"
      })

    local = cross_repository_git_fixture!(base_repository, head_repository, tmp_dir)
    now = DateTime.utc_now(:second)

    issue =
      Repo.insert!(%Issue{
        repository_id: base_repository.id,
        number: 7,
        kind: :pull_request,
        title: "Cross repository merge",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%PullRequest{
        issue_id: issue.id,
        repository_id: base_repository.id,
        head_repository_id: head_repository.id,
        head_ref: "refs/heads/feature/api",
        base_ref: "refs/heads/main",
        head_sha: local.head_oid,
        base_sha: local.base_oid
      })

    insert_ref_state!(base_binding.id, pull.base_ref, local.base_oid, now)
    insert_ref_state!(head_binding.id, pull.head_ref, local.head_oid, now)
    {:ok, projection} = ForgePulls.sync_projection(base_repository.id, :pull, pull.id)

    base_identity = %{
      "id" => base_binding.github_repository_id,
      "node_id" => base_binding.github_node_id
    }

    head_identity = %{
      "id" => head_binding.github_repository_id,
      "node_id" => head_binding.github_node_id
    }

    provider_identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => base_identity,
      "head_repository" => head_identity
    }

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: base_binding.id,
      resource_kind: :pull,
      local_resource_type: "ForgePulls.PullRequest",
      local_resource_id: pull.id,
      github_object_id: 902,
      github_node_id: "PR_902",
      github_number: 7,
      confirmed_local_version: projection.local_version,
      confirmed_remote_updated_at: now,
      confirmed_snapshot: projection.fields,
      confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
      provider_identity: provider_identity,
      state: :confirmed
    })
    |> Repo.insert!()

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: base_binding.id,
      resource_kind: :issue,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: issue.id,
      github_object_id: 901,
      github_node_id: "I_901",
      github_number: 7,
      confirmed_local_version: issue.sync_version,
      confirmed_remote_updated_at: now,
      confirmed_snapshot: %{
        "title" => issue.title,
        "body" => nil,
        "state" => "open",
        "state_reason" => nil,
        "label_github_ids" => [],
        "assignee_github_ids" => []
      },
      state: :confirmed
    })
    |> Repo.insert!()

    provider_base_path = Path.join(tmp_dir, "provider-base.git")
    provider_head_path = Path.join(tmp_dir, "provider-head.git")
    git!(["init", "--bare", provider_base_path])
    git!(["init", "--bare", provider_head_path])
    fetch_ref!(provider_base_path, local.base_path, local.base_oid, "refs/heads/main")
    fetch_ref!(provider_head_path, local.head_path, local.head_oid, "refs/heads/feature/api")

    bash = System.find_executable("bash") || flunk("bash executable is required")
    real_git = System.find_executable("git") || flunk("git executable is required")

    adapter =
      git_adapter!(tmp_dir, bash, real_git, base_binding.github_full_name, provider_base_path)

    Map.merge(local, %{
      actor: actor,
      owner: owner,
      organization: organization,
      base_repository: base_repository,
      head_repository: head_repository,
      base_binding: base_binding,
      head_binding: head_binding,
      issue: issue,
      pull: pull,
      now: now,
      provider_base_path: provider_base_path,
      provider_head_path: provider_head_path,
      git_adapter: adapter,
      credential_root: Path.join(tmp_dir, "provider-credentials")
    })
  end

  defp cross_repository_git_fixture!(base_repository, head_repository, tmp_dir) do
    work_path = Path.join(tmp_dir, "cross-work")
    base_path = ForgeRepos.absolute_storage_path(base_repository)
    head_path = ForgeRepos.absolute_storage_path(head_repository)
    git!(["init", "--initial-branch=main", work_path])
    File.write!(Path.join(work_path, "common.txt"), "common\n")
    commit_all!(work_path, "common")
    common_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    git!(["-C", work_path, "checkout", "-b", "feature/api"])
    File.write!(Path.join(work_path, "feature.txt"), "feature\n")
    commit_all!(work_path, "feature")
    head_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    git!(["-C", work_path, "checkout", "main"])
    File.write!(Path.join(work_path, "base.txt"), "base\n")
    commit_all!(work_path, "base")
    base_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    fetch_ref!(base_path, work_path, base_oid, "refs/heads/main")
    fetch_ref!(head_path, work_path, head_oid, "refs/heads/feature/api")

    refute git_object_exists?(base_path, head_oid)

    %{
      work_path: work_path,
      base_path: base_path,
      head_path: head_path,
      common_oid: common_oid,
      base_oid: base_oid,
      head_oid: head_oid
    }
  end

  defp insert_ref_state!(binding_id, ref_name, oid, now) do
    %MirrorRefState{}
    |> MirrorRefState.persistence_changeset(%{
      repository_mirror_id: binding_id,
      ref_name: ref_name,
      ref_kind: :branch,
      confirmed_oid: oid,
      last_local_oid: oid,
      last_remote_oid: oid,
      state: :confirmed,
      last_confirmed_at: now
    })
    |> Repo.insert!()
  end

  defp fetch_ref!(destination, source, oid, ref) do
    git!([
      "--git-dir",
      destination,
      "fetch",
      "--no-write-fetch-head",
      source,
      "#{oid}:#{ref}"
    ])
  end

  defp merge_worker_options(fixture, provider, stub, parent) do
    task_supervisor =
      start_supervised!(
        {Task.Supervisor, max_children: 2},
        id: :api_cross_merge_tasks
      )

    loop_task_supervisor =
      start_supervised!(
        {Task.Supervisor, max_children: 1},
        id: :api_cross_merge_loop
      )

    [
      name: PullMergeWorker,
      enabled: true,
      interval_ms: 10,
      task_supervisor: task_supervisor,
      loop_task_supervisor: loop_task_supervisor,
      token_fetch: fn _, scope ->
        %InstallationToken{
          token: "api-cross-merge-credential",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600),
          permissions: scope.permissions
        }
      end,
      request_options: [
        plug: {Req.Test, stub},
        resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
      ],
      push_remote: fn request, token, [update], transport_options ->
        assert Agent.get(provider, & &1.push_count) == 0

        options =
          Keyword.merge(transport_options,
            git: fixture.git_adapter,
            resolver: public_github_resolver(),
            credential_root: fixture.credential_root
          )

        assert :ok = GitCore.Remote.push_refs(request, token, [update], options)

        Agent.update(provider, fn state ->
          %{state | merge_oid: update.proposed_oid, push_count: state.push_count + 1}
        end)

        send(parent, {:provider_push, update.proposed_oid})
        {:error, :timeout}
      end
    ]
  end

  defp start_merge_worker!(options, owner) do
    start_supervised!(
      {PullMergeWorker, Keyword.put(options, :owner, owner)},
      id: :api_cross_merge_worker
    )
  end

  defp stop_merge_worker! do
    :sys.replace_state(PullMergeWorker, &%{&1 | enabled: false})
    assert eventually(fn -> :sys.get_state(PullMergeWorker).task_ref == nil end)
    :ok = stop_supervised(:api_cross_merge_worker)
  end

  defp provider_response(conn, fixture, provider) do
    case conn.request_path do
      "/repos/acme/api-cross-base" ->
        Req.Test.json(conn, provider_repository(fixture.base_binding, "acme/api-cross-base"))

      "/repos/contributor/api-cross-head" ->
        Req.Test.json(
          conn,
          provider_repository(fixture.head_binding, "contributor/api-cross-head")
        )

      "/repos/acme/api-cross-base/git/ref/heads/main" ->
        Req.Test.json(
          conn,
          provider_ref(
            "refs/heads/main",
            remote_ref(fixture.provider_base_path, "refs/heads/main")
          )
        )

      "/repos/contributor/api-cross-head/git/ref/heads/feature/api" ->
        Req.Test.json(
          conn,
          provider_ref(
            "refs/heads/feature/api",
            remote_ref(fixture.provider_head_path, "refs/heads/feature/api")
          )
        )

      "/repos/acme/api-cross-base/pulls/7" ->
        Req.Test.json(conn, provider_pull(fixture, provider))

      "/repos/acme/api-cross-base/issues/7" ->
        Req.Test.json(conn, provider_issue(fixture, provider))

      path ->
        flunk("unexpected provider request: #{conn.method} #{path}")
    end
  end

  defp provider_client_options(fixture, stub) do
    [
      plug: {Req.Test, stub},
      gate_key: {:github_installation, fixture.organization.github_installation_id},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp provider_repository(binding, full_name) do
    [owner, name] = String.split(full_name, "/", parts: 2)

    %{
      "id" => binding.github_repository_id,
      "node_id" => binding.github_node_id,
      "owner" => %{"id" => 12, "login" => owner},
      "name" => name,
      "full_name" => full_name,
      "description" => nil,
      "visibility" => "private",
      "default_branch" => "main",
      "has_issues" => true,
      "allow_merge_commit" => true,
      "fork" => false,
      "archived" => false,
      "html_url" => "https://github.com/#{full_name}",
      "updated_at" => "2026-09-14T00:00:00Z",
      "pushed_at" => "2026-09-14T00:00:00Z"
    }
  end

  defp provider_ref(ref, oid) do
    %{
      "ref" => ref,
      "node_id" => "REF_#{String.replace(ref, "/", "_")}",
      "url" => "https://api.github.com/provider/ref",
      "object" => %{
        "type" => "commit",
        "sha" => oid,
        "url" => "https://api.github.com/provider/commit/#{oid}"
      }
    }
  end

  defp provider_pull(fixture, provider) do
    state = Agent.get(provider, & &1)
    base_oid = remote_ref(fixture.provider_base_path, "refs/heads/main")
    merged? = is_binary(state.merge_oid) and base_oid == state.merge_oid
    timestamp = DateTime.to_iso8601(fixture.now)

    %{
      "id" => 902,
      "node_id" => "PR_902",
      "number" => 7,
      "title" => "Cross repository merge",
      "body" => nil,
      "state" => if(merged?, do: "closed", else: "open"),
      "draft" => false,
      "user" => nil,
      "created_at" => timestamp,
      "updated_at" => timestamp,
      "closed_at" => if(merged?, do: timestamp),
      "merged_at" => if(merged?, do: timestamp),
      "merge_commit_sha" => if(merged?, do: state.merge_oid),
      "merged" => merged?,
      "mergeable" => if(merged?, do: nil, else: true),
      "rebaseable" => if(merged?, do: nil, else: true),
      "mergeable_state" => if(merged?, do: "unknown", else: "clean"),
      "head" => %{
        "ref" => "feature/api",
        "sha" => fixture.head_oid,
        "repo" => %{
          "id" => fixture.head_binding.github_repository_id,
          "node_id" => fixture.head_binding.github_node_id,
          "full_name" => fixture.head_binding.github_full_name
        }
      },
      "base" => %{
        "ref" => "main",
        "sha" => base_oid,
        "repo" => %{
          "id" => fixture.base_binding.github_repository_id,
          "node_id" => fixture.base_binding.github_node_id,
          "full_name" => fixture.base_binding.github_full_name
        }
      }
    }
  end

  defp provider_issue(fixture, provider) do
    merged? = is_binary(Agent.get(provider, & &1.merge_oid))
    timestamp = DateTime.to_iso8601(fixture.now)

    %{
      "id" => 901,
      "node_id" => "I_901",
      "number" => 7,
      "title" => "Cross repository merge",
      "body" => nil,
      "state" => if(merged?, do: "closed", else: "open"),
      "state_reason" => nil,
      "labels" => [],
      "assignees" => [],
      "user" => nil,
      "created_at" => timestamp,
      "updated_at" => timestamp,
      "closed_at" => if(merged?, do: timestamp),
      "pull_request" => %{
        "url" => "https://api.github.com/repos/acme/api-cross-base/pulls/7"
      }
    }
  end

  defp pending_merge_released?(pull_id, merge_oid) do
    case Repo.one(
           from operation in MirrorOperation,
             where: operation.kind == "merge.pull",
             order_by: [desc: operation.id],
             limit: 1
         ) do
      %MirrorOperation{
        state: :effect_pending,
        lease_owner: nil,
        cursor: %{"pull_id" => ^pull_id},
        external_effect_marker: %{"merge_oid" => ^merge_oid}
      } ->
        true

      _ ->
        false
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp remote_ref(path, ref) do
    case System.cmd("git", ["--git-dir=#{path}", "rev-parse", "--verify", "--quiet", ref],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {_output, 1} -> nil
      {output, status} -> flunk("remote ref read failed (#{status}): #{output}")
    end
  end

  defp git_object_exists?(path, oid) do
    match?(
      {_output, 0},
      System.cmd("git", ["--git-dir=#{path}", "cat-file", "-e", oid], stderr_to_stdout: true)
    )
  end

  defp git_adapter!(tmp_dir, bash, real_git, full_name, remote_path) do
    adapter = Path.join(tmp_dir, "provider-git-adapter")

    File.write!(adapter, """
    #!#{bash}
    set -euo pipefail
    translated=()
    for argument in "$@"; do
      case "$argument" in
        https://github.com/#{full_name}.git) translated+=(#{shell_quote(remote_path)}) ;;
        protocol.file.allow=never) translated+=(protocol.file.allow=always) ;;
        *) translated+=("$argument") ;;
      esac
    done
    export GIT_ALLOW_PROTOCOL=https:file
    exec #{shell_quote(real_git)} "${translated[@]}"
    """)

    File.chmod!(adapter, 0o700)
    adapter
  end

  defp public_github_resolver do
    fn
      "github.com", :a -> [{140, 82, 121, 3}]
      "github.com", :aaaa -> [{0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}]
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp divergent_repository!(repository, tmp_dir, kind) do
    work_path = Path.join(tmp_dir, "work-#{repository.slug}")
    bare_path = ForgeRepos.absolute_storage_path(repository)

    git!(["init", "--initial-branch=main", work_path])
    git!(["-C", work_path, "remote", "add", "origin", bare_path])
    File.write!(Path.join(work_path, "common.txt"), "common\n")
    File.write!(Path.join(work_path, "conflict.txt"), "common\n")
    commit_all!(work_path, "common")
    git!(["-C", work_path, "push", "origin", "main"])

    git!(["-C", work_path, "checkout", "-b", "feature/api"])
    write_feature_change!(work_path, kind)
    commit_all!(work_path, "feature")
    head_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "push", "origin", "feature/api"])

    git!(["-C", work_path, "checkout", "main"])
    write_base_change!(work_path, kind)
    commit_all!(work_path, "base")
    base_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "push", "origin", "main"])

    %{work_path: work_path, base_oid: base_oid, head_oid: head_oid}
  end

  defp write_feature_change!(work_path, :mergeable),
    do: File.write!(Path.join(work_path, "feature.txt"), "feature\n")

  defp write_feature_change!(work_path, :conflict),
    do: File.write!(Path.join(work_path, "conflict.txt"), "feature\n")

  defp write_base_change!(work_path, :mergeable),
    do: File.write!(Path.join(work_path, "base.txt"), "base\n")

  defp write_base_change!(work_path, :conflict),
    do: File.write!(Path.join(work_path, "conflict.txt"), "base\n")

  defp advance_feature!(work_path) do
    git!(["-C", work_path, "checkout", "feature/api"])
    File.write!(Path.join(work_path, "moved-head.txt"), "moved\n")
    commit_all!(work_path, "move head")
    oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "push", "origin", "feature/api"])
    oid
  end

  defp commit_all!(work_path, message) do
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", message])
  end

  defp create_pull(secret, owner, repository, title) do
    api_conn(secret)
    |> post_json(pull_path(owner, repository), %{
      "title" => title,
      "head" => "feature/api",
      "base" => "main"
    })
    |> json_response(201)
  end

  defp pull_issue!(repository, created) do
    Repo.get_by!(Issue, repository_id: repository.id, number: created["number"])
  end

  defp refute_merge_success!(repository, created) do
    issue = pull_issue!(repository, created)
    pull = Repo.get_by!(PullRequest, issue_id: issue.id)

    refute Repo.exists?(
             from operation in MergeOperation,
               where: operation.pull_request_id == ^pull.id and operation.state == :completed
           )

    refute Repo.exists?(
             from event in AuditEvent,
               where:
                 event.action == "pull_request.merged" and event.target_type == "repository" and
                   event.target_id == ^to_string(repository.id)
           )
  end

  defp exact_ref(repository, branch) do
    {:ok, oid} =
      repository
      |> ForgeRepos.absolute_storage_path()
      |> GitCore.exact_ref("refs/heads/#{branch}")

    oid
  end

  defp git_commit_parents!(clone_path, oid),
    do: git!(["-C", clone_path, "rev-list", "--parents", "-n", "1", oid])

  defp start_git_http_server do
    pid =
      start_supervised!(
        {Bandit,
         plug: FornacastWeb.Endpoint,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp share_database! do
    if postgres?() do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]

  defp api_conn(secret, version \\ "2026-03-10") do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_req_header("x-github-api-version", version)
    |> put_req_header("authorization", "Bearer #{secret}")
  end

  defp pull_path(owner, repository),
    do: "/api/v3/repos/#{owner.username}/#{repository.slug}/pulls"

  defp pull_path(owner, repository, number), do: pull_path(owner, repository) <> "/#{number}"

  defp issue_path(owner, repository, number),
    do: "/api/v3/repos/#{owner.username}/#{repository.slug}/issues/#{number}"

  defp post_json(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> post(path, JSON.encode!(body))

  defp put_json(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, JSON.encode!(body))

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.test"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.test"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}:\n#{output}")
    end
  end
end
