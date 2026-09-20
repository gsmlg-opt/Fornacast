defmodule ForgeImports.GitHub.LFSImporterTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeImports.{ImportRun, Persistence}
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
