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
