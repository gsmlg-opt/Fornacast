defmodule ForgeImports.PatSyncWorkerTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeImports.{
    ImportRun,
    OrganizationPatSettings,
    PatSyncRun,
    PatSyncWorker,
    RepositoryItem,
    Worker
  }

  alias ForgeImports.TestSupport.{FakeGitHub, GitRemoteFixture}
  alias ForgeMirrors.PatSettings
  alias Fornacast.Repo

  @moduletag :tmp_dir
  @pat "github_pat_sync_worker_test"

  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: tmp_dir} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    n = System.unique_integer([:positive, :monotonic])

    owner =
      Repo.insert!(%User{
        username: "syncworker#{n}",
        email: "syncworker#{n}@test.local",
        password_hash: "unused",
        kind: :user,
        role: :user,
        state: :active
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "sync-org#{n}"})

    {:ok, account} =
      ForgeAccounts.save_github_account(
        owner,
        %{
          github_user_id: n + 1_000_000,
          login: "syncowner#{n}",
          avatar_url: nil,
          profile_url: nil
        },
        @pat,
        %{}
      )

    {:ok, config} =
      PatSettings.save(
        owner,
        org.id,
        %{
          "owner_user_id" => to_string(owner.id),
          "github_identity_id" => to_string(account.identity_id),
          "github_organization" => "source-org",
          "enabled" => "true",
          "lock_version" => "1"
        },
        %{}
      )

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    repos = [
      %{id: n + 10_000, name: "alpha", owner: "source-org"},
      %{id: n + 20_000, name: "beta", owner: "source-org"}
    ]

    stub =
      FakeGitHub.start!(%{
        login: "syncowner#{n}",
        user_id: n + 1_000_000,
        organization: %{"id" => 1, "login" => "source-org"},
        repos: repos
      })

    %{
      owner: owner,
      org: org,
      config: config,
      stub: stub,
      tmp_dir: tmp_dir,
      source: GitRemoteFixture.bare_repo!(tmp_dir)
    }
  end

  test "reports the current import failure and clears it after progress", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    [item | _] =
      Repo.all(
        from(i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, order_by: i.id)
      )

    Repo.update!(Ecto.Changeset.change(item, failure_kind: "request_gate_busy"))
    assert :pending = PatSyncWorker.perform(job.id)
    current = Repo.get!(PatSyncRun, job.id)
    assert current.progress[to_string(item.id)]["error"] == "request_gate_busy"
    Repo.update!(Ecto.Changeset.change(Repo.get!(RepositoryItem, item.id), failure_kind: nil))
    assert :pending = PatSyncWorker.perform(job.id)
    assert Repo.get!(PatSyncRun, job.id).progress[to_string(item.id)]["error"] == nil

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(RepositoryItem, item.id),
        state: :failed,
        failure_kind: "corrupt_repository"
      )
    )

    assert :pending = PatSyncWorker.perform(job.id)

    assert Repo.get!(PatSyncRun, job.id).progress[to_string(item.id)]["error"] ==
             "corrupt_repository"
  end

  test "another sync retries failed imports and retains completed repository updates", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    [alpha, beta] =
      Repo.all(
        from i in RepositoryItem,
          where: i.import_run_id == ^job.import_run_id,
          order_by: i.source_name
      )

    complete_item!(alpha, c)
    alpha = Repo.get!(RepositoryItem, alpha.id)
    repository = Repo.get!(ForgeRepos.Repository, alpha.hidden_repository_id)

    succeeded_update = %{
      "github_repository_id" => alpha.github_repository_id,
      "source_full_name" => alpha.source_full_name,
      "mode" => "update",
      "status" => "succeeded",
      "repository_id" => repository.id,
      "generation" => repository.generation
    }

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(PatSyncRun, job.id),
        progress: Map.put(job.progress, to_string(alpha.id), succeeded_update)
      )
    )

    Repo.update!(
      Ecto.Changeset.change(beta,
        state: :failed,
        failure_kind: "corrupt_repository",
        failure_count: 1
      )
    )

    assert {:ok, _} = ForgeImports.RunAggregator.finish_if_terminal(job.import_run_id)
    assert {:error, :repository_sync_failed} = PatSyncWorker.perform(job.id)

    assert {:ok, retry} =
             OrganizationPatSettings.sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert retry.id != job.id
    assert retry.import_run_id != nil
    successor = Repo.get!(ImportRun, retry.import_run_id)
    previous = Repo.get!(ImportRun, job.import_run_id)
    assert successor.predecessor_run_id == previous.id
    assert successor.credential_source == :saved
    assert successor.github_identity_id == previous.github_identity_id
    assert successor.github_credential_id == previous.github_credential_id
    assert successor.request_metadata["operation_id"] == "organization-pat-sync-#{retry.id}"
    assert [retried] = Repo.all(from i in RepositoryItem, where: i.import_run_id == ^successor.id)
    assert retried.predecessor_item_id == beta.id
    assert retry.progress[to_string(alpha.id)] == succeeded_update
    assert %{"mode" => "import", "status" => "pending"} = retry.progress[to_string(retried.id)]
    refute Map.has_key?(retry.progress, to_string(beta.id))

    assert {:ok, same} =
             OrganizationPatSettings.sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert same.id == retry.id
    assert :pending = PatSyncWorker.perform(retry.id)
    assert Repo.get!(ImportRun, successor.id).state == :running
    complete_item!(retried, c)
    assert :ok = PatSyncWorker.perform(retry.id)
    assert Repo.get!(PatSyncRun, retry.id).state == "succeeded"

    assert {:ok, %{config: %{last_sync_summary: %{"total" => 2, "succeeded" => 2}}}} =
             PatSettings.view(c.owner, c.org.id)
  end

  test "sync reports durable release asset progress in its saved summary", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    item =
      Repo.one!(from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, limit: 1)

    assert {:ok, _} =
             Worker.run(item.id, "asset-progress-stage",
               repository_worker_options: [
                 remote: GitRemoteFixture.mirror_remote_module(),
                 remote_options: [source: c.source, expected_pat: @pat],
                 client_options: Keyword.delete(FakeGitHub.client_opts(c.stub), :gate_key)
               ]
             )

    item = Repo.get!(RepositoryItem, item.id)
    Repo.update!(Ecto.Changeset.change(item, state: :staging_metadata))

    for {kind, id, evidence} <- [
          {"release", 42, %{"asset_count" => 3}},
          {"release_asset", 43, %{}}
        ] do
      Repo.insert!(%ForgeImports.ObjectMapping{
        repository_item_id: item.id,
        hidden_repository_id: item.hidden_repository_id,
        github_repository_id: item.github_repository_id,
        object_kind: kind,
        github_object_id: id,
        local_resource_type: kind,
        local_resource_id: id,
        source_evidence: evidence
      })
    end

    assert :pending = PatSyncWorker.perform(job.id)
    expected = %{"phase" => "release_assets", "completed" => 1, "total" => 3}
    assert Repo.get!(PatSyncRun, job.id).progress[to_string(item.id)]["progress"] == expected

    assert {:ok, %{config: %{last_sync_summary: %{"repositories" => rows}}}} =
             PatSettings.view(c.owner, c.org.id)

    assert Enum.find(rows, &(&1["source_full_name"] == item.source_full_name))["progress"] ==
             expected
  end

  test "restart fences active imports and carries staged metadata and LFS work into the successor",
       c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    [item | _] =
      Repo.all(
        from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, order_by: i.id
      )

    clock = make_ref()

    options = [
      repository_worker_options: [
        remote: GitRemoteFixture.mirror_remote_module(),
        remote_options: [source: c.source, expected_pat: @pat],
        client_options: Keyword.delete(FakeGitHub.client_opts(c.stub), :gate_key),
        lfs_options: [
          monotonic_time: fn ->
            value = Process.get(clock, 0)
            Process.put(clock, value + 250)
            value
          end
        ]
      ]
    ]

    for _ <- 1..2, do: assert({:ok, _} = Worker.run(item.id, "staged-restart", options))
    item = Repo.get!(RepositoryItem, item.id)
    assert %{"scan_id" => scan_id} = item.checkpoint["lfs_import"]

    assert Repo.aggregate(
             from(w in GitLFS.PointerScanner.WorkItem,
               where: w.scan_id == ^scan_id and w.state == :done
             ),
             :count
           ) == 1

    pages =
      Repo.aggregate(
        from(p in ForgeImports.PageCheckpoint, where: p.repository_item_id == ^item.id),
        :count
      )

    assert pages > 0

    assert {:ok, capability} =
             Fornacast.OperationLease.claim(
               RepositoryItem,
               item.id,
               "old-worker",
               DateTime.utc_now(:second),
               600,
               allowed_states: [:staging_metadata]
             )

    assert {:ok, replacement} =
             OrganizationPatSettings.restart_sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert replacement.id != job.id
    assert Repo.get!(PatSyncRun, job.id).state == "failed"
    assert Repo.get!(ImportRun, job.import_run_id).state == :canceled
    assert Repo.get!(RepositoryItem, item.id).state == :canceled
    assert Repo.get!(RepositoryItem, item.id).lease_owner == nil

    assert {:error, :lost_lease} =
             Fornacast.OperationLease.update_owned(RepositoryItem, capability,
               failure_kind: "late-worker"
             )

    successor =
      Repo.one!(
        from i in RepositoryItem,
          where:
            i.import_run_id == ^replacement.import_run_id and i.predecessor_item_id == ^item.id
      )

    assert successor.hidden_repository_id == item.hidden_repository_id
    assert successor.checkpoint == item.checkpoint

    assert Repo.aggregate(
             from(p in ForgeImports.PageCheckpoint, where: p.repository_item_id == ^successor.id),
             :count
           ) == pages

    assert Repo.aggregate(
             from(o in ForgeImports.CleanupOperation, where: o.repository_item_id == ^item.id),
             :count
           ) == 0

    assert :pending = PatSyncWorker.perform(replacement.id)
    assert Repo.get!(RepositoryItem, successor.id).attempt_count == 1
    assert {:ok, _} = Worker.run(successor.id, "resumed-restart", options)
    assert Repo.get!(RepositoryItem, successor.id).checkpoint["lfs_import"]["scan_id"] == scan_id

    assert Repo.aggregate(
             from(w in GitLFS.PointerScanner.WorkItem,
               where: w.scan_id == ^scan_id and w.state == :done
             ),
             :count
           ) == 2
  end

  test "restart preserves a repository published after the last progress poll", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    [published, pending] =
      Repo.all(
        from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, order_by: i.id
      )

    assert job.progress[to_string(published.id)]["status"] == "pending"
    complete_item!(published, c)

    assert {:ok, replacement} =
             OrganizationPatSettings.restart_sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert map_size(replacement.progress) == 2
    retained = replacement.progress[to_string(published.id)]
    assert retained["status"] == "succeeded"
    assert retained["source_full_name"] == published.source_full_name

    assert [successor] =
             Repo.all(
               from i in RepositoryItem, where: i.import_run_id == ^replacement.import_run_id
             )

    assert successor.predecessor_item_id == pending.id
    assert replacement.progress[to_string(successor.id)]["status"] == "pending"

    assert :pending = PatSyncWorker.perform(replacement.id)

    assert {:ok, second} =
             OrganizationPatSettings.restart_sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert map_size(second.progress) == 2
    assert second.progress[to_string(published.id)]["status"] == "succeeded"

    # Repair jobs already created by the old direct-predecessor-only reconstruction.
    second
    |> Ecto.Changeset.change(progress: Map.delete(second.progress, to_string(published.id)))
    |> Repo.update!()

    assert :pending = PatSyncWorker.perform(second.id)
    assert :pending = PatSyncWorker.perform(second.id)

    assert Repo.get!(PatSyncRun, second.id).progress[to_string(published.id)]["status"] ==
             "succeeded"

    assert Repo.get!(ForgeMirrors.PatConfiguration, c.config.id).last_sync_summary["total"] == 2
  end

  test "ancestor results reject foreign lineage, invalid publication and changed live repository",
       c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    [published, _] =
      Repo.all(
        from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, order_by: i.id
      )

    complete_item!(published, c)
    published = Repo.get!(RepositoryItem, published.id)
    ancestor = Repo.get!(ImportRun, job.import_run_id)
    repository = Repo.get!(ForgeRepos.Repository, published.hidden_repository_id)

    assert {:ok, replacement} =
             OrganizationPatSettings.restart_sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert :pending = PatSyncWorker.perform(replacement.id)

    current_item =
      Repo.one!(from i in RepositoryItem, where: i.import_run_id == ^replacement.import_run_id)

    complete_item!(current_item, c)

    foreign_identity =
      %ForgeAccounts.GitHubIdentity{}
      |> ForgeAccounts.GitHubIdentity.observed_changeset(%{
        github_user_id: System.unique_integer([:positive]) + 90_000_000,
        login: "foreign-source"
      })
      |> Repo.insert!()

    for {record, attrs} <- [
          {ancestor, [source_owner_login: "foreign-org"]},
          {ancestor, [source_owner_github_id: ancestor.source_owner_github_id + 1]},
          {ancestor, [actor_user_id: c.org.id]},
          {ancestor, [github_identity_id: foreign_identity.id]},
          {ancestor, [destination_organization_id: c.owner.id]},
          {published,
           [
             publication_evidence:
               Map.put(published.publication_evidence, "run_id", ancestor.id + 1)
           ]},
          {published,
           [publication_evidence: Map.delete(published.publication_evidence, "operation_id")]},
          {repository, [owner_user_id: c.owner.id]},
          {repository, [generation: repository.generation + 1]},
          {repository, [lifecycle: :importing]}
        ] do
      original = Repo.get!(record.__struct__, record.id)
      original |> Ecto.Changeset.change(attrs) |> Repo.update!()
      # A previous succeeded string must never replace durable proof.
      current = Repo.get!(PatSyncRun, replacement.id)

      forged = %{
        "mode" => "import",
        "status" => "succeeded",
        "source_full_name" => published.source_full_name,
        "github_repository_id" => published.github_repository_id
      }

      progress = Map.delete(current.progress, to_string(published.id))

      progress =
        if record.__struct__ == ImportRun,
          do: progress,
          else: Map.put(progress, to_string(published.id), forged)

      current |> Ecto.Changeset.change(progress: progress) |> Repo.update!()

      if record.__struct__ == ImportRun do
        assert {:error, :invalid_import_lineage} = PatSyncWorker.perform(replacement.id)

        refute Map.has_key?(
                 Repo.get!(PatSyncRun, replacement.id).progress,
                 to_string(published.id)
               )
      else
        assert {:error, :repository_sync_failed} = PatSyncWorker.perform(replacement.id)
        rejected = Repo.get!(PatSyncRun, replacement.id).progress[to_string(published.id)]
        assert rejected["status"] == "failed"
        assert rejected["error"] == "publication_inconsistent"
      end

      assert Repo.get!(PatSyncRun, replacement.id).state == "failed"
      current_record = Repo.get!(record.__struct__, record.id)
      restored = Enum.map(attrs, fn {key, _} -> {key, Map.fetch!(original, key)} end)
      current_record |> Ecto.Changeset.change(restored) |> Repo.update!()

      Repo.get!(PatSyncRun, replacement.id)
      |> Ecto.Changeset.change(state: "running", error: nil, finished_at: nil)
      |> Repo.update!()
    end

    assert :ok = PatSyncWorker.perform(replacement.id)
    assert Repo.get!(PatSyncRun, replacement.id).state == "succeeded"

    assert Repo.get!(PatSyncRun, replacement.id).progress[to_string(published.id)]["status"] ==
             "succeeded"
  end

  test "sync acquires lifecycle user locks before configuration and job locks", c do
    reference = make_ref()
    handler = {__MODULE__, reference}
    prefix = Repo.config()[:telemetry_prefix] || [:fornacast, :repo]

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:query],
        fn _event, _measurements, metadata, {caller, ref} ->
          if self() == caller and is_binary(metadata.query) and
               String.contains?(metadata.query, "FOR UPDATE") do
            case Regex.run(~r/FROM "([^"]+)"/, metadata.query) do
              [_, table] -> send(caller, {ref, table})
              _ -> :ok
            end
          end
        end,
        {self(), reference}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} =
             OrganizationPatSettings.sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    tables =
      Enum.map(1..2, fn _ ->
        receive do
          {^reference, table} -> table
        after
          1_000 -> flunk("missing lifecycle lock")
        end
      end)

    assert tables == ["users", "organization_pat_configurations"]
  end

  test "restart rejects a publication in progress without changing the job or run", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    item =
      Repo.one!(from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, limit: 1)

    complete_item!(item, c)
    Repo.update!(Ecto.Changeset.change(Repo.get!(RepositoryItem, item.id), state: :publishing))

    assert {:error, :busy} =
             OrganizationPatSettings.restart_sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{},
               dispatch: :manual
             )

    assert Repo.get!(PatSyncRun, job.id).state == "running"
    assert Repo.get!(ImportRun, job.import_run_id).state == :running
    refute Repo.exists?(from r in ImportRun, where: r.predecessor_run_id == ^job.import_run_id)
  end

  test "one click imports every visible repository without a review step even with saved selected scope",
       c do
    {:ok, config} =
      PatSettings.store_inventory(
        c.owner,
        c.org.id,
        to_string(c.config.lock_version),
        %{
          "repositories" => [
            %{"id" => 1, "full_name" => "source-org/unused", "visibility" => "public"}
          ]
        },
        %{}
      )

    {:ok, config} =
      PatSettings.select_repositories(
        c.owner,
        c.org.id,
        %{
          "lock_version" => to_string(config.lock_version),
          "repository_selection" => "selected",
          "selected_repository_ids" => ["1"]
        },
        %{}
      )

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    job = Repo.get!(PatSyncRun, job.id)

    assert %ImportRun{state: :awaiting_resolution, selected_count: 2} =
             Repo.get!(ImportRun, job.import_run_id)

    assert :pending = PatSyncWorker.perform(job.id)
    assert %ImportRun{state: :running} = Repo.get!(ImportRun, job.import_run_id)

    assert [alpha, beta] =
             Repo.all(
               from i in RepositoryItem,
                 where: i.import_run_id == ^job.import_run_id,
                 order_by: [asc: i.source_name]
             )

    assert alpha.source_name == "alpha"
    assert beta.source_name == "beta"

    for item <- [alpha, beta] do
      complete_item!(item, c)
    end

    assert :ok = PatSyncWorker.perform(job.id)
    assert %{state: "succeeded", progress: progress} = Repo.get!(PatSyncRun, job.id)
    assert Enum.all?(progress, fn {_id, row} -> row["status"] == "succeeded" end)

    assert {:ok,
            %{
              config: %{
                last_sync_status: "succeeded",
                last_sync_summary: %{"total" => 2, "succeeded" => 2}
              }
            }} =
             PatSettings.view(c.owner, c.org.id)

    for item <- [alpha, beta] do
      published = Repo.get!(RepositoryItem, item.id)
      assert {:ok, repo} = ForgeRepos.fetch_live_repository(published.hidden_repository_id)

      assert {:ok, oid} =
               GitCore.exact_ref(ForgeRepos.absolute_storage_path(repo), "refs/heads/main")

      assert {:ok, contents} =
               GitCore.read_blob(ForgeRepos.absolute_storage_path(repo), oid, "README.md")

      assert contents.data == "# Imported repository\n"
    end
  end

  test "expired leases resume and unknown name collisions fail individually while other repositories import",
       c do
    {:ok, conflict} = ForgeRepos.create_repository(c.org, %{slug: "alpha", name: "alpha"})

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    Repo.update!(
      Ecto.Changeset.change(job,
        lease_owner: "stopped-worker",
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)
      )
    )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    assert %{"mode" => "conflict", "status" => "failed"} =
             Enum.find_value(job.progress, fn {_id, row} ->
               if row["source_full_name"] == "source-org/alpha", do: row
             end)

    beta =
      Repo.one!(
        from i in RepositoryItem,
          where: i.import_run_id == ^job.import_run_id and i.source_name == "beta"
      )

    complete_item!(beta, c)
    assert {:error, :repository_sync_failed} = PatSyncWorker.perform(job.id)

    assert {:ok,
            %{
              config: %{
                last_sync_status: "failed",
                last_sync_summary: %{"total" => 2, "succeeded" => 1, "failed" => 1}
              }
            }} =
             PatSettings.view(c.owner, c.org.id)

    assert Repo.get!(ForgeRepos.Repository, conflict.id).generation == conflict.generation
  end

  test "restart after conflict decisions preserves the original plan", c do
    {:ok, _} = ForgeRepos.create_repository(c.org, %{slug: "alpha", name: "alpha"})

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    job = Repo.get!(PatSyncRun, job.id)

    alpha =
      Repo.one!(
        from i in RepositoryItem,
          where: i.import_run_id == ^job.import_run_id and i.source_name == "alpha"
      )

    row = %{
      "github_repository_id" => alpha.github_repository_id,
      "source_full_name" => alpha.source_full_name,
      "mode" => "conflict",
      "status" => "failed",
      "error" => "repository_conflict"
    }

    Repo.update!(Ecto.Changeset.change(job, progress: %{to_string(alpha.id) => row}))

    assert {:ok, _} =
             ForgeImports.resolve_repository_conflicts(
               c.owner,
               job.import_run_id,
               %{to_string(alpha.id) => %{action: :skip}},
               %{}
             )

    assert :pending = PatSyncWorker.perform(job.id)
    assert Repo.get!(PatSyncRun, job.id).progress[to_string(alpha.id)] == row
    assert Repo.get!(RepositoryItem, alpha.id).state == :skipped
  end

  test "an empty organization settles successfully without leaving a discovery active", c do
    stub =
      FakeGitHub.start!(%{
        login: "emptyowner",
        user_id: 999,
        organization: %{"id" => 1, "login" => "source-org"},
        repos: []
      })

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending =
             PatSyncWorker.perform(job.id,
               discovery_options: discovery_options(%{c | stub: stub})
             )

    assert :ok = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)
    assert job.state == "succeeded"
    assert Repo.get!(ImportRun, job.import_run_id).state in [:completed, :canceled]
  end

  test "subsequent clicks update bound repositories and finish even when there are no new imports",
       c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    for item <- Repo.all(from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id),
        do: complete_item!(item, c)

    assert :ok = PatSyncWorker.perform(job.id)

    work = Path.join(c.tmp_dir, "incremental-source")
    git!(["clone", c.source, work])
    File.write!(Path.join(work, "README.md"), "updated on GitHub\n")
    git!(["add", "."], work)
    git!(["commit", "-m", "new remote contents"], work)
    git!(["push", "origin", "main"], work)
    remote_oid = GitRemoteFixture.head_sha!(c.source)

    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)

    assert :pending =
             PatSyncWorker.perform(job.id,
               sync_repository: fn _, _, _, _, _ -> {:error, :request_gate_busy} end
             )

    pending = Repo.get!(PatSyncRun, job.id)

    busy_row =
      Enum.find_value(pending.progress, fn {id, row} ->
        if row["error"] == "request_gate_busy", do: {id, row}
      end)

    assert {id, %{"status" => "pending"} = row} = busy_row

    Repo.update!(
      Ecto.Changeset.change(pending,
        progress:
          Map.put(
            pending.progress,
            id,
            row |> Map.put("retry_after", 0) |> Map.put("status", "failed")
          )
      )
    )

    for _ <- 1..2,
        do:
          assert(
            :pending =
              PatSyncWorker.perform(job.id,
                sync_repository: fn owner, config, repo, name, opts ->
                  item =
                    Repo.one!(
                      from i in RepositoryItem,
                        where:
                          i.hidden_repository_id == ^repo.id and
                            i.state in [:published, :completed],
                        limit: 1
                    )

                  ForgeImports.PatRepositorySync.sync(
                    owner,
                    config,
                    repo,
                    name,
                    opts ++
                      [
                        fetch_refs: local_fetch(c),
                        lookup_repository: fn _, _, _, _ ->
                          {:ok, %{id: item.github_repository_id, owner_login: "source-org"}}
                        end
                      ]
                  )
                end
              )
          )

    assert :ok = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)
    assert job.state == "succeeded"

    for {_id, row} <- job.progress do
      assert row["mode"] == "update"
      repo = Repo.get!(ForgeRepos.Repository, row["repository_id"])

      assert {:ok, ^remote_oid} =
               GitCore.exact_ref(ForgeRepos.absolute_storage_path(repo), "refs/heads/main")

      assert {:ok, %{data: "updated on GitHub\n"}} =
               GitCore.read_blob(ForgeRepos.absolute_storage_path(repo), remote_oid, "README.md")
    end
  end

  test "owner revocation settles the durable job and visible status as failed", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    Repo.delete_all(
      from m in ForgeAccounts.OrganizationMember,
        where: m.organization_id == ^c.org.id and m.user_id == ^c.owner.id
    )

    assert {:error, _} = PatSyncWorker.perform(job.id)
    assert Repo.get!(PatSyncRun, job.id).state == "failed"
    assert Repo.get!(ForgeMirrors.PatConfiguration, c.config.id).last_sync_status == "failed"
  end

  test "pause and source changes fence newly discovered imports before any Git transfer", c do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{},
        dispatch: :manual
      )

    assert :pending = PatSyncWorker.perform(job.id, discovery_options: discovery_options(c))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    item =
      Repo.one!(from i in RepositoryItem, where: i.import_run_id == ^job.import_run_id, limit: 1)

    assert {:ok, _} = PatSettings.set_paused(c.owner, c.org.id, true, %{})
    assert {:error, :paused} = Worker.run(item.id, "paused-sync-test")
    assert {:ok, _} = PatSettings.set_paused(c.owner, c.org.id, false, %{})

    assert {:ok, _} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{
                 "github_organization" => "another-source",
                 "lock_version" => to_string(c.config.lock_version)
               },
               %{}
             )

    assert {:error, :configuration_changed} = Worker.run(item.id, "changed-sync-test")
  end

  defp local_fetch(c) do
    fn request, token, namespace ->
      assert token == @pat
      git!(["--git-dir=" <> request.repository_path, "fetch", "--no-tags", c.source, "HEAD"])

      refs =
        git!([
          "--git-dir=" <> c.source,
          "for-each-ref",
          "--format=%(refname) %(objectname)",
          "refs/heads",
          "refs/tags"
        ])

      {:ok,
       for line <- String.split(refs, "\n", trim: true) do
         [ref, oid] = String.split(line, " ")
         {:ok, tracking} = GitCore.tracking_ref_name(namespace, ref)
         git!(["--git-dir=" <> request.repository_path, "update-ref", tracking, oid])
         %GitCore.Remote.ObservedRef{ref: ref, oid: oid}
       end}
    end
  end

  defp git!(args, directory \\ File.cwd!()) do
    {output, code} =
      System.cmd("git", args,
        cd: directory,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "PAT sync"},
          {"GIT_COMMITTER_NAME", "PAT sync"},
          {"GIT_AUTHOR_EMAIL", "pat@example.test"},
          {"GIT_COMMITTER_EMAIL", "pat@example.test"}
        ]
      )

    assert code == 0, output
    String.trim(output)
  end

  defp discovery_options(c),
    do: [
      dispatch: :inline,
      client_options: Keyword.delete(FakeGitHub.client_opts(c.stub), :gate_key)
    ]

  defp complete_item!(item, c) do
    options = [
      repository_worker_options: [
        remote: GitRemoteFixture.mirror_remote_module(),
        remote_options: [source: c.source, expected_pat: @pat],
        client_options: Keyword.delete(FakeGitHub.client_opts(c.stub), :gate_key)
      ]
    ]

    Enum.reduce_while(1..20, nil, fn _, _ ->
      current = Repo.get!(RepositoryItem, item.id)

      if current.state in [:published, :completed] do
        {:halt, current}
      else
        result = Worker.run(item.id, "pat-sync-test", options)
        assert match?({:ok, _}, result), inspect(result)
        {:cont, result}
      end
    end)

    assert Repo.get!(RepositoryItem, item.id).state in [:published, :completed]
  end
end
