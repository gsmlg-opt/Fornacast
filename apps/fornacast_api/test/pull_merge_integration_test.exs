defmodule FornacastAPI.PullMergeIntegrationTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest}
  alias ForgeRepos.Repository
  alias Fornacast.AuditEvent

  @user_agent "fornacast-pull-merge-integration/1.0"

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

  defp repository(owner, slug) do
    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{
        name: slug,
        slug: slug,
        visibility: :public,
        default_branch: "main",
        has_issues: true,
        allow_merge_commit: true
      })

    repository
  end

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

  defp api_conn(secret) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_req_header("x-github-api-version", "2026-03-10")
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
