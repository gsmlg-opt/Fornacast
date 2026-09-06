defmodule GitCore.MirrorRefPrimitivesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, fixture: fixture(tmp_dir)}
  end

  test "ancestry is exact, bounded, and does not mutate repository state", %{fixture: fixture} do
    before_refs = refs(fixture.repo_path)
    before_objects = object_ids(fixture.repo_path)

    assert {:ok, true} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.root_oid,
               fixture.head_oid,
               deadline_ms: 1_000
             )

    assert {:ok, true} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.head_oid,
               fixture.head_oid,
               deadline_ms: 1_000
             )

    assert {:ok, false} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.head_oid,
               fixture.root_oid,
               deadline_ms: 1_000
             )

    assert {:ok, false} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.head_oid,
               fixture.diverged_oid,
               deadline_ms: 1_000
             )

    assert refs(fixture.repo_path) == before_refs
    assert object_ids(fixture.repo_path) == before_objects
  end

  test "ancestry rejects invalid targets and enforces the configured visit and deadline bounds",
       %{
         fixture: fixture
       } do
    tree_oid = git!(["--git-dir", fixture.repo_path, "rev-parse", "#{fixture.head_oid}^{tree}"])

    for {ancestor, descendant, kind} <- [
          {"not-an-oid", fixture.head_oid, :invalid_oid},
          {tree_oid, fixture.head_oid, :target_not_commit},
          {fixture.root_oid, tree_oid, :target_not_commit}
        ] do
      assert {:error, %GitCore.Error{kind: ^kind, operation: :is_ancestor}} =
               GitCore.is_ancestor(
                 fixture.repo_path,
                 ancestor,
                 descendant,
                 deadline_ms: 1_000
               )
    end

    assert {:error, %GitCore.Error{kind: :ref_timeout, operation: :is_ancestor}} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.root_oid,
               fixture.head_oid,
               deadline_ms: 0
             )

    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :is_ancestor}} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.root_oid,
               fixture.head_oid,
               [:not_a_keyword]
             )

    previous_limits = Application.get_env(:git_core, :limits)
    Application.put_env(:git_core, :limits, commit_visits: 1)
    on_exit(fn -> restore_limits(previous_limits) end)

    assert {:error, %GitCore.Error{kind: :commit_limit, operation: :is_ancestor}} =
             GitCore.is_ancestor(
               fixture.repo_path,
               fixture.root_oid,
               fixture.head_oid,
               deadline_ms: 1_000,
               commit_limit: 50_000
             )
  end

  test "exact deletion removes only the observed public ref target", %{fixture: fixture} do
    before_objects = object_ids(fixture.repo_path)
    head_oid = fixture.head_oid

    assert {:ok, ^head_oid} =
             GitCore.compare_and_delete_ref(
               fixture.repo_path,
               "refs/heads/main",
               fixture.head_oid,
               deadline_ms: 1_000
             )

    assert {:ok, nil} = GitCore.exact_ref(fixture.repo_path, "refs/heads/main")
    assert object_ids(fixture.repo_path) == before_objects

    git!([
      "--git-dir",
      fixture.repo_path,
      "update-ref",
      "refs/heads/main",
      fixture.head_oid
    ])

    assert {:error, %GitCore.Error{kind: :stale_ref, operation: :compare_and_delete_ref}} =
             GitCore.compare_and_delete_ref(
               fixture.repo_path,
               "refs/heads/main",
               fixture.root_oid,
               deadline_ms: 1_000
             )

    assert {:ok, ^head_oid} =
             GitCore.exact_ref(fixture.repo_path, "refs/heads/main")

    assert object_ids(fixture.repo_path) == before_objects
  end

  test "public exact deletion supports tags and admits only one concurrent owner", %{
    fixture: fixture
  } do
    tag_oid = fixture.tag_oid

    assert {:ok, ^tag_oid} =
             GitCore.compare_and_delete_ref(
               fixture.repo_path,
               "refs/tags/v1.0.0",
               tag_oid,
               deadline_ms: 1_000
             )

    results =
      1..2
      |> Task.async_stream(
        fn _index ->
          GitCore.compare_and_delete_ref(
            fixture.repo_path,
            "refs/heads/diverged",
            fixture.diverged_oid,
            deadline_ms: 1_000
          )
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _oid}, &1)) == 1

    assert Enum.count(results, fn
             {:error, %GitCore.Error{kind: :stale_ref, operation: :compare_and_delete_ref}} ->
               true

             _other ->
               false
           end) == 1
  end

  test "public exact creation retains an annotated tag object without peeling it", %{
    fixture: fixture
  } do
    assert {:ok, tag_oid} =
             GitCore.compare_and_swap_ref(
               fixture.repo_path,
               "refs/tags/copy",
               nil,
               fixture.tag_oid,
               :fast_forward,
               deadline_ms: 1_000
             )

    assert tag_oid == fixture.tag_oid
    assert {:ok, ^tag_oid} = GitCore.exact_ref(fixture.repo_path, "refs/tags/copy")

    assert git!(["--git-dir", fixture.repo_path, "cat-file", "-t", tag_oid]) == "tag"
  end

  test "public exact deletion validates refs, expected OIDs, and deadlines without mutation", %{
    fixture: fixture
  } do
    before_refs = refs(fixture.repo_path)

    for {full_ref, expected_oid, deadline_ms, kind} <- [
          {"refs/fornacast/mirrors/x/heads/main", fixture.head_oid, 1_000, :invalid_ref},
          {"refs/heads/main.lock", fixture.head_oid, 1_000, :invalid_ref},
          {"refs/heads/main", "not-an-oid", 1_000, :invalid_oid},
          {"refs/heads/main", fixture.head_oid, 0, :ref_timeout}
        ] do
      assert {:error, %GitCore.Error{kind: ^kind, operation: :compare_and_delete_ref}} =
               GitCore.compare_and_delete_ref(
                 fixture.repo_path,
                 full_ref,
                 expected_oid,
                 deadline_ms: deadline_ms
               )

      assert refs(fixture.repo_path) == before_refs
    end

    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :compare_and_delete_ref}} =
             GitCore.compare_and_delete_ref(
               fixture.repo_path,
               "refs/heads/main",
               nil,
               deadline_ms: 1_000
             )
  end

  test "tracking ref names are private mappings of validated standard refs" do
    assert {:ok, "refs/fornacast/mirrors/mirror-42/heads/main"} =
             GitCore.tracking_ref_name("mirror-42", "refs/heads/main")

    assert {:ok, "refs/fornacast/mirrors/mirror-42/tags/v1.0.0"} =
             GitCore.tracking_ref_name("mirror-42", "refs/tags/v1.0.0")

    for {namespace, source_ref} <- [
          {"", "refs/heads/main"},
          {"two/segments", "refs/heads/main"},
          {String.duplicate("a", 65), "refs/heads/main"},
          {"mirror-42", "refs/pull/1/head"},
          {"mirror-42", "refs/heads/main.lock"},
          {"mirror-42", "refs/fornacast/other"},
          {"mirror-42", "refs/heads/" <> String.duplicate("a", 1_014)}
        ] do
      assert {:error, %GitCore.Error{kind: :invalid_ref, operation: :tracking_ref_name}} =
               GitCore.tracking_ref_name(namespace, source_ref)
    end

    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :tracking_ref_name}} =
             GitCore.tracking_ref_name(:not_a_namespace, "refs/heads/main")
  end

  test "tracking refs support exact observation updates without entering public ref listings", %{
    fixture: fixture
  } do
    namespace = "mirror-42"
    source_ref = "refs/heads/main"
    root_oid = fixture.root_oid
    head_oid = fixture.head_oid
    diverged_oid = fixture.diverged_oid

    assert {:ok, nil} =
             GitCore.exact_tracking_ref(
               fixture.repo_path,
               namespace,
               source_ref,
               deadline_ms: 1_000
             )

    assert {:ok, ^root_oid} =
             GitCore.compare_and_swap_tracking_ref(
               fixture.repo_path,
               namespace,
               source_ref,
               nil,
               root_oid,
               deadline_ms: 1_000
             )

    assert {:ok, public_refs} = GitCore.list_refs(fixture.repo_path)

    refute Enum.any?(public_refs, fn ref ->
             String.starts_with?(ref.name, "refs/fornacast/")
           end)

    refute git!(["ls-remote", fixture.repo_path]) =~ "refs/fornacast/"

    assert {:ok, ^diverged_oid} =
             GitCore.compare_and_swap_tracking_ref(
               fixture.repo_path,
               namespace,
               source_ref,
               root_oid,
               diverged_oid,
               deadline_ms: 1_000
             )

    assert {:error, %GitCore.Error{kind: :stale_ref, operation: :compare_and_swap_tracking_ref}} =
             GitCore.compare_and_swap_tracking_ref(
               fixture.repo_path,
               namespace,
               source_ref,
               root_oid,
               head_oid,
               deadline_ms: 1_000
             )

    assert {:ok, ^diverged_oid} =
             GitCore.exact_tracking_ref(fixture.repo_path, namespace, source_ref)

    assert {:ok, ^diverged_oid} =
             GitCore.compare_and_delete_tracking_ref(
               fixture.repo_path,
               namespace,
               source_ref,
               diverged_oid,
               deadline_ms: 1_000
             )

    assert {:ok, nil} =
             GitCore.exact_tracking_ref(fixture.repo_path, namespace, source_ref)
  end

  test "tracking refs retain annotated tag objects and validate branch targets", %{
    fixture: fixture
  } do
    tree_oid = git!(["--git-dir", fixture.repo_path, "rev-parse", "#{fixture.head_oid}^{tree}"])
    tag_oid = fixture.tag_oid

    assert {:error,
            %GitCore.Error{kind: :target_not_commit, operation: :compare_and_swap_tracking_ref}} =
             GitCore.compare_and_swap_tracking_ref(
               fixture.repo_path,
               "mirror-42",
               "refs/heads/tree",
               nil,
               tree_oid,
               deadline_ms: 1_000
             )

    assert {:ok, ^tag_oid} =
             GitCore.compare_and_swap_tracking_ref(
               fixture.repo_path,
               "mirror-42",
               "refs/tags/v1.0.0",
               nil,
               tag_oid,
               deadline_ms: 1_000
             )

    assert {:ok, ^tag_oid} =
             GitCore.exact_tracking_ref(
               fixture.repo_path,
               "mirror-42",
               "refs/tags/v1.0.0"
             )
  end

  test "tracking creation has one exact winner and config-lock waits are bounded", %{
    fixture: fixture
  } do
    namespace = "raced"
    source_ref = "refs/heads/main"

    results =
      [fixture.root_oid, fixture.head_oid]
      |> Task.async_stream(
        fn proposed_oid ->
          GitCore.compare_and_swap_tracking_ref(
            fixture.repo_path,
            namespace,
            source_ref,
            nil,
            proposed_oid,
            deadline_ms: 1_000
          )
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _oid}, &1)) == 1

    assert Enum.count(results, fn
             {:error,
              %GitCore.Error{kind: :ref_exists, operation: :compare_and_swap_tracking_ref}} ->
               true

             _other ->
               false
           end) == 1

    isolated_repo = Path.join(Path.dirname(fixture.repo_path), "locked-config.git")
    git!(["init", "--bare", isolated_repo])
    git!(["--git-dir", isolated_repo, "fetch", fixture.repo_path, fixture.head_oid])
    File.write!(Path.join(isolated_repo, "config.lock"), "held by test")

    assert {:error, %GitCore.Error{kind: :ref_timeout, operation: :compare_and_swap_tracking_ref}} =
             GitCore.compare_and_swap_tracking_ref(
               isolated_repo,
               "locked",
               source_ref,
               nil,
               fixture.head_oid,
               deadline_ms: 5
             )

    assert {:ok, nil} = GitCore.exact_tracking_ref(isolated_repo, "locked", source_ref)
  end

  defp fixture(tmp_dir) do
    work_path = Path.join(tmp_dir, "mirror-primitives-work")
    repo_path = Path.join(tmp_dir, "mirror-primitives.git")

    git!(["init", work_path])
    git!(["-C", work_path, "config", "user.name", "Fornacast Test"])
    git!(["-C", work_path, "config", "user.email", "test@example.com"])

    File.write!(Path.join(work_path, "README.md"), "root\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "root"])
    git!(["-C", work_path, "branch", "-M", "main"])
    root_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    File.write!(Path.join(work_path, "README.md"), "head\n")
    git!(["-C", work_path, "commit", "-am", "head"])
    head_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "tag", "-a", "v1.0.0", "-m", "version 1"])
    tag_oid = git!(["-C", work_path, "rev-parse", "refs/tags/v1.0.0"])

    git!(["-C", work_path, "checkout", "-b", "diverged", root_oid])
    File.write!(Path.join(work_path, "diverged.txt"), "diverged\n")
    git!(["-C", work_path, "add", "diverged.txt"])
    git!(["-C", work_path, "commit", "-m", "diverged"])
    diverged_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    git!(["init", "--bare", repo_path])
    git!(["-C", work_path, "push", repo_path, "main:refs/heads/main"])
    git!(["-C", work_path, "push", repo_path, "diverged:refs/heads/diverged"])
    git!(["-C", work_path, "push", repo_path, "refs/tags/v1.0.0"])

    %{
      work_path: work_path,
      repo_path: repo_path,
      root_oid: root_oid,
      head_oid: head_oid,
      diverged_oid: diverged_oid,
      tag_oid: tag_oid
    }
  end

  defp restore_limits(nil), do: Application.delete_env(:git_core, :limits)
  defp restore_limits(limits), do: Application.put_env(:git_core, :limits, limits)

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

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end
