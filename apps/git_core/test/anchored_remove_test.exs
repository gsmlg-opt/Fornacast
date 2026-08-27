defmodule GitCore.AnchoredRemoveTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @mount_supported (case {:os.type(), File.read("/proc/self/status")} do
                      {{:unix, :linux}, {:ok, status}} ->
                        case Regex.run(~r/^CapEff:\s*([0-9A-Fa-f]+)$/m, status) do
                          [_, capabilities] ->
                            capabilities
                            |> String.to_integer(16)
                            |> Bitwise.band(Bitwise.bsl(1, 21))
                            |> Kernel.!=(0)

                          _missing ->
                            false
                        end

                      _unsupported ->
                        false
                    end)

  test "observes and removes a regular nested tree by exact anchored identity", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    target = Path.join([storage_root, "quarantine", "repository.git"])
    File.mkdir_p!(Path.join(target, "objects"))
    File.write!(Path.join(target, "objects/pack"), "git data")

    assert {:ok, {:present, proof}} =
             GitCore.contained_tree_identity(
               storage_root,
               ["quarantine", "repository.git"],
               5_000
             )

    assert %{root: root_identity, target: target_identity} = proof
    assert_identity(root_identity)
    assert_identity(target_identity)

    assert {:ok, {:removed, ^proof}} =
             GitCore.remove_contained_tree(
               storage_root,
               ["quarantine", "repository.git"],
               proof,
               5_000
             )

    refute File.exists?(target)
    assert File.dir?(storage_root)

    assert {:ok, {:missing, ^root_identity}} =
             GitCore.remove_contained_tree(
               storage_root,
               ["quarantine", "repository.git"],
               proof,
               5_000
             )
  end

  test "reports a missing target only after reaching its anchored parent", %{tmp_dir: tmp_dir} do
    storage_root = Path.join(tmp_dir, "storage")
    File.mkdir_p!(Path.join(storage_root, "quarantine"))

    assert {:ok, {:missing, root_identity}} =
             GitCore.contained_tree_identity(storage_root, ["quarantine", "missing.git"], 5_000)

    assert_identity(root_identity)
    assert root_identity == anchored_filesystem_identity(storage_root)

    assert {:error, :not_found} =
             GitCore.contained_tree_identity(storage_root, ["missing-parent", "target"], 5_000)
  end

  test "a valid missing absolute storage root reaches the NIF and returns not_found", %{
    tmp_dir: tmp_dir
  } do
    missing_root = Path.join(tmp_dir, "missing-storage")

    proof = %{
      root: %{mode: 0o700, major_device: 0, minor_device: 0, inode: 1},
      target: %{mode: 0o700, major_device: 0, minor_device: 0, inode: 1}
    }

    assert {:error, :not_found} =
             GitCore.contained_tree_identity(missing_root, ["target"], 5_000)

    assert {:error, :not_found} =
             GitCore.remove_contained_tree(missing_root, ["target"], proof, 5_000)
  end

  test "rejects every mismatched root and target proof field without removing the target", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    target = Path.join(storage_root, "target")
    File.mkdir_p!(target)
    proof = observe!(storage_root, ["target"])

    mismatches = [
      {:root, :mode, :mode_mismatch},
      {:root, :major_device, :root_changed},
      {:root, :minor_device, :root_changed},
      {:root, :inode, :root_changed},
      {:target, :mode, :mode_mismatch},
      {:target, :major_device, :identity_mismatch},
      {:target, :minor_device, :identity_mismatch},
      {:target, :inode, :identity_mismatch}
    ]

    for {side, field, expected_error} <- mismatches do
      forged = put_in(proof, [side, field], proof[side][field] + 1)

      assert {:error, ^expected_error} =
               GitCore.remove_contained_tree(storage_root, ["target"], forged, 5_000)

      assert File.dir?(target)
    end
  end

  test "rejects root, configured-ancestor, relative-ancestor, target, and nested symlinks", %{
    tmp_dir: tmp_dir
  } do
    real_root = Path.join(tmp_dir, "real-storage")
    File.mkdir_p!(Path.join(real_root, "parent/target"))

    root_symlink = Path.join(tmp_dir, "storage-link")
    File.ln_s!(real_root, root_symlink)
    assert {:error, :symlink} = GitCore.contained_tree_identity(root_symlink, ["parent"], 5_000)

    configured_parent = Path.join(tmp_dir, "configured")
    File.mkdir_p!(configured_parent)
    File.ln_s!(real_root, Path.join(configured_parent, "ancestor"))

    assert {:error, :symlink} =
             GitCore.contained_tree_identity(
               Path.join(configured_parent, "ancestor"),
               ["parent"],
               5_000
             )

    File.ln_s!(Path.join(real_root, "parent"), Path.join(real_root, "relative-link"))

    assert {:error, :symlink} =
             GitCore.contained_tree_identity(real_root, ["relative-link", "target"], 5_000)

    File.ln_s!(Path.join(real_root, "parent/target"), Path.join(real_root, "target-link"))

    assert {:error, :symlink} =
             GitCore.contained_tree_identity(real_root, ["target-link"], 5_000)

    proof = observe!(real_root, ["parent", "target"])
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)
    nested_link = Path.join(real_root, "parent/target/nested-link")
    File.ln_s!(outside, nested_link)

    assert {:error, :symlink} =
             GitCore.remove_contained_tree(real_root, ["parent", "target"], proof, 5_000)

    assert File.dir?(Path.join(real_root, "parent/target"))
    assert File.lstat!(nested_link).type == :symlink
    assert File.dir?(outside)
  end

  test "rejects a target-name swap after observation and leaves both trees untouched", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    target = Path.join(storage_root, "target")
    original = Path.join(storage_root, "original")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "original"), "original")
    proof = observe!(storage_root, ["target"])

    File.rename!(target, original)
    File.mkdir_p!(target)
    File.write!(Path.join(target, "replacement"), "replacement")

    assert {:error, :identity_mismatch} =
             GitCore.remove_contained_tree(storage_root, ["target"], proof, 5_000)

    assert File.read!(Path.join(original, "original")) == "original"
    assert File.read!(Path.join(target, "replacement")) == "replacement"
  end

  test "rejects configured-root replacement and leaves both roots untouched", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    original_root = Path.join(tmp_dir, "original-storage")
    File.mkdir_p!(Path.join(storage_root, "target"))
    File.write!(Path.join(storage_root, "target/original"), "original")
    proof = observe!(storage_root, ["target"])

    File.rename!(storage_root, original_root)
    File.mkdir_p!(Path.join(storage_root, "target"))
    File.write!(Path.join(storage_root, "target/replacement"), "replacement")

    assert {:error, :root_changed} =
             GitCore.remove_contained_tree(storage_root, ["target"], proof, 5_000)

    assert File.read!(Path.join(original_root, "target/original")) == "original"
    assert File.read!(Path.join(storage_root, "target/replacement")) == "replacement"
  end

  test "preflight rejects FIFO and socket special files without removing siblings", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")

    for kind <- [:fifo, :socket] do
      target = Path.join(storage_root, Atom.to_string(kind))
      File.mkdir_p!(target)
      sibling = Path.join(target, "keep")
      File.write!(sibling, "keep")
      special = Path.join(target, Atom.to_string(kind))
      cleanup = create_special_file!(kind, special)
      proof = observe!(storage_root, [Atom.to_string(kind)])

      try do
        assert {:error, :special_file} =
                 GitCore.remove_contained_tree(
                   storage_root,
                   [Atom.to_string(kind)],
                   proof,
                   5_000
                 )

        assert File.read!(sibling) == "keep"
        assert File.exists?(special)
      after
        cleanup.()
      end
    end
  end

  test "rejects invalid roots, segments, deadlines, and proof shapes before the NIF", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    File.mkdir_p!(Path.join(storage_root, "target"))
    proof = observe!(storage_root, ["target"])

    invalid_identity_requests = [
      {"/", ["target"], 1},
      {"relative", ["target"], 1},
      {storage_root <> "/", ["target"], 1},
      {storage_root <> "\\unsafe", ["target"], 1},
      {storage_root <> <<0>>, ["target"], 1},
      {"/" <> <<255>>, ["target"], 1},
      {"/" <> String.duplicate("x", 4_096), ["target"], 1},
      {storage_root, [], 1},
      {storage_root, ["/absolute"], 1},
      {storage_root, [""], 1},
      {storage_root, ["."], 1},
      {storage_root, [".."], 1},
      {storage_root, ["back\\slash"], 1},
      {storage_root, ["nul" <> <<0>>], 1},
      {storage_root, [<<255>>], 1},
      {storage_root, [String.duplicate("x", 256)], 1},
      {storage_root, List.duplicate("x", 129), 1},
      {storage_root, ["target"], -1},
      {storage_root, ["target"], :infinity}
    ]

    for {root, segments, deadline} <- invalid_identity_requests do
      assert {:error, :invalid_argument} =
               GitCore.contained_tree_identity(root, segments, deadline)
    end

    identities = [
      %{},
      %{root: proof.root},
      Map.put(proof, :extra, 1),
      put_in(proof, [:root], Map.put(proof.root, :extra, 1)),
      put_in(proof, [:target, :mode], -1),
      put_in(proof, [:target, :major_device], -1),
      put_in(proof, [:target, :minor_device], -1),
      put_in(proof, [:target, :inode], 0),
      put_in(proof, [:target, :inode], "1")
    ]

    for invalid_proof <- identities do
      assert {:error, :invalid_argument} =
               GitCore.remove_contained_tree(
                 storage_root,
                 ["target"],
                 invalid_proof,
                 5_000
               )

      assert File.dir?(Path.join(storage_root, "target"))
    end
  end

  test "zero deadline fails before observation or removal has an effect", %{tmp_dir: tmp_dir} do
    storage_root = Path.join(tmp_dir, "storage")
    target = Path.join(storage_root, "target")
    File.mkdir_p!(target)
    proof = observe!(storage_root, ["target"])

    assert {:error, :deadline_exceeded} =
             GitCore.contained_tree_identity(storage_root, ["target"], 0)

    assert {:error, :deadline_exceeded} =
             GitCore.remove_contained_tree(storage_root, ["target"], proof, 0)

    assert File.dir?(target)
  end

  test "enforces recursive depth and entry limits during read-only preflight", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    deep_target = Path.join(storage_root, "deep")

    deep_leaf =
      Enum.reduce(1..129, deep_target, fn index, parent ->
        child = Path.join(parent, Integer.to_string(index))
        File.mkdir_p!(child)
        child
      end)

    File.write!(Path.join(deep_leaf, "keep"), "keep")
    deep_proof = observe!(storage_root, ["deep"])

    assert {:error, :depth_limit} =
             GitCore.remove_contained_tree(storage_root, ["deep"], deep_proof, 30_000)

    assert File.read!(Path.join(deep_leaf, "keep")) == "keep"

    entry_target = Path.join(storage_root, "entries")
    File.mkdir_p!(entry_target)

    for index <- 0..10_000 do
      File.write!(Path.join(entry_target, Integer.to_string(index)), "")
    end

    entry_proof = observe!(storage_root, ["entries"])

    assert {:error, :entry_limit} =
             GitCore.remove_contained_tree(storage_root, ["entries"], entry_proof, 30_000)

    assert File.dir?(entry_target)
  end

  test "a bounded timeout preserves the target root and exact-proof replay can finish", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    target = Path.join(storage_root, "target")
    File.mkdir_p!(target)

    for index <- 0..4_999 do
      File.write!(Path.join(target, Integer.to_string(index)), "data")
    end

    proof = observe!(storage_root, ["target"])

    assert {:error, :deadline_exceeded} =
             GitCore.remove_contained_tree(storage_root, ["target"], proof, 1)

    assert anchored_filesystem_identity(target) == proof.target

    assert {:ok, {:removed, ^proof}} =
             GitCore.remove_contained_tree(storage_root, ["target"], proof, 30_000)

    refute File.exists?(target)
  end

  unless @mount_supported do
    @tag skip: "host cannot create a private tmpfs mount for cross-device coverage"
  end

  test "rejects a descendant filesystem-device crossing when the host permits a mount", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    target = Path.join(storage_root, "target")
    mountpoint = Path.join(target, "mounted")
    File.mkdir_p!(mountpoint)
    proof = observe!(storage_root, ["target"])

    {output, status} =
      System.cmd("mount", ["-t", "tmpfs", "none", mountpoint], stderr_to_stdout: true)

    assert status == 0, "mount capability probe succeeded but tmpfs mount failed: #{output}"

    try do
      File.write!(Path.join(mountpoint, "keep"), "mounted")

      assert {:error, :filesystem_device_changed} =
               GitCore.remove_contained_tree(storage_root, ["target"], proof, 5_000)

      assert File.read!(Path.join(mountpoint, "keep")) == "mounted"
      assert File.dir?(target)
    after
      {unmount_output, unmount_status} =
        System.cmd("umount", [mountpoint], stderr_to_stdout: true)

      assert unmount_status == 0, "failed to unmount tmpfs fixture: #{unmount_output}"
    end
  end

  test "production source is descriptor-relative and has no recursive path fallback" do
    source =
      __DIR__
      |> Path.join("../native/fornacast_git_core/src/anchored_remove.rs")
      |> File.read!()

    assert source =~ "openat("
    assert source =~ "statat("
    assert source =~ "unlinkat("
    assert source =~ ~s(target_os = "linux")
    assert source =~ ~s(target_os = "macos")
    assert source =~ "UnsupportedPlatform"
    assert source =~ "DirectoryManifest"
    assert source =~ "ManifestEntry"
    refute source =~ "directory_entry_names"
    refute source =~ "remove_dir_all"
    refute source =~ "File.rm_rf"
    refute source =~ "canonicalize("
  end

  defp observe!(storage_root, segments) do
    assert {:ok, {:present, proof}} =
             GitCore.contained_tree_identity(storage_root, segments, 5_000)

    proof
  end

  defp anchored_filesystem_identity(path) do
    parent = Path.dirname(path)

    assert {:ok, {:present, %{target: identity}}} =
             GitCore.contained_tree_identity(parent, [Path.basename(path)], 5_000)

    identity
  end

  defp create_special_file!(:fifo, path) do
    {"", 0} = System.cmd("mkfifo", [path], stderr_to_stdout: true)
    fn -> :ok end
  end

  defp create_special_file!(:socket, path) do
    script = "import socket; s=socket.socket(socket.AF_UNIX); s.bind('socket'); s.close()"

    {"", 0} =
      System.cmd("python3", ["-c", script], cd: Path.dirname(path), stderr_to_stdout: true)

    fn -> :ok end
  end

  defp assert_identity(identity) do
    assert %{mode: mode, major_device: major, minor_device: minor, inode: inode} = identity
    assert map_size(identity) == 4
    assert is_integer(mode) and mode >= 0
    assert is_integer(major) and major >= 0
    assert is_integer(minor) and minor >= 0
    assert is_integer(inode) and inode > 0
  end
end
