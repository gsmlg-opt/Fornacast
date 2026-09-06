defmodule GitCore.LFSScanObjectTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "bounded object expansion lets a durable queue cover branch history and annotated tags", %{
    tmp_dir: tmp_dir
  } do
    repo_path = Path.join(tmp_dir, "lfs-scan.git")
    work_path = Path.join(tmp_dir, "work")
    old_pointer = pointer("a", 11)
    new_pointer = pointer("b", 22)

    git!(["init", "--bare", repo_path])
    git!(["init", work_path])
    File.write!(Path.join(work_path, "asset.lfs"), old_pointer)
    File.write!(Path.join(work_path, "ordinary.txt"), "ordinary\n")
    File.write!(Path.join(work_path, "large.bin"), :binary.copy("x", 1_025))
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "old pointer"])
    first_commit = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "tag", "-a", "v1", first_commit, "-m", "v1"])

    File.write!(Path.join(work_path, "asset.lfs"), new_pointer)
    git!(["-C", work_path, "add", "asset.lfs"])
    git!(["-C", work_path, "commit", "-m", "new pointer"])
    head_commit = git!(["-C", work_path, "rev-parse", "HEAD"])
    tag_oid = git!(["-C", work_path, "rev-parse", "refs/tags/v1"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main", "refs/tags/v1"])

    baselines = [
      %{ref_name: "refs/heads/main", oid: head_commit, kind_hint: :commit},
      %{ref_name: "refs/tags/v1", oid: tag_oid, kind_hint: :tag_or_commit}
    ]

    candidates = drain_queue(repo_path, baselines, 1)

    assert candidate_bodies(candidates, "refs/heads/main") ==
             MapSet.new([old_pointer, new_pointer, "ordinary\n"])

    assert candidate_bodies(candidates, "refs/tags/v1") ==
             MapSet.new([old_pointer, "ordinary\n"])

    refute Enum.any?(candidates, &(&1.data == :binary.copy("x", 1_025)))
  end

  test "an object page is replay-safe and rejects a mismatched kind hint", %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "lfs-replay.git")
    work_path = Path.join(tmp_dir, "work")

    git!(["init", "--bare", repo_path])
    git!(["init", work_path])
    File.write!(Path.join(work_path, "one.txt"), "one\n")
    File.write!(Path.join(work_path, "two.txt"), "two\n")
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "two files"])
    commit = git!(["-C", work_path, "rev-parse", "HEAD"])
    tree = git!(["-C", work_path, "rev-parse", "HEAD^{tree}"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    assert {:ok, first} = GitCore.expand_lfs_scan_object(repo_path, tree, :tree, 0, 1)
    assert {:ok, ^first} = GitCore.expand_lfs_scan_object(repo_path, tree, :tree, 0, 1)
    assert first.object_kind == :tree
    assert length(first.children) == 1
    assert is_integer(first.next_offset)

    assert {:ok, second} =
             GitCore.expand_lfs_scan_object(repo_path, tree, :tree, first.next_offset, 1)

    assert length(second.children) == 1
    assert second.next_offset == nil

    assert {:error, %GitCore.Error{kind: :corrupt_repository}} =
             GitCore.expand_lfs_scan_object(repo_path, commit, :blob, 0, 1)

    assert {:error, %GitCore.Error{kind: :invalid_input}} =
             GitCore.expand_lfs_scan_object(repo_path, "not-an-oid", :commit, 0, 1)
  end

  defp drain_queue(repo_path, baselines, limit) do
    queue =
      Enum.map(baselines, fn baseline ->
        %{
          ref_name: baseline.ref_name,
          oid: baseline.oid,
          kind_hint: baseline.kind_hint,
          offset: 0
        }
      end)

    seen = MapSet.new(queue, &{&1.ref_name, &1.oid})
    drain_queue(repo_path, queue, seen, limit, [], 0)
  end

  defp drain_queue(_repo_path, [], _seen, _limit, candidates, _steps),
    do: candidates

  defp drain_queue(repo_path, [work | rest], seen, limit, candidates, steps)
       when steps < 10_000 do
    assert {:ok, expansion} =
             GitCore.expand_lfs_scan_object(
               repo_path,
               work.oid,
               work.kind_hint,
               work.offset,
               limit
             )

    assert length(expansion.children) <= limit

    rest =
      case expansion.next_offset do
        nil -> rest
        offset -> rest ++ [%{work | offset: offset}]
      end

    {rest, seen} =
      Enum.reduce(expansion.children, {rest, seen}, fn child, {queue, seen} ->
        key = {work.ref_name, child.oid}

        if MapSet.member?(seen, key) do
          {queue, seen}
        else
          item = %{ref_name: work.ref_name, oid: child.oid, kind_hint: child.kind, offset: 0}
          {queue ++ [item], MapSet.put(seen, key)}
        end
      end)

    candidates =
      case expansion.candidate do
        nil -> candidates
        candidate -> [Map.put(candidate, :ref_name, work.ref_name) | candidates]
      end

    drain_queue(repo_path, rest, seen, limit, candidates, steps + 1)
  end

  defp drain_queue(_repo_path, _queue, _seen, _limit, _candidates, _steps) do
    flunk("LFS object traversal did not converge")
  end

  defp candidate_bodies(candidates, ref_name) do
    candidates
    |> Enum.filter(&(&1.ref_name == ref_name))
    |> MapSet.new(& &1.data)
  end

  defp pointer(hex_digit, size) do
    "version https://git-lfs.github.com/spec/v1\n" <>
      "oid sha256:#{String.duplicate(hex_digit, 64)}\n" <>
      "size #{size}\n"
  end

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end
