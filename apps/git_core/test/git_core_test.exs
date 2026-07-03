defmodule GitCoreTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "initializes and opens a bare repository through the Rust NIF", %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "demo.git")

    assert {:ok, _path} = GitCore.init_bare(repo_path)
    assert {:ok, true} = GitCore.is_bare_repository?(repo_path)
    assert {:ok, true} = GitCore.empty?(repo_path)
  end

  @tag :tmp_dir
  test "lists branch and tag refs through the Rust NIF", %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "demo.git")
    work_path = Path.join(tmp_dir, "work")

    assert {:ok, _path} = GitCore.init_bare(repo_path)

    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])
    git!(["-C", work_path, "tag", "v0.1"])
    git!(["-C", work_path, "push", "origin", "v0.1"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    assert {:ok, false} = GitCore.empty?(repo_path)

    assert {:ok, [%GitCore.Ref{name: "refs/heads/main", kind: :branch, target: branch_target}]} =
             GitCore.branches(repo_path)

    assert {:ok, [%GitCore.Ref{name: "refs/tags/v0.1", kind: :tag, target: tag_target}]} =
             GitCore.tags(repo_path)

    assert branch_target == tag_target

    assert {:ok, [%GitCore.Commit{oid: ^commit_oid, title: "Initial commit"}]} =
             GitCore.commit_history(repo_path, "main")

    assert {:ok, %GitCore.Commit{oid: ^commit_oid, author_name: "Fornacast Test"}} =
             GitCore.commit(repo_path, commit_oid)

    assert {:ok, [%GitCore.TreeEntry{name: "README.md", kind: :blob}]} =
             GitCore.read_tree(repo_path, "main")

    assert {:ok, %GitCore.Blob{name: "README.md", data: "# Demo\n", binary: false}} =
             GitCore.read_blob(repo_path, "main", "README.md")

    File.write!(Path.join(work_path, "README.md"), "# Demo v2\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Update README"])
    git!(["-C", work_path, "push", "origin", "main"])
    second_commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    assert {:ok,
            %GitCore.CommitDiff{
              files: [
                %GitCore.DiffFile{
                  path: "README.md",
                  status: :modified,
                  binary: false
                }
              ],
              patch: patch,
              truncated: false
            }} = GitCore.diff_commit(repo_path, second_commit_oid)

    assert patch =~ "diff --git a/README.md b/README.md"
    assert patch =~ "-# Demo"
    assert patch =~ "+# Demo v2"

    assert {:ok, %GitCore.CommitDiff{patch: truncated_patch, truncated: true}} =
             GitCore.diff_commit(repo_path, second_commit_oid, limit: 24)

    assert byte_size(truncated_patch) <= 24

    File.write!(Path.join(work_path, "asset.bin"), <<0, 1, 2, 3>>)
    git!(["-C", work_path, "add", "asset.bin"])
    git!(["-C", work_path, "commit", "-m", "Add binary asset"])
    git!(["-C", work_path, "push", "origin", "main"])
    binary_commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    assert {:ok,
            %GitCore.CommitDiff{
              files: [
                %GitCore.DiffFile{
                  path: "asset.bin",
                  status: :added,
                  binary: true
                }
              ],
              patch: binary_patch
            }} = GitCore.diff_commit(repo_path, binary_commit_oid)

    assert binary_patch =~ "Binary files /dev/null and b/asset.bin differ"
  end

  @tag :tmp_dir
  test "generates a pack containing objects reachable from wanted commits", %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "demo.git")
    work_path = Path.join(tmp_dir, "work")
    pack_path = Path.join(tmp_dir, "fornacast.pack")

    assert {:ok, _path} = GitCore.init_bare(repo_path)

    git!(["init", work_path])
    File.mkdir_p!(Path.join(work_path, "lib"))
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    File.write!(Path.join(work_path, "lib/demo.ex"), "defmodule Demo, do: :ok\n")
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    assert {:ok, pack} = GitCore.pack_objects(repo_path, [commit_oid])
    assert <<"PACK", 0, 0, 0, 2, _rest::binary>> = pack

    File.write!(pack_path, pack)
    git!(["index-pack", "--strict", pack_path])
    verify_output = git!(["verify-pack", "-v", Path.rootname(pack_path) <> ".idx"])

    assert verify_output =~ commit_oid
    assert verify_output =~ " commit "
    assert verify_output =~ " tree "
    assert verify_output =~ " blob "
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
