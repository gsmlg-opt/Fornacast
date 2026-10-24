defmodule ForgeImports.PublicOrganizationWorkerTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Fornacast.Repo
  alias ForgeAccounts.User

  alias ForgeImports.{
    ImportRun,
    OrganizationPublicSync,
    PatSyncRun,
    PatSyncWorker,
    RepositoryItem,
    Worker
  }

  alias ForgeImports.TestSupport.{FakeGitHub, GitRemoteFixture}
  @moduletag :tmp_dir
  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: tmp_dir} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        username: "publicworker#{n}",
        email: "publicworker#{n}@test.local",
        password_hash: "unused"
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "public-worker#{n}"})

    stub =
      FakeGitHub.start!(%{
        organization: %{"id" => 1, "login" => "source-org"},
        repos: [%{id: 501, name: "project", owner: "source-org", visibility: "public"}]
      })

    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repositories"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)
    payload = "anonymous public LFS object bytes"

    %{
      owner: owner,
      org: org,
      stub: stub,
      tmp_dir: tmp_dir,
      payload: payload,
      source:
        GitRemoteFixture.bare_repo!(tmp_dir, extra_files: [{"asset.bin", lfs_pointer(payload)}])
    }
  end

  test "anonymous first import publishes Git metadata and LFS, adopts manual config, and next sync fast forwards",
       c do
    run = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    finish_item(c, item)
    assert Repo.get!(ImportRun, run.id).state == :completed
    published = Repo.get!(RepositoryItem, item.id)
    assert published.publication_evidence["state"] == "committed"
    assert {:ok, repository} = ForgeRepos.fetch_live_repository(published.hidden_repository_id)
    assert repository.owner_user_id == c.org.id
    oid = lfs_oid(c.payload)
    assert :ok = GitLFS.verify_object(repository, oid, byte_size(c.payload))
    assert {:ok, object, _} = GitLFS.open_object(repository, oid, byte_size(c.payload), :all)
    assert {:ok, payload, object} = GitLFS.read(object, byte_size(c.payload))
    assert payload == c.payload
    assert :ok = GitLFS.close(object)
    config = Repo.get_by!(ForgeMirrors.PatConfiguration, organization_id: c.org.id)
    assert config.credential_source == :public
    assert config.trigger_mode == "manual"
    assert config.github_organization_id == 1
    target = advance_remote(c)

    assert {:ok, job} =
             OrganizationPublicSync.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    Repo.delete_all(
      from member in ForgeAccounts.OrganizationMember,
        where: member.organization_id == ^c.org.id and member.user_id == ^c.owner.id
    )

    Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))
    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(job.import_run_id, "public-second-discovery",
               client_options: provider_options(c)
             )

    assert :pending = PatSyncWorker.perform(job.id)

    Enum.reduce_while(1..8, nil, fn _, _ ->
      result = PatSyncWorker.perform(job.id, repository_options: repository_options(c))

      if Repo.get!(PatSyncRun, job.id).state == "succeeded",
        do: {:halt, result},
        else:
          (
            assert result == :pending, inspect(result)
            {:cont, result}
          )
    end)

    assert Repo.get!(PatSyncRun, job.id).state == "succeeded"
    assert {:ok, updated} = ForgeRepos.fetch_live_repository(repository.id)
    assert updated.generation == repository.generation
    assert updated.write_version > repository.write_version

    assert {:ok, ^target} =
             GitCore.exact_ref(ForgeRepos.absolute_storage_path(updated), "refs/heads/main")

    assert :ok = GitLFS.verify_object(updated, oid, byte_size(c.payload))
    refute Repo.exists?(ForgeAccounts.GitHubIdentity)
    refute Repo.exists?(ForgeAccounts.GitHubCredential)
    refute Repo.exists?(ForgeAccounts.OrganizationGitHubCredential)
  end

  test "public visibility change after staging prevents publication", c do
    run = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    stage_until(c, item, :ready_to_publish)

    private_stub =
      FakeGitHub.start!(%{
        repos: [%{id: 501, name: "project", owner: "source-org", visibility: "private"}]
      })

    ForgeImports.SyncJobs.Execution.with_options(
      [publication: FakeGitHub.client_opts(private_stub)],
      fn ->
        assert {:error, _} = Worker.run(item.id, "public-publish", worker_options(c))
      end
    )

    current = Repo.get!(RepositoryItem, item.id)
    refute current.state in [:published, :completed]
    assert Repo.get!(ForgeRepos.Repository, current.hidden_repository_id).lifecycle == :importing
  end

  test "anonymous retry preserves public authority and publishes a successor", c do
    run = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    Repo.update!(Ecto.Changeset.change(item, state: :failed, failure_kind: "corrupt_repository"))
    assert {:ok, %{state: :failed}} = ForgeImports.RunAggregator.finish_if_terminal(run.id)
    assert {:ok, successor} = ForgeImports.retry_import(c.owner, run.id, :public, %{})
    assert successor.source.credential_source == :public
    assert successor.predecessor_run_id == run.id
    assert {:ok, _} = ForgeImports.start_import(c.owner, successor.id, %{})

    [next_item] =
      Repo.all(from item in RepositoryItem, where: item.import_run_id == ^successor.id)

    finish_item(c, next_item)
    assert Repo.get!(ImportRun, successor.id).state == :completed
    assert Repo.get!(ImportRun, run.id).state == :failed
  end

  test "anonymous discovery cancellation uses the existing terminal path", c do
    assert {:ok, view} =
             ForgeImports.create_organization_discovery(
               c.owner,
               %{
                 organization: "source-org",
                 credential_source: :public,
                 destination_organization: %{action: :existing, id: c.org.id}
               },
               %{}
             )

    run = Repo.get!(ImportRun, view.id)
    assert {:ok, %{state: :canceled}} = ForgeImports.Cancellation.request(c.owner, run, %{})
    assert {:ok, :ignored} = Worker.run_discovery(run.id, "public-canceled")
    refute Repo.exists?(RepositoryItem)
  end

  test "pause during public checkout retains the phase and resumes without credentials", c do
    {job, item} = begin_configured_import(c)

    pause = fn ->
      assert {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.owner, c.org.id, true, %{})
    end

    options = worker_options(c)
    inner = options[:repository_worker_options]

    inner =
      Keyword.merge(inner,
        client: __MODULE__.PausingClient,
        client_options: Keyword.put(provider_options(c), :pause, pause)
      )

    assert {:error, :paused} =
             Worker.run(item.id, "public-pause", repository_worker_options: inner)

    current = Repo.get!(RepositoryItem, item.id)
    assert current.state == :staging_git
    assert current.failure_kind == "paused"
    assert is_nil(current.lease_owner)
    assert Repo.get!(ImportRun, job.import_run_id).state == :running
    assert {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.owner, c.org.id, false, %{})
    Repo.update!(Ecto.Changeset.change(current, next_attempt_at: nil))
    finish_item(c, current)
    assert Repo.get!(ImportRun, job.import_run_id).state == :completed
  end

  test "required public LFS authentication fails explicitly without publication", c do
    run = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    stage_until(c, item, :git_staged)

    callbacks =
      Map.put(lfs_callbacks(c), :batch, fn :public, _, _, _, _, _ ->
        {:error, ForgeGitHub.Error.new(:forbidden)}
      end)

    inner =
      Keyword.put(worker_options(c)[:repository_worker_options], :lfs_transfer_options,
        callbacks: callbacks
      )

    Enum.reduce_while(1..20, nil, fn _, _ ->
      current = Repo.get!(RepositoryItem, item.id)

      if current.state == :failed,
        do: {:halt, nil},
        else:
          (
            assert {:ok, _} = Worker.run(item.id, "public-auth", repository_worker_options: inner)
            {:cont, nil}
          )
    end)

    current = Repo.get!(RepositoryItem, item.id)
    assert current.state == :failed
    assert current.failure_kind == "public_authorization_required"
    assert current.failure_detail =~ "GitHub App"
    assert Repo.get!(ImportRun, run.id).state == :failed
    assert Repo.get!(ForgeRepos.Repository, current.hidden_repository_id).lifecycle == :importing
    refute current.publication_evidence["state"] == "committed"
  end

  test "public visibility changing during LFS prevents subsequent ref publication", c do
    run = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    finish_item(c, item)
    published = Repo.get!(RepositoryItem, item.id)
    assert {:ok, repository} = ForgeRepos.fetch_live_repository(published.hidden_repository_id)
    config = Repo.get_by!(ForgeMirrors.PatConfiguration, organization_id: c.org.id)
    path = ForgeRepos.absolute_storage_path(repository)
    assert {:ok, old_oid} = GitCore.exact_ref(path, "refs/heads/main")

    next =
      Map.put(%{c | payload: "a different required public LFS object"}, :payloads, [
        c.payload,
        "a different required public LFS object"
      ])

    target = advance_remote(next)
    assert target != old_oid

    assert {:ok, job} =
             OrganizationPublicSync.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    assert {:ok, execution} = ForgeImports.OrganizationExecution.for_sync(job)
    {:ok, visibility} = Agent.start_link(fn -> :public end)
    options = repository_options(next)
    lookup = options[:lookup_repository]
    batch = lfs_callbacks(next).batch

    callbacks =
      Map.put(lfs_callbacks(next), :batch, fn token, owner, name, operation, objects, opts ->
        result = batch.(token, owner, name, operation, objects, opts)
        Agent.update(visibility, fn _ -> :private end)
        result
      end)

    options =
      Keyword.merge(options,
        github_repository_id: 501,
        lookup_repository: fn token, owner, name, opts ->
          {:ok, source} = lookup.(token, owner, name, opts)
          {:ok, %{source | visibility: Agent.get(visibility, & &1)}}
        end,
        lfs_transfer_options: [callbacks: callbacks]
      )

    assert {:error, :source_changed} =
             ForgeImports.PatRepositorySync.sync(
               execution,
               config,
               repository,
               "source-org/project",
               options
             )

    assert Agent.get(visibility, & &1) == :private
    assert {:ok, ^old_oid} = GitCore.exact_ref(path, "refs/heads/main")

    assert Repo.get!(ForgeRepos.Repository, repository.id).write_version ==
             repository.write_version
  end

  defmodule PausingClient do
    def repository(:public, owner, repository, opts) do
      Keyword.fetch!(opts, :pause).()
      ForgeGitHub.Client.repository(:public, owner, repository, Keyword.delete(opts, :pause))
    end
  end

  defp begin_configured_import(c) do
    assert {:ok, config} =
             OrganizationPublicSync.configure(
               c.owner,
               c.org.id,
               %{"github_organization" => "source-org", "lock_version" => "0"},
               %{},
               client_options: provider_options(c)
             )

    assert {:ok, job} =
             OrganizationPublicSync.sync(c.owner, c.org.id, to_string(config.lock_version), %{})

    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(job.import_run_id, "public-discovery",
               client_options: provider_options(c)
             )

    assert :pending = PatSyncWorker.perform(job.id)

    [item] =
      Repo.all(from item in RepositoryItem, where: item.import_run_id == ^job.import_run_id)

    {job, item}
  end

  defp begin_import(c) do
    assert {:ok, view} =
             ForgeImports.create_organization_discovery(
               c.owner,
               %{
                 organization: "source-org",
                 credential_source: :public,
                 destination_organization: %{action: :existing, id: c.org.id}
               },
               %{},
               dispatch: :inline,
               client_options: provider_options(c)
             )

    assert view.state == :awaiting_resolution
    assert {:ok, _} = ForgeImports.start_import(c.owner, view.id, %{})
    Repo.get!(ImportRun, view.id)
  end

  defp finish_item(c, item) do
    stage_until(c, item, :ready_to_publish)

    ForgeImports.SyncJobs.Execution.with_options([publication: provider_options(c)], fn ->
      assert {:ok, _} = Worker.run(item.id, "organization-test", worker_options(c))
    end)

    assert Repo.get!(RepositoryItem, item.id).state in [:published, :completed]
  end

  defp stage_until(c, item, target) do
    Enum.reduce_while(1..30, nil, fn _, _ ->
      current = Repo.get!(RepositoryItem, item.id)

      if current.state == target,
        do: {:halt, current},
        else:
          (
            result = Worker.run(item.id, "organization-test", worker_options(c))

            assert match?({:ok, _}, result),
                   inspect({current.state, result, Repo.get!(RepositoryItem, item.id).checkpoint})

            {:cont, result}
          )
    end)

    assert Repo.get!(RepositoryItem, item.id).state == target
  end

  defp advance_remote(c) do
    work = Path.join(c.tmp_dir, "second-sync-work")
    git!(c.tmp_dir, ["clone", c.source, work])
    File.write!(Path.join(work, "README.md"), "# Organization sync advanced\n")
    File.write!(Path.join(work, "asset.bin"), lfs_pointer(c.payload))
    git!(work, ["add", "README.md", "asset.bin"])
    git!(work, ["commit", "-m", "advance organization source"])
    target = git!(work, ["rev-parse", "HEAD"])
    git!(work, ["push", "origin", "main"])
    target
  end

  defp repository_options(c) do
    [
      client_options: provider_options(c),
      lookup_repository: fn token, "source-org", "project", opts ->
        assert token == :public
        assert opts[:gate_key] == {:public, 1}

        {:ok,
         %ForgeGitHub.Repository{
           id: 501,
           name: "project",
           full_name: "source-org/project",
           owner_id: 1,
           owner_login: "source-org",
           visibility: :public,
           default_branch: "main",
           has_issues: true,
           allow_merge_commit: true,
           fork: false,
           archived: false
         }}
      end,
      fetch_refs: fn request, token, namespace ->
        assert token == :public
        assert request.credential_login == nil
        assert request.authentication == :anonymous
        git!(request.repository_path, ["fetch", "--no-tags", c.source, "HEAD"])

        refs =
          git!(c.source, [
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            "refs/heads",
            "refs/tags"
          ])

        {:ok,
         for line <- String.split(refs, "\n", trim: true) do
           [ref, oid] = String.split(line, " ")
           {:ok, tracking} = GitCore.tracking_ref_name(namespace, ref)
           git!(request.repository_path, ["update-ref", tracking, oid])
           %GitCore.Remote.ObservedRef{ref: ref, oid: oid}
         end}
      end,
      lfs_transfer_options: [callbacks: lfs_callbacks(c)]
    ]
  end

  defp git!(directory, args) do
    {output, status} =
      System.cmd("git", args,
        cd: directory,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "Org sync test"},
          {"GIT_AUTHOR_EMAIL", "org@test.local"},
          {"GIT_COMMITTER_NAME", "Org sync test"},
          {"GIT_COMMITTER_EMAIL", "org@test.local"}
        ]
      )

    assert status == 0, output
    String.trim(output)
  end

  defp provider_options(c), do: Keyword.delete(FakeGitHub.client_opts(c.stub), :gate_key)

  defp worker_options(c),
    do: [
      repository_worker_options: [
        remote: GitRemoteFixture.mirror_remote_module(),
        remote_options: [source: c.source, expected_pat: :public],
        client_options: provider_options(c),
        lfs_transfer_options: [callbacks: lfs_callbacks(c)]
      ]
    ]

  defp lfs_callbacks(c) do
    payloads = Map.get(c, :payloads, [c.payload])

    %{
      batch: fn token, "source-org", "project", :download, objects, options ->
        assert token == :public
        assert options[:gate_key] == {:public, 1}
        assert :ok = options[:authorize].()

        {:ok,
         Enum.map(objects, fn object ->
           assert Enum.any?(payloads, &(lfs_oid(&1) == object.oid))

           %ForgeGitHub.LFS.Object{
             oid: object.oid,
             size: object.size,
             authenticated: false,
             actions: %{
               download:
                 ForgeGitHub.LFS.Action.new!(
                   :download,
                   "https://objects.example.test/#{object.oid}",
                   %{},
                   nil
                 )
             },
             error: nil
           }
         end)}
      end,
      consume_download: fn _action, object, consumer, _options ->
        payload = Enum.find(payloads, &(lfs_oid(&1) == object.oid))

        case consumer.(&lfs_chunk_reader/2, [payload]) do
          {:ok, staged, []} -> {:ok, staged}
          {:error, _reason, _state} -> {:error, ForgeGitHub.Error.new(:integrity_mismatch)}
        end
      end
    }
  end

  defp lfs_chunk_reader([chunk | rest], _options), do: {:ok, chunk, rest}
  defp lfs_chunk_reader([], _options), do: {:eof, []}
  defp lfs_oid(payload), do: :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

  defp lfs_pointer(payload),
    do:
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{lfs_oid(payload)}\nsize #{byte_size(payload)}\n"
end
