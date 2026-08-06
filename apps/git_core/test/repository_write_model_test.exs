defmodule GitCore.RepositoryWriteModelTest do
  use ExUnit.Case, async: false

  @moduletag :pull_merge

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "fornacast-pull-merge-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  test "merge analysis is a typed value with enforced keys" do
    assert_raise ArgumentError, fn ->
      struct!(GitCore.MergeAnalysis,
        base_oid: String.duplicate("a", 40),
        head_oid: String.duplicate("b", 40),
        mergeable: true,
        ahead_by: 1,
        behind_by: 1,
        commit_count: 1
      )
    end
  end

  test "analyzes clean divergence, identical tips, and an already-contained head", %{
    tmp_dir: tmp_dir
  } do
    fixture = clean_fixture!(tmp_dir)

    assert {:ok,
            %{
              __struct__: GitCore.MergeAnalysis,
              base_oid: base_oid,
              head_oid: head_oid,
              mergeable: true,
              ahead_by: 2,
              behind_by: 1,
              commit_count: 2,
              changed_paths: 2
            }} = GitCore.merge_analysis(fixture.repo_path, fixture.base_oid, fixture.head_oid, [])

    assert base_oid == fixture.base_oid
    assert head_oid == fixture.head_oid

    assert {:ok,
            %{
              __struct__: GitCore.MergeAnalysis,
              mergeable: true,
              ahead_by: 0,
              behind_by: 0,
              commit_count: 0,
              changed_paths: 0
            }} = GitCore.merge_analysis(fixture.repo_path, fixture.base_oid, fixture.base_oid, [])

    assert {:ok,
            %{
              __struct__: GitCore.MergeAnalysis,
              mergeable: true,
              ahead_by: 0,
              behind_by: 1,
              commit_count: 0,
              changed_paths: 0
            }} = GitCore.merge_analysis(fixture.repo_path, fixture.base_oid, fixture.root_oid, [])
  end

  test "reports text and tree conflicts without writing objects or moving refs", %{
    tmp_dir: tmp_dir
  } do
    for fixture <- [text_conflict_fixture!(tmp_dir), tree_conflict_fixture!(tmp_dir)] do
      before_objects = object_ids(fixture.repo_path)
      before_refs = refs(fixture.repo_path)

      assert {:ok, %{__struct__: GitCore.MergeAnalysis, mergeable: false}} =
               GitCore.merge_analysis(fixture.repo_path, fixture.base_oid, fixture.head_oid, [])

      assert object_ids(fixture.repo_path) == before_objects
      assert refs(fixture.repo_path) == before_refs

      assert {:error, %GitCore.Error{kind: :merge_conflict, operation: :write_merge_commit}} =
               GitCore.write_merge_commit(
                 fixture.repo_path,
                 fixture.base_oid,
                 fixture.head_oid,
                 signature(),
                 signature(),
                 "Merge conflicting pull",
                 []
               )

      assert object_ids(fixture.repo_path) == before_objects
      assert refs(fixture.repo_path) == before_refs
    end
  end

  test "enforces commit, tree-entry, changed-path, and deadline bounds before persistent writes",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = clean_fixture!(tmp_dir)

    for {opts, kind} <- [
          {[commit_limit: 2], :commit_limit},
          {[tree_entry_limit: 1], :tree_entry_limit},
          {[changed_path_limit: 1], :changed_path_limit},
          {[byte_limit: 1], :merge_byte_limit},
          {[deadline_ms: 0], :scan_timeout}
        ] do
      before_objects = object_ids(fixture.repo_path)
      before_refs = refs(fixture.repo_path)

      assert {:error, %GitCore.Error{kind: ^kind, operation: :merge_analysis}} =
               GitCore.merge_analysis(
                 fixture.repo_path,
                 fixture.base_oid,
                 fixture.head_oid,
                 opts
               )

      assert object_ids(fixture.repo_path) == before_objects
      assert refs(fixture.repo_path) == before_refs

      assert {:error, %GitCore.Error{kind: ^kind, operation: :write_merge_commit}} =
               GitCore.write_merge_commit(
                 fixture.repo_path,
                 fixture.base_oid,
                 fixture.head_oid,
                 signature(),
                 signature(),
                 "Bounded merge",
                 opts
               )

      assert object_ids(fixture.repo_path) == before_objects
      assert refs(fixture.repo_path) == before_refs
    end
  end

  test "rejects configured external merge drivers without executing them", %{tmp_dir: tmp_dir} do
    fixture = external_driver_fixture!(tmp_dir)
    marker = Path.join(tmp_dir, "external-driver-ran")

    git!([
      "--git-dir",
      fixture.repo_path,
      "config",
      "merge.fornacast-test.driver",
      "touch #{marker}"
    ])

    assert {:ok, %GitCore.MergeAnalysis{mergeable: false}} =
             GitCore.merge_analysis(
               fixture.repo_path,
               fixture.base_oid,
               fixture.head_oid,
               []
             )

    refute File.exists?(marker)
  end

  test "writes a genuine two-parent merge commit without moving a ref", %{tmp_dir: tmp_dir} do
    fixture = clean_fixture!(tmp_dir)
    before_refs = refs(fixture.repo_path)
    author = signature(name: "Pull Author", email: "author@example.com", seconds: 1_700_000_000)

    committer =
      signature(name: "Pull Merger", email: "merger@example.com", seconds: 1_700_000_100)

    assert {:ok, merge_oid} =
             GitCore.write_merge_commit(
               fixture.repo_path,
               fixture.base_oid,
               fixture.head_oid,
               author,
               committer,
               "Merge feature branch\n\nA bounded merge.",
               []
             )

    assert {:ok, commit} = GitCore.commit(fixture.repo_path, merge_oid)
    assert commit.parents == [fixture.base_oid, fixture.head_oid]
    assert commit.author_name == "Pull Author"
    assert commit.committer_name == "Pull Merger"
    assert commit.message == "Merge feature branch\n\nA bounded merge."

    raw = git!(["--git-dir", fixture.repo_path, "cat-file", "-p", merge_oid])
    assert parent_lines(raw) == ["parent #{fixture.base_oid}", "parent #{fixture.head_oid}"]
    assert refs(fixture.repo_path) == before_refs

    assert git!(["--git-dir", fixture.repo_path, "rev-parse", "refs/heads/main"]) ==
             fixture.base_oid
  end

  test "validates UTF-8 and signature/message size before inserting any object", %{
    tmp_dir: tmp_dir
  } do
    fixture = clean_fixture!(tmp_dir)

    invalid_calls = [
      {signature(name: "bad\nname"), signature(), "message"},
      {signature(), signature(email: "bad\n@example.com"), "message"},
      {signature(), signature(), <<255>>},
      {signature(), signature(), :binary.copy("m", 1_048_577)}
    ]

    for {author, committer, message} <- invalid_calls do
      before_objects = object_ids(fixture.repo_path)
      before_refs = refs(fixture.repo_path)

      assert {:error, %GitCore.Error{kind: :invalid_input, operation: :write_merge_commit}} =
               GitCore.write_merge_commit(
                 fixture.repo_path,
                 fixture.base_oid,
                 fixture.head_oid,
                 author,
                 committer,
                 message,
                 []
               )

      assert object_ids(fixture.repo_path) == before_objects
      assert refs(fixture.repo_path) == before_refs
    end
  end

  test "analysis runs under the supervised global scan limiter", %{tmp_dir: tmp_dir} do
    fixture = clean_fixture!(tmp_dir)

    limiter =
      start_supervised!(
        {GitCore.ScanLimiter, server: nil, capacity: 1, wait_timeout: 0},
        id: make_ref()
      )

    parent = self()

    holder =
      Task.async(fn ->
        GitCore.ScanLimiter.with_permit(
          :pull_merge_holder,
          fn ->
            send(parent, :permit_held)
            receive do: (:release -> :ok)
          end,
          server: limiter
        )
      end)

    assert_receive :permit_held

    assert {:error, %GitCore.Error{kind: :scan_busy, operation: :merge_analysis}} =
             GitCore.merge_analysis_with_runtime(
               fixture.repo_path,
               fixture.base_oid,
               fixture.head_oid,
               [],
               limiter: limiter,
               task_supervisor: GitCore.MergeTaskSupervisor,
               native_merge: &GitCore.Native.merge_analysis/8,
               native_await: &GitCore.Native.await_merge_worker/1
             )

    send(holder.pid, :release)
    assert Task.await(holder) == :ok
  end

  test "timed-out merge keepers remain inside the node-wide scan capacity" do
    limiter =
      start_supervised!(
        {GitCore.ScanLimiter, server: nil, capacity: 4, wait_timeout: 0},
        id: make_ref()
      )

    keeper_supervisor =
      start_supervised!({Task.Supervisor, name: nil}, id: make_ref())

    parent = self()

    callers =
      for _ <- 1..4 do
        Task.async(fn ->
          GitCore.merge_analysis_with_runtime(
            "unused-test-repository",
            String.duplicate("a", 40),
            String.duplicate("b", 40),
            [],
            limiter: limiter,
            task_supervisor: keeper_supervisor,
            native_merge: fn _path,
                             _base_oid,
                             _head_oid,
                             _commit_limit,
                             _tree_entry_limit,
                             _changed_path_limit,
                             _byte_limit,
                             _deadline_ms ->
              keeper = self()
              send(parent, {:merge_keeper_active, keeper})
              {:deferred, {"scan_timeout", "merge analysis exceeded its deadline"}, keeper}
            end,
            native_await: fn keeper ->
              receive do
                :release_merge_worker -> send(parent, {:merge_keeper_finished, keeper})
              end
            end
          )
        end)
      end

    keepers =
      for _ <- 1..4 do
        assert_receive {:merge_keeper_active, keeper}
        keeper
      end

    for caller <- callers do
      assert {:error, %GitCore.Error{kind: :scan_timeout, operation: :merge_analysis}} =
               Task.await(caller)
    end

    assert {:error, %GitCore.Error{kind: :scan_busy, operation: :ref_summary}} =
             GitCore.ScanLimiter.with_permit(:ref_summary, fn -> :unexpected end, server: limiter)

    [released | remaining] = keepers
    send(released, :release_merge_worker)
    assert_receive {:merge_keeper_finished, ^released}

    assert :ordinary_scan_entered =
             GitCore.ScanLimiter.with_permit(:ref_summary, fn -> :ordinary_scan_entered end,
               server: limiter
             )

    Enum.each(remaining, &send(&1, :release_merge_worker))

    for keeper <- remaining do
      assert_receive {:merge_keeper_finished, ^keeper}
    end

    assert :ok = wait_for_deferred_release(limiter, keeper_supervisor)
  end

  defp clean_fixture!(tmp_dir) do
    fixture = base_fixture!(tmp_dir, "clean")

    File.write!(Path.join(fixture.work_path, "base.txt"), "base\n")
    git!(["-C", fixture.work_path, "add", "base.txt"])
    git!(["-C", fixture.work_path, "commit", "-m", "base change"])
    base_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    git!(["-C", fixture.work_path, "checkout", "-b", "feature", fixture.root_oid])
    File.write!(Path.join(fixture.work_path, "head.txt"), "head\n")
    git!(["-C", fixture.work_path, "add", "head.txt"])
    git!(["-C", fixture.work_path, "commit", "-m", "head change one"])
    File.write!(Path.join(fixture.work_path, "head-two.txt"), "head two\n")
    git!(["-C", fixture.work_path, "add", "head-two.txt"])
    git!(["-C", fixture.work_path, "commit", "-m", "head change two"])
    head_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    publish_fixture!(fixture, base_oid, head_oid)
  end

  defp text_conflict_fixture!(tmp_dir) do
    fixture = base_fixture!(tmp_dir, "text-conflict")
    path = Path.join(fixture.work_path, "common.txt")

    File.write!(path, "base version\n")
    git!(["-C", fixture.work_path, "commit", "-am", "base conflict"])
    base_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    git!(["-C", fixture.work_path, "checkout", "-b", "feature", fixture.root_oid])
    File.write!(path, "head version\n")
    git!(["-C", fixture.work_path, "commit", "-am", "head conflict"])
    head_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    publish_fixture!(fixture, base_oid, head_oid)
  end

  defp tree_conflict_fixture!(tmp_dir) do
    fixture = base_fixture!(tmp_dir, "tree-conflict")
    shape = Path.join(fixture.work_path, "shape")

    File.write!(shape, "file\n")
    git!(["-C", fixture.work_path, "add", "shape"])
    git!(["-C", fixture.work_path, "commit", "-m", "base file"])
    base_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    git!(["-C", fixture.work_path, "checkout", "-b", "feature", fixture.root_oid])
    File.mkdir_p!(shape)
    File.write!(Path.join(shape, "item.txt"), "directory\n")
    git!(["-C", fixture.work_path, "add", "shape/item.txt"])
    git!(["-C", fixture.work_path, "commit", "-m", "head directory"])
    head_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    publish_fixture!(fixture, base_oid, head_oid)
  end

  defp external_driver_fixture!(tmp_dir) do
    fixture = base_fixture!(tmp_dir, "external-driver")
    attributed_path = Path.join(fixture.work_path, "driver.txt")

    File.write!(
      Path.join(fixture.work_path, ".gitattributes"),
      "driver.txt merge=fornacast-test\n"
    )

    File.write!(attributed_path, "ancestor\n")
    git!(["-C", fixture.work_path, "add", ".gitattributes", "driver.txt"])
    git!(["-C", fixture.work_path, "commit", "-m", "configure attributed merge driver"])
    root_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    File.write!(attributed_path, "base version\n")
    git!(["-C", fixture.work_path, "commit", "-am", "base attributed change"])
    base_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    git!(["-C", fixture.work_path, "checkout", "-b", "feature", root_oid])
    File.write!(attributed_path, "head version\n")
    git!(["-C", fixture.work_path, "commit", "-am", "head attributed change"])
    head_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])

    publish_fixture!(Map.put(fixture, :root_oid, root_oid), base_oid, head_oid)
  end

  defp base_fixture!(tmp_dir, name) do
    suffix = System.unique_integer([:positive, :monotonic])
    work_path = Path.join(tmp_dir, "#{name}-work-#{suffix}")
    repo_path = Path.join(tmp_dir, "#{name}-bare-#{suffix}.git")
    git!(["init", work_path])
    git!(["-C", work_path, "config", "user.name", "Fornacast Test"])
    git!(["-C", work_path, "config", "user.email", "test@example.com"])
    File.write!(Path.join(work_path, "common.txt"), "common\n")
    git!(["-C", work_path, "add", "common.txt"])
    git!(["-C", work_path, "commit", "-m", "root"])
    git!(["-C", work_path, "branch", "-M", "main"])
    root_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["init", "--bare", repo_path])
    %{work_path: work_path, repo_path: repo_path, root_oid: root_oid}
  end

  defp publish_fixture!(fixture, base_oid, head_oid) do
    git!(["-C", fixture.work_path, "push", fixture.repo_path, "main:refs/heads/main"])
    git!(["-C", fixture.work_path, "push", fixture.repo_path, "feature:refs/heads/feature"])
    Map.merge(fixture, %{base_oid: base_oid, head_oid: head_oid})
  end

  defp signature(overrides \\ []) do
    struct!(
      GitCore.Signature,
      Keyword.merge(
        [
          name: "Fornacast Test",
          email: "test@example.com",
          seconds: 1_700_000_000,
          offset_minutes: 0
        ],
        overrides
      )
    )
  end

  defp refs(repo_path) do
    git!(["--git-dir", repo_path, "for-each-ref", "--format=%(refname) %(objectname)"])
  end

  defp object_ids(repo_path) do
    git!([
      "--git-dir",
      repo_path,
      "cat-file",
      "--batch-all-objects",
      "--batch-check=%(objectname)"
    ])
  end

  defp parent_lines(raw) do
    raw
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "parent "))
  end

  defp wait_for_deferred_release(limiter, supervisor, attempts \\ 100)

  defp wait_for_deferred_release(_limiter, _supervisor, 0), do: {:error, :still_active}

  defp wait_for_deferred_release(limiter, supervisor, attempts) do
    %{active: active} = Supervisor.count_children(supervisor)
    %{grants: grants} = :sys.get_state(limiter)

    if active == 0 and map_size(grants) == 0 do
      :ok
    else
      Process.sleep(5)
      wait_for_deferred_release(limiter, supervisor, attempts - 1)
    end
  end

  defp git!(args) do
    {output, status} =
      System.cmd("git", args,
        stderr_to_stdout: true,
        env: [
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_AUTHOR_DATE", "1700000000 +0000"},
          {"GIT_COMMITTER_DATE", "1700000000 +0000"}
        ]
      )

    assert status == 0, "git #{Enum.join(args, " ")} failed:\n#{output}"
    String.trim(output)
  end
end
