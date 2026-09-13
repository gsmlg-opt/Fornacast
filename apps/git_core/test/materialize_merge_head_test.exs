defmodule GitCore.MaterializeMergeHeadTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "materializes a disjoint head object closure without changing refs or config", %{
    tmp_dir: tmp_dir
  } do
    fixture = disjoint_fixture!(tmp_dir)
    refs_before = refs(fixture.destination_path)
    config_before = config(fixture.destination_path)

    assert {:ok, head_oid} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid,
               commit_limit: 1
             )

    assert head_oid == fixture.head_oid
    assert git!(["--git-dir", fixture.destination_path, "cat-file", "-t", head_oid]) == "commit"

    assert git!(["--git-dir", fixture.destination_path, "ls-tree", "-r", head_oid]) =~
             "head-only.txt"

    assert refs(fixture.destination_path) == refs_before
    assert config(fixture.destination_path) == config_before

    objects_after_first = objects(fixture.destination_path)

    assert {:ok, ^head_oid} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid
             )

    assert objects(fixture.destination_path) == objects_after_first
    assert refs(fixture.destination_path) == refs_before
    assert config(fixture.destination_path) == config_before
  end

  test "rejects bounds before publishing any object", %{tmp_dir: tmp_dir} do
    for {suffix, opts, kind} <- [
          {"commits", [commit_limit: 0], :commit_limit},
          {"trees", [tree_entry_limit: 0], :tree_entry_limit},
          {"bytes", [byte_limit: 1], :merge_byte_limit},
          {"deadline", [deadline_ms: 0], :scan_timeout}
        ] do
      fixture = disjoint_fixture!(Path.join(tmp_dir, suffix))
      refs_before = refs(fixture.destination_path)
      config_before = config(fixture.destination_path)
      objects_before = objects(fixture.destination_path)

      assert {:error, %GitCore.Error{kind: ^kind, operation: :materialize_merge_head}} =
               GitCore.materialize_merge_head(
                 fixture.source_path,
                 fixture.destination_path,
                 fixture.head_oid,
                 opts
               )

      assert objects(fixture.destination_path) == objects_before
      assert refs(fixture.destination_path) == refs_before
      assert config(fixture.destination_path) == config_before
    end
  end

  test "fully validates the missing closure before publishing", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source.git")
    destination_path = Path.join(tmp_dir, "destination.git")
    git!(["init", "--bare", source_path])
    git!(["init", "--bare", destination_path])

    first_path = Path.join(tmp_dir, "one.txt")
    missing_path = Path.join(tmp_dir, "two.txt")
    File.write!(first_path, "one\n")
    File.write!(missing_path, "two\n")
    first_blob = git!(["--git-dir", source_path, "hash-object", "-w", first_path])
    missing_blob = git!(["--git-dir", source_path, "hash-object", "-w", missing_path])
    index_path = Path.join(tmp_dir, "materialize.index")

    git_env!(
      [
        "--git-dir",
        source_path,
        "update-index",
        "--add",
        "--cacheinfo",
        "100644,#{first_blob},one.txt",
        "--cacheinfo",
        "100644,#{missing_blob},two.txt"
      ],
      [{"GIT_INDEX_FILE", index_path}]
    )

    tree = git_env!(["--git-dir", source_path, "write-tree"], [{"GIT_INDEX_FILE", index_path}])
    head_oid = git!(["--git-dir", source_path, "commit-tree", tree, "-m", "corrupt closure"])

    File.rm!(loose_object_path(source_path, missing_blob))
    objects_before = objects(destination_path)

    assert {:error, %GitCore.Error{kind: :corrupt_repository, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(source_path, destination_path, head_oid)

    assert objects(destination_path) == objects_before
    assert git_status(destination_path, ["cat-file", "-e", first_blob]) != 0
  end

  test "repairs a partial destination closure behind an existing head", %{tmp_dir: tmp_dir} do
    fixture = disjoint_fixture!(tmp_dir)
    tree_oid = git!(["--git-dir", fixture.source_path, "rev-parse", "#{fixture.head_oid}^{tree}"])

    blob_oid =
      git!(["--git-dir", fixture.source_path, "rev-parse", "#{fixture.head_oid}:head-only.txt"])

    copy_loose_object!(fixture.source_path, fixture.destination_path, fixture.head_oid)
    copy_loose_object!(fixture.source_path, fixture.destination_path, tree_oid)

    assert git_status(fixture.destination_path, ["cat-file", "-e", fixture.head_oid]) == 0
    assert git_status(fixture.destination_path, ["cat-file", "-e", blob_oid]) != 0

    assert {:ok, head_oid} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid,
               commit_limit: 0,
               tree_entry_limit: 0
             )

    assert head_oid == fixture.head_oid

    assert git!(["--git-dir", fixture.destination_path, "cat-file", "blob", blob_oid]) ==
             "head only"

    assert git!(["--git-dir", fixture.destination_path, "fsck", "--strict", "--no-dangling"]) ==
             ""
  end

  test "rejects a checksum-corrupt existing destination object", %{tmp_dir: tmp_dir} do
    fixture = disjoint_fixture!(tmp_dir)
    tree_oid = git!(["--git-dir", fixture.source_path, "rev-parse", "#{fixture.head_oid}^{tree}"])

    blob_oid =
      git!(["--git-dir", fixture.source_path, "rev-parse", "#{fixture.head_oid}:head-only.txt"])

    copy_loose_object!(fixture.source_path, fixture.destination_path, fixture.head_oid)
    copy_loose_object!(fixture.source_path, fixture.destination_path, tree_oid)
    corrupt = :zlib.compress("blob 10\0corrupted\n")
    corrupt_path = loose_object_path(fixture.destination_path, blob_oid)
    File.mkdir_p!(Path.dirname(corrupt_path))
    File.write!(corrupt_path, corrupt)

    assert {:error, %GitCore.Error{kind: :corrupt_repository, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid
             )

    assert File.read!(corrupt_path) == corrupt
  end

  test "validates repeated object edges against every required kind", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source.git")
    destination_path = Path.join(tmp_dir, "destination.git")
    git!(["init", "--bare", source_path])
    git!(["init", "--bare", destination_path])

    empty = Path.join(tmp_dir, "empty")
    File.write!(empty, "")
    empty_tree = git!(["--git-dir", source_path, "hash-object", "-t", "tree", "-w", empty])
    raw_oid = Base.decode16!(empty_tree, case: :mixed)

    tree =
      write_raw_tree!(source_path, tmp_dir, [
        {"40000", "a-tree", raw_oid},
        {"100644", "b-blob", raw_oid}
      ])

    head_oid = git!(["--git-dir", source_path, "commit-tree", tree, "-m", "conflicting edge"])

    assert {:error, %GitCore.Error{kind: :corrupt_repository, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(source_path, destination_path, head_oid)

    assert objects(destination_path) == ""
  end

  test "rejects an oversized declared body from its header before publication", %{
    tmp_dir: tmp_dir
  } do
    source_path = Path.join(tmp_dir, "source.git")
    destination_path = Path.join(tmp_dir, "destination.git")
    git!(["init", "--bare", source_path])
    git!(["init", "--bare", destination_path])

    oversized_oid = String.duplicate("a", 40)

    tree =
      write_raw_tree!(source_path, tmp_dir, [
        {"100644", "oversized.bin", Base.decode16!(oversized_oid, case: :mixed)}
      ])

    head_oid = git!(["--git-dir", source_path, "commit-tree", tree, "-m", "oversized body"])
    oversized_path = loose_object_path(source_path, oversized_oid)
    File.mkdir_p!(Path.dirname(oversized_path))
    File.write!(oversized_path, :zlib.compress("blob 1000000000\0"))

    assert {:error, %GitCore.Error{kind: :merge_byte_limit, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(source_path, destination_path, head_oid)

    assert objects(destination_path) == ""
  end

  test "rejects an oversized existing destination tree before allocation", %{
    tmp_dir: tmp_dir
  } do
    fixture = disjoint_fixture!(tmp_dir)
    tree_oid = git!(["--git-dir", fixture.source_path, "rev-parse", "#{fixture.head_oid}^{tree}"])
    corrupt_path = loose_object_path(fixture.destination_path, tree_oid)
    File.mkdir_p!(Path.dirname(corrupt_path))
    corrupt = :zlib.compress("tree 1000000000\0")
    File.write!(corrupt_path, corrupt)
    refs_before = refs(fixture.destination_path)
    config_before = config(fixture.destination_path)

    assert {:error, %GitCore.Error{kind: :merge_byte_limit, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid
             )

    assert git_status(fixture.destination_path, ["cat-file", "-e", fixture.head_oid]) != 0
    assert File.read!(corrupt_path) == corrupt
    assert refs(fixture.destination_path) == refs_before
    assert config(fixture.destination_path) == config_before
  end

  test "rejects an oversized existing destination commit before allocation", %{
    tmp_dir: tmp_dir
  } do
    fixture = disjoint_fixture!(tmp_dir)
    corrupt_path = loose_object_path(fixture.destination_path, fixture.root_oid)
    corrupt = :zlib.compress("commit 1000000000\0")
    File.chmod!(corrupt_path, 0o600)
    File.write!(corrupt_path, corrupt)
    refs_before = refs(fixture.destination_path)
    config_before = config(fixture.destination_path)

    assert {:error, %GitCore.Error{kind: :merge_byte_limit, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid
             )

    assert git_status(fixture.destination_path, ["cat-file", "-e", fixture.head_oid]) != 0
    assert File.read!(corrupt_path) == corrupt
    assert refs(fixture.destination_path) == refs_before
    assert config(fixture.destination_path) == config_before
  end

  test "materializes between SHA-256 repositories", %{tmp_dir: tmp_dir} do
    fixture = disjoint_fixture!(tmp_dir, object_format: "sha256")
    assert byte_size(fixture.head_oid) == 64

    assert {:ok, head_oid} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               fixture.head_oid,
               commit_limit: 1
             )

    assert head_oid == fixture.head_oid

    assert git!(["--git-dir", fixture.destination_path, "fsck", "--strict", "--no-dangling"]) ==
             ""
  end

  test "requires matching repository hash formats and a source commit head", %{tmp_dir: tmp_dir} do
    fixture = disjoint_fixture!(Path.join(tmp_dir, "wrong-kind"))
    tree_oid = git!(["--git-dir", fixture.source_path, "rev-parse", "#{fixture.head_oid}^{tree}"])
    before = objects(fixture.destination_path)

    assert {:error, %GitCore.Error{kind: :commit_not_found, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               fixture.destination_path,
               tree_oid
             )

    assert objects(fixture.destination_path) == before

    sha256_path = Path.join(tmp_dir, "sha256.git")
    git!(["init", "--bare", "--object-format=sha256", sha256_path])

    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(
               fixture.source_path,
               sha256_path,
               fixture.head_oid
             )

    assert objects(sha256_path) == ""
  end

  test "validates public arguments and option types" do
    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head("source", "destination", "head", deadline_ms: "soon")

    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head("source", "destination", "head",
               changed_path_limit: "many"
             )

    assert {:error, %GitCore.Error{kind: :invalid_input, operation: :materialize_merge_head}} =
             GitCore.materialize_merge_head(:source, "destination", "head")
  end

  defp disjoint_fixture!(tmp_dir, opts \\ []) do
    source_path = Path.join(tmp_dir, "source.git")
    destination_path = Path.join(tmp_dir, "destination.git")
    work_path = Path.join(tmp_dir, "work")
    object_format = Keyword.get(opts, :object_format)

    init_args =
      ["init", "--bare"] ++ if(object_format, do: ["--object-format=#{object_format}"], else: [])

    git!(init_args ++ [source_path])
    git!(init_args ++ [destination_path])
    git!(["clone", source_path, work_path])
    git!(["-C", work_path, "config", "user.name", "Fornacast Test"])
    git!(["-C", work_path, "config", "user.email", "test@example.com"])

    File.write!(Path.join(work_path, "shared.txt"), "shared\n")
    git!(["-C", work_path, "add", "shared.txt"])
    git!(["-C", work_path, "commit", "-m", "shared root"])
    root_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "push", source_path, "HEAD:refs/heads/main"])
    git!(["-C", work_path, "push", destination_path, "HEAD:refs/heads/main"])

    File.write!(Path.join(work_path, "head-only.txt"), "head only\n")
    git!(["-C", work_path, "add", "head-only.txt"])
    git!(["-C", work_path, "commit", "-m", "head only"])
    head_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "push", source_path, "HEAD:refs/heads/feature"])

    assert git_status(destination_path, ["cat-file", "-e", head_oid]) != 0

    %{
      source_path: source_path,
      destination_path: destination_path,
      root_oid: root_oid,
      head_oid: head_oid
    }
  end

  defp refs(path) do
    git!(["--git-dir", path, "for-each-ref", "--format=%(refname) %(objectname)"])
  end

  defp config(path) do
    git!(["--git-dir", path, "config", "--local", "--list", "--show-origin"])
  end

  defp objects(path) do
    git!(["--git-dir", path, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
  end

  defp git_status(path, args) do
    {_, status} = System.cmd("git", ["--git-dir", path | args], stderr_to_stdout: true)
    status
  end

  defp loose_object_path(repo_path, oid) do
    Path.join([
      repo_path,
      "objects",
      binary_part(oid, 0, 2),
      binary_part(oid, 2, byte_size(oid) - 2)
    ])
  end

  defp copy_loose_object!(source_path, destination_path, oid) do
    destination = loose_object_path(destination_path, oid)
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(loose_object_path(source_path, oid), destination)
  end

  defp write_raw_tree!(repository_path, tmp_dir, entries) do
    raw =
      entries
      |> Enum.map(fn {mode, name, oid} -> [mode, " ", name, <<0>>, oid] end)
      |> IO.iodata_to_binary()

    path = Path.join(tmp_dir, "raw-tree-#{System.unique_integer([:positive])}")
    File.write!(path, raw)
    git!(["--git-dir", repository_path, "hash-object", "-t", "tree", "-w", path])
  end

  defp git_env!(args, env) do
    {output, status} = System.cmd("git", args, env: env, stderr_to_stdout: true)
    assert status == 0, "git #{inspect(args)} failed: #{output}"
    String.trim(output)
  end

  defp git!(args) do
    {output, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, "git #{inspect(args)} failed: #{output}"
    String.trim(output)
  end
end
