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
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end
