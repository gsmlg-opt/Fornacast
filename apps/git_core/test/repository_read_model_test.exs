defmodule GitCore.RepositoryReadModelTest do
  use ExUnit.Case, async: true

  describe "typed read models" do
    @describetag :typed_errors

    test "define the exact public struct fields" do
      expected_fields = [
        {GitCore.Error, [:kind, :operation, :detail]},
        {GitCore.RefSelector, [:kind, :full_name]},
        {GitCore.RefSummary, [:branch_count, :tag_count, :branches, :tags, :refs_truncated]},
        {GitCore.RefPage, [:refs, :total, :page, :per_page, :total_pages]},
        {GitCore.Snapshot, [:kind, :ref, :oid]},
        {GitCore.Ref, [:name, :kind, :target, :display_name]},
        {GitCore.CommitSummary, [:count, :latest]},
        {GitCore.CommitPage, [:commits, :total, :page, :per_page, :total_pages]},
        {GitCore.Commit,
         [
           :oid,
           :title,
           :message,
           :author_name,
           :author_email,
           :author_time,
           :committer_name,
           :committer_email,
           :committer_time,
           :parents
         ]},
        {GitCore.TreeEntry, [:name, :kind, :mode, :oid]},
        {GitCore.TreeHistoryEntry, [:name, :kind, :mode, :oid, :latest_commit]},
        {GitCore.TreePage, [:entries, :total_entries, :page, :per_page, :total_pages]},
        {GitCore.Blob, [:name, :oid, :size, :data, :truncated, :binary, :non_utf8, :lease]},
        {GitCore.DiffLine, [:type, :old_line, :new_line, :content]},
        {GitCore.DiffFile,
         [
           :path,
           :status,
           :old_oid,
           :new_oid,
           :binary,
           :additions,
           :deletions,
           :truncated,
           :lines
         ]},
        {GitCore.CommitDiff,
         [:files, :patch, :truncated, :changed_files, :additions, :deletions]},
        {GitCore.SearchResult, [:path, :line, :snippet]},
        {GitCore.SearchResults,
         [:scope, :results, :files_scanned, :bytes_scanned, :truncated_reasons]},
        {GitCore.LanguageStat, [:language, :bytes]},
        {GitCore.RepositoryAnalysis,
         [:languages, :total_bytes, :files_scanned, :bytes_scanned, :truncated]}
      ]

      Enum.each(expected_fields, fn {module, fields} ->
        assert Code.ensure_loaded?(module), "expected #{inspect(module)} to be loadable"

        assert function_exported?(module, :__struct__, 0),
               "expected #{inspect(module)} to define a struct"

        actual_fields =
          module.__struct__()
          |> Map.keys()
          |> List.delete(:__struct__)
          |> Enum.sort()

        assert actual_fields == Enum.sort(fields)
      end)
    end
  end

  describe "typed repository read errors" do
    @describetag :typed_errors

    @tag :tmp_dir
    test "classifies an unavailable repository path without inspecting detail", %{
      tmp_dir: tmp_dir
    } do
      missing_path = Path.join(tmp_dir, "missing.git")

      assert_error(GitCore.list_refs(missing_path), :storage_unavailable, :list_refs)
    end

    @tag :tmp_dir
    test "classifies repository open I/O failures as storage unavailable", %{tmp_dir: tmp_dir} do
      repo_path = Path.join(tmp_dir, "unreadable-commondir.git")
      commondir_path = Path.join(repo_path, "commondir")

      assert {:ok, _path} = GitCore.init_bare(repo_path)
      File.mkdir!(commondir_path)

      assert_error(GitCore.list_refs(repo_path), :storage_unavailable, :list_refs)
    end

    @tag :tmp_dir
    test "rejects an existing non-bare repository before reading it", %{tmp_dir: tmp_dir} do
      repo_path = Path.join(tmp_dir, "work")
      git!(["init", repo_path])

      assert_error(
        GitCore.is_bare_repository?(repo_path),
        :invalid_repository,
        :is_bare_repository?
      )

      assert_error(
        GitCore.diff_commit(repo_path, String.duplicate("f", 40)),
        :invalid_repository,
        :diff_commit
      )
    end

    @tag :tmp_dir
    test "classifies unknown refs, commits, missing paths, and wrong path kinds", %{
      tmp_dir: tmp_dir
    } do
      %{repo_path: repo_path} = populated_bare_repository!(tmp_dir)

      assert_error(GitCore.commit_history(repo_path, "missing"), :ref_not_found, :commit_history)

      assert_error(
        GitCore.commit(repo_path, String.duplicate("f", 40)),
        :commit_not_found,
        :commit
      )

      assert_error(GitCore.read_tree(repo_path, "main", "missing"), :path_not_found, :read_tree)
      assert_error(GitCore.read_tree(repo_path, "main", "README.md"), :path_not_found, :read_tree)
      assert_error(GitCore.read_blob(repo_path, "main", "lib"), :path_not_found, :read_blob)
    end

    @tag :tmp_dir
    test "preserves legacy repository reads for revision selectors", %{tmp_dir: tmp_dir} do
      %{repo_path: repo_path, commit_oid: commit_oid} = populated_bare_repository!(tmp_dir)
      git!(["--git-dir", repo_path, "symbolic-ref", "HEAD", "refs/heads/main"])

      selectors = ["main", "refs/heads/main", "HEAD", commit_oid]

      operations = [
        {:commit_history, &GitCore.commit_history(repo_path, &1, limit: 1)},
        {:read_tree, &GitCore.read_tree(repo_path, &1, "")},
        {:read_blob, &GitCore.read_blob(repo_path, &1, "README.md")}
      ]

      actual =
        for selector <- selectors, {operation, read} <- operations do
          result = read.(selector)
          {selector, operation, normalize_legacy_read(result, operation, commit_oid)}
        end

      expected =
        for selector <- selectors, {operation, _read} <- operations do
          {selector, operation, :ok}
        end

      assert actual == expected
    end

    @tag :tmp_dir
    test "classifies a blob-mode entry that loads a tree object as corruption", %{
      tmp_dir: tmp_dir
    } do
      repo_path = inconsistent_tree_repository!(tmp_dir)

      assert_error(
        GitCore.read_blob(repo_path, "main", "blob-mode-tree-object"),
        :corrupt_repository,
        :read_blob
      )
    end

    @tag :tmp_dir
    test "classifies a tree-mode entry that loads a blob object as corruption", %{
      tmp_dir: tmp_dir
    } do
      repo_path = inconsistent_tree_repository!(tmp_dir)

      assert_error(
        GitCore.read_tree(repo_path, "main", "tree-mode-blob-object"),
        :corrupt_repository,
        :read_tree
      )
    end

    @tag :tmp_dir
    test "classifies corrupt object data after opening a valid bare repository", %{
      tmp_dir: tmp_dir
    } do
      %{repo_path: repo_path, commit_oid: commit_oid} = populated_bare_repository!(tmp_dir)
      object_path = loose_object_path(repo_path, commit_oid)

      assert File.regular?(object_path), "expected the commit fixture to be a loose object"
      File.chmod!(object_path, 0o644)
      File.write!(object_path, "corrupt object data")

      assert_error(GitCore.commit(repo_path, commit_oid), :corrupt_repository, :commit)
    end
  end

  describe "bounded blob prefixes" do
    @describetag :prefix_blob
    @describetag :tmp_dir

    test "reads an exact prefix from a verified loose blob", %{tmp_dir: tmp_dir} do
      assert_prefix_blob_contract(prefix_blob_fixture!(tmp_dir, :loose))
    end

    test "reads an exact prefix from a verified packed-base blob", %{tmp_dir: tmp_dir} do
      assert_prefix_blob_contract(prefix_blob_fixture!(tmp_dir, :packed_base))
    end

    test "reads an exact prefix from a verified packed-delta blob", %{tmp_dir: tmp_dir} do
      assert_prefix_blob_contract(prefix_blob_fixture!(tmp_dir, :packed_delta))
    end

    test "reads the physical tree-entry blob instead of its replacement ref", %{tmp_dir: tmp_dir} do
      assert_prefix_blob_contract(replaced_prefix_blob_fixture!(tmp_dir))
    end
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %{
              __struct__: GitCore.Error,
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end

  defp normalize_legacy_read(
         {:ok, [%GitCore.Commit{oid: oid, title: "Initial commit"}]},
         :commit_history,
         commit_oid
       )
       when oid == commit_oid,
       do: :ok

  defp normalize_legacy_read(
         {:ok,
          [
            %GitCore.TreeEntry{name: "lib", kind: :tree},
            %GitCore.TreeEntry{name: "README.md", kind: :blob}
          ]},
         :read_tree,
         _commit_oid
       ),
       do: :ok

  defp normalize_legacy_read(
         {:ok,
          %GitCore.Blob{
            name: "README.md",
            size: 7,
            data: "# Demo\n",
            truncated: false,
            binary: false
          }},
         :read_blob,
         _commit_oid
       ),
       do: :ok

  defp normalize_legacy_read(result, _operation, _commit_oid), do: result

  defp assert_prefix_blob_contract(fixture) do
    limit = 64 * 1024

    assert {:ok,
            %GitCore.Blob{
              oid: oid,
              size: size,
              data: data,
              truncated: true,
              binary: true,
              non_utf8: true
            }} =
             GitCore.read_blob(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path,
               limit: limit
             )

    assert oid == fixture.oid
    assert size == byte_size(fixture.original)
    assert data == binary_part(fixture.original, 0, limit)
    assert byte_size(data) <= limit

    assert {:ok,
            %GitCore.Blob{
              oid: ^oid,
              size: ^size,
              data: complete,
              truncated: false,
              binary: true,
              non_utf8: true
            }} =
             GitCore.read_blob(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path,
               limit: size + 1
             )

    assert complete == fixture.original
  end

  defp prefix_blob_fixture!(tmp_dir, storage) do
    suffix = System.unique_integer([:positive])
    fixture_dir = Path.join(tmp_dir, "prefix-#{storage}-#{suffix}")
    repo_path = Path.join(fixture_dir, "repo.git")
    File.mkdir_p!(fixture_dir)
    git!(["init", "--bare", "--object-format=sha1", repo_path])

    first = deterministic_large_blob(0x3C6EF372)
    second = mutate_large_blob(first)

    blobs =
      case storage do
        :packed_delta -> [{"first.bin", first}, {"second.bin", second}]
        _ -> [{"blob.bin", first}]
      end

    objects =
      Enum.map(blobs, fn {name, data} ->
        path = Path.join(fixture_dir, name)
        File.write!(path, data)
        {name, git!(["--git-dir", repo_path, "hash-object", "-w", path]), data}
      end)

    tree_data =
      objects
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, oid, _data} -> ["100644 ", name, <<0>>, oid_bytes(oid)] end)
      |> IO.iodata_to_binary()

    tree_path = Path.join(fixture_dir, "tree")
    File.write!(tree_path, tree_data)
    tree_oid = git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", tree_path])
    commit_oid = git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "prefix blob"])
    git!(["--git-dir", repo_path, "update-ref", "refs/heads/main", commit_oid])

    case storage do
      :loose ->
        [{name, oid, original}] = objects
        assert File.regular?(loose_object_path(repo_path, oid))
        assert Path.wildcard(Path.join(repo_path, "objects/pack/*.idx")) == []
        fixture_result(repo_path, commit_oid, name, oid, original)

      :packed_base ->
        git!([
          "--git-dir",
          repo_path,
          "repack",
          "-a",
          "-d",
          "-f",
          "--window=0",
          "--depth=0"
        ])

        [{name, oid, original}] = objects
        evidence = verify_pack_line!(repo_path, oid)
        fields = String.split(evidence)
        assert Enum.at(fields, 1) == "blob", evidence
        assert Enum.at(fields, 2) == Integer.to_string(byte_size(original)), evidence
        assert length(fields) == 5, evidence
        refute File.exists?(loose_object_path(repo_path, oid))
        fixture_result(repo_path, commit_oid, name, oid, original)

      :packed_delta ->
        git!([
          "--git-dir",
          repo_path,
          "repack",
          "-a",
          "-d",
          "-f",
          "--window=50",
          "--depth=50"
        ])

        {name, oid, original, evidence} =
          Enum.find_value(objects, fn {name, oid, original} ->
            evidence = verify_pack_line!(repo_path, oid)
            fields = String.split(evidence)

            if length(fields) >= 7 and String.to_integer(Enum.at(fields, 5)) >= 1 do
              {name, oid, original, evidence}
            end
          end) || flunk("expected verify-pack to report a packed delta")

        fields = String.split(evidence)
        assert Enum.at(fields, 1) == "blob", evidence
        assert byte_size(Enum.at(fields, 6)) == 40, evidence
        refute File.exists?(loose_object_path(repo_path, oid))
        fixture_result(repo_path, commit_oid, name, oid, original)
    end
  end

  defp replaced_prefix_blob_fixture!(tmp_dir) do
    fixture = prefix_blob_fixture!(tmp_dir, :loose)
    replacement_path = Path.join(tmp_dir, "replacement-#{System.unique_integer([:positive])}")
    File.write!(replacement_path, "replacement metadata must not affect the tree entry")

    replacement_oid =
      git!([
        "--git-dir",
        fixture.repo_path,
        "hash-object",
        "-w",
        replacement_path
      ])

    git!([
      "--git-dir",
      fixture.repo_path,
      "update-ref",
      "refs/replace/#{fixture.oid}",
      replacement_oid
    ])

    # gix 0.85's repository-open path treats false here as enabling replacement loading.
    git!([
      "--git-dir",
      fixture.repo_path,
      "config",
      "core.useReplaceRefs",
      "false"
    ])

    fixture
  end

  defp fixture_result(repo_path, commit_oid, name, oid, original) do
    %{
      repo_path: repo_path,
      commit_oid: commit_oid,
      blob_path: name,
      oid: oid,
      original: original
    }
  end

  defp deterministic_large_blob(seed) do
    block_size = 64 * 1024

    {bytes, _state} =
      Enum.map_reduce(1..(block_size - 2), seed, fn _, state ->
        state = Bitwise.band(state * 1_664_525 + 1_013_904_223, 0xFFFF_FFFF)
        {Bitwise.band(Bitwise.bsr(state, 16), 0xFF), state}
      end)

    block = :erlang.list_to_binary([0, 255 | bytes])
    size = 3 * 1024 * 1024 + 257
    copies = div(size + block_size - 1, block_size)
    binary_part(:binary.copy(block, copies), 0, size)
  end

  defp mutate_large_blob(blob) do
    Enum.reduce([17, 181, 503, 701], blob, fn block, data ->
      start = block * 4096
      <<before::binary-size(start), segment::binary-size(4096), after_segment::binary>> = data

      mutated =
        segment
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map(fn {byte, index} ->
          Bitwise.bxor(byte, Bitwise.band(index * 31 + block, 0xFF))
        end)
        |> :erlang.list_to_binary()

      before <> mutated <> after_segment
    end)
  end

  defp verify_pack_line!(repo_path, oid) do
    [index_path] = Path.wildcard(Path.join(repo_path, "objects/pack/*.idx"))
    output = git!(["verify-pack", "-v", index_path])

    Enum.find(String.split(output, "\n"), fn line ->
      List.first(String.split(line)) == oid
    end) || flunk("verify-pack output has no line for #{oid}:\n#{output}")
  end

  defp populated_bare_repository!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "demo-#{suffix}.git")
    work_path = Path.join(tmp_dir, "work-#{suffix}")

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

    %{repo_path: repo_path, commit_oid: git!(["-C", work_path, "rev-parse", "HEAD"])}
  end

  defp inconsistent_tree_repository!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "inconsistent-#{suffix}.git")
    blob_path = Path.join(tmp_dir, "blob-#{suffix}")
    empty_tree_path = Path.join(tmp_dir, "empty-tree-#{suffix}")
    root_tree_path = Path.join(tmp_dir, "root-tree-#{suffix}")

    assert {:ok, _path} = GitCore.init_bare(repo_path)
    File.write!(blob_path, "blob data\n")
    File.write!(empty_tree_path, "")

    blob_oid = git!(["--git-dir", repo_path, "hash-object", "-w", blob_path])

    tree_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        empty_tree_path
      ])

    raw_tree =
      "100644 blob-mode-tree-object\0" <>
        oid_bytes(tree_oid) <>
        "40000 tree-mode-blob-object\0" <>
        oid_bytes(blob_oid)

    File.write!(root_tree_path, raw_tree)

    root_tree_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        root_tree_path
      ])

    commit_oid =
      git!(["--git-dir", repo_path, "commit-tree", root_tree_oid, "-m", "Inconsistent tree"])

    git!(["--git-dir", repo_path, "update-ref", "refs/heads/main", commit_oid])
    repo_path
  end

  defp oid_bytes(oid), do: Base.decode16!(oid, case: :mixed)

  defp loose_object_path(repo_path, oid) do
    {directory, filename} = String.split_at(oid, 2)
    Path.join([repo_path, "objects", directory, filename])
  end

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end
