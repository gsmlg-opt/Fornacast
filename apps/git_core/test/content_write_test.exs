defmodule GitCore.ContentWriteTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "content planning is effect-free and insertion is idempotent until exact CAS", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "bare.git")
    {:ok, _} = GitCore.init_bare(path)

    signature = %GitCore.Signature{
      name: "Tester",
      email: "test@example.test",
      seconds: 1_700_000_000,
      offset_minutes: 0
    }

    attrs = %{
      action: :create,
      ref: "refs/heads/main",
      path: "nested/file.txt",
      expected_ref_oid: nil,
      expected_blob_oid: nil,
      content: "hello\n",
      message: "Initial commit",
      author: signature,
      committer: signature
    }

    {:ok, plan} = GitCore.plan_content_change(path, attrs, [])
    assert {:ok, nil} = GitCore.exact_ref(path, "refs/heads/main")

    {objects, 0} =
      System.cmd("git", [
        "--git-dir",
        path,
        "cat-file",
        "--batch-all-objects",
        "--batch-check=%(objectname)"
      ])

    assert objects == ""
    assert {:ok, oid} = GitCore.write_content_change(path, plan, [])
    assert {:ok, ^oid} = GitCore.write_content_change(path, plan, [])

    assert {:ok, ^oid} =
             GitCore.compare_and_swap_ref(path, "refs/heads/main", nil, oid, :fast_forward, [])

    {"hello\n", 0} = System.cmd("git", ["--git-dir", path, "show", "main:nested/file.txt"])

    assert {:error, %GitCore.Error{kind: :invalid_input}} =
             GitCore.plan_content_change(
               path,
               %{
                 attrs
                 | action: :update,
                   expected_ref_oid: oid,
                   expected_blob_oid: String.duplicate("0", 40)
               },
               []
             )

    {:ok, deletion} =
      GitCore.plan_content_change(
        path,
        %{
          attrs
          | action: :delete,
            expected_ref_oid: oid,
            expected_blob_oid: plan.proposed_blob_oid,
            content: ""
        },
        []
      )

    {:ok, deleted} = GitCore.write_content_change(path, deletion)

    {:ok, ^deleted} =
      GitCore.compare_and_swap_ref(path, "refs/heads/main", oid, deleted, :fast_forward, [])

    assert {"", 0} = System.cmd("git", ["--git-dir", path, "ls-tree", "main"])

    assert {:error, %GitCore.Error{kind: :path_not_found}} =
             GitCore.content(path, "main", "nested")
  end

  test "content reads never follow symlinks and regular-file updates preserve executable mode", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "modes.git")
    {:ok, _} = GitCore.init_bare(path, "main")
    work = Path.join(dir, "work")
    git!(["init", "--initial-branch=main", work])
    git!(["-C", work, "config", "user.name", "Tester"])
    git!(["-C", work, "config", "user.email", "test@example.test"])
    File.write!(Path.join(work, "run.sh"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(work, "run.sh"), 0o755)
    File.ln_s!("/etc/passwd", Path.join(work, "escape"))
    git!(["-C", work, "add", "."])
    git!(["-C", work, "commit", "-m", "Modes"])
    git!(["-C", work, "push", path, "HEAD:refs/heads/main"])
    {:ok, parent} = GitCore.exact_ref(path, "refs/heads/main")

    assert {:error, %GitCore.Error{kind: :path_not_found}} =
             GitCore.content(path, "main", "escape/passwd")

    {:ok, symlink} = GitCore.content(path, "main", "escape")
    assert symlink.type == "symlink"
    assert symlink.content == "/etc/passwd"
    GitCore.GitData.release_content(symlink)

    signature = %GitCore.Signature{
      name: "Tester",
      email: "test@example.test",
      seconds: 1_700_000_000,
      offset_minutes: 0
    }

    attrs = %{
      action: :update,
      ref: "refs/heads/main",
      path: "escape",
      expected_ref_oid: parent,
      expected_blob_oid: symlink.oid,
      content: "unsafe",
      message: "Update",
      author: signature,
      committer: signature
    }

    assert {:error, %GitCore.Error{kind: :invalid_input}} =
             GitCore.plan_content_change(path, attrs)

    {:ok, executable} = GitCore.content(path, "main", "run.sh")
    GitCore.GitData.release_content(executable)

    {:ok, plan} =
      GitCore.plan_content_change(path, %{
        attrs
        | path: "run.sh",
          expected_blob_oid: executable.oid,
          content: "#!/bin/sh\nexit 1\n"
      })

    {:ok, proposed} = GitCore.write_content_change(path, plan)

    assert {:ok, ^proposed} =
             GitCore.compare_and_swap_ref(
               path,
               "refs/heads/main",
               parent,
               proposed,
               :fast_forward,
               []
             )

    assert git!(["--git-dir", path, "ls-tree", "main", "run.sh"]) =~ "100755 blob "
  end

  defp git!(args) do
    {output, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
