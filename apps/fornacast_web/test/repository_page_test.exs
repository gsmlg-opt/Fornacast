defmodule FornacastWeb.RepositoryPageTest.FakeGitCore do
  def reset(responses \\ %{}) do
    Process.put({__MODULE__, :responses}, responses)
    Process.put({__MODULE__, :calls}, [])
    :ok
  end

  def calls do
    Process.get({__MODULE__, :calls}, [])
  end

  def ref_summary(path, opts \\ []) do
    reply({:ref_summary, path, opts}, :ref_summary)
  end

  def ref_summary_for_route(path, segments) do
    reply({:ref_summary_for_route, path, segments}, :ref_summary_for_route)
  end

  def resolve_snapshot(path, selector) do
    reply({:resolve_snapshot, path, selector}, :resolve_snapshot)
  end

  def commit_summary(path, snapshot_oid, opts \\ []) do
    reply({:commit_summary, path, snapshot_oid, opts}, :commit_summary)
  end

  def read_tree_with_history(path, snapshot_oid, tree_path, page, opts \\ []) do
    reply(
      {:read_tree_with_history, path, snapshot_oid, tree_path, page, opts},
      :read_tree_with_history
    )
  end

  def read_blob(path, snapshot_oid, blob_path, opts \\ []) do
    reply({:read_blob, path, snapshot_oid, blob_path, opts}, {:read_blob, blob_path})
  end

  def repository_analysis(path, snapshot_oid, opts \\ []) do
    reply({:repository_analysis, path, snapshot_oid, opts}, :repository_analysis)
  end

  def repository_disk_usage(path, opts \\ []) do
    reply({:repository_disk_usage, path, opts}, :repository_disk_usage)
  end

  def ref_page(path, kind, page, opts \\ []) do
    reply({:ref_page, path, kind, page, opts}, :ref_page)
  end

  def commit_page(path, snapshot_oid, page, opts \\ []) do
    reply({:commit_page, path, snapshot_oid, page, opts}, :commit_page)
  end

  def commit(path, oid) do
    reply({:commit, path, oid}, :commit)
  end

  def diff_commit(path, oid, opts \\ []) do
    reply({:diff_commit, path, oid, opts}, :diff_commit)
  end

  def search_tree(path, snapshot_oid, query, opts \\ []) do
    reply({:search_tree, path, snapshot_oid, query, opts}, :search_tree)
  end

  def read_blob_complete(path, snapshot_oid, blob_path, opts \\ []) do
    reply(
      {:read_blob_complete, path, snapshot_oid, blob_path, opts},
      {:read_blob_complete, blob_path}
    )
  end

  def release_blob(blob) do
    reply({:release_blob, blob}, :release_blob, :ok)
  end

  defp reply(call, key, default \\ :no_default) do
    Process.put({__MODULE__, :calls}, calls() ++ [call])
    responses = Process.get({__MODULE__, :responses}, %{})

    response =
      case Map.fetch(responses, key) do
        {:ok, response} -> response
        :error when default != :no_default -> default
        :error -> raise "unexpected FakeGitCore call: #{inspect(call)}"
      end

    if is_function(response, 1), do: response.(call), else: response
  end
end

defmodule FornacastWeb.RepositoryPageTest do
  use ExUnit.Case, async: true

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.RepositoryPage
  alias FornacastWeb.RepositoryPageTest.FakeGitCore

  setup do
    FakeGitCore.reset()
    :ok
  end

  test "defines the exact typed repository page structs" do
    assert_struct_fields(RepositoryPage.Result, [:kind, :chrome, :content, :leases])

    assert_struct_fields(RepositoryPage.Chrome, [
      :owner,
      :repository,
      :viewer,
      :ref_summary,
      :snapshot,
      :clone
    ])

    assert_struct_fields(RepositoryPage.Clone, [:https_url, :ssh_url, :push_commands])

    assert_struct_fields(RepositoryPage.Code, [
      :commit_summary,
      :tree,
      :readme,
      :analysis,
      :disk_usage
    ])

    assert_struct_fields(RepositoryPage.Tree, [:path, :tree])
    assert_struct_fields(RepositoryPage.Blob, [:path, :blob])
    assert_struct_fields(RepositoryPage.Refs, [:kind, :page])
    assert_struct_fields(RepositoryPage.Commits, [:page])
    assert_struct_fields(RepositoryPage.Commit, [:commit, :diff, :ref_context])

    assert_struct_fields(RepositoryPage.Search, [
      :query,
      :scope,
      :results,
      :validation_error
    ])

    assert_struct_fields(RepositoryPage.Empty, [:write_access, :disk_usage])
    assert_struct_fields(RepositoryPage.MissingDefault, [:configured_ref])
    assert_struct_fields(RepositoryPage.Raw, [:blob])
  end

  test "exposes the repository orchestration API" do
    assert Code.ensure_loaded?(RepositoryPage)

    for {function, arity} <- [
          code: 4,
          code: 5,
          tree: 5,
          tree: 6,
          blob: 4,
          blob: 5,
          refs: 5,
          refs: 6,
          commits: 5,
          commits: 6,
          commit: 5,
          commit: 6,
          search: 6,
          search: 7,
          raw: 4,
          raw: 5,
          release: 1
        ] do
      assert function_exported?(RepositoryPage, function, arity),
             "expected RepositoryPage.#{function}/#{arity}"
    end
  end

  test "ref summary is the first GitCore call" do
    configure_successful_code()

    assert {:ok, %{__struct__: RepositoryPage.Result, kind: :code}} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )

    assert [{:ref_summary, _path, [selected_ref: "refs/heads/main"]} | _] =
             FakeGitCore.calls()
  end

  test "empty repositories make no commit-derived calls" do
    FakeGitCore.reset(%{
      ref_summary: {:ok, empty_ref_summary()},
      repository_disk_usage: {:ok, 128}
    })

    assert {:ok,
            %{
              __struct__: RepositoryPage.Result,
              kind: :empty,
              content: %{
                __struct__: RepositoryPage.Empty,
                write_access: false,
                disk_usage: {:ok, 128}
              }
            }} = RepositoryPage.code(repository(), owner(), nil, nil, git_core: FakeGitCore)

    assert [
             {:ref_summary, summary_path, [selected_ref: "refs/heads/main"]},
             {:repository_disk_usage, disk_path, []}
           ] = FakeGitCore.calls()

    assert summary_path == disk_path
  end

  test "a missing configured default returns the typed missing-default state" do
    FakeGitCore.reset(%{ref_summary: {:ok, ref_summary("refs/heads/other")}})

    assert {:ok,
            %{
              __struct__: RepositoryPage.Result,
              kind: :missing_default,
              chrome: %{
                __struct__: RepositoryPage.Chrome,
                ref_summary: %GitCore.RefSummary{
                  branches: [%GitCore.Ref{name: "refs/heads/other"}]
                }
              },
              content: %{
                __struct__: RepositoryPage.MissingDefault,
                configured_ref: "refs/heads/main"
              }
            }} = RepositoryPage.code(repository(), owner(), nil, nil, git_core: FakeGitCore)

    assert [{:ref_summary, _path, [selected_ref: "refs/heads/main"]}] = FakeGitCore.calls()
  end

  test "refs remain pageable when the configured default branch is missing" do
    FakeGitCore.reset(%{
      ref_summary: {:ok, ref_summary("refs/heads/other")},
      ref_page:
        {:ok,
         %GitCore.RefPage{
           refs: [],
           total: 1,
           page: 1,
           per_page: 100,
           total_pages: 1
         }}
    })

    assert {:ok,
            %{
              kind: :refs,
              chrome: %{__struct__: RepositoryPage.Chrome, snapshot: nil},
              content: %{
                __struct__: RepositoryPage.Refs,
                kind: :branch,
                page: %GitCore.RefPage{page: 1}
              }
            }} =
             RepositoryPage.refs(
               repository(),
               owner(),
               nil,
               :branch,
               1,
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary, summary_path, [selected_ref: "refs/heads/main"]},
             {:ref_page, page_path, :branch, 1, [per_page: 100]}
           ] = FakeGitCore.calls()

    assert summary_path == page_path
  end

  test "commit detail remains URL-SHA authoritative when the configured default is missing" do
    FakeGitCore.reset(%{
      ref_summary: {:ok, ref_summary("refs/heads/other")},
      commit: {:ok, commit_fixture("url-commit-oid")},
      diff_commit:
        {:ok,
         %GitCore.CommitDiff{
           files: [],
           patch: "",
           truncated: false,
           changed_files: 0,
           additions: 0,
           deletions: 0
         }}
    })

    assert {:ok,
            %{
              kind: :commit,
              chrome: %{__struct__: RepositoryPage.Chrome, snapshot: nil},
              content: %{
                __struct__: RepositoryPage.Commit,
                commit: %GitCore.Commit{oid: "url-commit-oid"},
                ref_context: nil
              }
            }} =
             RepositoryPage.commit(
               repository(),
               owner(),
               nil,
               "deadbeef",
               nil,
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary, summary_path, [selected_ref: "refs/heads/main"]},
             {:commit, commit_path, "deadbeef"},
             {:diff_commit, diff_path, "url-commit-oid", []}
           ] = FakeGitCore.calls()

    assert summary_path == commit_path
    assert commit_path == diff_path
  end

  test "one resolved snapshot OID feeds every commit-derived code read" do
    configure_successful_code()

    assert {:ok,
            %{
              __struct__: RepositoryPage.Result,
              kind: :code,
              chrome: %{
                __struct__: RepositoryPage.Chrome,
                snapshot: %GitCore.Snapshot{oid: "snapshot-1"}
              },
              leases: [{FakeGitCore, %GitCore.Blob{lease: :readme_lease}}]
            }} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )

    calls = FakeGitCore.calls()

    assert 1 ==
             Enum.count(calls, fn
               {:resolve_snapshot, _, _} -> true
               _ -> false
             end)

    assert ["snapshot-1"] ==
             calls
             |> Enum.flat_map(fn
               {:commit_summary, _, oid, _} -> [oid]
               {:read_tree_with_history, _, oid, _, _, _} -> [oid]
               {:read_blob, _, oid, _, _} -> [oid]
               {:repository_analysis, _, oid, _} -> [oid]
               _ -> []
             end)
             |> Enum.uniq()
  end

  test "a blob lease acquired before a required failure is released" do
    configure_successful_code(%{
      read_tree_with_history:
        {:error,
         %GitCore.Error{
           kind: :scan_timeout,
           operation: :tree_history,
           detail: "not exposed"
         }}
    })

    assert {:error, %GitCore.Error{kind: :scan_timeout}} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )

    assert Enum.any?(FakeGitCore.calls(), fn
             {:release_blob, %GitCore.Blob{lease: :readme_lease}} -> true
             _ -> false
           end)
  end

  test "an unexpected failure after README acquisition releases the held lease" do
    configure_successful_code(%{
      repository_analysis: fn _call -> raise "analysis crashed" end
    })

    assert_raise RuntimeError, "analysis crashed", fn ->
      RepositoryPage.code(
        repository(),
        owner(),
        nil,
        selector(),
        git_core: FakeGitCore
      )
    end

    assert Enum.any?(FakeGitCore.calls(), fn
             {:release_blob, %GitCore.Blob{lease: :readme_lease}} -> true
             _ -> false
           end)
  end

  test "wildcard source routes use one route-summary scan and one resolved snapshot" do
    FakeGitCore.reset(%{
      ref_summary_for_route:
        {:ok, {ref_summary("refs/heads/feature/docs"), selector("feature/docs"), "guide"}},
      resolve_snapshot:
        {:ok,
         %GitCore.Snapshot{
           kind: :branch,
           ref: "refs/heads/feature/docs",
           oid: "route-snapshot"
         }},
      read_tree_with_history:
        {:ok,
         %GitCore.TreePage{
           entries: [
             %GitCore.TreeHistoryEntry{
               name: "lib",
               kind: :tree,
               mode: 16_384,
               oid: "tree-1",
               latest_commit: commit_fixture("commit-1")
             },
             %GitCore.TreeHistoryEntry{
               name: "mix.exs",
               kind: :blob,
               mode: 33_188,
               oid: "blob-1",
               latest_commit: commit_fixture("commit-2")
             }
           ],
           total_entries: 2,
           page: 1,
           per_page: 200,
           total_pages: 1
         }}
    })

    assert {:ok,
            %{
              __struct__: RepositoryPage.Result,
              kind: :tree,
              content: %{
                __struct__: RepositoryPage.Tree,
                path: "guide",
                tree: %GitCore.TreePage{entries: [_, _]}
              }
            }} =
             RepositoryPage.tree(
               repository(),
               owner(),
               nil,
               ["feature", "docs", "guide"],
               1,
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary_for_route, summary_path, ["feature", "docs", "guide"]},
             {:resolve_snapshot, resolve_path,
              %GitCore.RefSelector{
                kind: :branch,
                full_name: "refs/heads/feature/docs"
              }},
             {:read_tree_with_history, tree_path, "route-snapshot", "guide", 1, []}
           ] = FakeGitCore.calls()

    assert summary_path == resolve_path
    assert resolve_path == tree_path
  end

  test "source tree orchestration falls back to a blob without re-reading refs" do
    blob = blob_fixture("guide.txt", :source_blob_lease)

    FakeGitCore.reset(%{
      {:read_blob, "docs/guide.txt"} => {:ok, blob},
      ref_summary_for_route:
        {:ok, {ref_summary("refs/heads/main"), selector(), "docs/guide.txt"}},
      resolve_snapshot:
        {:ok, %GitCore.Snapshot{kind: :branch, ref: "refs/heads/main", oid: "snapshot-1"}},
      read_tree_with_history:
        {:error,
         %GitCore.Error{
           kind: :path_not_found,
           operation: :tree_history,
           detail: "not a directory"
         }}
    })

    assert {:ok,
            %{
              __struct__: RepositoryPage.Result,
              kind: :blob,
              content: %{
                __struct__: RepositoryPage.Blob,
                path: "docs/guide.txt",
                blob: ^blob
              },
              leases: [{FakeGitCore, ^blob}]
            }} =
             RepositoryPage.tree(
               repository(),
               owner(),
               nil,
               ["refs", "heads", "main", "docs", "guide.txt"],
               1,
               git_core: FakeGitCore
             )

    assert 1 ==
             Enum.count(FakeGitCore.calls(), fn
               {:ref_summary_for_route, _, _} -> true
               _ -> false
             end)

    assert Enum.any?(FakeGitCore.calls(), fn
             {:read_blob, _, "snapshot-1", "docs/guide.txt", _} -> true
             _ -> false
           end)
  end

  test "refs, commits, search, and raw keep their first-call and snapshot contracts" do
    configure_context_reads()

    assert {:ok, %{kind: :refs}} =
             RepositoryPage.refs(
               repository(),
               owner(),
               nil,
               :branch,
               2,
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary, _, [selected_ref: "refs/heads/main"]},
             {:ref_page, _, :branch, 2, [per_page: 100]}
           ] = FakeGitCore.calls()

    configure_context_reads()

    assert {:ok, %{kind: :commits}} =
             RepositoryPage.commits(
               repository(),
               owner(),
               nil,
               ["main"],
               3,
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary_for_route, _, ["main"]},
             {:resolve_snapshot, _, _},
             {:commit_page, _, "snapshot-1", 3, [per_page: 50]}
           ] = FakeGitCore.calls()

    configure_context_reads()

    assert {:ok, %{kind: :search}} =
             RepositoryPage.search(
               repository(),
               owner(),
               nil,
               selector(),
               "needle",
               :content,
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary, _, [selected_ref: "refs/heads/main"]},
             {:resolve_snapshot, _, _},
             {:search_tree, _, "snapshot-1", "needle", [scope: :content]}
           ] = FakeGitCore.calls()

    configure_context_reads()

    assert {:ok,
            %{
              kind: :raw,
              leases: [{FakeGitCore, %GitCore.Blob{lease: :raw_lease}}]
            }} =
             RepositoryPage.raw(
               repository(),
               owner(),
               nil,
               ["main", "archive.bin"],
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary_for_route, _, ["main", "archive.bin"]},
             {:resolve_snapshot, _, _},
             {:read_blob_complete, _, "snapshot-1", "archive.bin", [limit: 100_000_000]}
           ] = FakeGitCore.calls()
  end

  test "commit detail diffs the URL commit while ref remains chrome context" do
    configure_context_reads()

    assert {:ok,
            %{
              kind: :commit,
              chrome: %{
                __struct__: RepositoryPage.Chrome,
                snapshot: %GitCore.Snapshot{oid: "snapshot-1"}
              },
              content: %{
                __struct__: RepositoryPage.Commit,
                commit: %GitCore.Commit{oid: "url-commit-oid"},
                ref_context: %GitCore.Snapshot{oid: "snapshot-1"}
              }
            }} =
             RepositoryPage.commit(
               repository(),
               owner(),
               nil,
               "deadbeef",
               selector(),
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary, _, [selected_ref: "refs/heads/main"]},
             {:resolve_snapshot, _, _},
             {:commit, _, "deadbeef"},
             {:diff_commit, _, "url-commit-oid", []}
           ] = FakeGitCore.calls()
  end

  test "README, language, and disk errors degrade only their optional panels" do
    readme_error = error(:blob_busy, :read_blob)
    analysis_error = error(:scan_busy, :repository_analysis)
    disk_error = error(:scan_timeout, :repository_disk_usage)

    configure_successful_code(%{
      {:read_blob, "README.md"} => {:error, readme_error},
      repository_analysis: {:error, analysis_error},
      repository_disk_usage: {:error, disk_error}
    })

    assert {:ok,
            %{
              kind: :code,
              content: %{
                __struct__: RepositoryPage.Code,
                readme: {:unavailable, ^readme_error},
                analysis: {:unavailable, ^analysis_error},
                disk_usage: {:unavailable, ^disk_error}
              },
              leases: []
            }} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )
  end

  test "README uses the first existing candidate and carries sanitized selected-ref HTML" do
    readme =
      blob_fixture("README.md", :rendered_readme_lease)
      |> Map.put(:data, "[Guide](docs/guide.md) <script>alert(1)</script>")

    configure_successful_code(%{
      {:read_blob, "README.md"} => {:ok, readme}
    })

    assert {:ok,
            %{
              kind: :code,
              content: %{
                __struct__: RepositoryPage.Code,
                readme:
                  {:ok,
                   %{
                     path: "README.md",
                     blob: ^readme,
                     html: {:safe, safe_html}
                   }}
              }
            }} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )

    html = IO.iodata_to_binary(safe_html)
    assert html =~ "/alice/demo/src/refs/heads/main/docs/guide.md"
    refute html =~ "<script"

    assert 1 ==
             Enum.count(FakeGitCore.calls(), fn
               {:read_blob, _, _, _, _} -> true
               _ -> false
             end)
  end

  test "README lookup continues only through missing candidates" do
    readme = blob_fixture("README", :plain_readme_lease)

    configure_successful_code(%{
      {:read_blob, "README.md"} => {:error, error(:path_not_found, :read_blob)},
      {:read_blob, "README"} => {:ok, readme}
    })

    assert {:ok,
            %{
              content: %{
                __struct__: RepositoryPage.Code,
                readme: {:ok, %{path: "README", blob: ^readme, html: {:safe, _}}}
              }
            }} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )

    assert [
             {:read_blob, _, "snapshot-1", "README.md", _},
             {:read_blob, _, "snapshot-1", "README", _}
           ] =
             Enum.filter(FakeGitCore.calls(), fn
               {:read_blob, _, _, _, _} -> true
               _ -> false
             end)
  end

  test "required errors stay typed and stop downstream reads" do
    required_error = error(:scan_timeout, :commit_summary)
    configure_successful_code(%{commit_summary: {:error, required_error}})

    assert {:error, ^required_error} =
             RepositoryPage.code(
               repository(),
               owner(),
               nil,
               selector(),
               git_core: FakeGitCore
             )

    assert [
             {:ref_summary, _, _},
             {:resolve_snapshot, _, _},
             {:commit_summary, _, "snapshot-1", []}
           ] = FakeGitCore.calls()
  end

  test "release is best effort for every held lease and safe to repeat" do
    first = blob_fixture("first.txt", :first_lease)
    second = blob_fixture("second.txt", :second_lease)

    FakeGitCore.reset(%{
      release_blob: fn
        {:release_blob, %GitCore.Blob{lease: :first_lease}} -> exit(:release_failed)
        {:release_blob, %GitCore.Blob{lease: :second_lease}} -> :ok
      end
    })

    result = %RepositoryPage.Result{
      kind: :blob,
      chrome: :unused,
      content: %RepositoryPage.Blob{path: "first.txt", blob: first},
      leases: [{FakeGitCore, first}, {FakeGitCore, second}]
    }

    assert :ok = RepositoryPage.release(result)
    assert :ok = RepositoryPage.release(result)

    assert [
             {:release_blob, ^first},
             {:release_blob, ^second},
             {:release_blob, ^first},
             {:release_blob, ^second}
           ] = FakeGitCore.calls()
  end

  test "SSH clone URLs use the active actor and push commands use the configured default" do
    actor = %{owner() | id: 11, username: "collaborator"}

    assert ForgeRepos.ssh_clone_url(repository(), owner(), actor) =~
             ~r{\Assh://collaborator@.+/alice/demo\.git\z}

    repository = %{repository() | default_branch: "trunk"}

    FakeGitCore.reset(%{
      ref_summary: {:ok, empty_ref_summary()},
      repository_disk_usage: {:ok, 128}
    })

    assert {:ok,
            %{
              kind: :empty,
              chrome: %{
                __struct__: RepositoryPage.Chrome,
                clone: %{
                  __struct__: RepositoryPage.Clone,
                  ssh_url: ssh_url,
                  push_commands: commands
                }
              }
            }} =
             RepositoryPage.code(
               repository,
               owner(),
               owner(),
               nil,
               git_core: FakeGitCore
             )

    assert ssh_url =~ ~r{\Assh://alice@.+/alice/demo\.git\z}
    assert "git branch -M trunk" in commands
    assert "git push -u origin trunk" in commands
    refute Enum.any?(commands, &String.contains?(&1, " main"))
  end

  defp configure_successful_code(overrides \\ %{}) do
    responses = %{
      {:read_blob, "README.md"} =>
        {:ok,
         %GitCore.Blob{
           name: "README.md",
           oid: "blob-1",
           size: 7,
           data: "# Hello",
           truncated: false,
           binary: false,
           non_utf8: false,
           lease: :readme_lease
         }},
      ref_summary: {:ok, ref_summary("refs/heads/main")},
      resolve_snapshot:
        {:ok, %GitCore.Snapshot{kind: :branch, ref: "refs/heads/main", oid: "snapshot-1"}},
      commit_summary:
        {:ok,
         %GitCore.CommitSummary{
           count: 1,
           latest: %GitCore.Commit{
             oid: "snapshot-1",
             title: "Initial",
             message: "Initial",
             author_name: "Alice",
             author_email: "alice@example.test",
             author_time: 1,
             committer_name: "Alice",
             committer_email: "alice@example.test",
             committer_time: 1,
             parents: []
           }
         }},
      read_tree_with_history:
        {:ok,
         %GitCore.TreePage{
           entries: [],
           total_entries: 0,
           page: 1,
           per_page: 200,
           total_pages: 1
         }},
      repository_analysis:
        {:ok,
         %GitCore.RepositoryAnalysis{
           languages: [],
           total_bytes: 0,
           files_scanned: 1,
           bytes_scanned: 7,
           truncated: false
         }},
      repository_disk_usage: {:ok, 256},
      release_blob: :ok
    }

    FakeGitCore.reset(Map.merge(responses, overrides))
  end

  defp configure_context_reads do
    FakeGitCore.reset(%{
      {:read_blob_complete, "archive.bin"} => {:ok, blob_fixture("archive.bin", :raw_lease)},
      ref_summary: {:ok, ref_summary("refs/heads/main")},
      ref_summary_for_route: {:ok, {ref_summary("refs/heads/main"), selector(), "archive.bin"}},
      resolve_snapshot:
        {:ok, %GitCore.Snapshot{kind: :branch, ref: "refs/heads/main", oid: "snapshot-1"}},
      ref_page:
        {:ok,
         %GitCore.RefPage{
           refs: [],
           total: 101,
           page: 2,
           per_page: 100,
           total_pages: 2
         }},
      commit_page:
        {:ok,
         %GitCore.CommitPage{
           commits: [],
           total: 101,
           page: 3,
           per_page: 50,
           total_pages: 3
         }},
      commit: {:ok, commit_fixture("url-commit-oid")},
      diff_commit:
        {:ok,
         %GitCore.CommitDiff{
           files: [],
           patch: "",
           truncated: false,
           changed_files: 0,
           additions: 0,
           deletions: 0
         }},
      search_tree:
        {:ok,
         %GitCore.SearchResults{
           scope: :content,
           results: [],
           files_scanned: 1,
           bytes_scanned: 2,
           truncated_reasons: []
         }}
    })
  end

  defp owner do
    %User{
      id: 10,
      username: "alice",
      kind: :user,
      role: :user,
      state: :active
    }
  end

  defp repository do
    %Repository{
      id: 20,
      owner_user_id: 10,
      slug: "demo",
      name: "Demo",
      visibility: :public,
      storage_path: "@test/repository-page/demo.git",
      default_branch: "main"
    }
  end

  defp selector(name \\ "main") do
    %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/#{name}"}
  end

  defp empty_ref_summary do
    %GitCore.RefSummary{
      branch_count: 0,
      tag_count: 0,
      branches: [],
      tags: [],
      refs_truncated: false
    }
  end

  defp ref_summary(full_name) do
    ref = %GitCore.Ref{
      name: full_name,
      kind: :branch,
      target: "snapshot-1",
      display_name: String.replace_prefix(full_name, "refs/heads/", "")
    }

    %GitCore.RefSummary{
      branch_count: 1,
      tag_count: 0,
      branches: [ref],
      tags: [],
      refs_truncated: false
    }
  end

  defp blob_fixture(name, lease) do
    %GitCore.Blob{
      name: name,
      oid: "blob-#{name}",
      size: 4,
      data: "data",
      truncated: false,
      binary: false,
      non_utf8: false,
      lease: lease
    }
  end

  defp commit_fixture(oid) do
    %GitCore.Commit{
      oid: oid,
      title: "Commit",
      message: "Commit",
      author_name: "Alice",
      author_email: "alice@example.test",
      author_time: 1,
      committer_name: "Alice",
      committer_email: "alice@example.test",
      committer_time: 1,
      parents: []
    }
  end

  defp error(kind, operation) do
    %GitCore.Error{kind: kind, operation: operation, detail: "not exposed"}
  end

  defp assert_struct_fields(module, fields) do
    assert Code.ensure_loaded?(module), "expected #{inspect(module)} to be defined"
    assert module.__struct__() |> Map.keys() |> Enum.sort() == Enum.sort([:__struct__ | fields])
  end
end
