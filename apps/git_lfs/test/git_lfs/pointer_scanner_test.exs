defmodule GitLFS.PointerScannerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Fornacast.Repo
  alias GitLFS.{LFSObject, RepositoryObject}
  alias GitLFS.PointerScanner
  alias GitLFS.PointerScanner.{Reachability, Scan, WorkItem}

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

  defp git_blob_oid(data), do: :crypto.hash(:sha, data) |> Base.encode16(case: :lower)
  defp git_oid(character), do: String.duplicate(character, 40)
  defp lfs_oid(character), do: String.duplicate(character, 64)
end
