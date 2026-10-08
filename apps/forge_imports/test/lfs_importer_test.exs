defmodule ForgeImports.GitHub.LFSImporterTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeImports.{ImportRun, Persistence}
  alias ForgeImports.GitHub.LFSImporter
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitLFS.PointerScanner

  @now ~U[2026-09-20 08:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    actor = user_fixture()
    %{actor: actor}
  end

  test "one advance expands multiple Git objects before returning", %{actor: actor} do
    fixture = scan_fixture(actor, 3)

    assert {:incomplete, checkpoint} =
             LFSImporter.advance(fixture.item, fixture.run, fn _, _, _ -> {:ok, nil} end, fn ->
               :ok
             end)

    assert checkpoint["lfs_import"]["status"] == "scan"
    assert Repo.get!(PointerScanner.Scan, checkpoint["lfs_import"]["scan_id"]).state == :complete
    assert done_work(fixture) == 4
  end

  test "shared refs reuse bounded expansions while retaining every pointer provenance", %{
    actor: actor
  } do
    fixture = shared_pointer_fixture(actor)
    counter = make_ref()

    assert {:incomplete, checkpoint} =
             advance(fixture,
               monotonic_time: fn -> 0 end,
               expand_object: fn path, oid, kind, offset, limit ->
                 Process.put(counter, Process.get(counter, 0) + 1)
                 GitCore.expand_lfs_scan_object(path, oid, kind, offset, limit)
               end
             )

    assert Process.get(counter) == 3
    scan_id = checkpoint["lfs_import"]["scan_id"]
    assert Repo.get!(PointerScanner.Scan, scan_id).state == :complete

    assert Repo.aggregate(
             from(w in PointerScanner.WorkItem,
               where: w.scan_id == ^scan_id and w.state == :done
             ),
             :count
           ) == 9

    assert Repo.all(
             from r in PointerScanner.Reachability,
               where: r.scan_id == ^scan_id,
               order_by: r.ref_name,
               select: {r.ref_name, r.oid_sha256, r.size}
           ) ==
             [
               {"refs/heads/main", fixture.lfs_oid, 1},
               {"refs/heads/shared", fixture.lfs_oid, 1},
               {"refs/tags/shared", fixture.lfs_oid, 1}
             ]

    uncached = shared_pointer_fixture(actor)
    Process.put(counter, 0)

    assert {:incomplete, other_checkpoint} =
             advance(uncached,
               monotonic_time: fn -> 0 end,
               cached_expansion: fn _, _ -> {:ok, nil} end,
               expand_object: fn path, oid, kind, offset, limit ->
                 Process.put(counter, Process.get(counter, 0) + 1)
                 GitCore.expand_lfs_scan_object(path, oid, kind, offset, limit)
               end
             )

    assert Process.get(counter) == 9
    other_id = other_checkpoint["lfs_import"]["scan_id"]

    assert Repo.all(
             from r in PointerScanner.Reachability,
               where: r.scan_id == ^other_id,
               order_by: r.ref_name,
               select: {r.ref_name, r.oid_sha256, r.size}
           ) ==
             Repo.all(
               from r in PointerScanner.Reachability,
                 where: r.scan_id == ^scan_id,
                 order_by: r.ref_name,
                 select: {r.ref_name, r.oid_sha256, r.size}
             )
  end

  for reason <- [:cancelled, :lost_lease] do
    test "a cached expansion still checks #{reason} before recording", %{actor: actor} do
      fixture = shared_pointer_fixture(actor)
      lost = make_ref()
      authorize = fn -> if Process.get(lost), do: {:error, unquote(reason)}, else: :ok end

      assert {:error, unquote(reason)} =
               advance(fixture,
                 authorize: authorize,
                 monotonic_time: fn -> 0 end,
                 cached_expansion: fn scan, work ->
                   result = PointerScanner.cached_expansion(scan, work)
                   if match?({:ok, %{}}, result), do: Process.put(lost, true)
                   result
                 end
               )

      assert Process.get(lost)
      assert done_work(fixture) == 1

      assert Repo.aggregate(
               from(w in PointerScanner.WorkItem, where: w.state == :processing),
               :count
             ) == 1

      refute Repo.exists?(PointerScanner.Reachability)
    end
  end

  test "an advance has a bounded number of object expansions", %{actor: actor} do
    fixture = scan_fixture(actor, 120)

    assert {:incomplete, _checkpoint} = advance(fixture)
    assert done_work(fixture) == 100
    refute Repo.exists?(from w in PointerScanner.WorkItem, where: w.state == :processing)
  end

  test "the time budget leaves unstarted work unclaimed", %{actor: actor} do
    fixture = scan_fixture(actor, 3)
    clock = make_ref()
    Process.put(clock, 0)

    assert {:incomplete, _} =
             advance(fixture,
               monotonic_time: fn -> Process.get(clock) end,
               record_expansion: fn work, owner, expansion ->
                 result = PointerScanner.record_expansion(work, owner, expansion)
                 Process.put(clock, 250)
                 result
               end
             )

    assert done_work(fixture) == 1
    assert Repo.exists?(from w in PointerScanner.WorkItem, where: w.state == :pending)
    refute Repo.exists?(from w in PointerScanner.WorkItem, where: w.state == :processing)
  end

  test "cancellation between objects preserves progress and stops further expansion", %{
    actor: actor
  } do
    fixture = scan_fixture(actor, 3)
    cancelled = make_ref()
    authorize = fn -> if Process.get(cancelled), do: {:error, :cancelled}, else: :ok end

    assert {:error, :cancelled} =
             advance(fixture,
               authorize: authorize,
               record_expansion: fn work, owner, expansion ->
                 result = PointerScanner.record_expansion(work, owner, expansion)
                 Process.put(cancelled, true)
                 result
               end
             )

    assert done_work(fixture) == 1
    refute Repo.exists?(from w in PointerScanner.WorkItem, where: w.state == :processing)
  end

  test "a later expansion failure retains earlier durable work", %{actor: actor} do
    fixture = scan_fixture(actor, 3)
    counter = make_ref()

    assert {:error, :injected_failure} =
             advance(fixture,
               expand_object: fn path, oid, kind, offset, limit ->
                 count = Process.get(counter, 0) + 1
                 Process.put(counter, count)

                 if count == 3,
                   do: {:error, :injected_failure},
                   else: GitCore.expand_lfs_scan_object(path, oid, kind, offset, limit)
               end
             )

    assert done_work(fixture) == 2

    assert Repo.aggregate(
             from(w in PointerScanner.WorkItem, where: w.state == :processing),
             :count
           ) == 1
  end

  test "authorization loss after expansion cannot record that object", %{actor: actor} do
    fixture = scan_fixture(actor, 3)
    lost = make_ref()
    counter = make_ref()
    authorize = fn -> if Process.get(lost), do: {:error, :lost_lease}, else: :ok end

    assert {:error, :lost_lease} =
             advance(fixture,
               authorize: authorize,
               expand_object: fn path, oid, kind, offset, limit ->
                 count = Process.get(counter, 0) + 1
                 Process.put(counter, count)
                 result = GitCore.expand_lfs_scan_object(path, oid, kind, offset, limit)
                 if count == 2, do: Process.put(lost, true)
                 result
               end
             )

    assert done_work(fixture) == 1
  end

  test "batched scanning retains tree pagination", %{actor: actor} do
    fixture = import_fixture(actor)
    blob = write_object!(fixture.path, "blob", "ordinary content")
    raw_oid = Base.decode16!(blob, case: :lower)

    tree =
      Enum.map_join(1..101, fn n ->
        "100644 file#{String.pad_leading(to_string(n), 3, "0")}\0" <> raw_oid
      end)
      |> then(&write_object!(fixture.path, "tree", &1))

    commit = git!(fixture.path, ["commit-tree", tree, "-m", "paged tree"])
    update_ref!(fixture.path, commit, "refs/heads/main")
    update_ref!(fixture.path, commit, "refs/heads/shared")
    counter = make_ref()

    assert {:incomplete, _} =
             advance(fixture,
               monotonic_time: fn -> 0 end,
               expand_object: fn path, oid, kind, offset, limit ->
                 if oid == tree, do: Process.put(counter, Process.get(counter, 0) + 1)
                 GitCore.expand_lfs_scan_object(path, oid, kind, offset, limit)
               end
             )

    works = Repo.all(from w in PointerScanner.WorkItem, where: w.object_oid == ^tree)
    assert length(works) == 2

    for work <- works do
      assert work.state == :done
      assert work.attempt_count == 2
      assert work.tree_offset > 0
    end

    assert Process.get(counter) == 2
  end

  test "scan completion yields its checkpoint before entering LFS transfer", %{actor: actor} do
    fixture = import_fixture(actor)
    oid = String.duplicate("a", 64)

    blob =
      write_object!(
        fixture.path,
        "blob",
        "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize 1\n"
      )

    tree =
      write_object!(
        fixture.path,
        "tree",
        "100644 pointer\0" <> Base.decode16!(blob, case: :lower)
      )

    commit = git!(fixture.path, ["commit-tree", tree, "-m", "LFS pointer"])
    update_ref!(fixture.path, commit, "refs/heads/main")
    parent = self()

    transfer = fn repository, scan, cursor ->
      send(parent, {:transfer, repository.id, scan.state, cursor})
      {:ok, oid}
    end

    assert {:incomplete, scan_checkpoint} = advance(fixture, transfer: transfer)
    refute_received {:transfer, _, _, _}
    assert scan_checkpoint["lfs_import"]["status"] == "scan"
    fixture = %{fixture | item: %{fixture.item | checkpoint: scan_checkpoint}}
    assert {:incomplete, checkpoint} = advance(fixture, transfer: transfer)

    assert_receive {:transfer, repository_id, :complete, nil}
    assert repository_id == fixture.shadow.id
    assert checkpoint["lfs_import"]["status"] == "transfer"
    assert checkpoint["lfs_import"]["object_cursor"] == oid
  end

  test "standalone completion requires an authentic published scan checkpoint", %{actor: actor} do
    fixture = import_fixture(actor)
    published = published_scan!(fixture, "standalone-proof")
    item = put_scan_checkpoint(fixture.item, fixture.shadow, published)

    assert ForgeImports.GitHub.LFSImporter.complete?(item)

    refute ForgeImports.GitHub.LFSImporter.complete?(%{
             item
             | checkpoint: Map.delete(item.checkpoint, "lfs_import")
           })

    forged = put_in(item.checkpoint, ["lfs_import", "scan_key"], "forged-scan-key")
    refute ForgeImports.GitHub.LFSImporter.complete?(%{item | checkpoint: forged})
  end

  test "standalone completion rejects ref fingerprint drift after publication", %{actor: actor} do
    fixture = import_fixture(actor)
    published = published_scan!(fixture, "ref-drift")
    item = put_scan_checkpoint(fixture.item, fixture.shadow, published)
    assert ForgeImports.GitHub.LFSImporter.complete?(item)

    new_oid = commit!(fixture.path, "new ref")
    update_ref!(fixture.path, new_oid, "refs/heads/main")

    refute ForgeImports.GitHub.LFSImporter.complete?(item)
  end

  test "standalone completion rejects repository generation drift", %{actor: actor} do
    fixture = import_fixture(actor)
    published = published_scan!(fixture, "generation-drift")
    item = put_scan_checkpoint(fixture.item, fixture.shadow, published)
    assert ForgeImports.GitHub.LFSImporter.complete?(item)

    assert {1, _rows} =
             Repo.update_all(
               from(repository in Repository, where: repository.id == ^fixture.shadow.id),
               set: [generation: fixture.shadow.generation + 1]
             )

    refute ForgeImports.GitHub.LFSImporter.complete?(item)
  end

  test "standalone completion rejects a prepared but unpublished scan", %{actor: actor} do
    fixture = import_fixture(actor)
    {:ok, scan} = PointerScanner.begin_scan(fixture.shadow, "prepared-only", [])
    assert {:ok, prepared} = PointerScanner.prepare_scan(scan)

    item = put_scan_checkpoint(fixture.item, fixture.shadow, prepared)

    refute ForgeImports.GitHub.LFSImporter.complete?(item)
  end

  test "mirror handoff requires a bound organization bootstrap and exact generation", %{
    actor: actor
  } do
    organization = organization_fixture(actor)
    fixture = import_fixture(actor, source_kind: :organization, owner: organization)
    handoff = put_mirror_handoff(fixture.item, fixture.shadow.generation)

    refute ForgeImports.GitHub.LFSImporter.complete?(handoff)

    _mirror = organization_mirror_fixture(actor, organization, fixture.run)
    assert ForgeImports.GitHub.LFSImporter.complete?(handoff)

    refute ForgeImports.GitHub.LFSImporter.complete?(
             put_mirror_handoff(fixture.item, fixture.shadow.generation + 1)
           )
  end

  test "mirror handoff evidence cannot complete a standalone repository import", %{actor: actor} do
    fixture = import_fixture(actor)

    refute ForgeImports.GitHub.LFSImporter.complete?(
             put_mirror_handoff(fixture.item, fixture.shadow.generation)
           )
  end

  defp advance(fixture, opts \\ []) do
    {authorize, opts} = Keyword.pop(opts, :authorize, fn -> :ok end)
    {transfer, opts} = Keyword.pop(opts, :transfer, fn _, _, _ -> {:ok, nil} end)
    opts = Keyword.put_new(opts, :monotonic_time, fn -> 0 end)
    LFSImporter.advance(fixture.item, fixture.run, transfer, authorize, opts)
  end

  defp scan_fixture(actor, commits) do
    fixture = import_fixture(actor)
    tree = git!(fixture.path, ["hash-object", "-t", "tree", "-w", "/dev/null"])

    head =
      Enum.reduce(1..commits, nil, fn n, parent ->
        args = ["commit-tree", tree, "-m", "history #{n}"]
        git!(fixture.path, if(parent, do: args ++ ["-p", parent], else: args))
      end)

    update_ref!(fixture.path, head, "refs/heads/main")
    fixture
  end

  defp done_work(fixture) do
    scan = Repo.get_by!(PointerScanner.Scan, repository_id: fixture.shadow.id)

    Repo.aggregate(
      from(w in PointerScanner.WorkItem, where: w.scan_id == ^scan.id and w.state == :done),
      :count
    )
  end

  defp shared_pointer_fixture(actor) do
    fixture = import_fixture(actor)
    lfs_oid = String.duplicate("a", 64)

    blob =
      write_object!(
        fixture.path,
        "blob",
        "version https://git-lfs.github.com/spec/v1\noid sha256:#{lfs_oid}\nsize 1\n"
      )

    tree =
      write_object!(
        fixture.path,
        "tree",
        "100644 pointer\0" <> Base.decode16!(blob, case: :lower)
      )

    commit = git!(fixture.path, ["commit-tree", tree, "-m", "shared pointer"])

    for ref <- ["refs/heads/main", "refs/heads/shared", "refs/tags/shared"],
        do: update_ref!(fixture.path, commit, ref)

    Map.put(fixture, :lfs_oid, lfs_oid)
  end

  defp write_object!(path, kind, bytes) do
    object_file = Path.join(path, "object-fixture")
    File.write!(object_file, bytes)
    git!(path, ["hash-object", "-t", kind, "-w", object_file])
  end

  defp import_fixture(actor, opts \\ []) do
    source_kind = Keyword.get(opts, :source_kind, :repository)
    owner = Keyword.get(opts, :owner, actor)
    run = run_fixture(actor, owner, source_kind)
    suffix = System.unique_integer([:positive, :monotonic])

    item =
      %{
        import_run_id: run.id,
        github_repository_id: 9_970_000_000 + suffix,
        source_full_name: "acme/lfs-proof-#{suffix}",
        source_name: "lfs-proof-#{suffix}",
        source_metadata: %{"default_branch" => "main", "archived" => false},
        source_observed_at: @now,
        selected: true,
        destination_owner_id: owner.id,
        destination_slug: "lfs-proof-#{suffix}",
        destination_visibility: :private,
        state: :queued,
        attempt_count: 1,
        checkpoint: %{"git_staged" => true}
      }
      |> Persistence.insert_repository_item()
      |> unwrap!()

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, owner.id, %{item_id: item.id, generation: 1})
      |> Repo.transaction()

    path = ForgeRepos.absolute_storage_path(shadow)
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, ^path} = GitCore.init_bare(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)

    item = %{item | hidden_repository_id: shadow.id, staged_storage_path: path}
    %{run: run, item: item, shadow: shadow, path: path}
  end

  defp run_fixture(actor, owner, source_kind) do
    suffix = System.unique_integer([:positive, :monotonic])

    %{
      actor_user_id: actor.id,
      source_kind: source_kind,
      credential_source: :github_app,
      source_owner_github_id: 8_970_000_000 + suffix,
      source_owner_login: "acme-#{suffix}",
      source_repository_github_id: if(source_kind == :repository, do: 9_970_000_000 + suffix),
      source_repository_full_name: if(source_kind == :repository, do: "acme-#{suffix}/lfs-proof"),
      destination_organization_action: :existing,
      destination_organization_slug: owner.username,
      destination_organization_id: if(owner.id == actor.id, do: nil, else: owner.id),
      destination_organization_status: :clean,
      state: :running,
      selected_count: 1,
      request_metadata: %{}
    }
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp published_scan!(fixture, key) do
    {:ok, scan} = PointerScanner.begin_scan(fixture.shadow, key, baselines!(fixture.path))
    {:ok, published} = PointerScanner.publish_scan(scan)
    published
  end

  defp baselines!(path) do
    {:ok, refs} = GitCore.list_refs(path)

    refs
    |> Enum.filter(&(&1.kind in [:branch, :tag]))
    |> Enum.map(&%{ref_name: &1.name, ref_kind: &1.kind, oid: &1.target})
  end

  defp put_scan_checkpoint(item, shadow, scan) do
    evidence = %{
      "status" => "complete",
      "repository_generation" => shadow.generation,
      "scan_id" => scan.id,
      "scan_key" => scan.scan_key,
      "baseline_fingerprint" => scan.baseline_fingerprint,
      "object_cursor" => nil
    }

    %{item | checkpoint: Map.put(item.checkpoint, "lfs_import", evidence)}
  end

  defp put_mirror_handoff(item, generation) do
    evidence = %{"status" => "mirror_handoff", "repository_generation" => generation}
    %{item | checkpoint: Map.put(item.checkpoint, "lfs_import", evidence)}
  end

  defp organization_mirror_fixture(actor, organization, %ImportRun{} = run) do
    pending =
      ForgeMirrors.create_organization_mirror(actor, %{
        organization_id: organization.id,
        provider: "github",
        github_installation_id: 8_980_000_000 + System.unique_integer([:positive]),
        github_account_id: run.source_owner_github_id,
        github_account_login: run.source_owner_login,
        bootstrap_import_run_id: run.id
      })
      |> unwrap!()

    ready =
      ForgeMirrors.transition_organization_mirror(actor, pending, :ready_to_bootstrap)
      |> unwrap!()

    ForgeMirrors.transition_organization_mirror(actor, ready, :bootstrapping) |> unwrap!()
  end

  defp organization_fixture(actor) do
    suffix = System.unique_integer([:positive, :monotonic])

    ForgeAccounts.create_organization(actor, %{
      username: "lfs-proof-org-#{suffix}",
      display_name: "LFS Proof Organization"
    })
    |> unwrap!()
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive, :monotonic])

    ForgeAccounts.create_user(%{
      username: "lfs-proof-#{suffix}",
      email: "lfs-proof-#{suffix}@example.test",
      password: "correct horse battery staple"
    })
    |> unwrap!()
  end

  defp commit!(path, message) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    git!(path, ["commit-tree", tree, "-m", message])
  end

  defp update_ref!(path, oid, ref), do: git!(path, ["update-ref", ref, oid])

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "LFS Importer Test"},
      {"GIT_AUTHOR_EMAIL", "lfs-importer@example.test"},
      {"GIT_COMMITTER_NAME", "LFS Importer Test"},
      {"GIT_COMMITTER_EMAIL", "lfs-importer@example.test"}
    ]

    {output, 0} = System.cmd("git", ["--git-dir", path | args], env: env, stderr_to_stdout: true)
    String.trim(output)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: flunk("expected success, got #{inspect(reason)}")
end
