defmodule GitLFS.PointerScannerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Fornacast.Repo
  alias GitLFS.{LFSObject, RepositoryObject}
  alias GitLFS.PointerScanner
  alias GitLFS.PointerScanner.{Reachability, Scan, WorkItem}
  alias GitLFS.PointerScanner.ExpansionPage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    assert {:ok, owner} =
             ForgeAccounts.create_user(%{
               username: "lfs-scan-#{suffix}",
               email: "lfs-scan-#{suffix}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(owner, %{
               name: "LFS scan repository",
               slug: "lfs-scan-repository"
             })

    %{repository: repository}
  end

  test "bounded children use one existing-work lookup and one strict insert", %{
    repository: repository
  } do
    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "child-batch", [
               baseline("refs/heads/main", :branch, git_oid("a"))
             ])

    assert {:ok, [root]} = PointerScanner.claim_work(scan, "worker")

    children =
      for n <- 1..100,
          do: %{
            oid: Integer.to_string(n, 16) |> String.downcase() |> String.pad_leading(40, "0"),
            kind: :blob
          }

    parent = self()
    reference = make_ref()
    handler = {__MODULE__, reference}
    prefix = Repo.config()[:telemetry_prefix] || [:fornacast, :repo]

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:query],
        fn _, _, metadata, _ ->
          if self() == parent and String.contains?(metadata.query, "lfs_pointer_scan_work_items"),
            do: send(parent, {reference, metadata.query})
        end,
        nil
      )

    try do
      assert {:ok, _} =
               PointerScanner.record_expansion(root, "worker", %{
                 object_kind: :commit,
                 children: children,
                 candidate: nil,
                 next_offset: nil
               })

      queries = collect_queries(reference)

      lookups =
        Enum.filter(
          queries,
          &(String.starts_with?(&1, "SELECT") and String.contains?(&1, "object_oid") and
              not String.contains?(&1, "FOR UPDATE"))
        )

      inserts =
        Enum.filter(
          queries,
          &String.starts_with?(&1, "INSERT INTO \"lfs_pointer_scan_work_items\"")
        )

      assert length(lookups) == 1
      assert length(inserts) == 1
    after
      :telemetry.detach(handler)
    end
  end

  test "scan pages replay across refs and offsets but reject contradictory payloads", %{
    repository: repository
  } do
    oid = git_oid("a")

    assert {:ok, scan} =
             PointerScanner.begin_scan(
               repository,
               "cached-pages",
               [baseline("refs/tags/first", :tag, oid), baseline("refs/tags/second", :tag, oid)],
               batch_limit: 2
             )

    assert {:ok, [first, second]} = PointerScanner.claim_work(scan, "worker", limit: 2)
    first_page = %{object_kind: :tree, children: [], candidate: nil, next_offset: 128}
    final_page = %{first_page | next_offset: nil}

    assert {:ok, nil} = PointerScanner.cached_expansion(scan, first)
    assert {:ok, _} = PointerScanner.record_expansion(first, "worker", first_page)
    assert {:ok, ^first_page} = PointerScanner.cached_expansion(scan, second)

    assert {:error, :expansion_conflict} =
             PointerScanner.record_expansion(second, "worker", final_page)

    assert Repo.get!(WorkItem, second.id).state == :processing
    assert {:ok, _} = PointerScanner.record_expansion(second, "worker", first_page)

    assert {:ok, [first, second]} = PointerScanner.claim_work(scan, "worker", limit: 2)
    assert first.tree_offset == 128
    assert {:ok, nil} = PointerScanner.cached_expansion(scan, first)
    assert {:ok, _} = PointerScanner.record_expansion(first, "worker", final_page)
    assert {:ok, ^final_page} = PointerScanner.cached_expansion(scan, second)

    assert {:ok, %{scan: %Scan{state: :complete}}} =
             PointerScanner.record_expansion(second, "worker", final_page)

    assert Repo.aggregate(ExpansionPage, :count) == 2
  end

  test "cached actual kind cannot satisfy a conflicting branch hint", %{repository: repository} do
    oid = git_oid("a")

    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "kind-conflict", [
               baseline("refs/heads/main", :branch, oid),
               baseline("refs/tags/tree", :tag, oid)
             ])

    assert {:ok, roots} = PointerScanner.claim_work(scan, "worker", limit: 2)
    tree = Enum.find(roots, &(&1.object_kind == :tag_or_commit))
    commit = Enum.find(roots, &(&1.object_kind == :commit))
    expansion = %{object_kind: :tree, children: [], candidate: nil, next_offset: nil}
    assert {:ok, _} = PointerScanner.record_expansion(tree, "worker", expansion)
    assert {:error, :object_kind_mismatch} = PointerScanner.cached_expansion(scan, commit)

    assert {:error, :object_kind_mismatch} =
             PointerScanner.record_expansion(commit, "worker", expansion)
  end

  test "failed child and pointer-size recording never populates a cache page", %{
    repository: repository
  } do
    root_oid = git_oid("a")

    expansion = %{
      object_kind: :tree,
      children: [%{oid: root_oid, kind: :commit}],
      candidate: nil,
      next_offset: nil
    }

    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "cache-rollback-child", [
               baseline("refs/heads/main", :branch, root_oid)
             ])

    assert {:ok, [root]} = PointerScanner.claim_work(scan, "worker")
    invalid = %{expansion | object_kind: :commit, children: [%{oid: root_oid, kind: :blob}]}

    assert {:error, :inconsistent_child_kind} =
             PointerScanner.record_expansion(root, "worker", invalid)

    assert {:ok, nil} = PointerScanner.cached_expansion(scan, root)
    assert Repo.get!(WorkItem, root.id).state == :processing

    data = pointer(lfs_oid("b"), 1)
    first_oid = git_blob_oid(data)
    other_data = pointer(lfs_oid("b"), 2)
    other_oid = git_blob_oid(other_data)

    assert {:ok, pointer_scan} =
             PointerScanner.begin_scan(repository, "cache-rollback-size", [
               baseline("refs/tags/first", :tag, first_oid),
               baseline("refs/tags/second", :tag, other_oid)
             ])

    assert {:ok, [first, second]} = PointerScanner.claim_work(pointer_scan, "worker", limit: 2)

    assert {:ok, _} =
             PointerScanner.record_expansion(first, "worker", %{
               object_kind: :blob,
               children: [],
               candidate: candidate(data),
               next_offset: nil
             })

    assert {:error, :pointer_size_mismatch} =
             PointerScanner.record_expansion(second, "worker", %{
               object_kind: :blob,
               children: [],
               candidate: candidate(other_data),
               next_offset: nil
             })

    assert {:ok, nil} = PointerScanner.cached_expansion(pointer_scan, second)
  end

  test "cache hits retain work leases and cannot cross scans or repository generations", %{
    repository: repository
  } do
    oid = git_oid("a")

    baselines = [
      baseline("refs/heads/first", :branch, oid),
      baseline("refs/heads/second", :branch, oid)
    ]

    assert {:ok, scan} = PointerScanner.begin_scan(repository, "cache-fences", baselines)
    assert {:ok, [first, second]} = PointerScanner.claim_work(scan, "worker", limit: 2)
    expansion = %{object_kind: :commit, children: [], candidate: nil, next_offset: nil}
    assert {:ok, _} = PointerScanner.record_expansion(first, "worker", expansion)
    assert {:ok, ^expansion} = PointerScanner.cached_expansion(scan, second)

    Repo.update_all(from(w in WorkItem, where: w.id == ^second.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
    )

    assert {:error, :stale_work} = PointerScanner.record_expansion(second, "worker", expansion)

    assert {:ok, other_scan} =
             PointerScanner.begin_scan(repository, "cache-other-scan", baselines)

    assert {:ok, [other]} = PointerScanner.claim_work(other_scan, "worker", limit: 1)
    assert {:ok, nil} = PointerScanner.cached_expansion(other_scan, other)

    Repo.update_all(from(r in ForgeRepos.Repository, where: r.id == ^repository.id),
      set: [generation: repository.generation + 1]
    )

    assert {:error, :stale_scan} = PointerScanner.cached_expansion(scan, second)

    assert {:ok, new_scan} =
             PointerScanner.begin_scan(
               %{repository | generation: repository.generation + 1},
               "cache-new-generation",
               baselines
             )

    assert {:ok, [new]} = PointerScanner.claim_work(new_scan, "worker", limit: 1)
    assert {:ok, nil} = PointerScanner.cached_expansion(new_scan, new)
  end

  test "cache payload fingerprints fail closed and format versions miss", %{
    repository: repository
  } do
    oid = git_oid("a")

    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "cache-payload", [
               baseline("refs/tags/first", :tag, oid),
               baseline("refs/tags/second", :tag, oid)
             ])

    assert {:ok, [first, second]} = PointerScanner.claim_work(scan, "worker", limit: 2)
    expansion = %{object_kind: :blob, children: [], candidate: candidate(<<>>), next_offset: nil}
    assert {:ok, _} = PointerScanner.record_expansion(first, "worker", expansion)
    assert {:ok, ^expansion} = PointerScanner.cached_expansion(scan, second)
    page = Repo.get_by!(ExpansionPage, scan_id: scan.id)

    Repo.update_all(from(p in ExpansionPage, where: p.id == ^page.id),
      set: [result_fingerprint: String.duplicate("0", 64)]
    )

    assert {:error, :expansion_conflict} = PointerScanner.cached_expansion(scan, second)

    Repo.update_all(from(p in ExpansionPage, where: p.id == ^page.id),
      set: [format_version: ExpansionPage.format_version() + 1]
    )

    assert {:ok, nil} = PointerScanner.cached_expansion(scan, second)
  end

  defp collect_queries(reference) do
    receive do
      {^reference, query} -> [query | collect_queries(reference)]
    after
      0 -> []
    end
  end

  test "hidden import scans can finish without making the repository public", %{
    repository: repository
  } do
    repository =
      repository
      |> Ecto.Changeset.change(lifecycle: :importing)
      |> Repo.update!()

    assert {:ok, %Scan{state: :complete} = scan} =
             PointerScanner.begin_scan(repository, "import-empty", [])

    assert {:ok, %Scan{state: :complete}} = PointerScanner.resume_scan(repository, "import-empty")
    assert {:ok, %Scan{state: :published}} = PointerScanner.publish_scan(scan)
    assert Repo.get!(ForgeRepos.Repository, repository.id).lifecycle == :importing

    stale = %{repository | generation: repository.generation + 1}
    assert {:error, :stale_repository} = PointerScanner.begin_scan(stale, "stale-import", [])
  end

  test "seeds branch and tag targets and reclaims an expired bounded lease", %{
    repository: repository
  } do
    baselines = [
      baseline("refs/heads/main", :branch, git_oid("a")),
      baseline("refs/tags/v1.0.0", :tag, git_oid("b"))
    ]

    assert {:ok, %Scan{state: :scanning} = scan} =
             PointerScanner.begin_scan(repository, "operation-1", baselines, batch_limit: 2)

    assert [
             %WorkItem{ref_name: "refs/heads/main", object_kind: :commit, state: :pending},
             %WorkItem{ref_name: "refs/tags/v1.0.0", object_kind: :tag_or_commit, state: :pending}
           ] = Repo.all(from(work in WorkItem, order_by: work.id))

    assert {:ok, %Scan{id: scan_id} = resumed_scan} =
             PointerScanner.resume_scan(repository, "operation-1")

    assert scan_id == scan.id

    assert {:ok, %Scan{id: ^scan_id}} =
             PointerScanner.begin_scan(repository, "operation-1", Enum.reverse(baselines),
               batch_limit: 2
             )

    assert {:ok, [%WorkItem{ref_name: "refs/heads/main", attempt_count: 1} = first]} =
             PointerScanner.claim_work(resumed_scan, "worker-1", limit: 1, lease_seconds: 30)

    assert {:ok, [%WorkItem{ref_name: "refs/tags/v1.0.0"}]} =
             PointerScanner.claim_work(scan, "worker-2", limit: 1, lease_seconds: 30)

    past = DateTime.add(DateTime.utc_now(:second), -1, :second)

    WorkItem
    |> where([work], work.id == ^first.id)
    |> Repo.update_all(set: [lease_expires_at: past])

    assert {:ok, [%WorkItem{id: reclaimed_id, attempt_count: 2}]} =
             PointerScanner.claim_work(scan, "worker-3", limit: 1, lease_seconds: 30)

    assert reclaimed_id == first.id
  end

  test "claims eligible work in id order across pending and expired leases", %{
    repository: repository
  } do
    baselines =
      for letter <- ~w(a b c d e),
          do: baseline("refs/heads/#{letter}", :branch, git_oid(letter))

    assert {:ok, scan} = PointerScanner.begin_scan(repository, "claim-order", baselines)
    assert {:ok, other} = PointerScanner.begin_scan(repository, "other-claim", baselines)

    [done, expired, held, pending, later] =
      Repo.all(from w in WorkItem, where: w.scan_id == ^scan.id, order_by: w.id)

    now = DateTime.utc_now(:second)
    Repo.update_all(from(w in WorkItem, where: w.id == ^done.id), set: [state: :done])

    Repo.update_all(from(w in WorkItem, where: w.id == ^expired.id),
      set: [state: :processing, lease_owner: "expired", lease_expires_at: DateTime.add(now, -1)]
    )

    Repo.update_all(from(w in WorkItem, where: w.id == ^held.id),
      set: [state: :processing, lease_owner: "held", lease_expires_at: DateTime.add(now, 300)]
    )

    assert {:ok, claimed} = PointerScanner.claim_work(scan, "new-owner", limit: 2)
    assert Enum.map(claimed, & &1.id) == [expired.id, pending.id]
    assert Enum.all?(claimed, &(&1.lease_owner == "new-owner" and &1.state == :processing))
    assert Repo.get!(WorkItem, held.id).lease_owner == "held"
    assert {:ok, [%WorkItem{id: later_id}]} = PointerScanner.claim_work(scan, "later", limit: 2)
    assert later_id == later.id
    assert {:ok, []} = PointerScanner.claim_work(scan, "empty", limit: 2)

    assert Repo.aggregate(
             from(w in WorkItem, where: w.scan_id == ^other.id and w.state == :pending),
             :count
           ) == 5
  end

  test "claim selector avoids completed history under custom and generic prepared plans", %{
    repository: repository
  } do
    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "claim-plan", [
               baseline("refs/heads/main", :branch, git_oid("a"))
             ])

    now = DateTime.utc_now(:second)

    history =
      for id <- 1..10_000 do
        %{
          scan_id: scan.id,
          ref_name: "refs/heads/history",
          object_oid:
            id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"),
          object_kind: :commit,
          state: :done,
          inserted_at: now,
          updated_at: now
        }
      end

    Enum.each(Enum.chunk_every(history, 1_000), &Repo.insert_all(WorkItem, &1))
    Repo.update_all(from(w in WorkItem, where: w.scan_id == ^scan.id), set: [state: :done])

    %WorkItem{}
    |> WorkItem.creation_changeset(%{
      scan_id: scan.id,
      ref_name: "refs/heads/main",
      object_oid: git_oid("b"),
      object_kind: :commit
    })
    |> Repo.insert!()

    Repo.query!("ANALYZE lfs_pointer_scan_work_items")
    {sql, params} = capture_claim_selector(scan)
    assert sql =~ ~s("state" = 'pending')
    assert sql =~ ~s("state" = 'processing')
    assert sql =~ "FOR UPDATE SKIP LOCKED"

    for mode <- ~w(force_custom_plan force_generic_plan) do
      Repo.query!("SET LOCAL plan_cache_mode = #{mode}")
      plan = explain_claim_selector(sql, params)
      assert plan =~ "lfs_pointer_scan_work_items_active_order_index"
      refute plan =~ "Sort"
      refute plan =~ "lfs_pointer_scan_work_items_pkey"
    end
  end

  test "expansion is replay-safe, pages trees, and deduplicates shared history", %{
    repository: repository
  } do
    ref_name = "refs/heads/main"
    lfs_oid = lfs_oid("1")

    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "operation-1", [
               baseline(ref_name, :branch, git_oid("a"))
             ])

    assert {:ok, [root]} = PointerScanner.claim_work(scan, "worker", limit: 10)

    tree_oid = git_oid("b")
    left_oid = git_oid("c")
    right_oid = git_oid("d")
    common_oid = git_oid("e")
    blob_oid = git_oid("f")

    assert {:ok, %{scan: %Scan{state: :scanning}}} =
             PointerScanner.record_expansion(root, "worker", %{
               object_kind: :commit,
               children: [
                 %{oid: tree_oid, kind: :tree},
                 %{oid: left_oid, kind: :commit},
                 %{oid: right_oid, kind: :commit}
               ],
               candidate: nil,
               next_offset: nil
             })

    assert {:ok, claimed} = PointerScanner.claim_work(scan, "worker", limit: 10)
    claimed = Map.new(claimed, &{&1.object_oid, &1})

    for parent_oid <- [left_oid, right_oid] do
      assert {:ok, _result} =
               PointerScanner.record_expansion(claimed[parent_oid], "worker", %{
                 object_kind: :commit,
                 children: [%{oid: common_oid, kind: :commit}],
                 candidate: nil,
                 next_offset: nil
               })
    end

    first_tree_page = %{
      object_kind: :tree,
      children: [%{oid: blob_oid, kind: :blob}],
      candidate: nil,
      next_offset: 128
    }

    assert {:ok, %{work_item: %WorkItem{tree_offset: 128, state: :pending}}} =
             PointerScanner.record_expansion(claimed[tree_oid], "worker", first_tree_page)

    assert {:ok, %{work_item: %WorkItem{tree_offset: 128}}} =
             PointerScanner.record_expansion(claimed[tree_oid], "worker", first_tree_page)

    assert Repo.aggregate(
             from(work in WorkItem,
               where: work.scan_id == ^scan.id and work.object_oid == ^common_oid
             ),
             :count
           ) == 1

    assert {:ok, next} = PointerScanner.claim_work(scan, "worker", limit: 10)
    next = Map.new(next, &{&1.object_oid, &1})

    assert {:ok, _result} =
             PointerScanner.record_expansion(next[common_oid], "worker", %{
               object_kind: :commit,
               children: [],
               candidate: nil,
               next_offset: nil
             })

    assert {:ok, _result} =
             PointerScanner.record_expansion(next[tree_oid], "worker", %{
               object_kind: :tree,
               children: [%{oid: blob_oid, kind: :blob}],
               candidate: nil,
               next_offset: nil
             })

    assert {:ok, _result} =
             PointerScanner.record_expansion(next[blob_oid], "worker", %{
               object_kind: :blob,
               children: [],
               candidate: candidate(pointer(lfs_oid, 12)),
               next_offset: nil
             })

    assert {:ok, %Scan{state: :complete}} = PointerScanner.resume_scan(repository, "operation-1")
    assert Repo.aggregate(Reachability, :count) == 1
  end

  test "follows annotated tag chains through their resolved object kinds", %{
    repository: repository
  } do
    assert {:ok, scan} =
             PointerScanner.begin_scan(repository, "operation-1", [
               baseline("refs/tags/v1.0.0", :tag, git_oid("a"))
             ])

    assert {:ok, [%WorkItem{object_kind: :tag_or_commit} = outer]} =
             PointerScanner.claim_work(scan, "worker", limit: 10)

    nested_oid = git_oid("b")

    assert {:ok, _result} =
             PointerScanner.record_expansion(outer, "worker", %{
               object_kind: :tag,
               children: [%{oid: nested_oid, kind: :tag_or_commit}],
               candidate: nil,
               next_offset: nil
             })

    assert {:ok, [%WorkItem{object_oid: ^nested_oid} = nested]} =
             PointerScanner.claim_work(scan, "worker", limit: 10)

    commit_oid = git_oid("c")

    assert {:ok, _result} =
             PointerScanner.record_expansion(nested, "worker", %{
               object_kind: :tag,
               children: [%{oid: commit_oid, kind: :commit}],
               candidate: nil,
               next_offset: nil
             })

    assert {:ok, [%WorkItem{object_oid: ^commit_oid} = commit]} =
             PointerScanner.claim_work(scan, "worker", limit: 10)

    assert {:ok, %{scan: %Scan{state: :complete}}} =
             PointerScanner.record_expansion(commit, "worker", %{
               object_kind: :commit,
               children: [],
               candidate: nil,
               next_offset: nil
             })
  end

  test "publishes incremental add/remove reachability and requirement provenance", %{
    repository: repository
  } do
    first_oid = lfs_oid("1")
    second_oid = lfs_oid("2")
    insert_ready_object(first_oid, 10)
    insert_ready_object(second_oid, 20)

    assert {:ok, first_scan} =
             complete_scan(repository, "operation-1", [
               {baseline("refs/heads/main", :branch, git_oid("a")), [{first_oid, 10}]},
               {baseline("refs/tags/v1.0.0", :tag, git_oid("b")),
                [{first_oid, 10}, {second_oid, 20}]}
             ])

    assert {:ok,
            %{
              objects: [
                %{oid: ^first_oid, size: 10, first_seen_ref: "refs/heads/main"},
                %{oid: ^second_oid, size: 20, first_seen_ref: "refs/tags/v1.0.0"}
              ],
              next_cursor: nil
            }} = PointerScanner.list_requirements(first_scan, limit: 10)

    assert {:error, :not_found} = PointerScanner.list_current_reachability(repository)
    assert {:ok, %Scan{state: :published} = first_scan} = PointerScanner.publish_scan(first_scan)

    assert {:ok, second_scan} =
             complete_scan(repository, "operation-2", [
               {baseline("refs/heads/main", :branch, git_oid("c")), [{second_oid, 20}]}
             ])

    assert {:ok, [%Reachability{scan_id: first_scan_id} | _]} =
             PointerScanner.list_current_reachability(repository, limit: 10)

    assert first_scan_id == first_scan.id
    assert {:ok, %Scan{state: :published}} = PointerScanner.publish_scan(second_scan)
    assert {:error, :superseded} = PointerScanner.publish_scan(first_scan)

    assert [
             %RepositoryObject{
               oid_sha256: ^first_oid,
               reachable: false,
               first_seen_ref: "refs/heads/main"
             },
             %RepositoryObject{
               oid_sha256: ^second_oid,
               reachable: true,
               first_seen_ref: "refs/tags/v1.0.0"
             }
           ] = Repo.all(from(mapping in RepositoryObject, order_by: mapping.oid_sha256))
  end

  test "publication rejects unavailable requirements atomically and an empty scan removes reachability",
       %{repository: repository} do
    ready_oid = lfs_oid("3")
    missing_oid = lfs_oid("4")
    insert_ready_object(ready_oid, 30)

    assert {:ok, ready_scan} =
             complete_scan(repository, "operation-1", [
               {baseline("refs/heads/main", :branch, git_oid("a")), [{ready_oid, 30}]}
             ])

    assert {:ok, %Scan{state: :published}} = PointerScanner.publish_scan(ready_scan)

    assert {:ok, missing_scan} =
             complete_scan(repository, "operation-2", [
               {baseline("refs/heads/main", :branch, git_oid("b")), [{missing_oid, 40}]}
             ])

    assert {:error, :requirements_unavailable} = PointerScanner.publish_scan(missing_scan)

    assert {:ok, [%Reachability{scan_id: published_scan_id}]} =
             PointerScanner.list_current_reachability(repository)

    assert published_scan_id == ready_scan.id

    assert [%RepositoryObject{oid_sha256: ^ready_oid, reachable: true}] =
             Repo.all(RepositoryObject)

    assert {:ok, %Scan{state: :complete} = empty_scan} =
             PointerScanner.begin_scan(repository, "operation-3", [])

    assert {:ok, %Scan{state: :published}} = PointerScanner.publish_scan(empty_scan)
    assert {:ok, []} = PointerScanner.list_current_reachability(repository)

    assert [%RepositoryObject{oid_sha256: ^ready_oid, reachable: false}] =
             Repo.all(RepositoryObject)
  end

  test "preparing prospective deletion preserves objects still used by public refs", %{
    repository: repository
  } do
    oid = lfs_oid("5")
    insert_ready_object(oid, 50)

    assert {:ok, live_scan} =
             complete_scan(repository, "live", [
               {baseline("refs/heads/main", :branch, git_oid("a")), [{oid, 50}]}
             ])

    assert {:ok, _} = PointerScanner.publish_scan(live_scan)
    assert {:ok, deletion_scan} = PointerScanner.begin_scan(repository, "delete", [])
    assert {:ok, %Scan{state: :prepared}} = PointerScanner.prepare_scan(deletion_scan)

    assert {:ok, [%Reachability{scan_id: scan_id}]} =
             PointerScanner.list_current_reachability(repository)

    assert scan_id == live_scan.id

    # A crash or failed CAS can leave main unchanged. Its download authorization survives.
    assert [%RepositoryObject{oid_sha256: ^oid, reachable: true}] = Repo.all(RepositoryObject)
  end

  @tag :tmp_dir
  test "durable tag work resolves real tree and blob roots into LFS reachability", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    work_path = Path.join(tmp_dir, "tag-work")
    repo_path = Path.join(tmp_dir, "tag-repository.git")
    lfs_oid = lfs_oid("d")
    git!(["init", "--bare", repo_path])
    git!(["init", work_path])
    File.write!(Path.join(work_path, "asset.lfs"), pointer(lfs_oid, 44))
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "pointer"])
    tree = git!(["-C", work_path, "rev-parse", "HEAD^{tree}"])
    blob = git!(["-C", work_path, "rev-parse", "HEAD:asset.lfs"])
    git!(["-C", work_path, "tag", "tree", tree])
    git!(["-C", work_path, "tag", "blob", blob])
    git!(["-C", work_path, "tag", "-a", "annotated-tree", tree, "-m", "tree"])
    git!(["-C", work_path, "tag", "-a", "annotated-blob", blob, "-m", "blob"])
    git!(["-C", work_path, "push", repo_path, "HEAD:refs/heads/main", "--tags"])

    baselines =
      for name <- ["tree", "blob", "annotated-tree", "annotated-blob"] do
        baseline(
          "refs/tags/#{name}",
          :tag,
          git!(["-C", work_path, "rev-parse", "refs/tags/#{name}"])
        )
      end

    assert {:ok, scan} = PointerScanner.begin_scan(repository, "real-tag-objects", baselines)

    assert {:ok, %Scan{state: :complete} = scan} =
             drain_real_scan(repository, scan, repo_path, 0)

    assert {:ok, %{objects: [%{oid: ^lfs_oid, size: 44}], next_cursor: nil}} =
             PointerScanner.list_requirements(scan)

    assert Repo.aggregate(Reachability, :count) == length(baselines)
  end

  defp drain_real_scan(repository, scan, repo_path, steps) when steps < 100 do
    case PointerScanner.claim_work(scan, "real-worker", limit: 1) do
      {:error, :scan_complete} ->
        PointerScanner.resume_scan(repository, "real-tag-objects")

      {:ok, []} ->
        PointerScanner.resume_scan(repository, "real-tag-objects")

      {:ok, [work]} ->
        assert {:ok, expansion} =
                 GitCore.expand_lfs_scan_object(
                   repo_path,
                   work.object_oid,
                   work.object_kind,
                   work.tree_offset,
                   1
                 )

        assert {:ok, _} = PointerScanner.record_expansion(work, "real-worker", expansion)
        drain_real_scan(repository, scan, repo_path, steps + 1)
    end
  end

  defp drain_real_scan(_repository, _scan, _repo_path, _steps),
    do: flunk("durable tag LFS traversal did not converge")

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

  defp complete_scan(repository, key, baseline_objects) do
    baselines = Enum.map(baseline_objects, &elem(&1, 0))

    object_map =
      Map.new(baseline_objects, fn {baseline, objects} -> {baseline.ref_name, objects} end)

    assert {:ok, scan} = PointerScanner.begin_scan(repository, key, baselines, batch_limit: 20)
    assert {:ok, roots} = PointerScanner.claim_work(scan, "worker", limit: 20)

    blob_candidates =
      Enum.reduce(roots, %{}, fn root, candidates ->
        objects = Map.fetch!(object_map, root.ref_name)

        {children, candidates} =
          Enum.map_reduce(objects, candidates, fn {oid, size}, acc ->
            data = pointer(oid, size)
            blob_oid = git_blob_oid(data)
            {%{oid: blob_oid, kind: :blob}, Map.put(acc, {root.ref_name, blob_oid}, data)}
          end)

        assert {:ok, _result} =
                 PointerScanner.record_expansion(root, "worker", %{
                   object_kind: :commit,
                   children: children,
                   candidate: nil,
                   next_offset: nil
                 })

        candidates
      end)

    assert {:ok, blobs} = PointerScanner.claim_work(scan, "worker", limit: 20)

    Enum.each(blobs, fn blob ->
      data = Map.fetch!(blob_candidates, {blob.ref_name, blob.object_oid})

      assert {:ok, _result} =
               PointerScanner.record_expansion(blob, "worker", %{
                 object_kind: :blob,
                 children: [],
                 candidate: candidate(data),
                 next_offset: nil
               })
    end)

    PointerScanner.resume_scan(repository, key)
  end

  defp baseline(ref_name, ref_kind, target_oid),
    do: %{ref_name: ref_name, ref_kind: ref_kind, oid: target_oid}

  defp candidate(data), do: %{data: data, blob_size: byte_size(data)}

  defp pointer(oid, size),
    do: "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize #{size}\n"

  defp insert_ready_object(oid, size) do
    assert {:ok, %LFSObject{}} =
             %LFSObject{}
             |> LFSObject.ready_changeset(%{
               oid_sha256: oid,
               size: size,
               storage_key: oid,
               verified_at: DateTime.utc_now(:second)
             })
             |> Repo.insert()
  end

  defp capture_claim_selector(scan) do
    handler = {__MODULE__, make_ref()}
    owner = self()
    prefix = Keyword.get(Repo.config(), :telemetry_prefix, [:fornacast, :repo])

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:query],
        fn _, _, metadata, _ ->
          query = metadata[:query]

          if is_binary(query) and String.contains?(query, "lfs_pointer_scan_work_items") and
               String.contains?(query, "FOR UPDATE SKIP LOCKED") do
            send(owner, {:claim_selector, query, metadata[:params]})
          end
        end,
        nil
      )

    try do
      assert {:ok, [_]} = PointerScanner.claim_work(scan, "plan-owner", limit: 1)
      assert_receive {:claim_selector, sql, params}
      {sql, params}
    after
      :telemetry.detach(handler)
    end
  end

  defp explain_claim_selector(sql, params) do
    statement = "fornacast_lfs_claim_selector"
    Repo.query!("PREPARE #{statement} AS #{sql}")

    try do
      arguments =
        Enum.map_join(params, ", ", fn
          value when is_integer(value) -> Integer.to_string(value)
          %DateTime{} = value -> "'#{DateTime.to_iso8601(value)}'"
          %NaiveDateTime{} = value -> "'#{NaiveDateTime.to_iso8601(value)}'"
          value when is_binary(value) -> "'" <> String.replace(value, "'", "''") <> "'"
        end)

      Repo.query!("EXPLAIN (COSTS OFF) EXECUTE #{statement}(#{arguments})").rows
      |> List.flatten()
      |> Enum.join("\n")
    after
      Repo.query!("DEALLOCATE #{statement}")
    end
  end

  defp git_blob_oid(data), do: :crypto.hash(:sha, data) |> Base.encode16(case: :lower)
  defp git_oid(character), do: String.duplicate(character, 40)
  defp lfs_oid(character), do: String.duplicate(character, 64)
end
