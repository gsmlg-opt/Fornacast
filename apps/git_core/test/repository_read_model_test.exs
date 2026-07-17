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
      %{repo_path: repo_path, commit_oid: commit_oid} = populated_bare_repository!(tmp_dir)

      assert_error(GitCore.commit_history(repo_path, "missing"), :ref_not_found, :commit_history)

      assert_error(
        GitCore.commit(repo_path, String.duplicate("f", 40)),
        :commit_not_found,
        :commit
      )

      assert_error(GitCore.read_tree(repo_path, "main", "missing"), :path_not_found, :read_tree)
      assert_error(GitCore.read_tree(repo_path, "main", "README.md"), :path_not_found, :read_tree)
      assert_error(GitCore.read_blob(repo_path, commit_oid, "lib"), :path_not_found, :read_blob)
    end

    @tag :tmp_dir
    test "preserves legacy repository reads for revision selectors", %{tmp_dir: tmp_dir} do
      %{repo_path: repo_path, commit_oid: commit_oid} = populated_bare_repository!(tmp_dir)
      git!(["--git-dir", repo_path, "symbolic-ref", "HEAD", "refs/heads/main"])

      selectors = ["main", "refs/heads/main", "HEAD", commit_oid]

      operations = [
        {:commit_history, &GitCore.commit_history(repo_path, &1, limit: 1)},
        {:read_tree, &GitCore.read_tree(repo_path, &1, "")}
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
      commit_oid = git!(["--git-dir", repo_path, "rev-parse", "refs/heads/main"])

      assert_error(
        GitCore.read_blob(repo_path, commit_oid, "blob-mode-tree-object"),
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

    test "ignores an unrelated pack index whose pack file is absent", %{tmp_dir: tmp_dir} do
      assert_prefix_blob_contract(stale_unrelated_index_prefix_blob_fixture!(tmp_dir))
    end
  end

  describe "canonical refs and immutable snapshots" do
    @describetag :refs
    @describetag :tmp_dir

    test "summarizes exact byte-sorted refs with bounded samples and direct targets", %{
      tmp_dir: tmp_dir
    } do
      fixture = ref_fixture!(tmp_dir)

      assert {:ok, summary} =
               GitCore.ref_summary(fixture.repo_path, selected_ref: fixture.selected_branch)

      assert %GitCore.RefSummary{
               branch_count: branch_count,
               tag_count: tag_count,
               branches: branches,
               tags: tags,
               refs_truncated: true
             } = summary

      assert branch_count == length(fixture.branch_names)
      assert tag_count == length(fixture.tag_names)

      expected_branches =
        fixture.branch_names
        |> Enum.sort()
        |> Enum.take(100)
        |> Kernel.++([fixture.selected_branch])
        |> Enum.uniq()
        |> Enum.sort()

      assert Enum.map(branches, & &1.name) == expected_branches

      assert Enum.map(tags, & &1.name) ==
               fixture.tag_names |> Enum.sort() |> Enum.take(100)

      refute fixture.selected_branch in Enum.take(Enum.sort(fixture.branch_names), 100)
      assert Enum.all?(branches, &(&1.kind == :branch))
      assert Enum.all?(tags, &(&1.kind == :tag))

      assert Enum.map(branches, & &1.display_name) ==
               Enum.map(expected_branches, &String.replace_prefix(&1, "refs/heads/", ""))

      annotated = find_ref!(summary.tags, "refs/tags/annotated")
      nested = find_ref!(summary.tags, "refs/tags/nested")
      same_tag = find_ref!(summary.tags, "refs/tags/same")

      assert annotated.target == fixture.annotated_tag_oid
      assert nested.target == fixture.nested_tag_oid
      assert same_tag.target == fixture.second_commit_oid

      assert {:ok,
              %GitCore.RefSummary{
                branch_count: 0,
                tag_count: 0,
                branches: [],
                tags: [],
                refs_truncated: false
              }} = GitCore.ref_summary(empty_bare_repository!(tmp_dir))
    end

    test "paginates exact refs with a hard 100-row cap and typed empty pages", %{
      tmp_dir: tmp_dir
    } do
      fixture = ref_fixture!(tmp_dir)
      expected = Enum.sort(fixture.branch_names)
      total = length(expected)
      total_pages = div(total + 99, 100)

      assert {:ok,
              %GitCore.RefPage{
                refs: first,
                total: ^total,
                page: 1,
                per_page: 100,
                total_pages: ^total_pages
              }} = GitCore.ref_page(fixture.repo_path, :branch, 1, per_page: 500)

      assert Enum.map(first, & &1.name) == Enum.take(expected, 100)

      assert {:ok,
              %GitCore.RefPage{
                refs: second,
                total: ^total,
                page: 2,
                per_page: 100,
                total_pages: ^total_pages
              }} = GitCore.ref_page(fixture.repo_path, :branch, 2)

      assert Enum.map(second, & &1.name) == Enum.drop(expected, 100)

      expected_tags = Enum.sort(fixture.tag_names)
      tag_total = length(expected_tags)
      tag_total_pages = div(tag_total + 6, 7)

      assert {:ok,
              %GitCore.RefPage{
                refs: tag_refs,
                total: ^tag_total,
                page: 1,
                per_page: 7,
                total_pages: ^tag_total_pages
              }} = GitCore.ref_page(fixture.repo_path, :tag, 1, per_page: 7)

      assert Enum.map(tag_refs, & &1.name) == Enum.take(expected_tags, 7)
      assert find_ref!(tag_refs, "refs/tags/annotated").target == fixture.annotated_tag_oid

      assert {:ok,
              %GitCore.RefPage{
                refs: [],
                total: ^total,
                page: 3,
                per_page: 100,
                total_pages: ^total_pages
              }} = GitCore.ref_page(fixture.repo_path, :branch, 3)

      huge_page = Bitwise.bsl(1, 200)

      assert {:ok,
              %GitCore.RefPage{
                refs: [],
                total: ^total,
                page: ^huge_page,
                per_page: 100,
                total_pages: ^total_pages
              }} = GitCore.ref_page(fixture.repo_path, :branch, huge_page)

      empty_repo = empty_bare_repository!(tmp_dir)

      for page <- [1, 2] do
        assert {:ok,
                %GitCore.RefPage{
                  refs: [],
                  total: 0,
                  page: ^page,
                  per_page: 100,
                  total_pages: 1
                }} = GitCore.ref_page(empty_repo, :tag, page)
      end
    end

    test "resolves canonical refs exactly and legacy refs branch-first", %{tmp_dir: tmp_dir} do
      fixture = ref_fixture!(tmp_dir)

      assert {:ok,
              %GitCore.Snapshot{
                kind: :branch,
                ref: "refs/heads/same",
                oid: branch_oid
              }} =
               GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
                 kind: :branch,
                 full_name: "refs/heads/same"
               })

      assert branch_oid == fixture.commit_oid

      assert {:ok,
              %GitCore.Snapshot{
                kind: :tag,
                ref: "refs/tags/same",
                oid: tag_oid
              }} =
               GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
                 kind: :tag,
                 full_name: "refs/tags/same"
               })

      assert tag_oid == fixture.second_commit_oid

      for tag <- ["annotated", "nested"] do
        assert {:ok,
                %GitCore.Snapshot{
                  kind: :tag,
                  ref: "refs/tags/" <> ^tag,
                  oid: oid
                }} =
                 GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
                   kind: :tag,
                   full_name: "refs/tags/#{tag}"
                 })

        assert oid == fixture.commit_oid
      end

      assert {:ok,
              %GitCore.Snapshot{
                kind: :branch,
                ref: "refs/heads/same",
                oid: legacy_oid
              }} =
               GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
                 kind: :legacy,
                 full_name: "same"
               })

      assert legacy_oid == fixture.commit_oid

      assert_error(
        GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
          kind: :tag,
          full_name: "refs/tags/blob-target"
        }),
        :ref_not_found,
        :resolve_snapshot
      )

      cycle_repo = symbolic_ref_cycle_repository!(tmp_dir)

      assert_error(
        GitCore.resolve_snapshot(cycle_repo, %GitCore.RefSelector{
          kind: :tag,
          full_name: "refs/tags/cycle-a"
        }),
        :ref_not_found,
        :resolve_snapshot
      )

      assert_error(
        GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
          kind: :branch,
          full_name: "refs/tags/same"
        }),
        :ref_not_found,
        :resolve_snapshot
      )

      assert_error(
        GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
          kind: :branch,
          full_name: "refs/heads/tag-object"
        }),
        :ref_not_found,
        :resolve_snapshot
      )

      assert_error(
        GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
          kind: :tag,
          full_name: "refs/tags/missing"
        }),
        :ref_not_found,
        :resolve_snapshot
      )
    end

    test "rejects malformed canonical and legacy selectors as missing refs", %{tmp_dir: tmp_dir} do
      fixture = ref_fixture!(tmp_dir)

      for {kind, full_name} <- [
            {:branch, "refs/heads/../escape"},
            {:tag, "refs/tags/bad\0name"},
            {:legacy, "../escape"},
            {:legacy, "bad\0name"}
          ] do
        assert_error(
          GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
            kind: kind,
            full_name: full_name
          }),
          :ref_not_found,
          :resolve_snapshot
        )
      end
    end

    test "rejects an annotated tag whose declared target kind is false", %{tmp_dir: tmp_dir} do
      fixture = ref_fixture!(tmp_dir)

      assert_error(
        GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
          kind: :tag,
          full_name: "refs/tags/type-mismatch"
        }),
        :corrupt_repository,
        :resolve_snapshot
      )
    end

    test "rejects an annotated tag without its mandatory tag header", %{tmp_dir: tmp_dir} do
      fixture = ref_fixture!(tmp_dir)

      assert_error(
        GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
          kind: :tag,
          full_name: "refs/tags/missing-tag-header"
        }),
        :corrupt_repository,
        :resolve_snapshot
      )
    end

    test "resolves large annotated tags and commits through bounded prefixes", %{tmp_dir: tmp_dir} do
      large = large_snapshot_repository!(tmp_dir)

      assert {:ok,
              %GitCore.Snapshot{
                kind: :tag,
                ref: "refs/tags/large",
                oid: large_oid
              }} =
               GitCore.resolve_snapshot(large.repo_path, %GitCore.RefSelector{
                 kind: :tag,
                 full_name: "refs/tags/large"
               })

      assert large_oid == large.commit_oid

      assert {:ok,
              %GitCore.Snapshot{
                kind: :tag,
                ref: "refs/tags/long-header",
                oid: long_header_oid
              }} =
               GitCore.resolve_snapshot(large.repo_path, %GitCore.RefSelector{
                 kind: :tag,
                 full_name: "refs/tags/long-header"
               })

      assert long_header_oid == large.commit_oid
    end

    test "preserves valid non-UTF-8 ref names byte-for-byte", %{tmp_dir: tmp_dir} do
      fixture = raw_ref_repository!(tmp_dir)

      assert {:ok,
              %GitCore.RefSummary{
                branch_count: 2,
                tag_count: 0,
                branches: branches,
                tags: [],
                refs_truncated: false
              }} = GitCore.ref_summary(fixture.repo_path, selected_ref: fixture.selected_ref)

      assert Enum.map(branches, & &1.name) == fixture.full_names
      assert Enum.map(branches, & &1.display_name) == fixture.short_names
      assert Enum.all?(branches, &(&1.target == fixture.commit_oid))

      assert {:ok,
              %GitCore.RefPage{
                refs: page_refs,
                total: 2,
                page: 1,
                per_page: 100,
                total_pages: 1
              }} = GitCore.ref_page(fixture.repo_path, :branch, 1)

      assert Enum.map(page_refs, & &1.name) == fixture.full_names

      assert {:ok,
              %GitCore.Snapshot{
                kind: :branch,
                ref: selected_ref,
                oid: selected_oid
              }} =
               GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
                 kind: :branch,
                 full_name: fixture.selected_ref
               })

      assert selected_ref == fixture.selected_ref
      assert selected_oid == fixture.commit_oid

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :branch, full_name: route_ref}, "raw/path"}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "refs",
                 "heads",
                 fixture.selected_short_name,
                 "raw",
                 "path"
               ])

      assert route_ref == fixture.selected_ref
    end

    test "matches wildcard refs and paths in the same summary scan", %{tmp_dir: tmp_dir} do
      fixture = ref_fixture!(tmp_dir)

      assert {:ok, {summary, selector, repository_path}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "refs",
                 "heads",
                 "zz-selected",
                 "deep",
                 "lib",
                 "demo.ex"
               ])

      assert %GitCore.RefSelector{kind: :branch, full_name: full_name} = selector
      assert full_name == fixture.selected_branch
      assert repository_path == "lib/demo.ex"
      assert Enum.any?(summary.branches, &(&1.name == fixture.selected_branch))
      assert length(summary.branches) == 101

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :tag, full_name: "refs/tags/release/deep"},
               "docs/guide.md"}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "refs",
                 "tags",
                 "release",
                 "deep",
                 "docs",
                 "guide.md"
               ])

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :legacy, full_name: "feature/deep"},
               "README.md"}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "feature",
                 "deep",
                 "README.md"
               ])

      long_path = for index <- 1..512, do: "segment-#{index}"

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :legacy, full_name: "feature/deep"},
               long_repository_path}} =
               GitCore.ref_summary_for_route(
                 fixture.repo_path,
                 ["feature", "deep" | long_path]
               )

      assert long_repository_path == Enum.join(long_path, "/")

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :legacy, full_name: "release/deep"},
               "docs/guide.md"}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "release",
                 "deep",
                 "docs",
                 "guide.md"
               ])

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :legacy, full_name: "topic"},
               "deep/README.md"}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "topic",
                 "deep",
                 "README.md"
               ])

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :tag, full_name: "refs/tags/blob-target"},
               "not-probed.txt"}} =
               GitCore.ref_summary_for_route(fixture.repo_path, [
                 "refs",
                 "tags",
                 "blob-target",
                 "not-probed.txt"
               ])

      assert_error(
        GitCore.ref_summary_for_route(fixture.repo_path, ["missing", "path"]),
        :ref_not_found,
        :ref_summary_for_route
      )

      collision_repo = same_kind_route_repository!(tmp_dir)

      assert {:ok,
              {_summary, %GitCore.RefSelector{kind: :legacy, full_name: "feature/deep"},
               "src/file.ex"}} =
               GitCore.ref_summary_for_route(collision_repo, [
                 "feature",
                 "deep",
                 "src",
                 "file.ex"
               ])
    end
  end

  describe "exact deterministic commit summary and pages" do
    @describetag :commits
    @describetag :tmp_dir

    test "counts every unique merge ancestor and orders child-before-parent deterministically", %{
      tmp_dir: tmp_dir
    } do
      fixture = commit_dag_fixture!(tmp_dir)

      assert {:ok,
              %GitCore.CommitSummary{
                count: count,
                latest: %GitCore.Commit{} = latest
              }} = GitCore.commit_summary(fixture.repo_path, fixture.tip_oid)

      assert count == length(fixture.expected_order)

      assert latest == %GitCore.Commit{
               oid: fixture.tip_oid,
               title: fixture.tip_title,
               message: fixture.tip_title <> "\n",
               author_name: "Fornacast Test",
               author_email: "test@example.com",
               author_time: fixture.tip_time,
               committer_name: "Fornacast Test",
               committer_email: "test@example.com",
               committer_time: fixture.tip_time,
               parents: [fixture.tip_parent_oid]
             }

      assert {:ok,
              %GitCore.CommitPage{
                commits: first_page,
                total: ^count,
                page: 1,
                per_page: 50,
                total_pages: 2
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1, per_page: 500)

      assert Enum.map(first_page, & &1.oid) == Enum.take(fixture.expected_order, 50)

      assert {:ok,
              %GitCore.CommitPage{
                commits: second_page,
                total: ^count,
                page: 2,
                per_page: 50,
                total_pages: 2
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 2)

      assert Enum.map(second_page, & &1.oid) == Enum.drop(fixture.expected_order, 50)

      assert Enum.find(second_page, &(&1.oid == fixture.merge_oid)).parents ==
               [fixture.left_tip_oid, fixture.right_tip_oid]

      assert {:ok,
              %GitCore.CommitPage{
                commits: seven_commits,
                total: ^count,
                page: 1,
                per_page: 7,
                total_pages: 9
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1, per_page: 7)

      assert length(seven_commits) == 7

      assert {:ok,
              %GitCore.CommitPage{
                commits: [_only_commit],
                total: ^count,
                page: 1,
                per_page: 1,
                total_pages: ^count
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1, per_page: 0)

      assert Enum.slice(fixture.expected_order, 53, 2) ==
               Enum.sort([fixture.left_tip_oid, fixture.right_tip_oid])

      assert Enum.slice(fixture.expected_order, 55, 2) ==
               [fixture.left_base_oid, fixture.right_base_oid]

      assert List.last(fixture.expected_order) == fixture.root_oid

      assert {:ok,
              %GitCore.CommitPage{
                commits: [],
                total: ^count,
                page: 3,
                per_page: 50,
                total_pages: 2
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 3)

      huge_page = Bitwise.bsl(1, 200)

      assert {:ok,
              %GitCore.CommitPage{
                commits: [],
                total: ^count,
                page: ^huge_page,
                per_page: 50,
                total_pages: 2
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, huge_page)
    end

    test "uses the immutable snapshot OID after the branch advances", %{tmp_dir: tmp_dir} do
      fixture = commit_dag_fixture!(tmp_dir)

      new_tip_oid =
        commit_tree!(
          fixture.repo_path,
          fixture.tree_oid,
          "advanced branch",
          [fixture.tip_oid],
          fixture.tip_time + 1
        )

      git!([
        "--git-dir",
        fixture.repo_path,
        "update-ref",
        "refs/heads/main",
        new_tip_oid
      ])

      assert {:ok, %GitCore.CommitSummary{count: old_count, latest: old_latest}} =
               GitCore.commit_summary(fixture.repo_path, fixture.tip_oid)

      assert old_count == length(fixture.expected_order)
      assert old_latest.oid == fixture.tip_oid

      assert {:ok, %GitCore.CommitSummary{count: new_count, latest: new_latest}} =
               GitCore.commit_summary(fixture.repo_path, new_tip_oid)

      assert new_count == old_count + 1
      assert new_latest.oid == new_tip_oid

      replacement_oid =
        commit_tree!(
          fixture.repo_path,
          fixture.tree_oid,
          "replacement must be ignored",
          [],
          fixture.tip_time + 2
        )

      # Pinned gix currently loads replacement refs when this switch is false. Exercise that
      # configuration so immutable snapshot reads prove they bypass the replacement map.
      git!(["--git-dir", fixture.repo_path, "config", "core.useReplaceRefs", "false"])
      git!(["--git-dir", fixture.repo_path, "replace", fixture.tip_oid, replacement_oid])

      assert {:ok, %GitCore.CommitSummary{count: physical_count, latest: physical_latest}} =
               GitCore.commit_summary(fixture.repo_path, fixture.tip_oid)

      assert physical_count == old_count
      assert physical_latest.oid == fixture.tip_oid
      assert physical_latest.title == fixture.tip_title

      assert {:ok,
              %GitCore.CommitPage{
                commits: [physical_page_tip | _],
                total: ^old_count,
                page: 1,
                per_page: 50,
                total_pages: 2
              }} = GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1)

      assert physical_page_tip.oid == fixture.tip_oid
      assert physical_page_tip.title == fixture.tip_title
    end

    test "returns typed timeout errors instead of partial exact results", %{tmp_dir: tmp_dir} do
      fixture = commit_dag_fixture!(tmp_dir)

      assert_error(
        GitCore.commit_summary(fixture.repo_path, fixture.tip_oid, deadline_ms: 0),
        :scan_timeout,
        :commit_summary
      )

      assert_error(
        GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1, deadline_ms: 0),
        :scan_timeout,
        :commit_page
      )
    end

    @tag :typed_errors
    test "classifies unreadable loose commit storage as unavailable", %{tmp_dir: tmp_dir} do
      fixture = commit_dag_fixture!(tmp_dir)
      object_path = loose_object_path(fixture.repo_path, fixture.tip_oid)
      original_mode = Bitwise.band(File.stat!(object_path).mode, 0o777)

      try do
        File.chmod!(object_path, 0o000)
        assert {:error, :eacces} = File.read(object_path)

        assert_error(
          GitCore.commit_summary(fixture.repo_path, fixture.tip_oid),
          :storage_unavailable,
          :commit_summary
        )

        assert_error(
          GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1),
          :storage_unavailable,
          :commit_page
        )
      after
        File.chmod!(object_path, original_mode)
      end
    end

    @tag :typed_errors
    test "classifies an empty loose commit object as repository corruption", %{tmp_dir: tmp_dir} do
      fixture = commit_dag_fixture!(tmp_dir)
      object_path = loose_object_path(fixture.repo_path, fixture.tip_oid)
      File.chmod!(object_path, 0o600)
      File.write!(object_path, "")

      assert_error(
        GitCore.commit_summary(fixture.repo_path, fixture.tip_oid),
        :corrupt_repository,
        :commit_summary
      )

      assert_error(
        GitCore.commit_page(fixture.repo_path, fixture.tip_oid, 1),
        :corrupt_repository,
        :commit_page
      )
    end

    test "classifies malformed reachable commit objects as repository corruption", %{
      tmp_dir: tmp_dir
    } do
      fixture = commit_dag_fixture!(tmp_dir)

      malformed_oid =
        literal_object!(
          tmp_dir,
          fixture.repo_path,
          "malformed-commit",
          :commit,
          "tree not-an-object-id\n\nmalformed commit\n"
        )

      assert_error(
        GitCore.commit_summary(fixture.repo_path, malformed_oid),
        :corrupt_repository,
        :commit_summary
      )

      assert_error(
        GitCore.commit_page(fixture.repo_path, malformed_oid, 1),
        :corrupt_repository,
        :commit_page
      )

      missing_parent_oid = String.duplicate("f", 40)

      missing_parent_tip_oid =
        literal_object!(
          tmp_dir,
          fixture.repo_path,
          "missing-parent-commit",
          :commit,
          "tree #{fixture.tree_oid}\n" <>
            "parent #{missing_parent_oid}\n" <>
            "author Fornacast Test <test@example.com> 946684800 +0000\n" <>
            "committer Fornacast Test <test@example.com> 946684800 +0000\n\n" <>
            "missing reachable parent\n"
        )

      assert_error(
        GitCore.commit_summary(fixture.repo_path, missing_parent_tip_oid),
        :corrupt_repository,
        :commit_summary
      )

      wrong_kind_parent_tip_oid =
        literal_object!(
          tmp_dir,
          fixture.repo_path,
          "wrong-kind-parent-commit",
          :commit,
          "tree #{fixture.tree_oid}\n" <>
            "parent #{fixture.tree_oid}\n" <>
            "author Fornacast Test <test@example.com> 946684800 +0000\n" <>
            "committer Fornacast Test <test@example.com> 946684800 +0000\n\n" <>
            "wrong-kind reachable parent\n"
        )

      assert_error(
        GitCore.commit_page(fixture.repo_path, wrong_kind_parent_tip_oid, 1),
        :corrupt_repository,
        :commit_page
      )

      malformed_parent_tip_oid =
        literal_object!(
          tmp_dir,
          fixture.repo_path,
          "malformed-parent-header-commit",
          :commit,
          "tree #{fixture.tree_oid}\n" <>
            "parent not-an-object-id\n" <>
            "author Fornacast Test <test@example.com> 946684800 +0000\n" <>
            "committer Fornacast Test <test@example.com> 946684800 +0000\n\n" <>
            "malformed parent header\n"
        )

      assert_error(
        GitCore.commit_summary(fixture.repo_path, malformed_parent_tip_oid),
        :corrupt_repository,
        :commit_summary
      )

      malformed_time_tip_oid =
        literal_object!(
          tmp_dir,
          fixture.repo_path,
          "malformed-committer-time-commit",
          :commit,
          "tree #{fixture.tree_oid}\n" <>
            "author Fornacast Test <test@example.com> 946684800 +0000\n" <>
            "committer Fornacast Test <test@example.com> not-a-time +0000\n\n" <>
            "malformed committer time\n"
        )

      assert_error(
        GitCore.commit_page(fixture.repo_path, malformed_time_tip_oid, 1),
        :corrupt_repository,
        :commit_page
      )
    end

    test "requires an immutable commit OID rather than resolving a ref name", %{tmp_dir: tmp_dir} do
      fixture = commit_dag_fixture!(tmp_dir)

      assert_error(
        GitCore.commit_summary(fixture.repo_path, "refs/heads/main"),
        :commit_not_found,
        :commit_summary
      )

      assert_error(
        GitCore.commit_page(fixture.repo_path, "main", 1),
        :commit_not_found,
        :commit_page
      )

      blob_path = Path.join(tmp_dir, "snapshot-blob")
      File.write!(blob_path, "not a commit\n")
      blob_oid = git!(["--git-dir", fixture.repo_path, "hash-object", "-w", blob_path])

      git!([
        "--git-dir",
        fixture.repo_path,
        "tag",
        "-a",
        "snapshot-tag-object",
        fixture.tip_oid,
        "-m",
        "tag object"
      ])

      tag_oid =
        git!(["--git-dir", fixture.repo_path, "rev-parse", "refs/tags/snapshot-tag-object"])

      for oid <- [fixture.tree_oid, blob_oid, tag_oid, String.duplicate("0", 40)] do
        assert_error(
          GitCore.commit_summary(fixture.repo_path, oid),
          :commit_not_found,
          :commit_summary
        )
      end
    end
  end

  describe "commit-aware bounded tree pages" do
    @describetag :tree_history
    @describetag :tmp_dir

    test "sorts directories first by raw name bytes and caps one page at 200 rows", %{
      tmp_dir: tmp_dir
    } do
      fixture = tree_history_fixture!(tmp_dir)

      assert {:ok,
              %GitCore.TreePage{
                entries: entries,
                total_entries: 205,
                page: 1,
                per_page: 200,
                total_pages: 2
              }} =
               GitCore.read_tree_with_history(
                 fixture.repo_path,
                 fixture.tip_oid,
                 "",
                 1,
                 per_page: 500
               )

      assert length(entries) == 200

      assert Enum.map(entries, & &1.name) ==
               ["alpha-dir", "empty-dir", "zeta-dir"] ++
                 for(
                   index <- 0..196,
                   do: "file-#{String.pad_leading(Integer.to_string(index), 3, "0")}.txt"
                 )

      assert Enum.all?(entries, &match?(%GitCore.TreeHistoryEntry{}, &1))

      assert %GitCore.TreeHistoryEntry{
               kind: :tree,
               latest_commit: %GitCore.Commit{oid: alpha_oid, title: "left descendant change"}
             } = find_tree_entry!(entries, "alpha-dir")

      assert alpha_oid == fixture.left_oid

      assert %GitCore.TreeHistoryEntry{
               kind: :tree,
               latest_commit: %GitCore.Commit{oid: zeta_oid, title: "merge first-parent delta"}
             } = find_tree_entry!(entries, "zeta-dir")

      assert zeta_oid == fixture.merge_oid

      assert %GitCore.TreeHistoryEntry{
               kind: :blob,
               latest_commit: %GitCore.Commit{oid: tip_oid, title: "tip file change"}
             } = find_tree_entry!(entries, "file-000.txt")

      assert tip_oid == fixture.tip_oid

      assert %GitCore.TreeHistoryEntry{
               latest_commit: %GitCore.Commit{
                 oid: root_oid,
                 title: "root tree",
                 author_name: "Fornacast Test",
                 author_time: root_time
               }
             } = find_tree_entry!(entries, "file-001.txt")

      assert root_oid == fixture.root_oid
      assert root_time == fixture.root_time
    end

    test "orders prefix-related directories by raw bytes instead of Git slash sentinels", %{
      tmp_dir: tmp_dir
    } do
      fixture = prefix_directory_tree_fixture!(tmp_dir)

      assert {:ok, %GitCore.TreePage{entries: entries, total_entries: 2}} =
               GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", 1)

      assert Enum.map(entries, & &1.name) == ["foo", "foo.bar"]
      assert Enum.all?(entries, &(&1.kind == :tree))
    end

    test "returns exact later, small, out-of-range, and huge pages", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)

      assert {:ok,
              %GitCore.TreePage{
                entries: last_entries,
                total_entries: 205,
                page: 2,
                per_page: 200,
                total_pages: 2
              }} =
               GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", 2)

      assert Enum.map(last_entries, & &1.name) == [
               "file-197.txt",
               "file-198.txt",
               <<"raw-", 0xFE>>,
               <<"raw-", 0xFF>>,
               "renamed.txt"
             ]

      assert %GitCore.TreeHistoryEntry{
               latest_commit: %GitCore.Commit{oid: merge_oid, title: "merge first-parent delta"}
             } = find_tree_entry!(last_entries, "file-198.txt")

      assert merge_oid == fixture.merge_oid

      assert %GitCore.TreeHistoryEntry{
               mode: "100755",
               latest_commit: %GitCore.Commit{oid: mode_oid, title: "left descendant change"}
             } = find_tree_entry!(last_entries, "file-197.txt")

      assert mode_oid == fixture.left_oid

      raw_names = Enum.slice(Enum.map(last_entries, & &1.name), 2, 2)
      assert raw_names == [<<"raw-", 0xFE>>, <<"raw-", 0xFF>>]
      assert Enum.all?(raw_names, &(not String.valid?(&1)))

      assert %GitCore.TreeHistoryEntry{
               latest_commit: %GitCore.Commit{oid: rename_oid, title: "left descendant change"}
             } = find_tree_entry!(last_entries, "renamed.txt")

      assert rename_oid == fixture.left_oid

      assert {:ok,
              %GitCore.TreePage{
                entries: [single_entry],
                total_entries: 205,
                page: 1,
                per_page: 1,
                total_pages: 205
              }} =
               GitCore.read_tree_with_history(
                 fixture.repo_path,
                 fixture.tip_oid,
                 "",
                 1,
                 per_page: 0
               )

      assert single_entry.name == "alpha-dir"

      assert {:ok, %GitCore.TreePage{entries: [], page: 3, total_pages: 2}} =
               GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", 3)

      huge_page = Bitwise.bsl(1, 200)

      assert {:ok,
              %GitCore.TreePage{entries: [], page: ^huge_page, total_entries: 205, total_pages: 2}} =
               GitCore.read_tree_with_history(
                 fixture.repo_path,
                 fixture.tip_oid,
                 "",
                 huge_page
               )
    end

    test "attributes nested descendants using the first declared merge parent", %{
      tmp_dir: tmp_dir
    } do
      fixture = tree_history_fixture!(tmp_dir)

      assert {:ok,
              %GitCore.TreePage{
                entries: [
                  %GitCore.TreeHistoryEntry{
                    name: "nested.txt",
                    latest_commit: %GitCore.Commit{
                      oid: latest_oid,
                      title: "left descendant change"
                    }
                  }
                ],
                total_entries: 1,
                page: 1,
                per_page: 200,
                total_pages: 1
              }} =
               GitCore.read_tree_with_history(
                 fixture.repo_path,
                 fixture.tip_oid,
                 "alpha-dir",
                 1
               )

      assert latest_oid == fixture.left_oid
      refute latest_oid == fixture.merge_oid
    end

    test "returns exact empty directory pages for page one and later pages", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)

      for page <- [1, 2] do
        assert {:ok,
                %GitCore.TreePage{
                  entries: [],
                  total_entries: 0,
                  page: ^page,
                  per_page: 200,
                  total_pages: 1
                }} =
                 GitCore.read_tree_with_history(
                   fixture.repo_path,
                   fixture.tip_oid,
                   "empty-dir",
                   page
                 )
      end
    end

    test "uses an already-resolved slash ref OID after the branch advances", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)

      assert {:ok, %GitCore.Snapshot{oid: snapshot_oid}} =
               GitCore.resolve_snapshot(fixture.repo_path, %GitCore.RefSelector{
                 kind: :branch,
                 full_name: "refs/heads/feature/slash"
               })

      assert snapshot_oid == fixture.tip_oid

      git!([
        "--git-dir",
        fixture.repo_path,
        "update-ref",
        "refs/heads/feature/slash",
        fixture.root_oid
      ])

      assert {:ok, %GitCore.TreePage{entries: entries}} =
               GitCore.read_tree_with_history(fixture.repo_path, snapshot_oid, "", 1)

      assert %GitCore.TreeHistoryEntry{
               latest_commit: %GitCore.Commit{oid: latest_oid, title: "tip file change"}
             } = find_tree_entry!(entries, "file-000.txt")

      assert latest_oid == fixture.tip_oid
    end

    test "ignores replacement refs and reads the physical snapshot", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)

      git!(["--git-dir", fixture.repo_path, "config", "core.useReplaceRefs", "false"])
      git!(["--git-dir", fixture.repo_path, "replace", fixture.tip_oid, fixture.root_oid])

      assert {:ok, %GitCore.TreePage{entries: entries, total_entries: 205}} =
               GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", 2)

      assert %GitCore.TreeHistoryEntry{
               name: "renamed.txt",
               latest_commit: %GitCore.Commit{oid: latest_oid}
             } = find_tree_entry!(entries, "renamed.txt")

      assert latest_oid == fixture.left_oid
    end

    test "rejects unsafe or missing Git paths and enforces a lower deadline", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)

      for tree_path <- [
            "../alpha-dir",
            "alpha-dir/../zeta-dir",
            "/alpha-dir",
            "alpha-dir/",
            "alpha-dir//nested",
            "alpha-dir\0nested",
            "missing",
            "file-000.txt"
          ] do
        assert_error(
          GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, tree_path, 1),
          :path_not_found,
          :tree_history
        )
      end

      assert_error(
        GitCore.read_tree_with_history(fixture.repo_path, "refs/heads/main", "", 1),
        :commit_not_found,
        :tree_history
      )

      assert_error(
        GitCore.read_tree_with_history(
          fixture.repo_path,
          fixture.tip_oid,
          "",
          1,
          deadline_ms: 0
        ),
        :scan_timeout,
        :tree_history
      )
    end

    test "validates the selected tip path before walking ancestor history", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)
      File.rm!(loose_object_path(fixture.repo_path, fixture.root_oid))

      assert_error(
        GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "missing", 1),
        :path_not_found,
        :tree_history
      )
    end

    test "rejects cross-kind duplicate names before paginating any direct tree page", %{
      tmp_dir: tmp_dir
    } do
      fixture = tree_history_cross_kind_duplicate_fixture!(tmp_dir)

      for page <- [1, 2, 1_000] do
        assert_error(
          GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", page,
            per_page: 1
          ),
          :corrupt_repository,
          :tree_history
        )
      end
    end

    test "rejects unsupported tree modes before pagination", %{tmp_dir: tmp_dir} do
      fixture = tree_history_invalid_mode_fixture!(tmp_dir)

      for page <- [1, 2] do
        assert_error(
          GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", page),
          :corrupt_repository,
          :tree_history
        )
      end
    end

    @tag :typed_errors
    test "distinguishes unavailable commit storage from corrupt tree storage", %{tmp_dir: tmp_dir} do
      unavailable = tree_history_fixture!(tmp_dir)
      commit_path = loose_object_path(unavailable.repo_path, unavailable.tip_oid)
      original_mode = Bitwise.band(File.stat!(commit_path).mode, 0o777)

      try do
        File.chmod!(commit_path, 0o000)
        assert {:error, :eacces} = File.read(commit_path)

        assert_error(
          GitCore.read_tree_with_history(unavailable.repo_path, unavailable.tip_oid, "", 1),
          :storage_unavailable,
          :tree_history
        )
      after
        File.chmod!(commit_path, original_mode)
      end

      unavailable_tree = tree_history_fixture!(tmp_dir)

      unavailable_tree_path =
        loose_object_path(unavailable_tree.repo_path, unavailable_tree.tip_tree_oid)

      original_tree_mode = Bitwise.band(File.stat!(unavailable_tree_path).mode, 0o777)

      try do
        File.chmod!(unavailable_tree_path, 0o000)
        assert {:error, :eacces} = File.read(unavailable_tree_path)

        assert_error(
          GitCore.read_tree_with_history(
            unavailable_tree.repo_path,
            unavailable_tree.tip_oid,
            "",
            1
          ),
          :storage_unavailable,
          :tree_history
        )
      after
        File.chmod!(unavailable_tree_path, original_tree_mode)
      end

      corrupt = tree_history_fixture!(tmp_dir)
      tree_path = loose_object_path(corrupt.repo_path, corrupt.tip_tree_oid)
      File.chmod!(tree_path, 0o600)
      File.write!(tree_path, "")

      assert_error(
        GitCore.read_tree_with_history(corrupt.repo_path, corrupt.tip_oid, "", 1),
        :corrupt_repository,
        :tree_history
      )

      wrong_kind = tree_history_wrong_kind_fixture!(tmp_dir)

      assert_error(
        GitCore.read_tree_with_history(wrong_kind.repo_path, wrong_kind.tip_oid, "bad-tree", 1),
        :corrupt_repository,
        :tree_history
      )
    end

    test "makes exactly one native call for zero, one, or 200 retained rows", %{tmp_dir: tmp_dir} do
      fixture = tree_history_fixture!(tmp_dir)
      mfa = {GitCore, :native_tree_history_call, 6}
      tracee = self()
      tracer = spawn_link(fn -> tree_history_trace_counter(0) end)
      assert {:module, GitCore} = Code.ensure_loaded(GitCore)
      assert 1 == :erlang.trace(tracee, true, [:call, {:tracer, tracer}])
      assert 1 == :erlang.trace_pattern(mfa, true, [:local])
      assert_tree_history_trace_count(tracee, tracer, 0)

      try do
        assert {:ok, %GitCore.TreePage{entries: [_]}} =
                 GitCore.read_tree_with_history(
                   fixture.repo_path,
                   fixture.tip_oid,
                   "",
                   1,
                   per_page: 1
                 )

        assert_tree_history_trace_count(tracee, tracer, 1)

        assert {:ok, %GitCore.TreePage{entries: entries}} =
                 GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", 1)

        assert length(entries) == 200
        assert_tree_history_trace_count(tracee, tracer, 2)

        assert {:ok, %GitCore.TreePage{entries: []}} =
                 GitCore.read_tree_with_history(fixture.repo_path, fixture.tip_oid, "", 3)

        assert_tree_history_trace_count(tracee, tracer, 3)
      after
        :erlang.trace_pattern(mfa, false, [:local])
        :erlang.trace(tracee, false, [:call])
        send(tracer, :stop)
      end
    end
  end

  describe "scan limiter" do
    @describetag :limiter

    test "admits four production permits and expires the next waiter without a ghost" do
      server = start_scan_limiter!(wait_timeout: 20)
      owners = start_scan_owners(server, 4)

      assert_scan_owners_entered(owners)
      started_at = System.monotonic_time(:millisecond)

      assert_error(
        GitCore.ScanLimiter.with_permit(:ref_summary, fn -> :unexpected end, server: server),
        :scan_busy,
        :ref_summary
      )

      elapsed = System.monotonic_time(:millisecond) - started_at
      assert elapsed >= 15
      assert elapsed < 500
      assert_waiter_index_size(server, 0)

      release_scan_owners(owners)

      assert :reacquired ==
               GitCore.ScanLimiter.with_permit(:ref_summary, fn -> :reacquired end,
                 server: server
               )
    end

    test "admits queued waiters in FIFO order" do
      server = start_scan_limiter!(capacity: 1, wait_timeout: 200)
      [holder] = start_scan_owners(server, 1)
      assert_scan_owners_entered([holder])

      first = start_scan_owner(server)
      wait_for_waiter_count(server, 1)
      second = start_scan_owner(server)
      wait_for_waiter_count(server, 2)
      assert_waiter_index_size(server, 2)

      send(holder, :release)
      assert_receive {:scan_entered, ^first}
      refute_receive {:scan_entered, ^second}, 20

      send(first, :release)
      assert_receive {:scan_entered, ^second}
      send(second, :release)

      assert_scan_owners_finished([holder, first, second])
    end

    test "releases a permit in after when the protected operation raises, throws, or exits" do
      server = start_scan_limiter!(capacity: 1)

      assert_raise RuntimeError, "boom", fn ->
        GitCore.ScanLimiter.with_permit(:commit_page, fn -> raise "boom" end, server: server)
      end

      assert :after_raise ==
               GitCore.ScanLimiter.with_permit(:commit_page, fn -> :after_raise end,
                 server: server
               )

      assert catch_throw(
               GitCore.ScanLimiter.with_permit(:commit_page, fn -> throw(:boom) end,
                 server: server
               )
             ) == :boom

      assert :after_throw ==
               GitCore.ScanLimiter.with_permit(:commit_page, fn -> :after_throw end,
                 server: server
               )

      assert catch_exit(
               GitCore.ScanLimiter.with_permit(:commit_page, fn -> exit(:boom) end,
                 server: server
               )
             ) == :boom

      assert :available ==
               GitCore.ScanLimiter.with_permit(:commit_page, fn -> :available end, server: server)
    end

    test "removes queued and granted permits when their owners die" do
      server = start_scan_limiter!(capacity: 1, wait_timeout: 200)
      granted = start_scan_owner(server)
      assert_receive {:scan_entered, ^granted}

      queued = start_scan_owner(server)
      wait_for_waiter_count(server, 1)

      Process.exit(queued, :kill)
      wait_for_waiter_count(server, 0)
      Process.exit(granted, :kill)

      assert :recovered ==
               GitCore.ScanLimiter.with_permit(:tree_history, fn -> :recovered end,
                 server: server
               )
    end

    test "fails closed when the limiter process is unavailable" do
      server = spawn(fn -> receive do: (:stop -> :ok) end)
      monitor = Process.monitor(server)
      send(server, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}

      assert_error(
        GitCore.ScanLimiter.with_permit(:repository_analysis, fn -> :unexpected end,
          server: server
        ),
        :scan_busy,
        :repository_analysis
      )
    end

    test "stays unavailable after its supervised process crashes while permits are held" do
      server = {:global, {__MODULE__, :scan_crash, make_ref()}}
      supervisor = start_limiter_supervisor!(GitCore.ScanLimiter, server)
      limiter = GenServer.whereis(server)
      owners = start_scan_owners(server, 4)
      assert_scan_owners_entered(owners)
      on_exit(fn -> Enum.each(owners, &send(&1, :release)) end)

      monitor = Process.monitor(limiter)
      Process.exit(limiter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}
      wait_for_supervisor_settle(supervisor, server, limiter)

      assert_error(
        GitCore.ScanLimiter.with_permit(:ref_summary, fn -> :unexpected end, server: server),
        :scan_busy,
        :ref_summary
      )

      release_scan_owners(owners)
    end

    test "prunes many arbitrary waiter deaths without rebuilding or retaining ghosts" do
      server = start_scan_limiter!(capacity: 1)
      holder = start_scan_owner(server)
      assert_receive {:scan_entered, ^holder}

      waiters = start_scan_owners(server, 128)
      wait_for_waiter_count(server, 128)
      assert_waiter_index_size(server, 128)

      {victims, survivors} =
        waiters
        |> Enum.with_index()
        |> Enum.split_with(fn {_pid, index} -> rem(index, 2) == 0 end)
        |> then(fn {victims, survivors} ->
          {Enum.map(victims, &elem(&1, 0)), Enum.map(survivors, &elem(&1, 0))}
        end)

      Enum.each(victims, &Process.exit(&1, :kill))
      wait_for_waiter_count(server, 64)
      assert_waiter_index_size(server, 64)

      Enum.each(survivors, fn waiter ->
        assert_receive {:scan_finished, ^waiter, result}, 1_000
        assert_error(result, :scan_busy, :test_scan)
      end)

      assert_waiter_index_size(server, 0)
      send(holder, :release)
      assert_scan_owners_finished([holder])

      assert :reacquired ==
               GitCore.ScanLimiter.with_permit(:test_scan, fn -> :reacquired end, server: server)
    end
  end

  describe "weighted blob limiter" do
    @describetag :limiter

    test "admits eight production leases and counts a zero-byte body as a slot" do
      server = start_blob_limiter!(wait_timeout: 20)

      leases =
        for _ <- 1..8 do
          assert {:ok, lease} = GitCore.BlobLimiter.acquire(0, server: server)
          lease
        end

      assert_error(
        GitCore.BlobLimiter.acquire(0, server: server, operation: :read_blob_complete),
        :blob_busy,
        :read_blob_complete
      )

      Enum.each(leases, &assert(:ok == GitCore.BlobLimiter.release(&1)))
    end

    test "enforces and exactly releases the 128 MiB production byte limit" do
      server = start_blob_limiter!(wait_timeout: 20)
      byte_limit = 128 * 1024 * 1024

      assert {:ok, lease} = GitCore.BlobLimiter.acquire(byte_limit, server: server)

      assert_error(
        GitCore.BlobLimiter.acquire(1, server: server, operation: :read_blob_complete),
        :blob_busy,
        :read_blob_complete
      )

      assert :ok = GitCore.BlobLimiter.release(lease)
      assert {:ok, replacement} = GitCore.BlobLimiter.acquire(byte_limit, server: server)
      assert :ok = GitCore.BlobLimiter.release(replacement)
    end

    test "rejects one overweight request before contacting the limiter" do
      server = spawn(fn -> receive do: (:stop -> :ok) end)
      monitor = Process.monitor(server)
      send(server, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}

      assert_error(
        GitCore.BlobLimiter.acquire(128 * 1024 * 1024 + 1,
          server: server,
          operation: :read_blob_complete
        ),
        :blob_too_large,
        :read_blob_complete
      )
    end

    test "keeps weighted waiters FIFO when a lighter request could bypass the head" do
      server = start_blob_limiter!(capacity: 4, byte_capacity: 10, wait_timeout: 200)
      assert {:ok, four_byte_lease} = GitCore.BlobLimiter.acquire(4, server: server)
      assert {:ok, two_byte_lease} = GitCore.BlobLimiter.acquire(2, server: server)

      first = start_blob_owner(server, 5)
      wait_for_waiter_count(server, 1)
      second = start_blob_owner(server, 4)
      wait_for_waiter_count(server, 2)
      assert_waiter_index_size(server, 2)
      refute_receive {:blob_acquired, ^second, _lease}, 20

      assert :ok = GitCore.BlobLimiter.release(two_byte_lease)
      assert_receive {:blob_acquired, ^first, _first_lease}
      refute_receive {:blob_acquired, ^second, _lease}, 20

      assert :ok = GitCore.BlobLimiter.release(four_byte_lease)
      assert_receive {:blob_acquired, ^second, _second_lease}

      release_blob_owners([first, second])
    end

    test "uses the production 250 ms waiter timeout" do
      server = start_blob_limiter!(capacity: 1)
      assert {:ok, lease} = GitCore.BlobLimiter.acquire(0, server: server)
      started_at = System.monotonic_time(:millisecond)

      assert_error(
        GitCore.BlobLimiter.acquire(0, server: server, operation: :read_blob),
        :blob_busy,
        :read_blob
      )

      elapsed = System.monotonic_time(:millisecond) - started_at
      assert elapsed >= 200
      assert elapsed < 1_000
      assert :ok = GitCore.BlobLimiter.release(lease)
    end

    test "removes queued and granted blob leases when their owners die" do
      server = start_blob_limiter!(capacity: 1, byte_capacity: 10, wait_timeout: 200)
      granted = start_blob_owner(server, 10)
      assert_receive {:blob_acquired, ^granted, _lease}

      queued = start_blob_owner(server, 1)
      wait_for_waiter_count(server, 1)

      Process.exit(queued, :kill)
      wait_for_waiter_count(server, 0)
      Process.exit(granted, :kill)

      assert {:ok, recovered} = GitCore.BlobLimiter.acquire(10, server: server)
      assert :ok = GitCore.BlobLimiter.release(recovered)
    end

    test "routes opaque leases to the right server and releases idempotently" do
      first_server = start_blob_limiter!(capacity: 1, wait_timeout: 20)
      second_server = start_blob_limiter!(capacity: 1, wait_timeout: 20)
      assert {:ok, first_lease} = GitCore.BlobLimiter.acquire(0, server: first_server)
      assert {:ok, second_lease} = GitCore.BlobLimiter.acquire(0, server: second_server)

      assert :ok = GitCore.BlobLimiter.release(first_lease)
      assert :ok = GitCore.BlobLimiter.release(first_lease)
      assert {:ok, replacement} = GitCore.BlobLimiter.acquire(0, server: first_server)

      assert_error(
        GitCore.BlobLimiter.acquire(0, server: second_server, operation: :read_blob),
        :blob_busy,
        :read_blob
      )

      assert :ok = GitCore.BlobLimiter.release(replacement)
      assert :ok = GitCore.BlobLimiter.release(second_lease)
    end

    test "fails closed when the blob limiter process is unavailable" do
      server = spawn(fn -> receive do: (:stop -> :ok) end)
      monitor = Process.monitor(server)
      send(server, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}

      assert_error(
        GitCore.BlobLimiter.acquire(1, server: server, operation: :read_blob),
        :blob_busy,
        :read_blob
      )
    end

    test "stays unavailable after its supervised process crashes with full weight held" do
      server = {:global, {__MODULE__, :blob_crash, make_ref()}}
      supervisor = start_limiter_supervisor!(GitCore.BlobLimiter, server)
      limiter = GenServer.whereis(server)
      assert {:ok, old_lease} = GitCore.BlobLimiter.acquire(128 * 1024 * 1024, server: server)
      on_exit(fn -> GitCore.BlobLimiter.release(old_lease) end)

      monitor = Process.monitor(limiter)
      Process.exit(limiter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}
      wait_for_supervisor_settle(supervisor, server, limiter)

      assert_error(
        GitCore.BlobLimiter.acquire(1, server: server, operation: :read_blob_complete),
        :blob_busy,
        :read_blob_complete
      )

      assert :ok = GitCore.BlobLimiter.release(old_lease)
      assert :ok = GitCore.BlobLimiter.release(old_lease)
    end

    test "keeps test overrides inside hard production bounds" do
      assert_raise ArgumentError, fn -> GitCore.ScanLimiter.init(capacity: 5) end
      assert_raise ArgumentError, fn -> GitCore.ScanLimiter.init(wait_timeout: 251) end
      assert_raise ArgumentError, fn -> GitCore.BlobLimiter.init(capacity: 9) end

      assert_raise ArgumentError, fn ->
        GitCore.BlobLimiter.init(byte_capacity: 128 * 1024 * 1024 + 1)
      end

      assert_raise ArgumentError, fn -> GitCore.BlobLimiter.init(wait_timeout: 251) end
    end

    test "supervises both production limiters with independent children" do
      children = Supervisor.which_children(GitCore.Supervisor)

      assert {GitCore.ScanLimiter, scan_pid, :worker, [GitCore.ScanLimiter]} =
               List.keyfind(children, GitCore.ScanLimiter, 0)

      assert {GitCore.BlobLimiter, blob_pid, :worker, [GitCore.BlobLimiter]} =
               List.keyfind(children, GitCore.BlobLimiter, 0)

      assert is_pid(scan_pid)
      assert is_pid(blob_pid)
      refute scan_pid == blob_pid
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

  defp start_scan_limiter!(opts) do
    start_supervised!({GitCore.ScanLimiter, Keyword.put(opts, :server, nil)})
  end

  defp start_blob_limiter!(opts) do
    start_supervised!({GitCore.BlobLimiter, Keyword.put(opts, :server, nil)},
      id: make_ref()
    )
  end

  defp start_limiter_supervisor!(module, server) do
    {:ok, supervisor} =
      Supervisor.start_link([{module, server: server}], strategy: :one_for_one)

    on_exit(fn ->
      try do
        Supervisor.stop(supervisor)
      catch
        :exit, _reason -> :ok
      end
    end)

    supervisor
  end

  defp start_scan_owners(server, count) do
    for _ <- 1..count, do: start_scan_owner(server)
  end

  defp start_scan_owner(server) do
    parent = self()

    spawn(fn ->
      result =
        GitCore.ScanLimiter.with_permit(
          :test_scan,
          fn ->
            send(parent, {:scan_entered, self()})

            receive do
              :release -> :finished
            end
          end,
          server: server
        )

      send(parent, {:scan_finished, self(), result})
    end)
  end

  defp assert_scan_owners_entered(owners) do
    Enum.each(owners, fn owner ->
      assert_receive {:scan_entered, ^owner}
    end)
  end

  defp release_scan_owners(owners) do
    Enum.each(owners, &send(&1, :release))
    assert_scan_owners_finished(owners)
  end

  defp assert_scan_owners_finished(owners) do
    Enum.each(owners, fn owner ->
      assert_receive {:scan_finished, ^owner, :finished}
    end)
  end

  defp start_blob_owner(server, weight) do
    parent = self()

    spawn(fn ->
      case GitCore.BlobLimiter.acquire(weight, server: server) do
        {:ok, lease} ->
          send(parent, {:blob_acquired, self(), lease})

          receive do
            :release ->
              result = GitCore.BlobLimiter.release(lease)
              send(parent, {:blob_released, self(), result})
          end

        error ->
          send(parent, {:blob_acquire_failed, self(), error})
      end
    end)
  end

  defp release_blob_owners(owners) do
    Enum.each(owners, &send(&1, :release))

    Enum.each(owners, fn owner ->
      assert_receive {:blob_released, ^owner, :ok}
    end)
  end

  defp wait_for_waiter_count(server, count) do
    wait_until(fn ->
      server
      |> :sys.get_state()
      |> Map.fetch!(:waiters)
      |> map_size() == count
    end)
  end

  defp assert_waiter_index_size(server, count) do
    state = :sys.get_state(server)
    assert map_size(state.waiters) == count
    assert :gb_trees.size(state.queue) == count
  end

  defp wait_for_supervisor_settle(supervisor, server, old_limiter) do
    wait_until(fn ->
      registered = GenServer.whereis(server)
      counts = Supervisor.count_children(supervisor)

      (is_nil(registered) and counts.active == 0) or
        (is_pid(registered) and registered != old_limiter and counts.active == 1)
    end)
  end

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(5)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0), do: flunk("condition did not become true")

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
            } = prefix_blob} =
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
    assert :ok = GitCore.release_blob(prefix_blob)

    assert {:ok,
            %GitCore.Blob{
              oid: ^oid,
              size: ^size,
              data: complete,
              truncated: false,
              binary: true,
              non_utf8: true
            } = complete_blob} =
             GitCore.read_blob_complete(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path
             )

    assert complete == fixture.original
    assert :ok = GitCore.release_blob(complete_blob)
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

  defp stale_unrelated_index_prefix_blob_fixture!(tmp_dir) do
    fixture = prefix_blob_fixture!(tmp_dir, :loose)
    unrelated = populated_bare_repository!(tmp_dir)

    git!([
      "--git-dir",
      unrelated.repo_path,
      "repack",
      "-a",
      "-d",
      "-f",
      "--window=0",
      "--depth=0"
    ])

    [unrelated_index] =
      Path.wildcard(Path.join(unrelated.repo_path, "objects/pack/*.idx"))

    refute git!(["verify-pack", "-v", unrelated_index])
           |> String.split("\n")
           |> Enum.any?(fn line -> List.first(String.split(line)) == fixture.oid end)

    target_pack_dir = Path.join(fixture.repo_path, "objects/pack")
    File.mkdir_p!(target_pack_dir)
    stale_index = Path.join(target_pack_dir, Path.basename(unrelated_index))
    File.cp!(unrelated_index, stale_index)
    refute File.exists?(Path.rootname(stale_index) <> ".pack")

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

  defp ref_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "refs-#{suffix}.git")
    empty_tree_path = Path.join(tmp_dir, "empty-tree-#{suffix}")
    blob_path = Path.join(tmp_dir, "tag-blob-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(empty_tree_path, "")
    File.write!(blob_path, "not a commit\n")

    tree_oid =
      git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", empty_tree_path])

    blob_oid = git!(["--git-dir", repo_path, "hash-object", "-w", blob_path])
    commit_oid = git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "first"])

    second_commit_oid =
      git!([
        "--git-dir",
        repo_path,
        "commit-tree",
        tree_oid,
        "-p",
        commit_oid,
        "-m",
        "second"
      ])

    generated_branches =
      for index <- 0..104 do
        "refs/heads/branch/#{String.pad_leading(Integer.to_string(index), 3, "0")}"
      end

    selected_branch = "refs/heads/zz-selected/deep"

    branch_names =
      generated_branches ++
        [
          "refs/heads/feature/deep",
          "refs/heads/same",
          "refs/heads/tag-object",
          "refs/heads/topic",
          selected_branch
        ]

    Enum.each(branch_names, fn name ->
      git!(["--git-dir", repo_path, "update-ref", name, commit_oid])
    end)

    git!(["--git-dir", repo_path, "update-ref", "refs/tags/same", second_commit_oid])
    git!(["--git-dir", repo_path, "update-ref", "refs/tags/release/deep", commit_oid])
    git!(["--git-dir", repo_path, "update-ref", "refs/tags/topic/deep", second_commit_oid])
    git!(["--git-dir", repo_path, "update-ref", "refs/tags/blob-target", blob_oid])
    git!(["--git-dir", repo_path, "tag", "-a", "annotated", commit_oid, "-m", "annotated"])
    annotated_tag_oid = git!(["--git-dir", repo_path, "rev-parse", "refs/tags/annotated"])

    File.write!(
      Path.join([repo_path, "refs", "heads", "tag-object"]),
      annotated_tag_oid <> "\n"
    )

    git!(["--git-dir", repo_path, "tag", "-a", "nested", annotated_tag_oid, "-m", "nested"])
    nested_tag_oid = git!(["--git-dir", repo_path, "rev-parse", "refs/tags/nested"])

    mismatched_tag_path = Path.join(tmp_dir, "mismatched-tag-#{suffix}")

    File.write!(
      mismatched_tag_path,
      "object #{commit_oid}\ntype blob\ntag type-mismatch\n" <>
        "tagger Fornacast Test <test@example.com> 946684800 +0000\n\ninvalid type\n"
    )

    mismatched_tag_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tag",
        "-w",
        mismatched_tag_path
      ])

    git!([
      "--git-dir",
      repo_path,
      "update-ref",
      "refs/tags/type-mismatch",
      mismatched_tag_oid
    ])

    missing_tag_header_path = Path.join(tmp_dir, "missing-tag-header-#{suffix}")
    File.write!(missing_tag_header_path, "object #{commit_oid}\ntype commit\n")

    missing_tag_header_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tag",
        "-w",
        missing_tag_header_path
      ])

    File.write!(
      Path.join([repo_path, "refs", "tags", "missing-tag-header"]),
      missing_tag_header_oid <> "\n"
    )

    generated_tags =
      for index <- 0..104 do
        "refs/tags/tag/#{String.pad_leading(Integer.to_string(index), 3, "0")}"
      end

    Enum.each(generated_tags, fn name ->
      git!(["--git-dir", repo_path, "update-ref", name, commit_oid])
    end)

    tag_names =
      generated_tags ++
        [
          "refs/tags/annotated",
          "refs/tags/blob-target",
          "refs/tags/missing-tag-header",
          "refs/tags/nested",
          "refs/tags/release/deep",
          "refs/tags/same",
          "refs/tags/topic/deep",
          "refs/tags/type-mismatch"
        ]

    %{
      repo_path: repo_path,
      commit_oid: commit_oid,
      second_commit_oid: second_commit_oid,
      selected_branch: selected_branch,
      branch_names: branch_names,
      tag_names: tag_names,
      annotated_tag_oid: annotated_tag_oid,
      nested_tag_oid: nested_tag_oid
    }
  end

  defp empty_bare_repository!(tmp_dir) do
    path = Path.join(tmp_dir, "empty-#{System.unique_integer([:positive])}.git")
    git!(["init", "--bare", "--object-format=sha1", path])
    path
  end

  defp tree_history_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "tree-history-#{suffix}.git")
    git!(["init", "--bare", "--object-format=sha1", repo_path])

    base_blob = blob_object!(tmp_dir, repo_path, "tree-base-#{suffix}", "base\n")
    rename_blob = blob_object!(tmp_dir, repo_path, "tree-rename-#{suffix}", "renamed\n")
    nested_root_blob = blob_object!(tmp_dir, repo_path, "nested-root-#{suffix}", "root\n")
    nested_left_blob = blob_object!(tmp_dir, repo_path, "nested-left-#{suffix}", "left\n")
    zeta_right_blob = blob_object!(tmp_dir, repo_path, "zeta-right-#{suffix}", "right\n")
    file_right_blob = blob_object!(tmp_dir, repo_path, "file-right-#{suffix}", "right\n")
    file_tip_blob = blob_object!(tmp_dir, repo_path, "file-tip-#{suffix}", "tip\n")

    alpha_root_tree =
      tree_object!(tmp_dir, repo_path, "alpha-root-#{suffix}", [
        {"100644", "nested.txt", nested_root_blob}
      ])

    alpha_left_tree =
      tree_object!(tmp_dir, repo_path, "alpha-left-#{suffix}", [
        {"100644", "nested.txt", nested_left_blob}
      ])

    zeta_root_tree =
      tree_object!(tmp_dir, repo_path, "zeta-root-#{suffix}", [
        {"100644", "stable.txt", base_blob}
      ])

    zeta_right_tree =
      tree_object!(tmp_dir, repo_path, "zeta-right-#{suffix}", [
        {"100644", "stable.txt", zeta_right_blob}
      ])

    empty_tree = tree_object!(tmp_dir, repo_path, "empty-dir-#{suffix}", [])

    generated_names =
      for index <- 0..198,
          do: "file-#{String.pad_leading(Integer.to_string(index), 3, "0")}.txt"

    generated_root_entries = Enum.map(generated_names, &{"100644", &1, base_blob})

    raw_name_entries = [
      {"100644", <<"raw-", 0xFE>>, base_blob},
      {"100644", <<"raw-", 0xFF>>, base_blob}
    ]

    root_entries =
      [
        {"40000", "alpha-dir", alpha_root_tree},
        {"40000", "empty-dir", empty_tree},
        {"40000", "zeta-dir", zeta_root_tree},
        {"100644", "legacy-name.txt", rename_blob}
      ] ++ generated_root_entries ++ raw_name_entries

    left_entries =
      [
        {"40000", "alpha-dir", alpha_left_tree},
        {"40000", "empty-dir", empty_tree},
        {"40000", "zeta-dir", zeta_root_tree},
        {"100644", "renamed.txt", rename_blob}
      ] ++
        replace_tree_mode(generated_root_entries, "file-197.txt", "100755") ++
        raw_name_entries

    right_entries =
      [
        {"40000", "alpha-dir", alpha_root_tree},
        {"40000", "empty-dir", empty_tree},
        {"40000", "zeta-dir", zeta_right_tree},
        {"100644", "legacy-name.txt", rename_blob}
      ] ++
        replace_tree_blob(generated_root_entries, "file-198.txt", file_right_blob) ++
        raw_name_entries

    merge_entries =
      [
        {"40000", "alpha-dir", alpha_left_tree},
        {"40000", "empty-dir", empty_tree},
        {"40000", "zeta-dir", zeta_right_tree},
        {"100644", "renamed.txt", rename_blob}
      ] ++
        (generated_root_entries
         |> replace_tree_mode("file-197.txt", "100755")
         |> replace_tree_blob("file-198.txt", file_right_blob)) ++ raw_name_entries

    tip_entries = replace_tree_blob(merge_entries, "file-000.txt", file_tip_blob)

    root_tree_oid = tree_object!(tmp_dir, repo_path, "root-#{suffix}", root_entries)
    left_tree_oid = tree_object!(tmp_dir, repo_path, "left-#{suffix}", left_entries)
    right_tree_oid = tree_object!(tmp_dir, repo_path, "right-#{suffix}", right_entries)
    merge_tree_oid = tree_object!(tmp_dir, repo_path, "merge-#{suffix}", merge_entries)
    tip_tree_oid = tree_object!(tmp_dir, repo_path, "tip-#{suffix}", tip_entries)

    root_time = 946_684_800
    root_oid = commit_tree!(repo_path, root_tree_oid, "root tree", [], root_time)

    left_oid =
      commit_tree!(
        repo_path,
        left_tree_oid,
        "left descendant change",
        [root_oid],
        root_time + 100
      )

    right_oid =
      commit_tree!(
        repo_path,
        right_tree_oid,
        "right descendant change",
        [root_oid],
        root_time + 200
      )

    merge_oid =
      commit_tree!(
        repo_path,
        merge_tree_oid,
        "merge first-parent delta",
        [left_oid, right_oid],
        root_time + 300
      )

    tip_oid =
      commit_tree!(repo_path, tip_tree_oid, "tip file change", [merge_oid], root_time + 400)

    git!(["--git-dir", repo_path, "update-ref", "refs/heads/main", tip_oid])
    git!(["--git-dir", repo_path, "update-ref", "refs/heads/feature/slash", tip_oid])

    %{
      repo_path: repo_path,
      root_oid: root_oid,
      left_oid: left_oid,
      right_oid: right_oid,
      merge_oid: merge_oid,
      tip_oid: tip_oid,
      tip_tree_oid: tip_tree_oid,
      root_time: root_time
    }
  end

  defp blob_object!(tmp_dir, repo_path, name, data) do
    path = Path.join(tmp_dir, name)
    File.write!(path, data)
    git!(["--git-dir", repo_path, "hash-object", "-w", path])
  end

  defp tree_object!(tmp_dir, repo_path, name, entries) do
    path = Path.join(tmp_dir, name)

    contents =
      entries
      |> Enum.sort_by(fn {_mode, entry_name, _oid} -> entry_name end)
      |> Enum.map(fn {mode, entry_name, oid} ->
        [mode, " ", entry_name, <<0>>, oid_bytes(oid)]
      end)
      |> IO.iodata_to_binary()

    File.write!(path, contents)
    git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", path])
  end

  defp replace_tree_blob(entries, name, oid) do
    Enum.map(entries, fn
      {mode, ^name, _old_oid} -> {mode, name, oid}
      entry -> entry
    end)
  end

  defp replace_tree_mode(entries, name, mode) do
    Enum.map(entries, fn
      {_old_mode, ^name, oid} -> {mode, name, oid}
      entry -> entry
    end)
  end

  defp tree_history_wrong_kind_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "tree-history-wrong-kind-#{suffix}.git")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    blob_oid = blob_object!(tmp_dir, repo_path, "wrong-kind-blob-#{suffix}", "blob\n")

    root_tree_oid =
      tree_object!(tmp_dir, repo_path, "wrong-kind-tree-#{suffix}", [
        {"40000", "bad-tree", blob_oid}
      ])

    tip_oid = commit_tree!(repo_path, root_tree_oid, "wrong kind tree", [], 946_684_800)
    %{repo_path: repo_path, tip_oid: tip_oid}
  end

  defp tree_history_cross_kind_duplicate_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "tree-history-duplicate-#{suffix}.git")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    blob_oid = blob_object!(tmp_dir, repo_path, "duplicate-blob-#{suffix}", "blob\n")
    empty_tree_oid = tree_object!(tmp_dir, repo_path, "duplicate-empty-#{suffix}", [])

    root_tree_oid =
      tree_object_in_order!(tmp_dir, repo_path, "duplicate-root-#{suffix}", [
        {"100644", "foo", blob_oid},
        {"40000", "foo.bar", empty_tree_oid},
        {"40000", "foo", empty_tree_oid}
      ])

    tip_oid = commit_tree!(repo_path, root_tree_oid, "duplicate tree names", [], 946_684_800)
    %{repo_path: repo_path, tip_oid: tip_oid}
  end

  defp tree_history_invalid_mode_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "tree-history-invalid-mode-#{suffix}.git")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    blob_oid = blob_object!(tmp_dir, repo_path, "invalid-mode-blob-#{suffix}", "blob\n")

    root_tree_oid =
      tree_object_in_order!(tmp_dir, repo_path, "invalid-mode-root-#{suffix}", [
        {"100600", "invalid.txt", blob_oid}
      ])

    tip_oid = commit_tree!(repo_path, root_tree_oid, "invalid tree mode", [], 946_684_800)
    %{repo_path: repo_path, tip_oid: tip_oid}
  end

  defp prefix_directory_tree_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "tree-history-prefix-dirs-#{suffix}.git")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    empty_tree_oid = tree_object!(tmp_dir, repo_path, "prefix-empty-#{suffix}", [])

    # Git's canonical slash-sentinel order is foo.bar/ then foo/. The public contract is raw
    # filename-byte order, which deliberately reverses these two direct children.
    root_tree_oid =
      tree_object_in_order!(tmp_dir, repo_path, "prefix-root-#{suffix}", [
        {"40000", "foo.bar", empty_tree_oid},
        {"40000", "foo", empty_tree_oid}
      ])

    tip_oid = commit_tree!(repo_path, root_tree_oid, "prefix directories", [], 946_684_800)
    %{repo_path: repo_path, tip_oid: tip_oid}
  end

  defp tree_object_in_order!(tmp_dir, repo_path, name, entries) do
    path = Path.join(tmp_dir, name)

    contents =
      entries
      |> Enum.map(fn {mode, entry_name, oid} ->
        [mode, " ", entry_name, <<0>>, oid_bytes(oid)]
      end)
      |> IO.iodata_to_binary()

    File.write!(path, contents)
    git!(["--git-dir", repo_path, "hash-object", "--literally", "-t", "tree", "-w", path])
  end

  defp find_tree_entry!(entries, name) do
    Enum.find(entries, &(&1.name == name)) || flunk("expected tree entry #{inspect(name)}")
  end

  defp tree_history_trace_counter(count) do
    receive do
      {:trace, _pid, :call, {GitCore, :native_tree_history_call, _args}} ->
        tree_history_trace_counter(count + 1)

      {:read_tree_history_trace_count, from, ref} ->
        send(from, {:tree_history_trace_count, ref, count})
        tree_history_trace_counter(count)

      :stop ->
        :ok
    end
  end

  defp assert_tree_history_trace_count(tracee, tracer, expected) do
    barrier = :erlang.trace_delivered(tracee)
    assert_receive {:trace_delivered, ^tracee, ^barrier}, 1_000
    query = make_ref()
    send(tracer, {:read_tree_history_trace_count, self(), query})
    assert_receive {:tree_history_trace_count, ^query, ^expected}, 1_000
  end

  defp commit_dag_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "commit-dag-#{suffix}.git")
    empty_tree_path = Path.join(tmp_dir, "commit-dag-tree-#{suffix}")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(empty_tree_path, "")

    tree_oid =
      git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", empty_tree_path])

    base_time = 946_684_800
    # The root is deliberately newer than every descendant. A global timestamp sort would put it
    # first; the required Kahn walk cannot emit it until both merge branches have been emitted.
    root_oid = commit_tree!(repo_path, tree_oid, "root", [], base_time + 900)
    left_base_oid = commit_tree!(repo_path, tree_oid, "left base", [root_oid], base_time + 300)
    right_base_oid = commit_tree!(repo_path, tree_oid, "right base", [root_oid], base_time + 200)

    left_tip_oid =
      commit_tree!(repo_path, tree_oid, "left tip", [left_base_oid], base_time + 400)

    right_tip_oid =
      commit_tree!(repo_path, tree_oid, "right tip", [right_base_oid], base_time + 400)

    merge_oid =
      commit_tree!(
        repo_path,
        tree_oid,
        "merge",
        [left_tip_oid, right_tip_oid],
        base_time + 500
      )

    {tip_oid, chain_order} =
      Enum.reduce(1..52, {merge_oid, []}, fn index, {parent_oid, order} ->
        oid =
          commit_tree!(
            repo_path,
            tree_oid,
            "chain #{index}",
            [parent_oid],
            base_time + 500 + index
          )

        {oid, [oid | order]}
      end)

    git!(["--git-dir", repo_path, "update-ref", "refs/heads/main", tip_oid])

    expected_order =
      chain_order ++
        [merge_oid] ++
        Enum.sort([left_tip_oid, right_tip_oid]) ++
        [left_base_oid, right_base_oid, root_oid]

    %{
      repo_path: repo_path,
      tree_oid: tree_oid,
      tip_oid: tip_oid,
      tip_parent_oid: Enum.at(chain_order, 1),
      tip_title: "chain 52",
      tip_time: base_time + 552,
      expected_order: expected_order,
      root_oid: root_oid,
      left_base_oid: left_base_oid,
      right_base_oid: right_base_oid,
      left_tip_oid: left_tip_oid,
      right_tip_oid: right_tip_oid,
      merge_oid: merge_oid
    }
  end

  defp commit_tree!(repo_path, tree_oid, message, parents, timestamp) do
    args =
      ["--git-dir", repo_path, "commit-tree", tree_oid] ++
        Enum.flat_map(parents, &["-p", &1]) ++ ["-m", message]

    date = "#{timestamp} +0000"

    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"},
      {"GIT_AUTHOR_DATE", date},
      {"GIT_COMMITTER_DATE", date}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end

  defp literal_object!(tmp_dir, repo_path, name, kind, data) do
    object_path = Path.join(tmp_dir, "#{name}-#{System.unique_integer([:positive])}")
    File.write!(object_path, data)

    git!([
      "--git-dir",
      repo_path,
      "hash-object",
      "--literally",
      "-t",
      Atom.to_string(kind),
      "-w",
      object_path
    ])
  end

  defp symbolic_ref_cycle_repository!(tmp_dir) do
    path = empty_bare_repository!(tmp_dir)
    tags_path = Path.join([path, "refs", "tags"])
    File.mkdir_p!(tags_path)
    File.write!(Path.join(tags_path, "cycle-a"), "ref: refs/tags/cycle-b\n")
    File.write!(Path.join(tags_path, "cycle-b"), "ref: refs/tags/cycle-a\n")
    path
  end

  defp raw_ref_repository!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "raw-refs-#{suffix}.git")
    empty_tree_path = Path.join(tmp_dir, "raw-empty-tree-#{suffix}")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(empty_tree_path, "")

    tree_oid =
      git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", empty_tree_path])

    commit_oid = git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "raw refs"])
    short_names = [<<"raw-", 0xFE>>, <<"raw-", 0xFF>>]
    full_names = Enum.map(short_names, &(<<"refs/heads/">> <> &1))
    heads_path = Path.join([repo_path, "refs", "heads"])

    Enum.each(short_names, fn short_name ->
      File.write!(Path.join(heads_path, short_name), commit_oid <> "\n")
    end)

    %{
      repo_path: repo_path,
      commit_oid: commit_oid,
      short_names: short_names,
      full_names: full_names,
      selected_short_name: List.last(short_names),
      selected_ref: List.last(full_names)
    }
  end

  defp large_snapshot_repository!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "large-snapshot-#{suffix}.git")
    empty_tree_path = Path.join(tmp_dir, "large-empty-tree-#{suffix}")
    commit_message_path = Path.join(tmp_dir, "large-commit-message-#{suffix}")
    tag_message_path = Path.join(tmp_dir, "large-tag-message-#{suffix}")
    long_header_tag_path = Path.join(tmp_dir, "long-header-tag-#{suffix}")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(empty_tree_path, "")
    File.write!(commit_message_path, :binary.copy("commit message\n", 200_000))
    File.write!(tag_message_path, :binary.copy("tag message\n", 250_000))

    tree_oid =
      git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", empty_tree_path])

    commit_oid =
      git!([
        "--git-dir",
        repo_path,
        "commit-tree",
        tree_oid,
        "-F",
        commit_message_path
      ])

    git!([
      "--git-dir",
      repo_path,
      "tag",
      "-a",
      "large",
      commit_oid,
      "-F",
      tag_message_path
    ])

    long_internal_name = :binary.copy("long-internal-name-", 1_024)

    File.write!(
      long_header_tag_path,
      "object #{commit_oid}\ntype commit\ntag #{long_internal_name}\n" <>
        "tagger Fornacast Test <test@example.com> 946684800 +0000\n\nvalid long header\n"
    )

    long_header_tag_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tag",
        "-w",
        long_header_tag_path
      ])

    git!([
      "--git-dir",
      repo_path,
      "update-ref",
      "refs/tags/long-header",
      long_header_tag_oid
    ])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp same_kind_route_repository!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "same-kind-route-#{suffix}.git")
    empty_tree_path = Path.join(tmp_dir, "same-kind-empty-tree-#{suffix}")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(empty_tree_path, "")

    tree_oid =
      git!(["--git-dir", repo_path, "hash-object", "-t", "tree", "-w", empty_tree_path])

    commit_oid = git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "same kind"])

    # Git's loose ref namespace cannot contain both a file and a directory at this boundary.
    # A packed-only fixture still exercises deterministic longest-match behavior defensively.
    File.write!(
      Path.join(repo_path, "packed-refs"),
      "# pack-refs with: sorted\n" <>
        "#{commit_oid} refs/heads/feature\n" <>
        "#{commit_oid} refs/heads/feature/deep\n"
    )

    repo_path
  end

  defp find_ref!(refs, name) do
    Enum.find(refs, &(&1.name == name)) || flunk("expected ref #{name}")
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

defmodule GitCore.CacheTest do
  use ExUnit.Case, async: true

  @moduletag :cache
  @moduletag capture_log: true

  test "computes a miss once and returns the cached hit" do
    server = start_cache!()

    computation = fn ->
      Process.put(:cache_computations, Process.get(:cache_computations, 0) + 1)
      {:ok, :cached_value}
    end

    assert {:ok, :cached_value} = GitCore.Cache.fetch(:key, computation, server: server)
    assert {:ok, :cached_value} = GitCore.Cache.fetch(:key, computation, server: server)
    assert Process.get(:cache_computations) == 1
  end

  test "keeps every storage path and semantic key argument isolated" do
    server = start_cache!()

    keys = [
      {"/repos/one.git", :commit_summary, "oid-1"},
      {"/repos/two.git", :commit_summary, "oid-1"},
      {"/repos/one.git", :commit_summary, "oid-2"},
      {"/repos/one.git", :tree_history, "oid-1", "", 1, 200},
      {"/repos/one.git", :tree_history, "oid-1", "lib", 1, 200},
      {"/repos/one.git", :tree_history, "oid-1", "", 2, 200},
      {"/repos/one.git", :tree_history, "oid-1", "", 1, 100},
      {"/repos/one.git", :repository_analysis, "oid-1", {100_000, 536_870_912, 2_000}},
      {"/repos/one.git", :repository_analysis, "oid-1", {1, 536_870_912, 2_000}},
      {"/repos/one.git", :repository_analysis, "oid-1", {100_000, 1, 2_000}},
      {"/repos/one.git", :repository_analysis, "oid-1", {100_000, 536_870_912, 1}},
      {"/repos/one.git", :diff_commit, "oid-1", {200_000, 5_000}},
      {"/repos/one.git", :diff_commit, "oid-1", {1, 5_000}},
      {"/repos/one.git", :diff_commit, "oid-1", {200_000, 1}}
    ]

    Enum.with_index(keys, fn key, index ->
      assert {:ok, ^index} =
               GitCore.Cache.fetch(key, fn -> {:ok, index} end, server: server)
    end)

    Enum.with_index(keys, fn key, index ->
      assert {:ok, ^index} =
               GitCore.Cache.fetch(key, fn -> flunk("expected an isolated cache hit") end,
                 server: server
               )
    end)
  end

  test "evicts the strict least-recently-accessed entry at exactly 512 entries" do
    server = start_cache!()

    Enum.each(1..512, fn key ->
      assert {:ok, ^key} = GitCore.Cache.fetch(key, fn -> {:ok, key} end, server: server)
    end)

    assert {:ok, 1} =
             GitCore.Cache.fetch(1, fn -> flunk("expected key 1 to refresh") end, server: server)

    assert {:ok, 513} = GitCore.Cache.fetch(513, fn -> {:ok, 513} end, server: server)

    assert {:ok, 1} =
             GitCore.Cache.fetch(1, fn -> flunk("expected refreshed key 1 to remain") end,
               server: server
             )

    assert {:ok, :recomputed} =
             GitCore.Cache.fetch(2, fn -> {:ok, :recomputed} end, server: server)

    state = :sys.get_state(server)
    assert state.count == 512
    assert :ets.info(state.table, :size) == 512
  end

  test "accounts exact key-and-value external bytes and evicts at the injected byte bound" do
    first = {String.duplicate("first-key-", 8), :value}
    second = {String.duplicate("second-key-", 8), :value}
    first_size = :erlang.external_size(first)
    second_size = :erlang.external_size(second)
    assert first_size > :erlang.external_size(elem(first, 1))
    assert second_size > :erlang.external_size(elem(second, 1))

    server = start_cache!(max_bytes: max(first_size, second_size))

    assert {:ok, :value} =
             GitCore.Cache.fetch(elem(first, 0), fn -> {:ok, elem(first, 1)} end, server: server)

    first_state = :sys.get_state(server)
    assert first_state.used_bytes == first_size
    assert first_state.count == 1

    assert {:ok, :value} =
             GitCore.Cache.fetch(elem(second, 0), fn -> {:ok, elem(second, 1)} end,
               server: server
             )

    second_state = :sys.get_state(server)
    assert second_state.used_bytes == second_size
    assert second_state.count == 1

    assert {:ok, :recomputed} =
             GitCore.Cache.fetch(elem(first, 0), fn -> {:ok, :recomputed} end, server: server)
  end

  test "caches a value exactly at one MiB and bypasses one byte over" do
    value_limit = 1_048_576
    exact = :binary.copy(<<0>>, value_limit - :erlang.external_size(<<>>))
    over = exact <> <<0>>
    assert :erlang.external_size(exact) == value_limit
    assert :erlang.external_size(over) == value_limit + 1
    server = start_cache!()

    assert {:ok, ^exact} =
             GitCore.Cache.fetch(:exact, fn -> {:ok, exact} end, server: server)

    assert {:ok, ^exact} =
             GitCore.Cache.fetch(:exact, fn -> flunk("exact cutoff should be cached") end,
               server: server
             )

    counter = make_ref()
    Process.put(counter, 0)

    oversized = fn ->
      Process.put(counter, Process.get(counter) + 1)
      {:ok, over}
    end

    assert {:ok, ^over} = GitCore.Cache.fetch(:over, oversized, server: server)
    assert {:ok, ^over} = GitCore.Cache.fetch(:over, oversized, server: server)
    assert Process.get(counter) == 2
  end

  test "expires at 900,000 idle milliseconds and refreshes access time" do
    {clock, set_clock} = manual_clock()
    server = start_cache!(clock: clock)

    assert {:ok, :refreshed} =
             GitCore.Cache.fetch(:refreshed, fn -> {:ok, :refreshed} end, server: server)

    assert {:ok, :boundary} =
             GitCore.Cache.fetch(:boundary, fn -> {:ok, :boundary} end, server: server)

    set_clock.(899_999)

    assert {:ok, :refreshed} =
             GitCore.Cache.fetch(:refreshed, fn -> flunk("899,999 ms must remain live") end,
               server: server
             )

    set_clock.(900_000)

    assert {:ok, :expired} =
             GitCore.Cache.fetch(:boundary, fn -> {:ok, :expired} end, server: server)

    set_clock.(1_799_998)

    assert {:ok, :refreshed} =
             GitCore.Cache.fetch(:refreshed, fn -> flunk("access must refresh idle time") end,
               server: server
             )

    state = :sys.get_state(server)
    assert state.count == 2
  end

  test "treats process and table lookup or put failures as misses" do
    dead_server = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_server)
    assert_receive {:DOWN, ^monitor, :process, ^dead_server, _reason}

    assert {:ok, :from_dead_process} =
             GitCore.Cache.fetch(:key, fn -> {:ok, :from_dead_process} end, server: dead_server)

    lookup_server = start_cache!()
    :sys.replace_state(lookup_server, &Map.put(&1, :table, make_ref()))

    assert {:ok, :from_bad_lookup_table} =
             GitCore.Cache.fetch(:key, fn -> {:ok, :from_bad_lookup_table} end,
               server: lookup_server
             )

    put_server = start_cache!()

    assert {:ok, :from_bad_put_table} =
             GitCore.Cache.fetch(
               :key,
               fn ->
                 :sys.replace_state(put_server, &Map.put(&1, :table, make_ref()))
                 {:ok, :from_bad_put_table}
               end,
               server: put_server
             )

    stopped_server = start_cache!()

    assert {:ok, :from_stopped_process} =
             GitCore.Cache.fetch(
               :key,
               fn ->
                 stopped = Process.monitor(stopped_server)
                 Process.exit(stopped_server, :kill)
                 assert_receive {:DOWN, ^stopped, :process, ^stopped_server, :killed}
                 {:ok, :from_stopped_process}
               end,
               server: stopped_server
             )
  end

  test "does not cache typed errors or swallow computation raise, throw, or exit" do
    server = start_cache!()

    typed_error =
      {:error,
       %GitCore.Error{
         kind: :scan_timeout,
         operation: :repository_analysis,
         detail: "timed out"
       }}

    assert ^typed_error = GitCore.Cache.fetch(:typed, fn -> typed_error end, server: server)
    assert ^typed_error = GitCore.Cache.fetch(:typed, fn -> typed_error end, server: server)

    assert_raise RuntimeError, "boom", fn ->
      GitCore.Cache.fetch(:raise, fn -> raise "boom" end, server: server)
    end

    assert catch_throw(GitCore.Cache.fetch(:throw, fn -> throw(:boom) end, server: server)) ==
             :boom

    assert catch_exit(GitCore.Cache.fetch(:exit, fn -> exit(:boom) end, server: server)) ==
             :boom

    assert :ets.info(:sys.get_state(server).table, :size) == 0
  end

  test "serializes concurrent same-key puts without count or byte inflation" do
    server = start_cache!()
    parent = self()
    replacement = String.duplicate("replacement-", 32)

    first =
      Task.async(fn ->
        GitCore.Cache.fetch(
          :shared,
          fn ->
            send(parent, {:computed, self(), :first})
            receive do: (:release -> {:ok, :first})
          end,
          server: server
        )
      end)

    second =
      Task.async(fn ->
        GitCore.Cache.fetch(
          :shared,
          fn ->
            send(parent, {:computed, self(), :second})
            receive do: (:release -> {:ok, replacement})
          end,
          server: server
        )
      end)

    assert_receive {:computed, first_pid, :first}
    assert_receive {:computed, second_pid, :second}
    send(first_pid, :release)
    assert {:ok, :first} = Task.await(first)
    send(second_pid, :release)
    assert {:ok, ^replacement} = Task.await(second)

    assert {:ok, ^replacement} =
             GitCore.Cache.fetch(:shared, fn -> flunk("expected the replacement hit") end,
               server: server
             )

    state = :sys.get_state(server)
    assert state.count == 1
    assert state.used_bytes == :erlang.external_size({:shared, replacement})
    assert :ets.info(state.table, :size) == 1
  end

  test "uses a private ETS table and keeps test overrides inside production caps" do
    server = start_cache!()
    state = :sys.get_state(server)

    assert :ets.info(state.table, :protection) == :private
    assert :ets.info(state.table, :owner) == server
    assert state.max_entries == 512
    assert state.max_bytes == 67_108_864
    assert state.max_value_bytes == 1_048_576
    assert state.idle_expiration_ms == 900_000

    assert_raise ArgumentError, fn -> GitCore.Cache.init(max_entries: 513) end
    assert_raise ArgumentError, fn -> GitCore.Cache.init(max_bytes: 67_108_865) end
    assert_raise ArgumentError, fn -> GitCore.Cache.init(max_value_bytes: 1_048_577) end
    assert_raise ArgumentError, fn -> GitCore.Cache.init(idle_expiration_ms: 900_001) end
  end

  defp start_cache!(opts \\ []) do
    opts = Keyword.put_new(opts, :clock, fn -> 0 end)

    start_supervised!({GitCore.Cache, Keyword.put(opts, :server, nil)},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp manual_clock do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, 0)

    {
      fn -> :atomics.get(clock, 1) end,
      fn now -> :atomics.put(clock, 1, now) end
    }
  end
end

defmodule GitCore.CacheIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :cache
  @moduletag :tmp_dir
  @moduletag capture_log: true

  test "supervises the production cache after both limiters" do
    assert [
             {GitCore.Cache, cache_pid, :worker, [GitCore.Cache]},
             {GitCore.BlobLimiter, blob_pid, :worker, [GitCore.BlobLimiter]},
             {GitCore.ScanLimiter, scan_pid, :worker, [GitCore.ScanLimiter]}
           ] = Supervisor.which_children(GitCore.Supervisor)

    assert is_pid(cache_pid)
    assert is_pid(blob_pid)
    assert is_pid(scan_pid)
  end

  test "constructs exact normalized immutable keys for all four cached reads", %{
    tmp_dir: tmp_dir
  } do
    fixture = repository_fixture!(tmp_dir, "keys-one")

    assert {:ok, summary} = GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)

    assert {:ok, ^summary} =
             GitCore.commit_summary(fixture.repo_path, fixture.commit_oid, deadline_ms: 0)

    assert {:ok, _tree} =
             GitCore.read_tree_with_history(
               fixture.repo_path,
               fixture.commit_oid,
               "",
               1,
               per_page: 500
             )

    assert {:ok, _tree} =
             GitCore.read_tree_with_history(
               fixture.repo_path,
               fixture.commit_oid,
               "",
               1,
               per_page: 200
             )

    assert {:ok, _tree} =
             GitCore.read_tree_with_history(
               fixture.repo_path,
               fixture.commit_oid,
               "",
               1,
               per_page: 0
             )

    assert {:ok, _tree} =
             GitCore.read_tree_with_history(
               fixture.repo_path,
               fixture.commit_oid,
               "",
               2
             )

    assert {:ok, _tree} =
             GitCore.read_tree_with_history(
               fixture.repo_path,
               fixture.commit_oid,
               "lib",
               1
             )

    assert {:ok, _analysis} =
             GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid)

    assert {:ok, _analysis} =
             GitCore.repository_analysis(
               fixture.repo_path,
               fixture.commit_oid,
               file_limit: 100_001,
               byte_limit: 536_870_913,
               deadline_ms: 2_001
             )

    assert {:ok, _analysis} =
             GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid, file_limit: 1)

    assert {:ok, _analysis} =
             GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid, byte_limit: 1)

    assert {:ok, _analysis} =
             GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid, deadline_ms: 0)

    assert {:ok, _diff} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    assert {:ok, _diff} =
             GitCore.diff_commit(
               fixture.repo_path,
               fixture.commit_oid,
               limit: 200_001,
               deadline_ms: 5_001
             )

    assert {:ok, _diff} =
             GitCore.diff_commit(fixture.repo_path, fixture.commit_oid, limit: 0)

    assert {:ok, _diff} =
             GitCore.diff_commit(fixture.repo_path, fixture.commit_oid, deadline_ms: 4_999)

    expected_keys =
      MapSet.new([
        {fixture.repo_path, :commit_summary, fixture.commit_oid},
        {fixture.repo_path, :tree_history, fixture.commit_oid, "", 1, 200},
        {fixture.repo_path, :tree_history, fixture.commit_oid, "", 1, 1},
        {fixture.repo_path, :tree_history, fixture.commit_oid, "", 2, 200},
        {fixture.repo_path, :tree_history, fixture.commit_oid, "lib", 1, 200},
        {fixture.repo_path, :repository_analysis, fixture.commit_oid,
         {100_000, 536_870_912, 2_000}},
        {fixture.repo_path, :repository_analysis, fixture.commit_oid, {1, 536_870_912, 2_000}},
        {fixture.repo_path, :repository_analysis, fixture.commit_oid, {100_000, 1, 2_000}},
        {fixture.repo_path, :repository_analysis, fixture.commit_oid, {100_000, 536_870_912, 0}},
        {fixture.repo_path, :diff_commit, fixture.commit_oid, {200_000, 5_000}},
        {fixture.repo_path, :diff_commit, fixture.commit_oid, {1, 5_000}},
        {fixture.repo_path, :diff_commit, fixture.commit_oid, {200_000, 4_999}}
      ])

    assert cache_keys_for(fixture.repo_path) == expected_keys

    isolated = repository_fixture!(tmp_dir, "keys-two")
    assert isolated.commit_oid == fixture.commit_oid
    assert {:ok, _summary} = GitCore.commit_summary(isolated.repo_path, isolated.commit_oid)

    assert cache_keys_for(isolated.repo_path) ==
             MapSet.new([{isolated.repo_path, :commit_summary, isolated.commit_oid}])
  end

  test "cached hits bypass four saturated scan permits while a distinct miss stays protected", %{
    tmp_dir: tmp_dir
  } do
    fixture = repository_fixture!(tmp_dir, "saturated")

    assert {:ok, summary} = GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)

    assert {:ok, tree} =
             GitCore.read_tree_with_history(fixture.repo_path, fixture.commit_oid, "", 1)

    assert {:ok, analysis} =
             GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid)

    assert {:ok, diff} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    holders = start_scan_holders(4)
    assert_scan_holders_entered(holders)

    try do
      assert {:ok, ^summary} = GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)

      assert {:ok, ^tree} =
               GitCore.read_tree_with_history(fixture.repo_path, fixture.commit_oid, "", 1)

      assert {:ok, ^analysis} =
               GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid)

      assert {:ok, ^diff} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

      assert_error(
        GitCore.commit_summary(fixture.repo_path, String.duplicate("f", 40)),
        :scan_busy,
        :commit_summary
      )
    after
      release_scan_holders(holders)
    end
  end

  test "cache failure falls back through ScanLimiter and its restart discards only derived data",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = repository_fixture!(tmp_dir, "restart")
    assert {:ok, summary} = GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)
    old_cache = Process.whereis(GitCore.Cache)
    monitor = Process.monitor(old_cache)
    holders = start_scan_holders(4)
    assert_scan_holders_entered(holders)

    try do
      :sys.replace_state(old_cache, &Map.put(&1, :table, make_ref()))

      assert_error(
        GitCore.commit_summary(fixture.repo_path, fixture.commit_oid),
        :scan_busy,
        :commit_summary
      )

      assert_receive {:DOWN, ^monitor, :process, ^old_cache, _reason}, 1_000
    after
      release_scan_holders(holders)
    end

    new_cache = wait_for_cache_restart(old_cache)
    refute new_cache == old_cache
    assert :sys.get_state(new_cache).count == 0
    assert {:ok, ^summary} = GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)
  end

  test "a pushed OID gets a new key while the old immutable result stays stable", %{
    tmp_dir: tmp_dir
  } do
    fixture = repository_fixture!(tmp_dir, "push")

    assert {:ok, %GitCore.CommitSummary{count: 1} = old_summary} =
             GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)

    File.write!(Path.join(fixture.work_path, "README.md"), "# Updated\n")
    git!(["-C", fixture.work_path, "add", "README.md"])
    git!(["-C", fixture.work_path, "commit", "-m", "Second commit"])
    git!(["-C", fixture.work_path, "push", "origin", "main"])
    new_oid = git!(["-C", fixture.work_path, "rev-parse", "HEAD"])
    refute new_oid == fixture.commit_oid

    assert {:ok, %GitCore.CommitSummary{count: 2, latest: %{oid: ^new_oid}}} =
             GitCore.commit_summary(fixture.repo_path, new_oid)

    assert {:ok, ^old_summary} =
             GitCore.commit_summary(fixture.repo_path, fixture.commit_oid)

    assert cache_keys_for(fixture.repo_path)
           |> MapSet.intersection(
             MapSet.new([
               {fixture.repo_path, :commit_summary, fixture.commit_oid},
               {fixture.repo_path, :commit_summary, new_oid}
             ])
           )
           |> MapSet.size() == 2
  end

  test "explicitly uncached repository operations add no cache key", %{tmp_dir: tmp_dir} do
    fixture = repository_fixture!(tmp_dir, "uncached")
    assert cache_keys_for(fixture.repo_path) == MapSet.new()

    assert {:ok, _refs} = GitCore.list_refs(fixture.repo_path)
    assert {:ok, true} = GitCore.is_bare_repository?(fixture.repo_path)
    assert {:ok, false} = GitCore.empty?(fixture.repo_path)
    assert {:ok, _summary} = GitCore.ref_summary(fixture.repo_path)
    assert {:ok, _page} = GitCore.ref_page(fixture.repo_path, :branch, 1)

    selector = %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/main"}
    assert {:ok, _snapshot} = GitCore.resolve_snapshot(fixture.repo_path, selector)
    assert {:ok, _page} = GitCore.commit_page(fixture.repo_path, fixture.commit_oid, 1)

    assert {:ok, inline_blob} =
             GitCore.read_blob(fixture.repo_path, fixture.commit_oid, "README.md")

    assert :ok = GitCore.release_blob(inline_blob)

    assert {:ok, complete_blob} =
             GitCore.read_blob_complete(fixture.repo_path, fixture.commit_oid, "README.md")

    assert :ok = GitCore.release_blob(complete_blob)

    assert {:ok, _results} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "README")

    assert {:ok, _bytes} = GitCore.repository_disk_usage(fixture.repo_path)
    assert {:ok, _branches} = GitCore.branches(fixture.repo_path)
    assert {:ok, _tags} = GitCore.tags(fixture.repo_path)
    assert {:ok, _history} = GitCore.commit_history(fixture.repo_path, "main")
    assert {:ok, _commit} = GitCore.commit(fixture.repo_path, fixture.commit_oid)
    assert {:ok, _tree} = GitCore.read_tree(fixture.repo_path, "main")

    assert {:ok, <<"PACK", _rest::binary>> = pack} =
             GitCore.pack_objects(fixture.repo_path, [fixture.commit_oid])

    assert {:ok, []} = GitCore.receive_pack(fixture.repo_path, pack, [])

    assert cache_keys_for(fixture.repo_path) == MapSet.new()
  end

  defp repository_fixture!(tmp_dir, name) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "#{name}-#{suffix}.git")
    work_path = Path.join(tmp_dir, "#{name}-work-#{suffix}")

    assert {:ok, _path} = GitCore.init_bare(repo_path)
    git!(["init", "--object-format=sha1", work_path])
    File.mkdir_p!(Path.join(work_path, "lib"))
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    File.write!(Path.join(work_path, "lib/demo.ex"), "defmodule Demo, do: :ok\n")
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])

    %{
      repo_path: repo_path,
      work_path: work_path,
      commit_oid: git!(["-C", work_path, "rev-parse", "HEAD"])
    }
  end

  defp cache_keys_for(repo_path) do
    parent = self()
    ref = make_ref()

    :sys.replace_state(GitCore.Cache, fn state ->
      send(parent, {ref, :ets.tab2list(state.table)})
      state
    end)

    assert_receive {^ref, entries}

    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(is_tuple(&1) and tuple_size(&1) > 0 and elem(&1, 0) == repo_path))
    |> MapSet.new()
  end

  defp start_scan_holders(count) do
    parent = self()

    for _ <- 1..count do
      spawn(fn ->
        result =
          GitCore.ScanLimiter.with_permit(:cache_scan_holder, fn ->
            send(parent, {:cache_scan_entered, self()})

            receive do
              :release -> :released
            end
          end)

        send(parent, {:cache_scan_finished, self(), result})
      end)
    end
  end

  defp assert_scan_holders_entered(holders) do
    Enum.each(holders, fn holder ->
      assert_receive {:cache_scan_entered, ^holder}, 1_000
    end)
  end

  defp release_scan_holders(holders) do
    Enum.each(holders, &send(&1, :release))

    Enum.each(holders, fn holder ->
      assert_receive {:cache_scan_finished, ^holder, :released}, 1_000
    end)
  end

  defp wait_for_cache_restart(old_cache, attempts \\ 100)

  defp wait_for_cache_restart(old_cache, attempts) when attempts > 0 do
    case Process.whereis(GitCore.Cache) do
      cache when is_pid(cache) and cache != old_cache ->
        cache

      _other ->
        Process.sleep(5)
        wait_for_cache_restart(old_cache, attempts - 1)
    end
  end

  defp wait_for_cache_restart(_old_cache, 0), do: flunk("cache did not restart")

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Cache Test"},
      {"GIT_AUTHOR_EMAIL", "cache@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Cache Test"},
      {"GIT_COMMITTER_EMAIL", "cache@example.com"},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end

defmodule GitCore.RepositorySearchTest do
  use ExUnit.Case, async: false

  @moduletag :search
  @content_blob_limit 1_048_576

  @tag :tmp_dir
  test "path search is literal case-insensitive, raw-byte ordered, stable, and physical", %{
    tmp_dir: tmp_dir
  } do
    fixture = path_search_fixture!(tmp_dir)

    expected_paths = [
      "a/match-inside.txt",
      "foo.match",
      "foo/match-child.txt",
      <<"raw-", 0xFF, "-MATCH.txt">>,
      "unicode-İ-match.txt"
    ]

    for _ <- 1..2 do
      assert {:ok,
              %GitCore.SearchResults{
                scope: :path,
                results: results,
                files_scanned: 5,
                bytes_scanned: 0,
                truncated_reasons: []
              }} = GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "mAtCh")

      assert Enum.map(results, & &1.path) == expected_paths

      assert Enum.all?(results, fn result ->
               match?(%GitCore.SearchResult{line: nil, snippet: nil}, result)
             end)
    end

    assert {:ok, %GitCore.SearchResults{results: [%{path: "unicode-İ-match.txt"}]}} =
             GitCore.search_tree(
               fixture.repo_path,
               fixture.commit_oid,
               "i\u0307",
               scope: :path
             )

    assert {:ok, %GitCore.SearchResults{results: [%{path: "foo.match"}]}} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "foo.", scope: :path)

    refute Enum.any?(expected_paths, &(&1 == "replacement-only-match.txt"))
  end

  @tag :tmp_dir
  test "path caps preserve zero, apply after ordering, and report only omitted work", %{
    tmp_dir: tmp_dir
  } do
    fixture = path_search_fixture!(tmp_dir)

    assert {:ok, %GitCore.SearchResults{results: exact, truncated_reasons: []}} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "match",
               result_limit: 5,
               file_limit: 5
             )

    assert length(exact) == 5

    assert {:ok,
            %GitCore.SearchResults{
              results: first_three,
              files_scanned: 5,
              truncated_reasons: [:result_limit]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "match", result_limit: 3)

    assert Enum.map(first_three, & &1.path) == Enum.take(Enum.map(exact, & &1.path), 3)

    assert {:ok,
            %GitCore.SearchResults{
              results: [],
              files_scanned: 5,
              truncated_reasons: [:result_limit]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "match", result_limit: 0)

    assert {:ok,
            %GitCore.SearchResults{
              results: [],
              files_scanned: 0,
              truncated_reasons: [:file_limit]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "match", file_limit: 0)

    assert {:ok,
            %GitCore.SearchResults{
              results: [],
              files_scanned: 0,
              truncated_reasons: [:deadline]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "match", deadline_ms: 0)

    empty = empty_search_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.SearchResults{
              results: [],
              files_scanned: 0,
              truncated_reasons: []
            }} =
             GitCore.search_tree(empty.repo_path, empty.commit_oid, "match",
               file_limit: 0,
               result_limit: 0,
               deadline_ms: 0
             )
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "path search never scans more than ten thousand files", %{tmp_dir: tmp_dir} do
    fixture = many_path_search_fixture!(tmp_dir, 10_001)

    assert {:ok,
            %GitCore.SearchResults{
              results: [],
              files_scanned: 10_000,
              bytes_scanned: 0,
              truncated_reasons: [:file_limit]
            }} = GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "absent")

    assert {:ok,
            %GitCore.SearchResults{
              results: results,
              files_scanned: 10_000,
              truncated_reasons: [:file_limit, :result_limit]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "file-",
               file_limit: 20_000,
               result_limit: 200,
               deadline_ms: 20_000
             )

    assert length(results) == 100
    assert hd(results).path == "file-00001.txt"
    assert List.last(results).path == "file-00100.txt"
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "content search excludes ineligible bodies and returns bounded ordered lines", %{
    tmp_dir: tmp_dir
  } do
    fixture = content_search_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.SearchResults{
              scope: :content,
              results: results,
              files_scanned: 7,
              bytes_scanned: bytes_scanned,
              truncated_reasons: []
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "nEeDlE", scope: :content)

    assert Enum.map(results, &{&1.path, &1.line}) == [
             {"a.txt", 2},
             {"a.txt", 3},
             {"exact.txt", 1},
             {"nested/inside.txt", 2},
             {"z.txt", 1}
           ]

    assert bytes_scanned == fixture.eligible_bytes
    assert Enum.count(results, &(&1.path == "a.txt" and &1.line == 2)) == 1

    long = Enum.find(results, &(&1.path == "z.txt"))
    assert long.snippet == String.duplicate("界", 240)
    assert byte_size(long.snippet) == 720
    assert String.valid?(long.snippet)

    refute Enum.any?(results, &(&1.path in ["binary.txt", "huge.txt", "invalid.txt"]))

    assert {:ok,
            %GitCore.SearchResults{
              results: [%GitCore.SearchResult{path: "nested/inside.txt", line: 2}]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "i\u0307tem",
               scope: :content
             )
  end

  @tag :tmp_dir
  test "content byte and result reasons are ordered and only mark omitted work", %{
    tmp_dir: tmp_dir
  } do
    fixture = content_search_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.SearchResults{
              results: [%{path: "a.txt", line: 2}],
              bytes_scanned: scanned,
              truncated_reasons: [:byte_limit, :result_limit]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "needle",
               scope: :content,
               byte_limit: fixture.first_blob_bytes,
               result_limit: 1
             )

    assert scanned == fixture.first_blob_bytes

    assert {:ok,
            %GitCore.SearchResults{
              results: [],
              bytes_scanned: 0,
              truncated_reasons: [:byte_limit]
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "needle",
               scope: :content,
               byte_limit: 0
             )

    assert {:ok,
            %GitCore.SearchResults{
              results: exact,
              truncated_reasons: []
            }} =
             GitCore.search_tree(fixture.repo_path, fixture.commit_oid, "needle",
               scope: :content,
               result_limit: 5
             )

    assert length(exact) == 5

    post_limit = post_byte_limit_corruption_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.SearchResults{
              results: [%GitCore.SearchResult{path: "a.txt", line: 1}],
              files_scanned: 3,
              bytes_scanned: 7,
              truncated_reasons: [:byte_limit]
            }} =
             GitCore.search_tree(post_limit.repo_path, post_limit.commit_oid, "needle",
               scope: :content,
               byte_limit: 7
             )
  end

  @tag :tmp_dir
  test "content search rejects false blob identities and noncanonical trees", %{tmp_dir: tmp_dir} do
    aliased = aliased_search_blob_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.SearchResults{
              results: [%GitCore.SearchResult{path: "aliased.txt"}]
            }} = GitCore.search_tree(aliased.repo_path, aliased.commit_oid, "aliased")

    assert_error(
      GitCore.search_tree(aliased.repo_path, aliased.commit_oid, "needle", scope: :content),
      :corrupt_repository,
      :search_tree
    )

    malformed = malformed_search_tree_fixture!(tmp_dir)

    assert_error(
      GitCore.search_tree(malformed.repo_path, malformed.commit_oid, "needle", scope: :content),
      :corrupt_repository,
      :search_tree
    )

    aliased_commit = aliased_search_commit_fixture!(tmp_dir)

    assert_error(
      GitCore.search_tree(aliased_commit.repo_path, aliased_commit.commit_oid, "needle"),
      :corrupt_repository,
      :search_tree
    )
  end

  test "search cannot redirect around the supervised global scan limiter" do
    isolated_limiter =
      start_supervised!({GitCore.ScanLimiter, server: nil}, id: make_ref())

    holders = for _ <- 1..4, do: start_global_search_holder()

    Enum.each(holders, fn holder ->
      assert_receive {:global_search_scan_entered, ^holder}, 1_000
    end)

    missing_path =
      Path.join(System.tmp_dir!(), "missing-search-#{System.unique_integer([:positive])}.git")

    try do
      assert_error(
        GitCore.search_tree(missing_path, String.duplicate("f", 40), "query",
          scan_limiter: isolated_limiter
        ),
        :scan_busy,
        :search_tree
      )
    after
      Enum.each(holders, &send(&1, :release))

      Enum.each(holders, fn holder ->
        assert_receive {:global_search_scan_finished, ^holder, :released}, 1_000
      end)
    end
  end

  defp path_search_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "path-search")
    blob_oid = write_blob!(repo_path, tmp_dir, "path-body-#{suffix}", "body\n")

    a_tree =
      write_tree!(repo_path, tmp_dir, "path-a-#{suffix}", [
        {"100644", "match-inside.txt", blob_oid}
      ])

    foo_tree =
      write_tree!(repo_path, tmp_dir, "path-foo-#{suffix}", [
        {"100644", "match-child.txt", blob_oid}
      ])

    root_tree =
      write_tree!(repo_path, tmp_dir, "path-root-#{suffix}", [
        {"40000", "a", a_tree},
        {"100644", "foo.match", blob_oid},
        {"40000", "foo", foo_tree},
        {"100644", <<"raw-", 0xFF, "-MATCH.txt">>, blob_oid},
        {"100644", "unicode-İ-match.txt", blob_oid}
      ])

    commit_oid = commit_tree!(repo_path, root_tree, "search snapshot")

    replacement_tree =
      write_tree!(repo_path, tmp_dir, "path-replacement-#{suffix}", [
        {"100644", "replacement-only-match.txt", blob_oid}
      ])

    replacement_oid = commit_tree!(repo_path, replacement_tree, "replacement snapshot")
    git!(["--git-dir", repo_path, "update-ref", "refs/replace/#{commit_oid}", replacement_oid])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp empty_search_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "empty-search")
    tree_oid = write_tree!(repo_path, tmp_dir, "empty-tree-#{suffix}", [])
    %{repo_path: repo_path, commit_oid: commit_tree!(repo_path, tree_oid, "empty search")}
  end

  defp many_path_search_fixture!(tmp_dir, count) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "many-search")
    blob_oid = write_blob!(repo_path, tmp_dir, "many-body-#{suffix}", "body\n")

    entries =
      for index <- 1..count do
        {"100644", "file-#{String.pad_leading(Integer.to_string(index), 5, "0")}.txt", blob_oid}
      end

    tree_oid = write_tree!(repo_path, tmp_dir, "many-tree-#{suffix}", entries)
    %{repo_path: repo_path, commit_oid: commit_tree!(repo_path, tree_oid, "many search")}
  end

  defp content_search_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "content-search")
    first = "heading\nNeedle twice needle\ntail needle\n"
    binary = <<"needle", 0, "hidden\n">>
    invalid = <<"needle invalid ", 0xFF, "\n">>
    exact = String.pad_trailing("needle\n", @content_blob_limit, "x")
    nested = "nothing\nİTEM NEEDLE nested\n"
    long = String.duplicate("界", 250) <> " needle\n"

    blobs = %{
      first: write_blob!(repo_path, tmp_dir, "content-a-#{suffix}", first),
      binary: write_blob!(repo_path, tmp_dir, "content-binary-#{suffix}", binary),
      exact: write_blob!(repo_path, tmp_dir, "content-exact-#{suffix}", exact),
      huge: write_declared_blob_header!(repo_path, @content_blob_limit + 1),
      invalid: write_blob!(repo_path, tmp_dir, "content-invalid-#{suffix}", invalid),
      nested: write_blob!(repo_path, tmp_dir, "content-nested-#{suffix}", nested),
      long: write_blob!(repo_path, tmp_dir, "content-z-#{suffix}", long)
    }

    replacement = write_blob!(repo_path, tmp_dir, "content-replacement-#{suffix}", "hidden\n")
    git!(["--git-dir", repo_path, "update-ref", "refs/replace/#{blobs.first}", replacement])

    nested_tree =
      write_tree!(repo_path, tmp_dir, "content-nested-tree-#{suffix}", [
        {"100644", "inside.txt", blobs.nested}
      ])

    root_tree =
      write_tree!(repo_path, tmp_dir, "content-root-#{suffix}", [
        {"100644", "a.txt", blobs.first},
        {"100644", "binary.txt", blobs.binary},
        {"100644", "exact.txt", blobs.exact},
        {"100644", "huge.txt", blobs.huge},
        {"100644", "invalid.txt", blobs.invalid},
        {"40000", "nested", nested_tree},
        {"100644", "z.txt", blobs.long}
      ])

    %{
      repo_path: repo_path,
      commit_oid: commit_tree!(repo_path, root_tree, "content search"),
      first_blob_bytes: byte_size(first),
      eligible_bytes:
        Enum.sum(Enum.map([first, binary, exact, invalid, nested, long], &byte_size/1))
    }
  end

  defp aliased_search_blob_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "aliased-search")
    canonical_oid = write_blob!(repo_path, tmp_dir, "aliased-body-#{suffix}", "needle\n")
    fake_oid = String.duplicate("b", 40)
    fake_path = loose_object_path(repo_path, fake_oid)
    File.mkdir_p!(Path.dirname(fake_path))
    File.cp!(loose_object_path(repo_path, canonical_oid), fake_path)

    tree_oid =
      write_tree!(repo_path, tmp_dir, "aliased-tree-#{suffix}", [
        {"100644", "aliased.txt", fake_oid}
      ])

    %{repo_path: repo_path, commit_oid: commit_tree!(repo_path, tree_oid, "aliased search")}
  end

  defp malformed_search_tree_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "malformed-search")
    blob_oid = write_blob!(repo_path, tmp_dir, "malformed-body-#{suffix}", "needle\n")

    tree_oid =
      write_tree!(repo_path, tmp_dir, "malformed-tree-#{suffix}", [
        {"100644", "z.txt", blob_oid},
        {"100644", "a.txt", blob_oid}
      ])

    %{repo_path: repo_path, commit_oid: commit_tree!(repo_path, tree_oid, "malformed search")}
  end

  defp aliased_search_commit_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "aliased-search-commit")
    blob_oid = write_blob!(repo_path, tmp_dir, "aliased-commit-body-#{suffix}", "needle\n")

    tree_oid =
      write_tree!(repo_path, tmp_dir, "aliased-commit-tree-#{suffix}", [
        {"100644", "needle.txt", blob_oid}
      ])

    canonical_oid = commit_tree!(repo_path, tree_oid, "aliased search commit")
    fake_oid = String.duplicate("c", 40)
    fake_path = loose_object_path(repo_path, fake_oid)
    File.mkdir_p!(Path.dirname(fake_path))
    File.cp!(loose_object_path(repo_path, canonical_oid), fake_path)
    %{repo_path: repo_path, commit_oid: fake_oid}
  end

  defp post_byte_limit_corruption_fixture!(tmp_dir) do
    {repo_path, suffix} = init_search_repo!(tmp_dir, "post-byte-limit-corruption")
    first_oid = write_blob!(repo_path, tmp_dir, "post-limit-first-#{suffix}", "needle\n")
    boundary_oid = write_blob!(repo_path, tmp_dir, "post-limit-boundary-#{suffix}", "x")
    corrupt_oid = String.duplicate("d", 40)
    corrupt_path = loose_object_path(repo_path, corrupt_oid)
    File.mkdir_p!(Path.dirname(corrupt_path))
    File.write!(corrupt_path, "not a zlib stream")

    tree_oid =
      write_tree!(repo_path, tmp_dir, "post-limit-tree-#{suffix}", [
        {"100644", "a.txt", first_oid},
        {"100644", "b.txt", boundary_oid},
        {"100644", "c.txt", corrupt_oid}
      ])

    %{
      repo_path: repo_path,
      commit_oid: commit_tree!(repo_path, tree_oid, "post byte limit corruption")
    }
  end

  defp init_search_repo!(tmp_dir, name) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "#{name}-#{suffix}.git")
    git!(["init", "--bare", "--object-format=sha1", repo_path])
    {repo_path, suffix}
  end

  defp write_blob!(repo_path, tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, body)
    git!(["--git-dir", repo_path, "hash-object", "-w", path])
  end

  defp write_declared_blob_header!(repo_path, declared_size) do
    oid = String.duplicate("a", 40)
    path = loose_object_path(repo_path, oid)
    File.mkdir_p!(Path.dirname(path))
    stream = :zlib.open()
    :ok = :zlib.deflateInit(stream)
    compressed = :zlib.deflate(stream, "blob #{declared_size}\0", :sync)
    :zlib.close(stream)
    File.write!(path, compressed)
    oid
  end

  defp write_tree!(repo_path, tmp_dir, name, entries) do
    body =
      Enum.map(entries, fn {mode, path, oid} ->
        [mode, " ", path, <<0>>, oid_bytes(oid)]
      end)

    path = Path.join(tmp_dir, name)
    File.write!(path, body)

    git!([
      "--git-dir",
      repo_path,
      "hash-object",
      "--literally",
      "-t",
      "tree",
      "-w",
      path
    ])
  end

  defp commit_tree!(repo_path, tree_oid, message) do
    git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", message])
  end

  defp start_global_search_holder do
    parent = self()

    spawn(fn ->
      result =
        GitCore.ScanLimiter.with_permit(:search_busy_contract, fn ->
          send(parent, {:global_search_scan_entered, self()})

          receive do
            :release -> :released
          end
        end)

      send(parent, {:global_search_scan_finished, self(), result})
    end)
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end

  defp oid_bytes(oid), do: oid |> String.upcase() |> Base.decode16!()

  defp loose_object_path(repo_path, oid) do
    {directory, filename} = String.split_at(oid, 2)
    Path.join([repo_path, "objects", directory, filename])
  end

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Search Test"},
      {"GIT_AUTHOR_EMAIL", "search@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Search Test"},
      {"GIT_COMMITTER_EMAIL", "search@example.com"},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end

defmodule GitCore.RepositoryAnalysisTest do
  use ExUnit.Case, async: true

  @moduletag :analysis
  @moduletag :tmp_dir

  test "classifies the complete table and counts every non-gitlink candidate", %{
    tmp_dir: tmp_dir
  } do
    extension_cases = [
      {"extensions/elixir.EX", "Elixir"},
      {"extensions/elixir-script.exs", "Elixir"},
      {"extensions/erlang.ERL", "Erlang"},
      {"extensions/erlang-header.hrl", "Erlang"},
      {"extensions/rust.RS", "Rust"},
      {"extensions/javascript.JS", "JavaScript"},
      {"extensions/javascript-module.mjs", "JavaScript"},
      {"extensions/javascript-common.cjs", "JavaScript"},
      {"extensions/javascript-react.jsx", "JavaScript"},
      {"extensions/typescript.TS", "TypeScript"},
      {"extensions/typescript-react.tsx", "TypeScript"},
      {"extensions/typescript-module.mts", "TypeScript"},
      {"extensions/typescript-common.cts", "TypeScript"},
      {"extensions/styles.CSS", "CSS"},
      {"extensions/page.HTML", "HTML"},
      {"extensions/legacy.htm", "HTML"},
      {"extensions/component.heex", "HTML"},
      {"extensions/readme.MD", "Markdown"},
      {"extensions/notes.markdown", "Markdown"},
      {"extensions/data.JSON", "JSON"},
      {"extensions/config.TOML", "TOML"},
      {"extensions/config.YML", "YAML"},
      {"extensions/config.yaml", "YAML"},
      {"extensions/script.SH", "Shell"},
      {"extensions/script.bash", "Shell"},
      {"extensions/script.zsh", "Shell"},
      {"extensions/program.PY", "Python"},
      {"extensions/program.RB", "Ruby"},
      {"extensions/program.GO", "Go"},
      {"extensions/program.JAVA", "Java"},
      {"extensions/program.C", "C"},
      {"extensions/program.h", "C"},
      {"extensions/program.CC", "C++"},
      {"extensions/program.cpp", "C++"},
      {"extensions/program.cxx", "C++"},
      {"extensions/program.hpp", "C++"},
      {"extensions/program.hh", "C++"},
      {"extensions/program.hxx", "C++"},
      {"extensions/query.SQL", "SQL"},
      {"containers/Dockerfile", "Dockerfile"},
      {"containers/Dockerfile.dev", "Dockerfile"},
      {"containers/dockerfile", "Other"},
      {"containers/DOCKERFILE.test", "Other"}
    ]

    extension_entries =
      extension_cases
      |> Enum.with_index(1)
      |> Enum.map(fn {{path, language}, index} ->
        {path, String.duplicate("x", index) <> "\n", language}
      end)

    shebang_entries = [
      {"shebang/elixir", "#!/usr/bin/env elixir\nx\n", "Elixir"},
      {"shebang/escript", "#!/usr/bin/env escript\nx\n", "Elixir"},
      {"shebang/python", "#!/usr/bin/python\nx\n", "Python"},
      {"shebang/python3", "#!/usr/bin/env python3\nx\n", "Python"},
      {"shebang/node", "#!/usr/bin/env node\nx\n", "JavaScript"},
      {"shebang/deno", "#!/usr/bin/env deno\nx\n", "JavaScript"},
      {"shebang/bun", "#!/usr/bin/env bun\nx\n", "JavaScript"},
      {"shebang/bash", "#!/bin/bash\nx\n", "Shell"},
      {"shebang/sh", "#!/bin/sh\nx\n", "Shell"},
      {"shebang/zsh", "#!/usr/bin/env zsh\nx\n", "Shell"},
      {"shebang/ruby", "#!/usr/bin/env ruby\nx\n", "Ruby"},
      {"shebang/env-option", "#!/usr/bin/env -S python3\nx\n", "Python"},
      {"shebang/env-assignment", "#!/usr/bin/env MODE=test ruby\nx\n", "Ruby"},
      {"shebang/exact-token", "#!/usr/bin/python-wrapper\nx\n", "Other"},
      {"shebang/direct-first", "#!/bin/echo ruby\nx\n", "Other"},
      {"shebang/env-first", "#!/usr/bin/env unknown python3\nx\n", "Other"}
    ]

    classified =
      extension_entries ++
        shebang_entries ++
        [
          {"unknown/plain", "unknown text\n", "Other"},
          {"filename-wins.py", "#!/usr/bin/env node\nx\n", "Python"},
          {"streaming/split.rs", String.duplicate("x", 8_191) <> "😀", "Rust"},
          {:executable, "executable/tool.rb", "puts :ok\n", "Ruby"},
          {:symlink, "links/script.sh", "../target", "Shell"}
        ]

    excluded = [
      {"excluded/invalid.rs", <<0xFF, 0xFE>>},
      {"excluded/split-invalid.ex", String.duplicate("x", 8_191) <> <<0xE2, 0x28, 0xA1>>},
      {"excluded/incomplete.py", String.duplicate("x", 9_000) <> <<0xF0, 0x9F>>},
      {"excluded/late-nul.rs", String.duplicate("x", 9_000) <> <<0>>}
    ]

    fixture =
      analysis_fixture!(
        tmp_dir,
        Enum.map(classified, &fixture_entry/1) ++ excluded,
        gitlink: true
      )

    assert {:ok,
            %GitCore.RepositoryAnalysis{
              languages: languages,
              total_bytes: total_bytes,
              files_scanned: files_scanned,
              bytes_scanned: bytes_scanned,
              truncated: false
            }} = GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid)

    assert languages == expected_languages(classified)
    assert total_bytes == Enum.sum(Enum.map(classified, &(entry_body(&1) |> byte_size())))
    assert files_scanned == length(classified) + length(excluded)

    assert bytes_scanned ==
             total_bytes + Enum.sum(Enum.map(excluded, fn {_path, body} -> byte_size(body) end))
  end

  test "sorts byte ties alphabetically and returns stable repeated results", %{tmp_dir: tmp_dir} do
    fixture =
      analysis_fixture!(tmp_dir, [
        {"a.c", "same"},
        {"b.go", "same"},
        {"c.rs", "longer"}
      ])

    assert {:ok,
            %GitCore.RepositoryAnalysis{
              languages: [
                %GitCore.LanguageStat{language: "Rust", bytes: 6},
                %GitCore.LanguageStat{language: "C", bytes: 4},
                %GitCore.LanguageStat{language: "Go", bytes: 4}
              ],
              total_bytes: 14,
              files_scanned: 3,
              bytes_scanned: 14,
              truncated: false
            } = first} = GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid)

    assert {:ok, ^first} = GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid)
  end

  test "preserves zero and marks only actually omitted file work as truncated", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      analysis_fixture!(tmp_dir, [
        {"a.py", "aaa"},
        {"b.rb", "bbbb"},
        {"c.go", "ccccc"}
      ])

    assert_analysis(fixture, [file_limit: 0], 0, 0, true, [])
    assert_analysis(fixture, [file_limit: -1], 0, 0, true, [])

    assert_analysis(
      fixture,
      [file_limit: 2],
      2,
      7,
      true,
      [{"Python", 3}, {"Ruby", 4}]
    )

    assert_analysis(
      fixture,
      [file_limit: 3],
      3,
      12,
      false,
      [{"Go", 5}, {"Python", 3}, {"Ruby", 4}]
    )

    assert_analysis(
      fixture,
      [file_limit: 100_001],
      3,
      12,
      false,
      [{"Go", 5}, {"Python", 3}, {"Ruby", 4}]
    )
  end

  @tag timeout: 30_000
  test "clamps a 100,001-entry raw tree at the production file maximum", %{
    tmp_dir: tmp_dir
  } do
    fixture = repeated_empty_blob_analysis_fixture!(tmp_dir, 100_001)

    assert {:ok,
            %GitCore.RepositoryAnalysis{
              languages: [%GitCore.LanguageStat{language: "Other", bytes: 0}],
              total_bytes: 0,
              files_scanned: 100_000,
              bytes_scanned: 0,
              truncated: true
            }} =
             GitCore.repository_analysis(
               fixture.repo_path,
               fixture.commit_oid,
               file_limit: 100_001
             )
  end

  test "applies file bounds to canonical byte-order depth-first traversal", %{tmp_dir: tmp_dir} do
    fixture =
      analysis_fixture!(tmp_dir, [
        {"a-directory/z.py", "aaa"},
        {"b-root.rb", "bbbb"}
      ])

    assert_analysis(
      fixture,
      [file_limit: 1],
      1,
      3,
      true,
      [{"Python", 3}]
    )
  end

  test "preflights bytes and does not begin or count a body that exceeds the remainder", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      analysis_fixture!(tmp_dir, [
        {"a.py", "aaa"},
        {"b.rb", "bbbb"},
        {"c.go", "ccccc"}
      ])

    assert_analysis(fixture, [byte_limit: 0], 0, 0, true, [])
    assert_analysis(fixture, [byte_limit: -1], 0, 0, true, [])
    assert_analysis(fixture, [byte_limit: 3], 1, 3, true, [{"Python", 3}])

    assert_analysis(
      fixture,
      [byte_limit: 7],
      2,
      7,
      true,
      [{"Python", 3}, {"Ruby", 4}]
    )

    assert_analysis(
      fixture,
      [byte_limit: 12],
      3,
      12,
      false,
      [{"Go", 5}, {"Python", 3}, {"Ruby", 4}]
    )

    assert_analysis(
      fixture,
      [byte_limit: 536_870_913],
      3,
      12,
      false,
      [{"Go", 5}, {"Python", 3}, {"Ruby", 4}]
    )

    oversized = declared_size_analysis_fixture!(tmp_dir, 536_870_913)
    assert_analysis(oversized, [byte_limit: 536_870_913], 0, 0, true, [])
  end

  test "does not finalize a corrupt N+1 body after an exact lowered bound", %{
    tmp_dir: tmp_dir
  } do
    fixture = post_bound_false_blob_fixture!(tmp_dir)

    assert_analysis(fixture, [file_limit: 1], 1, 3, true, [{"Python", 3}])
    assert_analysis(fixture, [byte_limit: 3], 1, 3, true, [{"Python", 3}])
  end

  test "zero limits remain complete for empty work and allow an exact empty body", %{
    tmp_dir: tmp_dir
  } do
    empty = analysis_fixture!(tmp_dir, [])

    assert_analysis(
      empty,
      [file_limit: 0, byte_limit: 0],
      0,
      0,
      false,
      []
    )

    assert_analysis(
      empty,
      [deadline_ms: 0],
      0,
      0,
      false,
      []
    )

    empty_file = analysis_fixture!(tmp_dir, [{"empty.txt", ""}])

    assert_analysis(
      empty_file,
      [file_limit: 1, byte_limit: 0],
      1,
      0,
      false,
      [{"Other", 0}]
    )
  end

  test "a lowered cooperative deadline returns partial success rather than scan_timeout", %{
    tmp_dir: tmp_dir
  } do
    fixture = analysis_fixture!(tmp_dir, [{"source.ex", String.duplicate("x", 32_768)}])

    assert {:ok,
            %GitCore.RepositoryAnalysis{
              languages: [],
              total_bytes: 0,
              files_scanned: 0,
              bytes_scanned: 0,
              truncated: true
            }} =
             GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid, deadline_ms: 0)
  end

  test "verifies physical commit tree and blob identities and ignores every replacement", %{
    tmp_dir: tmp_dir
  } do
    fixture = analysis_fixture!(tmp_dir, [{"physical.ex", "physical\n"}])
    replaced = replace_analysis_objects!(tmp_dir, fixture, "replacement payload\n")

    assert_analysis(
      replaced,
      [],
      1,
      9,
      false,
      [{"Elixir", 9}]
    )

    for kind <- [:commit, :tree, :blob] do
      false_fixture = false_analysis_object_fixture!(tmp_dir, kind)

      assert_error(
        GitCore.repository_analysis(false_fixture.repo_path, false_fixture.commit_oid),
        :corrupt_repository,
        :repository_analysis
      )
    end
  end

  test "disk usage sums logical non-directory sizes without following any symlink", %{
    tmp_dir: tmp_dir
  } do
    fixture = analysis_fixture!(tmp_dir, [{"source.ex", "source\n"}])
    baseline = logical_disk_usage!(fixture.repo_path)
    nested = Path.join([fixture.repo_path, "analysis-extra", "nested"])
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(nested)
    File.mkdir_p!(outside)
    File.write!(Path.join(nested, "payload"), "inside")
    File.write!(Path.join(outside, "large"), String.duplicate("x", 128_000))
    File.ln_s!(outside, Path.join(fixture.repo_path, "outside-link"))
    File.ln_s!("missing-target", Path.join(fixture.repo_path, "broken-link"))
    File.ln_s!("loop-b", Path.join(fixture.repo_path, "loop-a"))
    File.ln_s!("loop-a", Path.join(fixture.repo_path, "loop-b"))

    link_bytes =
      byte_size(outside) +
        byte_size("missing-target") +
        byte_size("loop-b") +
        byte_size("loop-a")

    expected = baseline + byte_size("inside") + link_bytes
    outside_target_bytes = File.stat!(Path.join(outside, "large")).size

    assert {:ok, actual} = GitCore.repository_disk_usage(fixture.repo_path)
    assert actual == expected
    assert actual - baseline == byte_size("inside") + link_bytes
    refute actual == expected + outside_target_bytes
    assert {:ok, ^expected} = GitCore.repository_disk_usage(fixture.repo_path, deadline_ms: 2_001)
  end

  test "disk usage returns a typed timeout and surfaces storage failures", %{tmp_dir: tmp_dir} do
    fixture = analysis_fixture!(tmp_dir, [{"source.ex", "source\n"}])

    assert_error(
      GitCore.repository_disk_usage(fixture.repo_path, deadline_ms: 0),
      :scan_timeout,
      :repository_disk_usage
    )

    assert_error(
      GitCore.repository_disk_usage(Path.join(tmp_dir, "missing.git")),
      :storage_unavailable,
      :repository_disk_usage
    )
  end

  @tag :cache
  test "disk usage is uncached and changes after gc repacks the same repository", %{
    tmp_dir: tmp_dir
  } do
    fixture = analysis_fixture!(tmp_dir, [{"history.txt", "root\n"}])
    history_path = Path.join(fixture.work_path, "history.txt")

    for index <- 1..24 do
      File.write!(history_path, String.duplicate("#{index}\n", 256))
      git!(["-C", fixture.work_path, "add", "history.txt"])
      git!(["-C", fixture.work_path, "commit", "-m", "history #{index}"])
    end

    git!(["-C", fixture.work_path, "push", "origin", "HEAD:refs/heads/main"])
    assert {:ok, before_gc} = GitCore.repository_disk_usage(fixture.repo_path)
    git!(["--git-dir", fixture.repo_path, "gc", "--prune=now"])
    assert {:ok, after_gc} = GitCore.repository_disk_usage(fixture.repo_path)
    refute after_gc == before_gc
  end

  defp analysis_fixture!(tmp_dir, files, opts \\ []) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "analysis-#{suffix}.git")
    work_path = Path.join(tmp_dir, "analysis-work-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])

    Enum.each(files, fn
      {path, body} ->
        full_path = Path.join(work_path, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, body)

      {:executable, path, body} ->
        full_path = Path.join(work_path, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, body)
        File.chmod!(full_path, 0o755)

      {:symlink, path, target} ->
        full_path = Path.join(work_path, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.ln_s!(target, full_path)
    end)

    git!(["-C", work_path, "add", "."])

    if Keyword.get(opts, :gitlink, false) do
      git!(["-C", work_path, "commit", "--allow-empty", "-m", "analysis base"])
      gitlink_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

      git!([
        "-C",
        work_path,
        "update-index",
        "--add",
        "--cacheinfo",
        "160000,#{gitlink_oid},vendor/submodule"
      ])

      git!(["-C", work_path, "commit", "-m", "analysis gitlink"])
    else
      git!(["-C", work_path, "commit", "--allow-empty", "-m", "analysis fixture"])
    end

    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid, work_path: work_path}
  end

  defp repeated_empty_blob_analysis_fixture!(tmp_dir, entry_count) do
    fixture = analysis_fixture!(tmp_dir, [])
    empty_path = Path.join(tmp_dir, "analysis-empty-#{System.unique_integer([:positive])}")
    File.write!(empty_path, "")
    empty_blob = git!(["--git-dir", fixture.repo_path, "hash-object", "-w", empty_path])

    tree =
      0..(entry_count - 1)
      |> Enum.map(fn index ->
        [
          "100644 file-",
          Integer.to_string(index) |> String.pad_leading(6, "0"),
          ".txt",
          0,
          oid_bytes(empty_blob)
        ]
      end)

    tree_oid = write_raw_tree!(tmp_dir, fixture.repo_path, tree, "large-analysis-tree")
    commit_oid = write_commit_for_tree!(tmp_dir, fixture.repo_path, tree_oid, "large analysis")
    %{fixture | commit_oid: commit_oid}
  end

  defp declared_size_analysis_fixture!(tmp_dir, declared_size) do
    fixture = analysis_fixture!(tmp_dir, [])
    fake_blob = String.duplicate("4", 40)
    fake_path = loose_object_path(fixture.repo_path, fake_blob)
    File.mkdir_p!(Path.dirname(fake_path))
    File.write!(fake_path, :zlib.compress("blob #{declared_size}\0x"))

    tree_oid =
      write_raw_tree!(
        tmp_dir,
        fixture.repo_path,
        [["100644 oversized.rs", 0, oid_bytes(fake_blob)]],
        "oversized-analysis-tree"
      )

    commit_oid =
      write_commit_for_tree!(tmp_dir, fixture.repo_path, tree_oid, "oversized analysis")

    %{fixture | commit_oid: commit_oid}
  end

  defp post_bound_false_blob_fixture!(tmp_dir) do
    fixture = analysis_fixture!(tmp_dir, [{"a.py", "aaa"}, {"b.rs", "bbbb"}])
    valid_blob = git!(["--git-dir", fixture.repo_path, "rev-parse", "#{fixture.commit_oid}:b.rs"])
    fake_blob = String.duplicate("5", 40)
    alias_loose_object!(fixture.repo_path, valid_blob, fake_blob)

    first_blob =
      git!(["--git-dir", fixture.repo_path, "rev-parse", "#{fixture.commit_oid}:a.py"])

    tree_oid =
      write_raw_tree!(
        tmp_dir,
        fixture.repo_path,
        [
          ["100644 a.py", 0, oid_bytes(first_blob)],
          ["100644 b.rs", 0, oid_bytes(fake_blob)]
        ],
        "post-bound-analysis-tree"
      )

    commit_oid =
      write_commit_for_tree!(tmp_dir, fixture.repo_path, tree_oid, "post-bound analysis")

    %{fixture | commit_oid: commit_oid}
  end

  defp write_raw_tree!(tmp_dir, repo_path, tree_iodata, label) do
    tree_path = Path.join(tmp_dir, "#{label}-#{System.unique_integer([:positive])}")
    File.write!(tree_path, tree_iodata)

    git!([
      "--git-dir",
      repo_path,
      "hash-object",
      "--literally",
      "-t",
      "tree",
      "-w",
      tree_path
    ])
  end

  defp fixture_entry({:executable, path, body, _language}), do: {:executable, path, body}
  defp fixture_entry({:symlink, path, target, _language}), do: {:symlink, path, target}
  defp fixture_entry({path, body, _language}), do: {path, body}

  defp entry_body({:executable, _path, body, _language}), do: body
  defp entry_body({:symlink, _path, target, _language}), do: target
  defp entry_body({_path, body, _language}), do: body

  defp expected_languages(entries) do
    entries
    |> Enum.group_by(
      fn
        {:executable, _path, _body, language} -> language
        {:symlink, _path, _target, language} -> language
        {_path, _body, language} -> language
      end,
      &entry_body/1
    )
    |> Enum.map(fn {language, bodies} ->
      %GitCore.LanguageStat{
        language: language,
        bytes: Enum.sum(Enum.map(bodies, &byte_size/1))
      }
    end)
    |> Enum.sort_by(&{-&1.bytes, &1.language})
  end

  defp assert_analysis(fixture, opts, files_scanned, bytes_scanned, truncated, languages) do
    expected_languages =
      languages
      |> Enum.map(fn {language, bytes} ->
        %GitCore.LanguageStat{language: language, bytes: bytes}
      end)
      |> Enum.sort_by(&{-&1.bytes, &1.language})

    assert {:ok,
            %GitCore.RepositoryAnalysis{
              languages: ^expected_languages,
              total_bytes: total_bytes,
              files_scanned: ^files_scanned,
              bytes_scanned: ^bytes_scanned,
              truncated: ^truncated
            }} = GitCore.repository_analysis(fixture.repo_path, fixture.commit_oid, opts)

    assert total_bytes == Enum.sum(Enum.map(expected_languages, & &1.bytes))
  end

  defp replace_analysis_objects!(tmp_dir, fixture, replacement_body) do
    original_commit = fixture.commit_oid

    original_tree =
      git!(["--git-dir", fixture.repo_path, "rev-parse", "#{original_commit}^{tree}"])

    original_blob =
      git!([
        "--git-dir",
        fixture.repo_path,
        "rev-parse",
        "#{original_commit}:physical.ex"
      ])

    replacement_path =
      Path.join(tmp_dir, "analysis-replacement-#{System.unique_integer([:positive])}")

    replacement_tree_path =
      Path.join(tmp_dir, "analysis-replacement-tree-#{System.unique_integer([:positive])}")

    File.write!(replacement_path, replacement_body)

    replacement_blob =
      git!(["--git-dir", fixture.repo_path, "hash-object", "-w", replacement_path])

    File.write!(
      replacement_tree_path,
      "100644 physical.ex\0" <> oid_bytes(replacement_blob)
    )

    replacement_tree =
      git!([
        "--git-dir",
        fixture.repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        replacement_tree_path
      ])

    replacement_commit =
      git!([
        "--git-dir",
        fixture.repo_path,
        "commit-tree",
        replacement_tree,
        "-m",
        "replacement analysis"
      ])

    for {original, replacement} <- [
          {original_blob, replacement_blob},
          {original_tree, replacement_tree},
          {original_commit, replacement_commit}
        ] do
      git!([
        "--git-dir",
        fixture.repo_path,
        "update-ref",
        "refs/replace/#{original}",
        replacement
      ])
    end

    fixture
  end

  defp false_analysis_object_fixture!(tmp_dir, kind) do
    fixture = analysis_fixture!(tmp_dir, [{"source.ex", "physical\n"}])
    original_commit = fixture.commit_oid

    original_tree =
      git!(["--git-dir", fixture.repo_path, "rev-parse", "#{original_commit}^{tree}"])

    original_blob =
      git!(["--git-dir", fixture.repo_path, "rev-parse", "#{original_commit}:source.ex"])

    case kind do
      :commit ->
        fake_commit = String.duplicate("1", 40)
        alias_loose_object!(fixture.repo_path, original_commit, fake_commit)
        %{fixture | commit_oid: fake_commit}

      :tree ->
        fake_tree = String.duplicate("2", 40)
        alias_loose_object!(fixture.repo_path, original_tree, fake_tree)
        commit_oid = write_commit_for_tree!(tmp_dir, fixture.repo_path, fake_tree, "false tree")
        %{fixture | commit_oid: commit_oid}

      :blob ->
        fake_blob = String.duplicate("3", 40)
        alias_loose_object!(fixture.repo_path, original_blob, fake_blob)

        tree_path =
          Path.join(tmp_dir, "false-blob-tree-#{System.unique_integer([:positive])}")

        File.write!(tree_path, "100644 source.ex\0" <> oid_bytes(fake_blob))

        tree_oid =
          git!([
            "--git-dir",
            fixture.repo_path,
            "hash-object",
            "--literally",
            "-t",
            "tree",
            "-w",
            tree_path
          ])

        commit_oid = write_commit_for_tree!(tmp_dir, fixture.repo_path, tree_oid, "false blob")
        %{fixture | commit_oid: commit_oid}
    end
  end

  defp alias_loose_object!(repo_path, source_oid, target_oid) do
    source = loose_object_path(repo_path, source_oid)
    target = loose_object_path(repo_path, target_oid)
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
  end

  defp write_commit_for_tree!(tmp_dir, repo_path, tree_oid, message) do
    commit_path = Path.join(tmp_dir, "analysis-commit-#{System.unique_integer([:positive])}")

    File.write!(
      commit_path,
      "tree #{tree_oid}\n" <>
        "author Fornacast Analysis Test <analysis@example.com> 946684800 +0000\n" <>
        "committer Fornacast Analysis Test <analysis@example.com> 946684800 +0000\n\n" <>
        "#{message}\n"
    )

    git!([
      "--git-dir",
      repo_path,
      "hash-object",
      "--literally",
      "-t",
      "commit",
      "-w",
      commit_path
    ])
  end

  defp logical_disk_usage!(path) do
    path
    |> File.ls!()
    |> Enum.reduce(0, fn name, total ->
      entry_path = Path.join(path, name)
      stat = File.lstat!(entry_path)

      if stat.type == :directory do
        total + logical_disk_usage!(entry_path)
      else
        total + stat.size
      end
    end)
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end

  defp oid_bytes(oid), do: Base.decode16!(oid, case: :mixed)

  defp loose_object_path(repo_path, oid) do
    {directory, filename} = String.split_at(oid, 2)
    Path.join([repo_path, "objects", directory, filename])
  end

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Analysis Test"},
      {"GIT_AUTHOR_EMAIL", "analysis@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Analysis Test"},
      {"GIT_COMMITTER_EMAIL", "analysis@example.com"},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end

defmodule GitCore.RepositoryAnalysisBusyTest do
  use ExUnit.Case, async: false

  @moduletag :analysis

  test "analysis APIs cannot redirect around the supervised global scan limiter" do
    isolated_limiter =
      start_supervised!({GitCore.ScanLimiter, server: nil}, id: make_ref())

    holders = for _ <- 1..4, do: start_global_scan_holder()

    Enum.each(holders, fn holder ->
      assert_receive {:analysis_global_scan_entered, ^holder}, 1_000
    end)

    missing_path =
      Path.join(
        System.tmp_dir!(),
        "missing-analysis-scan-#{System.unique_integer([:positive])}.git"
      )

    try do
      assert_error(
        GitCore.repository_analysis(
          missing_path,
          String.duplicate("f", 40),
          scan_limiter: isolated_limiter
        ),
        :scan_busy,
        :repository_analysis
      )

      assert_error(
        GitCore.repository_disk_usage(missing_path, scan_limiter: isolated_limiter),
        :scan_busy,
        :repository_disk_usage
      )
    after
      Enum.each(holders, &send(&1, :release))

      Enum.each(holders, fn holder ->
        assert_receive {:analysis_global_scan_finished, ^holder, :released}, 1_000
      end)
    end
  end

  defp start_global_scan_holder do
    parent = self()

    spawn(fn ->
      result =
        GitCore.ScanLimiter.with_permit(:analysis_busy_contract, fn ->
          send(parent, {:analysis_global_scan_entered, self()})

          receive do
            :release -> :released
          end
        end)

      send(parent, {:analysis_global_scan_finished, self(), result})
    end)
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end
end

defmodule GitCore.StructuredDiffTest do
  use ExUnit.Case, async: false

  @moduletag :diffs
  @diff_source_limit 200_000

  @tag :tmp_dir
  test "returns real structured hunks and exact stats for root and first-parent diffs", %{
    tmp_dir: tmp_dir
  } do
    fixture = structured_diff_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 4,
              additions: 4,
              deletions: 3,
              truncated: false,
              files: files,
              patch: patch
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    assert ["added.txt", "asset.bin", "deleted.txt", "multi.txt"] ==
             Enum.map(files, & &1.path)

    assert %GitCore.DiffFile{
             status: :added,
             old_oid: nil,
             new_oid: added_oid,
             binary: false,
             additions: 2,
             deletions: 0,
             truncated: false,
             lines: added_lines
           } = diff_file!(files, "added.txt")

    assert is_binary(added_oid)
    assert Enum.any?(added_lines, &match?(%GitCore.DiffLine{type: :added}, &1))

    assert Enum.any?(
             added_lines,
             &match?(%GitCore.DiffLine{type: :hunk, old_line: 0, new_line: 1}, &1)
           )

    assert patch =~ "@@ -0,0 +1,2 @@"

    assert %GitCore.DiffFile{
             status: :deleted,
             old_oid: deleted_oid,
             new_oid: nil,
             binary: false,
             additions: 0,
             deletions: 1,
             truncated: false
           } = diff_file!(files, "deleted.txt")

    assert is_binary(deleted_oid)
    assert patch =~ "@@ -1,1 +0,0 @@"

    assert %GitCore.DiffFile{
             status: :added,
             binary: true,
             additions: 0,
             deletions: 0,
             truncated: false,
             lines: []
           } = diff_file!(files, "asset.bin")

    assert %GitCore.DiffFile{
             status: :modified,
             binary: false,
             additions: 2,
             deletions: 2,
             truncated: false,
             lines: multi_lines
           } = diff_file!(files, "multi.txt")

    assert [
             %GitCore.DiffLine{type: :hunk, old_line: 1, new_line: 1},
             %GitCore.DiffLine{type: :hunk}
           ] = Enum.filter(multi_lines, &(&1.type == :hunk))

    assert %GitCore.DiffLine{type: :context, old_line: 1, new_line: 1, content: "line 01"} in multi_lines

    assert %GitCore.DiffLine{type: :deleted, old_line: 2, new_line: nil, content: "line 02"} in multi_lines

    assert %GitCore.DiffLine{type: :added, old_line: nil, new_line: 2, content: "changed 02"} in multi_lines

    assert patch =~ "diff --git a/multi.txt b/multi.txt"
    assert patch =~ "-line 02"
    assert patch =~ "+changed 02"
    refute File.exists?(fixture.external_filter_marker)

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 3,
              additions: 23,
              deletions: 0,
              truncated: false,
              files: root_files,
              patch: root_patch
            }} = GitCore.diff_commit(fixture.repo_path, fixture.root_oid)

    assert Enum.all?(root_files, &(&1.status == :added))
    assert root_patch =~ "diff --git a/multi.txt b/multi.txt"

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1,
              additions: 1,
              deletions: 0,
              files: [
                %GitCore.DiffFile{
                  path: "side-only.txt",
                  status: :added,
                  additions: 1,
                  deletions: 0
                }
              ]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.merge_oid)
  end

  @tag :tmp_dir
  test "preserves storage I/O classification while diffing blob resources", %{tmp_dir: tmp_dir} do
    fixture = structured_diff_fixture!(tmp_dir)

    blob_oid =
      git!(["--git-dir", fixture.repo_path, "rev-parse", "#{fixture.commit_oid}:multi.txt"])

    object_path = loose_object_path(fixture.repo_path, blob_oid)
    assert File.regular?(object_path)
    File.chmod!(object_path, 0o000)

    assert_error(
      GitCore.diff_commit(fixture.repo_path, fixture.commit_oid),
      :storage_unavailable,
      :diff_commit
    )
  end

  @tag :tmp_dir
  test "rejects diff bodies stored under a false blob OID", %{tmp_dir: tmp_dir} do
    fixture = aliased_diff_blob_fixture!(tmp_dir, "forged diff body\n")

    refute fixture.canonical_oid == fixture.fake_oid
    assert File.regular?(loose_object_path(fixture.repo_path, fixture.fake_oid))

    assert_error(
      GitCore.diff_commit(fixture.repo_path, fixture.commit_oid),
      :corrupt_repository,
      :diff_commit
    )
  end

  @tag :tmp_dir
  test "rejects duplicate names in the new diff tree", %{tmp_dir: tmp_dir} do
    fixture = malformed_diff_tree_fixture!(tmp_dir, :duplicate_new)

    assert_error(
      GitCore.diff_commit(fixture.repo_path, fixture.commit_oid),
      :corrupt_repository,
      :diff_commit
    )
  end

  @tag :tmp_dir
  test "rejects noncanonical entry order in the parent diff tree", %{tmp_dir: tmp_dir} do
    fixture = malformed_diff_tree_fixture!(tmp_dir, :unsorted_parent)

    assert_error(
      GitCore.diff_commit(fixture.repo_path, fixture.commit_oid),
      :corrupt_repository,
      :diff_commit
    )
  end

  @tag :tmp_dir
  test "retains at most one thousand sections while finishing exact totals", %{tmp_dir: tmp_dir} do
    fixture = many_file_diff_fixture!(tmp_dir, 1_001)

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1_001,
              additions: 1_001,
              deletions: 0,
              truncated: true,
              files: files,
              patch: patch
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    assert length(files) == 1_000
    assert Enum.all?(files, &match?(%GitCore.DiffFile{status: :added, additions: 1}, &1))
    assert Enum.all?(files, &(&1.truncated == false))
    assert Enum.map(files, & &1.path) == Enum.map(1..1_000, &file_name/1)
    assert files |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 1_000
    assert byte_size(patch) <= @diff_source_limit
  end

  @tag :tmp_dir
  test "shares one bounded source budget between compatibility patch and structured lines", %{
    tmp_dir: tmp_dir
  } do
    fixture = large_diff_fixture!(tmp_dir, 30_000)

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1,
              additions: 30_000,
              deletions: 30_000,
              truncated: true,
              files: [file],
              patch: patch
            }} =
             GitCore.diff_commit(
               fixture.repo_path,
               fixture.commit_oid,
               limit: @diff_source_limit * 3
             )

    assert %GitCore.DiffFile{
             status: :modified,
             additions: 30_000,
             deletions: 30_000,
             truncated: true,
             binary: false,
             lines: [_ | _] = lines
           } = file

    assert byte_size(patch) in 199_000..@diff_source_limit
    assert retained_line_source_bytes(lines) <= byte_size(patch)

    assert structured_patch_lines(lines) ==
             patch |> retained_patch_lines() |> Enum.take(length(lines))

    assert length(lines) < 60_001
  end

  @tag :tmp_dir
  test "retains only complete shared diff records at the source boundary", %{tmp_dir: tmp_dir} do
    fixture = boundary_diff_fixture!(tmp_dir)

    assert {:ok, %GitCore.CommitDiff{patch: full_patch}} =
             GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    limit = byte_size(full_patch) - 3

    assert {:ok,
            %GitCore.CommitDiff{
              truncated: true,
              patch: patch,
              files: [%GitCore.DiffFile{truncated: true, lines: lines}]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid, limit: limit)

    assert byte_size(patch) < limit
    assert binary_part(full_patch, 0, byte_size(patch)) == patch
    assert String.ends_with?(patch, "-old\n")
    assert Enum.map(lines, & &1.type) == [:hunk, :deleted]
    assert structured_patch_lines(lines) == retained_patch_lines(patch)
  end

  @tag :tmp_dir
  test "emits and atomically budgets missing-final-newline markers", %{tmp_dir: tmp_dir} do
    fixture = missing_newline_diff_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.CommitDiff{
              truncated: false,
              patch: full_patch,
              files: [%GitCore.DiffFile{lines: full_lines}]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    marker = "\\ No newline at end of file\n"
    assert full_patch =~ "-old\n#{marker}+new\n#{marker}"

    assert Enum.map(full_lines, &{&1.type, &1.content}) == [
             {:hunk, "@@ -1,1 +1,1 @@"},
             {:deleted, "old"},
             {:added, "new"}
           ]

    {added_offset, _length} = :binary.match(full_patch, "+new\n")
    limit = added_offset + byte_size("+new\n") + 2

    assert {:ok,
            %GitCore.CommitDiff{
              truncated: true,
              patch: patch,
              files: [%GitCore.DiffFile{truncated: true, lines: lines}]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid, limit: limit)

    assert patch == binary_part(full_patch, 0, added_offset)
    assert String.ends_with?(patch, marker)
    assert Enum.map(lines, & &1.type) == [:hunk, :deleted]
  end

  @tag :tmp_dir
  test "counts and renders adding only a final LF", %{tmp_dir: tmp_dir} do
    fixture = newline_exactness_fixture!(tmp_dir, "line", "line\n", "add-final-lf")

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1,
              additions: 1,
              deletions: 1,
              patch: patch,
              files: [%GitCore.DiffFile{additions: 1, deletions: 1, lines: lines}]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    marker = "\\ No newline at end of file\n"
    assert patch =~ "-line\n#{marker}+line\n"
    refute String.ends_with?(patch, marker <> "\n")

    assert Enum.map(lines, &{&1.type, &1.content}) == [
             {:hunk, "@@ -1,1 +1,1 @@"},
             {:deleted, "line"},
             {:added, "line"}
           ]
  end

  @tag :tmp_dir
  test "counts and renders removing only a final LF", %{tmp_dir: tmp_dir} do
    fixture = newline_exactness_fixture!(tmp_dir, "line\n", "line", "remove-final-lf")

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1,
              additions: 1,
              deletions: 1,
              patch: patch,
              files: [%GitCore.DiffFile{additions: 1, deletions: 1, lines: lines}]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    marker = "\\ No newline at end of file\n"
    assert patch =~ "-line\n+line\n#{marker}"

    assert Enum.map(lines, &{&1.type, &1.content}) == [
             {:hunk, "@@ -1,1 +1,1 @@"},
             {:deleted, "line"},
             {:added, "line"}
           ]
  end

  @tag :tmp_dir
  test "counts an earlier edit and one-sided EOF LF independently", %{tmp_dir: tmp_dir} do
    fixture =
      newline_exactness_fixture!(
        tmp_dir,
        "first\nlast",
        "changed\nlast\n",
        "edit-and-final-lf"
      )

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1,
              additions: 2,
              deletions: 2,
              patch: patch,
              files: [%GitCore.DiffFile{additions: 2, deletions: 2, lines: lines}]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    assert patch =~ "-first\n"
    assert patch =~ "-last\n\\ No newline at end of file\n"
    assert patch =~ "+changed\n"
    assert patch =~ "+last\n"

    assert Enum.map(lines, &{&1.type, &1.content}) == [
             {:hunk, "@@ -1,2 +1,2 @@"},
             {:deleted, "first"},
             {:deleted, "last"},
             {:added, "changed"},
             {:added, "last"}
           ]
  end

  @tag :tmp_dir
  test "emits metadata only for a mode-only binary diff", %{tmp_dir: tmp_dir} do
    fixture = mode_only_binary_diff_fixture!(tmp_dir)

    assert {:ok,
            %GitCore.CommitDiff{
              changed_files: 1,
              additions: 0,
              deletions: 0,
              truncated: false,
              patch: patch,
              files: [
                %GitCore.DiffFile{
                  status: :modified,
                  old_oid: oid,
                  new_oid: oid,
                  binary: true,
                  additions: 0,
                  deletions: 0,
                  lines: []
                }
              ]
            }} = GitCore.diff_commit(fixture.repo_path, fixture.commit_oid)

    assert patch =~ "old mode 100644\nnew mode 100755\n"
    refute patch =~ "Binary files"
    refute patch =~ "--- "
    refute patch =~ "+++ "
  end

  @tag :tmp_dir
  test "returns a typed timeout instead of partial exact totals", %{tmp_dir: tmp_dir} do
    fixture = many_file_diff_fixture!(tmp_dir, 2)

    assert_error(
      GitCore.diff_commit(fixture.repo_path, fixture.commit_oid, deadline_ms: 0),
      :scan_timeout,
      :diff_commit
    )
  end

  test "cannot bypass the supervised global scan limiter" do
    isolated_limiter =
      start_supervised!({GitCore.ScanLimiter, server: nil}, id: make_ref())

    holders = for _ <- 1..4, do: start_global_scan_holder()

    Enum.each(holders, fn holder ->
      assert_receive {:global_diff_scan_entered, ^holder}, 1_000
    end)

    missing_path =
      Path.join(System.tmp_dir!(), "missing-diff-scan-#{System.unique_integer([:positive])}.git")

    try do
      assert_error(
        GitCore.diff_commit(
          missing_path,
          String.duplicate("f", 40),
          scan_limiter: isolated_limiter
        ),
        :scan_busy,
        :diff_commit
      )
    after
      Enum.each(holders, &send(&1, :release))

      Enum.each(holders, fn holder ->
        assert_receive {:global_diff_scan_finished, ^holder, :released}, 1_000
      end)
    end
  end

  defp structured_diff_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "structured-diff-#{suffix}.git")
    work_path = Path.join(tmp_dir, "structured-diff-work-#{suffix}")
    external_filter_marker = Path.join(tmp_dir, "external-diff-ran-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])

    File.write!(
      Path.join(work_path, ".gitattributes"),
      "*.txt diff=external\n*.bin diff=external\n"
    )

    File.write!(Path.join(work_path, "deleted.txt"), "remove me\n")

    File.write!(
      Path.join(work_path, "multi.txt"),
      Enum.map_join(1..20, "", &"line #{String.pad_leading(Integer.to_string(&1), 2, "0")}\n")
    )

    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "root diff fixture"])
    root_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "branch", "-M", "main"])

    updated_lines =
      1..20
      |> Enum.map(fn
        2 -> "changed 02\n"
        18 -> "changed 18\n"
        index -> "line #{String.pad_leading(Integer.to_string(index), 2, "0")}\n"
      end)
      |> IO.iodata_to_binary()

    File.write!(Path.join(work_path, "multi.txt"), updated_lines)
    File.write!(Path.join(work_path, "added.txt"), "first added\nsecond added\n")
    File.write!(Path.join(work_path, "asset.bin"), <<0, 1, 2, 3, 4>>)
    File.rm!(Path.join(work_path, "deleted.txt"))
    git!(["-C", work_path, "add", "-A"])
    git!(["-C", work_path, "commit", "-m", "structured diff fixture"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    git!(["-C", work_path, "switch", "-c", "side", root_oid])
    File.write!(Path.join(work_path, "side-only.txt"), "side branch\n")
    git!(["-C", work_path, "add", "side-only.txt"])
    git!(["-C", work_path, "commit", "-m", "side branch"])
    git!(["-C", work_path, "switch", "main"])
    git!(["-C", work_path, "merge", "--no-ff", "side", "-m", "merge side"])
    merge_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])
    git!(["--git-dir", repo_path, "symbolic-ref", "HEAD", "refs/heads/main"])

    git!([
      "--git-dir",
      repo_path,
      "config",
      "diff.external.command",
      "touch #{external_filter_marker}"
    ])

    git!([
      "--git-dir",
      repo_path,
      "config",
      "diff.external.textconv",
      "touch #{external_filter_marker}"
    ])

    %{
      repo_path: repo_path,
      root_oid: root_oid,
      commit_oid: commit_oid,
      merge_oid: merge_oid,
      external_filter_marker: external_filter_marker
    }
  end

  defp many_file_diff_fixture!(tmp_dir, count) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "many-file-diff-#{suffix}.git")
    work_path = Path.join(tmp_dir, "many-file-diff-work-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])

    for index <- 1..count do
      File.write!(Path.join(work_path, file_name(index)), "x\n")
    end

    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "many file diff"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp aliased_diff_blob_fixture!(tmp_dir, data) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "aliased-diff-#{suffix}.git")
    tree_path = Path.join(tmp_dir, "aliased-diff-tree-#{suffix}")
    fake_oid = String.duplicate("2", 40)

    canonical_oid =
      :crypto.hash(:sha, "blob #{byte_size(data)}\0" <> data)
      |> Base.encode16(case: :lower)

    loose_path = loose_object_path(repo_path, fake_oid)

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.mkdir_p!(Path.dirname(loose_path))
    File.write!(loose_path, :zlib.compress("blob #{byte_size(data)}\0" <> data))
    File.write!(tree_path, "100644 aliased.txt\0" <> oid_bytes(fake_oid))

    tree_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        tree_path
      ])

    commit_oid = git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "aliased diff"])

    %{
      repo_path: repo_path,
      commit_oid: commit_oid,
      fake_oid: fake_oid,
      canonical_oid: canonical_oid
    }
  end

  defp malformed_diff_tree_fixture!(tmp_dir, kind) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "malformed-diff-tree-#{kind}-#{suffix}.git")
    blob_path = Path.join(tmp_dir, "malformed-diff-blob-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(blob_path, "tree validation body\n")
    blob_oid = git!(["--git-dir", repo_path, "hash-object", "-w", blob_path])

    commit_oid =
      case kind do
        :duplicate_new ->
          tree_oid =
            write_raw_diff_tree!(tmp_dir, repo_path, "duplicate-new-#{suffix}", [
              {"100644", "duplicate.txt", blob_oid},
              {"100644", "duplicate.txt", blob_oid}
            ])

          git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "duplicate new tree"])

        :unsorted_parent ->
          parent_tree_oid =
            write_raw_diff_tree!(tmp_dir, repo_path, "unsorted-parent-#{suffix}", [
              {"100644", "z-last.txt", blob_oid},
              {"100644", "a-first.txt", blob_oid}
            ])

          parent_oid =
            git!([
              "--git-dir",
              repo_path,
              "commit-tree",
              parent_tree_oid,
              "-m",
              "unsorted parent tree"
            ])

          new_tree_oid =
            write_raw_diff_tree!(tmp_dir, repo_path, "canonical-new-#{suffix}", [
              {"100644", "replacement.txt", blob_oid}
            ])

          git!([
            "--git-dir",
            repo_path,
            "commit-tree",
            new_tree_oid,
            "-p",
            parent_oid,
            "-m",
            "canonical child tree"
          ])
      end

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp write_raw_diff_tree!(tmp_dir, repo_path, name, entries) do
    path = Path.join(tmp_dir, name)

    contents =
      entries
      |> Enum.map(fn {mode, entry_name, oid} ->
        [mode, " ", entry_name, <<0>>, oid_bytes(oid)]
      end)
      |> IO.iodata_to_binary()

    File.write!(path, contents)
    git!(["--git-dir", repo_path, "hash-object", "--literally", "-t", "tree", "-w", path])
  end

  defp large_diff_fixture!(tmp_dir, line_count) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "large-diff-#{suffix}.git")
    work_path = Path.join(tmp_dir, "large-diff-work-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])

    old_payload =
      Enum.map_join(1..line_count, "", fn index ->
        "old-value-#{String.pad_leading("#{index}", 5, "0")}\n"
      end)

    payload =
      Enum.map_join(1..line_count, "", fn index ->
        "payload-#{String.pad_leading("#{index}", 5, "0")}\n"
      end)

    assert byte_size(payload) > @diff_source_limit
    File.write!(Path.join(work_path, "large.txt"), old_payload)
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "large diff base"])
    File.write!(Path.join(work_path, "large.txt"), payload)
    git!(["-C", work_path, "add", "large.txt"])
    git!(["-C", work_path, "commit", "-m", "large diff replacement"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp boundary_diff_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "boundary-diff-#{suffix}.git")
    work_path = Path.join(tmp_dir, "boundary-diff-work-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])
    File.write!(Path.join(work_path, "boundary.txt"), "old\n")
    git!(["-C", work_path, "add", "boundary.txt"])
    git!(["-C", work_path, "commit", "-m", "boundary diff base"])
    File.write!(Path.join(work_path, "boundary.txt"), "new\n")
    git!(["-C", work_path, "add", "boundary.txt"])
    git!(["-C", work_path, "commit", "-m", "boundary diff replacement"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp missing_newline_diff_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "missing-newline-diff-#{suffix}.git")
    work_path = Path.join(tmp_dir, "missing-newline-diff-work-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])
    File.write!(Path.join(work_path, "no-newline.txt"), "old")
    git!(["-C", work_path, "add", "no-newline.txt"])
    git!(["-C", work_path, "commit", "-m", "missing newline base"])
    File.write!(Path.join(work_path, "no-newline.txt"), "new")
    git!(["-C", work_path, "add", "no-newline.txt"])
    git!(["-C", work_path, "commit", "-m", "missing newline replacement"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp newline_exactness_fixture!(tmp_dir, old, new, name) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "newline-exactness-#{name}-#{suffix}.git")
    work_path = Path.join(tmp_dir, "newline-exactness-work-#{name}-#{suffix}")
    file_path = Path.join(work_path, "newline.txt")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])
    File.write!(file_path, old)
    git!(["-C", work_path, "add", "newline.txt"])
    git!(["-C", work_path, "commit", "-m", "newline exactness base"])
    File.write!(file_path, new)
    git!(["-C", work_path, "add", "newline.txt"])
    git!(["-C", work_path, "commit", "-m", "newline exactness change"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp mode_only_binary_diff_fixture!(tmp_dir) do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "mode-only-binary-diff-#{suffix}.git")
    work_path = Path.join(tmp_dir, "mode-only-binary-diff-work-#{suffix}")
    file_path = Path.join(work_path, "mode.bin")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    git!(["init", "--object-format=sha1", work_path])
    File.write!(file_path, <<0, 1, 2, 3>>)
    File.chmod!(file_path, 0o644)
    git!(["-C", work_path, "add", "mode.bin"])
    git!(["-C", work_path, "commit", "-m", "binary mode base"])
    File.chmod!(file_path, 0o755)
    git!(["-C", work_path, "add", "mode.bin"])
    git!(["-C", work_path, "commit", "-m", "binary mode change"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "HEAD:refs/heads/main"])

    %{repo_path: repo_path, commit_oid: commit_oid}
  end

  defp diff_file!(files, path) do
    Enum.find(files, &(&1.path == path)) || flunk("missing diff file #{inspect(path)}")
  end

  defp retained_line_source_bytes(lines) do
    Enum.reduce(lines, 0, fn line, total ->
      prefix_size = if line.type == :hunk, do: 0, else: 1
      total + prefix_size + byte_size(line.content) + 1
    end)
  end

  defp structured_patch_lines(lines) do
    Enum.map(lines, fn
      %GitCore.DiffLine{type: :hunk, content: content} -> content
      %GitCore.DiffLine{type: type, content: content} -> diff_prefix(type) <> content
    end)
  end

  defp retained_patch_lines(patch) do
    patch
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.starts_with?(line, "@@") or
        (String.starts_with?(line, "+") and not String.starts_with?(line, "+++")) or
        (String.starts_with?(line, "-") and not String.starts_with?(line, "---")) or
        String.starts_with?(line, " ")
    end)
  end

  defp diff_prefix(:added), do: "+"
  defp diff_prefix(:deleted), do: "-"
  defp diff_prefix(:context), do: " "

  defp file_name(index), do: "file-#{String.pad_leading("#{index}", 4, "0")}.txt"

  defp loose_object_path(repo_path, oid) do
    {directory, filename} = String.split_at(oid, 2)
    Path.join([repo_path, "objects", directory, filename])
  end

  defp start_global_scan_holder do
    parent = self()

    spawn(fn ->
      result =
        GitCore.ScanLimiter.with_permit(:diff_busy_contract, fn ->
          send(parent, {:global_diff_scan_entered, self()})

          receive do
            :release -> :released
          end
        end)

      send(parent, {:global_diff_scan_finished, self(), result})
    end)
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end

  defp oid_bytes(oid), do: oid |> String.upcase() |> Base.decode16!()

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Diff Test"},
      {"GIT_AUTHOR_EMAIL", "diff@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Diff Test"},
      {"GIT_COMMITTER_EMAIL", "diff@example.com"},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end

defmodule GitCore.CommitScanBusyTest do
  use ExUnit.Case, async: false

  @moduletag :commits

  test "commit APIs cannot bypass the supervised global scan limit" do
    isolated_limiter =
      start_supervised!({GitCore.ScanLimiter, server: nil}, id: make_ref())

    holders = for _ <- 1..4, do: start_global_scan_holder()

    Enum.each(holders, fn holder ->
      assert_receive {:global_scan_entered, ^holder}, 1_000
    end)

    missing_path =
      Path.join(
        System.tmp_dir!(),
        "missing-commit-scan-#{System.unique_integer([:positive])}.git"
      )

    try do
      # Unknown caller options cannot redirect either public API around the global limiter.
      assert_error(
        GitCore.commit_summary(missing_path, "not-an-object-id", scan_limiter: isolated_limiter),
        :scan_busy,
        :commit_summary
      )

      assert_error(
        GitCore.commit_page(missing_path, "not-an-object-id", 1, scan_limiter: isolated_limiter),
        :scan_busy,
        :commit_page
      )
    after
      Enum.each(holders, &send(&1, :release))

      Enum.each(holders, fn holder ->
        assert_receive {:global_scan_finished, ^holder, :released}, 1_000
      end)
    end
  end

  @tag :tree_history
  test "tree history cannot bypass the supervised global scan limit" do
    isolated_limiter =
      start_supervised!({GitCore.ScanLimiter, server: nil}, id: make_ref())

    holders = for _ <- 1..4, do: start_global_scan_holder()

    Enum.each(holders, fn holder ->
      assert_receive {:global_scan_entered, ^holder}, 1_000
    end)

    missing_path =
      Path.join(
        System.tmp_dir!(),
        "missing-tree-scan-#{System.unique_integer([:positive])}.git"
      )

    try do
      assert_error(
        GitCore.read_tree_with_history(
          missing_path,
          "not-an-object-id",
          "",
          1,
          scan_limiter: isolated_limiter
        ),
        :scan_busy,
        :tree_history
      )
    after
      Enum.each(holders, &send(&1, :release))

      Enum.each(holders, fn holder ->
        assert_receive {:global_scan_finished, ^holder, :released}, 1_000
      end)
    end
  end

  defp start_global_scan_holder do
    parent = self()

    spawn(fn ->
      result =
        GitCore.ScanLimiter.with_permit(:commit_busy_contract, fn ->
          send(parent, {:global_scan_entered, self()})

          receive do
            :release -> :released
          end
        end)

      send(parent, {:global_scan_finished, self(), result})
    end)
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end
end

defmodule GitCore.BlobReadLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :blobs
  @inline_limit 1_048_576
  @complete_limit 100_000_000

  setup do
    wait_for_blob_limiter(0, 0)
    :ok
  end

  @tag :tmp_dir
  test "inline reads clamp and retain exactly one MiB of blob capacity", %{tmp_dir: tmp_dir} do
    data = :binary.copy("a", @inline_limit + 17)
    fixture = blob_fixture!(tmp_dir, data)

    assert {:ok,
            %GitCore.Blob{
              oid: oid,
              size: size,
              data: prefix,
              truncated: true,
              binary: false,
              non_utf8: false,
              lease: lease
            } = blob} =
             GitCore.read_blob(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path,
               limit: @complete_limit
             )

    assert oid == fixture.blob_oid
    assert size == byte_size(data)
    assert prefix == binary_part(data, 0, @inline_limit)
    assert lease != nil
    assert_blob_limiter(1, @inline_limit, [@inline_limit])

    assert :ok = GitCore.release_blob(blob)
    assert :ok = GitCore.release_blob(blob)
    assert :ok = GitCore.release_blob(%{blob | lease: nil})
    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "complete reads reserve the exact declared size and never truncate", %{tmp_dir: tmp_dir} do
    data = :binary.copy(<<0, 255, 65>>, 171)
    fixture = blob_fixture!(tmp_dir, data)

    assert {:ok,
            %GitCore.Blob{
              oid: oid,
              size: size,
              data: ^data,
              truncated: false,
              binary: true,
              non_utf8: true,
              lease: lease
            } = blob} =
             GitCore.read_blob_complete(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path
             )

    assert oid == fixture.blob_oid
    assert size == byte_size(data)
    assert lease != nil
    assert_blob_limiter(1, byte_size(data), [byte_size(data)])

    assert :ok = GitCore.release_blob(blob)
    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "native body reads recheck declared size before returning a BEAM binary", %{
    tmp_dir: tmp_dir
  } do
    data = "native binary body"
    fixture = blob_fixture!(tmp_dir, data)

    assert {:ok, {name, oid, size}} =
             GitCore.Native.blob_metadata(
               fixture.repo_path,
               fixture.commit_oid,
               :binary.bin_to_list(fixture.blob_path)
             )

    assert IO.iodata_to_binary(name) == fixture.blob_path
    assert oid == fixture.blob_oid
    assert size == byte_size(data)

    assert {:ok, {^size, native_data, false, false}} =
             GitCore.Native.read_blob_prefix(fixture.repo_path, oid, size, @inline_limit)

    assert is_binary(native_data)
    assert native_data == data

    assert {:error, {"corrupt_repository", detail}} =
             GitCore.Native.read_blob_prefix(fixture.repo_path, oid, size + 1, @inline_limit)

    assert detail =~ "size changed between metadata and body reads"
  end

  @tag :tmp_dir
  test "a complete zero-byte blob retains one exact zero-weight read slot", %{tmp_dir: tmp_dir} do
    fixture = blob_fixture!(tmp_dir, "")

    assert {:ok,
            %GitCore.Blob{
              size: 0,
              data: "",
              truncated: false,
              binary: false,
              non_utf8: false,
              lease: lease
            } = blob} =
             GitCore.read_blob_complete(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path
             )

    assert lease != nil
    assert_blob_limiter(1, 0, [0])
    assert :ok = GitCore.release_blob(blob)
    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "complete and untruncated inline reads reject a valid body stored under a false OID", %{
    tmp_dir: tmp_dir
  } do
    fixture = aliased_blob_fixture!(tmp_dir, "body stored under the wrong object name")

    complete =
      GitCore.read_blob_complete(
        fixture.repo_path,
        fixture.commit_oid,
        fixture.blob_path
      )

    inline = GitCore.read_blob(fixture.repo_path, fixture.commit_oid, fixture.blob_path)
    release_successful_blob(complete)
    release_successful_blob(inline)

    assert_error(complete, :corrupt_repository, :read_blob_complete)
    assert_error(inline, :corrupt_repository, :read_blob)
    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "complete zero-byte reads reject a trailing body and release their slot", %{
    tmp_dir: tmp_dir
  } do
    fixture = malformed_zero_blob_fixture!(tmp_dir)

    result =
      GitCore.read_blob_complete(
        fixture.repo_path,
        fixture.commit_oid,
        fixture.blob_path
      )

    release_successful_blob(result)
    assert_error(result, :corrupt_repository, :read_blob_complete)
    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "oversized complete reads reject metadata before body allocation or lease acquisition", %{
    tmp_dir: tmp_dir
  } do
    fixture = declared_blob_fixture!(tmp_dir, @complete_limit + 1)

    assert_error(
      GitCore.read_blob_complete(
        fixture.repo_path,
        fixture.commit_oid,
        fixture.blob_path,
        limit: @complete_limit * 2
      ),
      :blob_too_large,
      :read_blob_complete
    )

    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "a body failure after metadata releases the exact-size lease", %{tmp_dir: tmp_dir} do
    fixture = declared_blob_fixture!(tmp_dir, 17)

    assert_error(
      GitCore.read_blob_complete(
        fixture.repo_path,
        fixture.commit_oid,
        fixture.blob_path
      ),
      :corrupt_repository,
      :read_blob_complete
    )

    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "inline reads preserve invalid UTF-8 without misclassifying it as NUL-binary", %{
    tmp_dir: tmp_dir
  } do
    data = <<255, 254, "plain">>
    fixture = blob_fixture!(tmp_dir, data)

    assert {:ok,
            %GitCore.Blob{
              data: ^data,
              truncated: false,
              binary: false,
              non_utf8: true
            } = blob} =
             GitCore.read_blob(fixture.repo_path, fixture.commit_oid, fixture.blob_path)

    assert :ok = GitCore.release_blob(blob)
  end

  @tag :tmp_dir
  test "inline reads detect NUL bytes independently of UTF-8 validity", %{tmp_dir: tmp_dir} do
    data = "valid\0utf8"
    fixture = blob_fixture!(tmp_dir, data)

    assert {:ok,
            %GitCore.Blob{
              data: ^data,
              truncated: false,
              binary: true,
              non_utf8: false
            } = blob} =
             GitCore.read_blob(fixture.repo_path, fixture.commit_oid, fixture.blob_path)

    assert :ok = GitCore.release_blob(blob)
  end

  @tag :tmp_dir
  test "the supervised limiter releases a retained blob lease when its owner dies", %{
    tmp_dir: tmp_dir
  } do
    data = "owner-held bytes"
    fixture = blob_fixture!(tmp_dir, data)
    parent = self()

    owner =
      spawn(fn ->
        result =
          GitCore.read_blob_complete(
            fixture.repo_path,
            fixture.commit_oid,
            fixture.blob_path
          )

        send(parent, {:owner_blob, self(), result})
        Process.sleep(:infinity)
      end)

    monitor = Process.monitor(owner)

    assert_receive {:owner_blob, ^owner, {:ok, %GitCore.Blob{lease: lease} = blob}}, 2_000
    assert lease != nil
    assert_blob_limiter(1, byte_size(data), [byte_size(data)])

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
    wait_for_blob_limiter(0, 0)
    assert :ok = GitCore.release_blob(blob)
  end

  @tag :tmp_dir
  test "public blob reads fail closed with blob_busy and cannot redirect the limiter", %{
    tmp_dir: tmp_dir
  } do
    fixture = blob_fixture!(tmp_dir, "busy")
    isolated = start_supervised!({GitCore.BlobLimiter, server: nil}, id: make_ref())

    leases =
      for _ <- 1..8 do
        assert {:ok, lease} = GitCore.BlobLimiter.acquire(0)
        lease
      end

    try do
      assert_error(
        GitCore.read_blob(
          fixture.repo_path,
          fixture.commit_oid,
          fixture.blob_path,
          blob_limiter: isolated
        ),
        :blob_busy,
        :read_blob
      )

      assert_error(
        GitCore.read_blob_complete(
          fixture.repo_path,
          fixture.commit_oid,
          fixture.blob_path,
          blob_limiter: isolated
        ),
        :blob_busy,
        :read_blob_complete
      )
    after
      Enum.each(leases, &GitCore.BlobLimiter.release/1)
    end

    assert_blob_limiter(0, 0, [])
  end

  @tag :tmp_dir
  test "snapshot and blob OIDs bypass physical replacement refs", %{tmp_dir: tmp_dir} do
    original = "physical snapshot body"
    fixture = replaced_blob_fixture!(tmp_dir, original, "replacement body")

    assert {:ok, %GitCore.Blob{oid: oid, data: ^original} = inline} =
             GitCore.read_blob(fixture.repo_path, fixture.commit_oid, fixture.blob_path)

    assert oid == fixture.blob_oid
    assert :ok = GitCore.release_blob(inline)

    assert {:ok, %GitCore.Blob{oid: ^oid, data: ^original, truncated: false} = complete} =
             GitCore.read_blob_complete(
               fixture.repo_path,
               fixture.commit_oid,
               fixture.blob_path
             )

    assert :ok = GitCore.release_blob(complete)
  end

  defp blob_fixture!(tmp_dir, data, blob_path \\ "blob.bin") do
    suffix = System.unique_integer([:positive])
    repo_path = Path.join(tmp_dir, "blob-lifecycle-#{suffix}.git")
    source_path = Path.join(tmp_dir, "blob-lifecycle-source-#{suffix}")
    tree_path = Path.join(tmp_dir, "blob-lifecycle-tree-#{suffix}")

    git!(["init", "--bare", "--object-format=sha1", repo_path])
    File.write!(source_path, data)
    blob_oid = git!(["--git-dir", repo_path, "hash-object", "-w", source_path])
    File.write!(tree_path, "100644 #{blob_path}\0" <> oid_bytes(blob_oid))

    tree_oid =
      git!([
        "--git-dir",
        repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        tree_path
      ])

    commit_oid = git!(["--git-dir", repo_path, "commit-tree", tree_oid, "-m", "blob fixture"])
    git!(["--git-dir", repo_path, "update-ref", "refs/heads/main", commit_oid])

    %{
      repo_path: repo_path,
      commit_oid: commit_oid,
      blob_path: blob_path,
      blob_oid: blob_oid,
      tree_oid: tree_oid
    }
  end

  defp declared_blob_fixture!(tmp_dir, declared_size) do
    fixture = blob_fixture!(tmp_dir, "placeholder", "declared.bin")
    fake_oid = String.duplicate("1", 40)
    loose_path = loose_object_path(fixture.repo_path, fake_oid)
    File.mkdir_p!(Path.dirname(loose_path))
    zlib = :zlib.open()
    :ok = :zlib.deflateInit(zlib)

    compressed_header =
      zlib
      |> :zlib.deflate("blob #{declared_size}\0", :sync)
      |> IO.iodata_to_binary()

    :ok = :zlib.close(zlib)
    File.write!(loose_path, compressed_header)

    tree_path = Path.join(tmp_dir, "declared-tree-#{System.unique_integer([:positive])}")
    File.write!(tree_path, "100644 declared.bin\0" <> oid_bytes(fake_oid))

    tree_oid =
      git!([
        "--git-dir",
        fixture.repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        tree_path
      ])

    commit_oid =
      git!(["--git-dir", fixture.repo_path, "commit-tree", tree_oid, "-m", "declared blob"])

    %{fixture | commit_oid: commit_oid, blob_oid: fake_oid}
  end

  defp aliased_blob_fixture!(tmp_dir, data) do
    fixture = blob_fixture!(tmp_dir, "placeholder", "aliased.bin")
    fake_oid = String.duplicate("2", 40)
    loose_path = loose_object_path(fixture.repo_path, fake_oid)
    File.mkdir_p!(Path.dirname(loose_path))
    File.write!(loose_path, :zlib.compress("blob #{byte_size(data)}\0" <> data))
    retarget_blob_fixture!(tmp_dir, fixture, fake_oid, "aliased.bin", "aliased blob")
  end

  defp malformed_zero_blob_fixture!(tmp_dir) do
    fixture = blob_fixture!(tmp_dir, "", "zero.bin")
    loose_path = loose_object_path(fixture.repo_path, fixture.blob_oid)
    File.chmod!(loose_path, 0o644)
    File.write!(loose_path, :zlib.compress("blob 0\0X"))
    fixture
  end

  defp retarget_blob_fixture!(tmp_dir, fixture, blob_oid, blob_path, message) do
    tree_path = Path.join(tmp_dir, "retarget-tree-#{System.unique_integer([:positive])}")
    File.write!(tree_path, "100644 #{blob_path}\0" <> oid_bytes(blob_oid))

    tree_oid =
      git!([
        "--git-dir",
        fixture.repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        tree_path
      ])

    commit_oid =
      git!(["--git-dir", fixture.repo_path, "commit-tree", tree_oid, "-m", message])

    %{
      fixture
      | commit_oid: commit_oid,
        blob_oid: blob_oid,
        blob_path: blob_path,
        tree_oid: tree_oid
    }
  end

  defp replaced_blob_fixture!(tmp_dir, original, replacement) do
    fixture = blob_fixture!(tmp_dir, original)
    suffix = System.unique_integer([:positive])
    replacement_path = Path.join(tmp_dir, "replacement-blob-#{suffix}")
    replacement_tree_path = Path.join(tmp_dir, "replacement-tree-#{suffix}")

    File.write!(replacement_path, replacement)

    replacement_oid =
      git!(["--git-dir", fixture.repo_path, "hash-object", "-w", replacement_path])

    File.write!(
      replacement_tree_path,
      "100644 #{fixture.blob_path}\0" <> oid_bytes(replacement_oid)
    )

    replacement_tree_oid =
      git!([
        "--git-dir",
        fixture.repo_path,
        "hash-object",
        "--literally",
        "-t",
        "tree",
        "-w",
        replacement_tree_path
      ])

    replacement_commit_oid =
      git!([
        "--git-dir",
        fixture.repo_path,
        "commit-tree",
        replacement_tree_oid,
        "-m",
        "replacement commit"
      ])

    git!([
      "--git-dir",
      fixture.repo_path,
      "update-ref",
      "refs/replace/#{fixture.blob_oid}",
      replacement_oid
    ])

    git!([
      "--git-dir",
      fixture.repo_path,
      "update-ref",
      "refs/replace/#{fixture.commit_oid}",
      replacement_commit_oid
    ])

    assert git!(["--git-dir", fixture.repo_path, "cat-file", "-p", fixture.blob_oid]) ==
             replacement

    assert git!([
             "--no-replace-objects",
             "--git-dir",
             fixture.repo_path,
             "cat-file",
             "-p",
             fixture.blob_oid
           ]) == original

    assert git!(["--git-dir", fixture.repo_path, "cat-file", "-p", fixture.commit_oid]) =~
             "tree #{replacement_tree_oid}"

    assert git!([
             "--no-replace-objects",
             "--git-dir",
             fixture.repo_path,
             "cat-file",
             "-p",
             fixture.commit_oid
           ]) =~ "tree #{fixture.tree_oid}"

    fixture
  end

  defp assert_blob_limiter(grant_count, used_bytes, weights) do
    state = :sys.get_state(GitCore.BlobLimiter)
    assert map_size(state.grants) == grant_count
    assert state.used_bytes == used_bytes

    assert state.grants |> Map.values() |> Enum.map(& &1.weight) |> Enum.sort() ==
             Enum.sort(weights)
  end

  defp wait_for_blob_limiter(grant_count, used_bytes, attempts \\ 100)

  defp wait_for_blob_limiter(grant_count, used_bytes, attempts) when attempts > 0 do
    state = :sys.get_state(GitCore.BlobLimiter)

    if map_size(state.grants) == grant_count and state.used_bytes == used_bytes do
      :ok
    else
      Process.sleep(5)
      wait_for_blob_limiter(grant_count, used_bytes, attempts - 1)
    end
  end

  defp wait_for_blob_limiter(grant_count, used_bytes, 0) do
    state = :sys.get_state(GitCore.BlobLimiter)

    flunk(
      "blob limiter did not settle to #{grant_count} grants/#{used_bytes} bytes: #{inspect(state)}"
    )
  end

  defp assert_error(result, expected_kind, expected_operation) do
    assert {:error,
            %GitCore.Error{
              kind: ^expected_kind,
              operation: ^expected_operation,
              detail: detail
            }} = result

    assert is_binary(detail)
    refute detail == ""
  end

  defp release_successful_blob({:ok, %GitCore.Blob{} = blob}), do: GitCore.release_blob(blob)
  defp release_successful_blob(_result), do: :ok

  defp oid_bytes(oid), do: Base.decode16!(oid, case: :mixed)

  defp loose_object_path(repo_path, oid) do
    {directory, filename} = String.split_at(oid, 2)
    Path.join([repo_path, "objects", directory, filename])
  end

  defp git!(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Blob Test"},
      {"GIT_AUTHOR_EMAIL", "blob@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Blob Test"},
      {"GIT_COMMITTER_EMAIL", "blob@example.com"},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end
end
