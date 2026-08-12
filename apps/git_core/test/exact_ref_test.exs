defmodule GitCore.ExactRefTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "reads only an exact direct target without peeling or mutating storage", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "exact.git")
    {:ok, _path} = GitCore.init_bare(path)

    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    commit = git!(path, ["commit-tree", tree, "-m", "commit"])
    git!(path, ["update-ref", "refs/heads/main", commit])
    before_snapshot = snapshot(path)

    assert {:ok, ^commit} = GitCore.exact_ref(path, "refs/heads/main", deadline_ms: 1_000)
    assert {:ok, nil} = GitCore.exact_ref(path, "refs/heads/missing", deadline_ms: 1_000)
    assert snapshot(path) == before_snapshot

    assert {:error, %GitCore.Error{kind: :invalid_input}} =
             GitCore.exact_ref(path, "refs/heads/main", deadline_ms: 0)
  end

  defp snapshot(path) do
    {git!(path, ["for-each-ref", "--format=%(refname) %(objectname)"]),
     git!(path, ["count-objects", "-v"])}
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Exact Ref Test"},
      {"GIT_AUTHOR_EMAIL", "exact-ref@example.com"},
      {"GIT_COMMITTER_NAME", "Exact Ref Test"},
      {"GIT_COMMITTER_EMAIL", "exact-ref@example.com"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args],
        env: env,
        stderr_to_stdout: true
      )

    String.trim(output)
  end
end
