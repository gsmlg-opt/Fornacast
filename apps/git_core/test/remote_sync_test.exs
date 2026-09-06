defmodule GitCore.RemoteSyncTest do
  use ExUnit.Case, async: false

  alias GitCore.Remote.{ObservedRef, RefUpdate, SyncRequest}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, fixture: fixture(tmp_dir)}
  end

  test "fetches only standard refs into a hidden caller-owned tracking namespace", %{
    fixture: fixture,
    tmp_dir: tmp_dir
  } do
    request = sync_request(fixture)
    credential_root = Path.join(tmp_dir, "credentials")

    assert {:ok,
            [
              %ObservedRef{ref: "refs/heads/main", oid: main_oid},
              %ObservedRef{ref: "refs/tags/v1.0.0", oid: tag_oid}
            ]} =
             GitCore.Remote.fetch_observed_refs(request, "github_pat_secret", "mirror-42",
               git: fixture.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert main_oid == fixture.root_oid
    assert tag_oid == fixture.tag_oid

    assert {:ok, ^main_oid} =
             GitCore.exact_tracking_ref(
               fixture.local_path,
               "mirror-42",
               "refs/heads/main"
             )

    assert {:ok, ^tag_oid} =
             GitCore.exact_tracking_ref(
               fixture.local_path,
               "mirror-42",
               "refs/tags/v1.0.0"
             )

    assert git!([
             "--git-dir",
             fixture.local_path,
             "for-each-ref",
             "refs/fornacast/mirrors/mirror-42/pull"
           ]) == ""

    assert {:ok, nil} = GitCore.exact_ref(fixture.local_path, "refs/heads/main")
    assert {:ok, nil} = GitCore.exact_ref(fixture.local_path, "refs/tags/v1.0.0")

    assert {:ok,
            [
              %ObservedRef{ref: "refs/heads/main", oid: ^main_oid},
              %ObservedRef{ref: "refs/tags/v1.0.0", oid: ^tag_oid}
            ]} =
             GitCore.Remote.list_observed_refs(fixture.local_path, "mirror-42")

    refute git!(["ls-remote", fixture.local_path]) =~ "refs/fornacast/"

    config = git!(["--git-dir", fixture.local_path, "config", "--local", "--list"])
    assert config =~ "transfer.hiderefs=refs/fornacast/"
    refute config =~ "remote."
    refute config =~ "github_pat_secret"
    assert {:ok, []} = File.ls(credential_root)
  end

  test "pushes atomic exact-state branch and tag updates without force", %{
    fixture: fixture,
    tmp_dir: tmp_dir
  } do
    request = sync_request(fixture)
    credential_root = Path.join(tmp_dir, "push-credentials")

    updates = [
      %RefUpdate{
        ref: "refs/heads/main",
        expected_oid: fixture.root_oid,
        proposed_oid: fixture.head_oid
      },
      %RefUpdate{
        ref: "refs/heads/release",
        expected_oid: nil,
        proposed_oid: fixture.head_oid
      },
      %RefUpdate{
        ref: "refs/tags/v2.0.0",
        expected_oid: nil,
        proposed_oid: fixture.tag_two_oid
      }
    ]

    assert :ok =
             GitCore.Remote.push_refs(request, "github_pat_secret", updates,
               git: fixture.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert remote_ref(fixture, "refs/heads/main") == fixture.head_oid
    assert remote_ref(fixture, "refs/heads/release") == fixture.head_oid
    assert remote_ref(fixture, "refs/tags/v2.0.0") == fixture.tag_two_oid

    config = git!(["--git-dir", fixture.local_path, "config", "--local", "--list"])
    refute config =~ "remote."
    refute config =~ "github_pat_secret"
    assert {:ok, []} = File.ls(credential_root)
  end

  test "rejects stale and divergent pushes without changing remote refs", %{fixture: fixture} do
    request = sync_request(fixture)
    opts = remote_opts(fixture)

    assert :ok =
             GitCore.Remote.push_refs(
               request,
               "github_pat_secret",
               [
                 %RefUpdate{
                   ref: "refs/heads/main",
                   expected_oid: fixture.root_oid,
                   proposed_oid: fixture.head_oid
                 }
               ],
               opts
             )

    assert {:error, %GitCore.Remote.Error{kind: :stale_remote}} =
             GitCore.Remote.push_refs(
               request,
               "github_pat_secret",
               [
                 %RefUpdate{
                   ref: "refs/heads/main",
                   expected_oid: fixture.root_oid,
                   proposed_oid: fixture.diverged_oid
                 }
               ],
               opts
             )

    assert remote_ref(fixture, "refs/heads/main") == fixture.head_oid

    assert {:error, %GitCore.Remote.Error{kind: :non_fast_forward}} =
             GitCore.Remote.push_refs(
               request,
               "github_pat_secret",
               [
                 %RefUpdate{
                   ref: "refs/heads/main",
                   expected_oid: fixture.head_oid,
                   proposed_oid: fixture.diverged_oid
                 }
               ],
               opts
             )

    assert {:error, %GitCore.Remote.Error{kind: :tag_retarget}} =
             GitCore.Remote.push_refs(
               request,
               "github_pat_secret",
               [
                 %RefUpdate{
                   ref: "refs/tags/v1.0.0",
                   expected_oid: fixture.tag_oid,
                   proposed_oid: fixture.tag_two_oid
                 }
               ],
               opts
             )

    assert remote_ref(fixture, "refs/heads/main") == fixture.head_oid
    assert remote_ref(fixture, "refs/tags/v1.0.0") == fixture.tag_oid
  end

  test "deletes a remote ref only at its exact expected oid", %{fixture: fixture} do
    request = sync_request(fixture)
    opts = remote_opts(fixture)

    assert :ok =
             GitCore.Remote.delete_ref(
               request,
               "github_pat_secret",
               "refs/heads/main",
               fixture.root_oid,
               opts
             )

    assert remote_ref(fixture, "refs/heads/main") == nil

    assert {:error, %GitCore.Remote.Error{kind: :stale_remote}} =
             GitCore.Remote.delete_ref(
               request,
               "github_pat_secret",
               "refs/tags/v1.0.0",
               fixture.head_oid,
               opts
             )

    assert remote_ref(fixture, "refs/tags/v1.0.0") == fixture.tag_oid
  end

  defp fixture(tmp_dir) do
    real_git = System.find_executable("git") || flunk("git executable is required")
    bash = System.find_executable("bash") || flunk("bash executable is required")
    work_path = Path.join(tmp_dir, "work")
    remote_path = Path.join(tmp_dir, "remote.git")
    local_path = Path.join(tmp_dir, "local.git")

    git!(["init", work_path])
    git!(["-C", work_path, "config", "user.name", "Fornacast Test"])
    git!(["-C", work_path, "config", "user.email", "test@example.com"])
    File.write!(Path.join(work_path, "README.md"), "main\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "main"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "tag", "-a", "v1.0.0", "-m", "version 1"])

    root_oid = git!(["-C", work_path, "rev-parse", "refs/heads/main"])
    tag_oid = git!(["-C", work_path, "rev-parse", "refs/tags/v1.0.0"])

    git!(["init", "--bare", remote_path])
    git!(["--git-dir", remote_path, "config", "receive.denyDeleteCurrent", "ignore"])
    git!(["-C", work_path, "push", remote_path, "refs/heads/main", "refs/tags/v1.0.0"])

    File.write!(Path.join(work_path, "README.md"), "head\n")
    git!(["-C", work_path, "commit", "-am", "head"])
    git!(["-C", work_path, "tag", "-a", "v2.0.0", "-m", "version 2"])
    head_oid = git!(["-C", work_path, "rev-parse", "refs/heads/main"])
    tag_two_oid = git!(["-C", work_path, "rev-parse", "refs/tags/v2.0.0"])

    git!(["-C", work_path, "checkout", "-b", "diverged", root_oid])
    File.write!(Path.join(work_path, "README.md"), "diverged\n")
    git!(["-C", work_path, "commit", "-am", "diverged"])
    diverged_oid = git!(["-C", work_path, "rev-parse", "refs/heads/diverged"])
    git!(["-C", work_path, "checkout", "main"])

    git!(["--git-dir", remote_path, "update-ref", "refs/pull/1/head", root_oid])
    git!(["--git-dir", remote_path, "update-ref", "refs/fornacast/private", root_oid])
    git!(["init", "--bare", local_path])

    git!([
      "--git-dir",
      local_path,
      "fetch",
      "--no-write-fetch-head",
      work_path,
      "refs/heads/main",
      "refs/heads/diverged",
      "refs/tags/v2.0.0"
    ])

    %{
      git: git_adapter!(tmp_dir, bash, real_git, remote_path),
      diverged_oid: diverged_oid,
      head_oid: head_oid,
      local_path: local_path,
      remote_path: remote_path,
      root_oid: root_oid,
      tag_oid: tag_oid,
      tag_two_oid: tag_two_oid
    }
  end

  defp git_adapter!(tmp_dir, bash, real_git, remote_path) do
    adapter = Path.join(tmp_dir, "git-adapter")

    File.write!(adapter, """
    #!#{bash}
    set -euo pipefail
    translated=()
    for argument in "$@"; do
      case "$argument" in
        https://github.com/octocat/hello-world.git) translated+=(#{shell_quote(remote_path)}) ;;
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

  defp sync_request(fixture) do
    struct!(SyncRequest,
      provider: :github,
      owner: "octocat",
      repository: "hello-world",
      credential_login: "verified-octocat",
      repository_path: fixture.local_path
    )
  end

  defp public_resolver do
    fn
      "github.com", :a -> [{140, 82, 121, 3}]
      "github.com", :aaaa -> [{0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}]
    end
  end

  defp remote_opts(fixture) do
    [
      git: fixture.git,
      resolver: public_resolver(),
      credential_root: Path.join(Path.dirname(fixture.local_path), "credentials")
    ]
  end

  defp remote_ref(fixture, ref) do
    git = System.find_executable("git") || flunk("git executable is required")

    case System.cmd(
           git,
           ["--git-dir", fixture.remote_path, "rev-parse", "--verify", "--quiet", ref],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {_output, 1} -> nil
      {output, status} -> flunk("remote ref read failed (#{status}): #{output}")
    end
  end

  defp git!(arguments) do
    git = System.find_executable("git") || flunk("git executable is required")

    case System.cmd(git, arguments, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{inspect(arguments)} failed (#{status}): #{output}")
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
