defmodule ForgeImports.OrganizationDeviceWorkerTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Fornacast.Repo
  alias ForgeAccounts.{OrganizationGitHubCredentials, User}
  alias ForgeMirrors.{OrganizationGitHubConnections, PatSettings}

  alias ForgeImports.{
    ImportRun,
    OrganizationPatSettings,
    PatSyncRun,
    PatSyncWorker,
    RepositoryItem,
    Worker
  }

  alias ForgeImports.TestSupport.{FakeGitHub, GitRemoteFixture}

  defmodule BusyInstallationClient do
    def user_installations(_token, _options) do
      send(self(), :organization_installation_gate_busy)
      {:error, ForgeGitHub.Error.new(:request_gate_busy)}
    end
  end

  @moduletag :tmp_dir
  @access "organization-worker-access-secret"
  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: tmp_dir} = context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        username: "orgworker#{n}",
        email: "orgworker#{n}@test.local",
        password_hash: "unused"
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "worker-org#{n}"})
    {:ok, reference} = OrganizationGitHubCredentials.reference(owner, org.id)

    token = %ForgeGitHub.DeviceFlow.Token{
      client_id: "Iv23lizCVE3E24s7fCA0",
      access_token: @access,
      refresh_token: "organization-worker-refresh-secret",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }

    {:ok, credential} =
      OrganizationGitHubCredentials.save_device_grant_if_current(
        owner,
        org.id,
        %{github_user_id: n, login: "external-authorizer"},
        token,
        reference,
        %{}
      )

    {:ok, connection} =
      OrganizationGitHubConnections.transaction(owner, org.id, 0, fn conn ->
        OrganizationGitHubConnections.store_grant(conn, credential, owner, %{})
      end)

    repositories =
      for index <- 1..Map.get(context, :repository_count, 1) do
        %{
          id: 500 + index,
          name: if(index == 1, do: "project", else: "project-#{index}"),
          owner: "source-org"
        }
      end

    installation = %{
      id: 44,
      account_id: 1,
      account_login: "source-org",
      account_type: :organization,
      repository_selection: :selected,
      state: :active,
      permissions: %{"contents" => "write", "issues" => "read", "pull_requests" => "read"}
    }

    {:ok, connection} =
      OrganizationGitHubConnections.transaction(owner, org.id, connection.lock_version, fn conn ->
        OrganizationGitHubConnections.bind(
          conn,
          installation,
          %{
            "repositories" => Enum.map(repositories, &FakeGitHub.repository_json/1)
          },
          owner,
          %{}
        )
      end)

    {:ok, scope} = OrganizationGitHubConnections.scope(connection.id)
    {:ok, config} = PatSettings.activate_organization_connection(owner, org.id, scope, "1", %{})

    installation_json = %{
      "id" => 44,
      "app_id" => 5_412_311,
      "app_slug" => "fornacast",
      "client_id" => token.client_id,
      "account" => %{"id" => 1, "login" => "source-org", "type" => "Organization"},
      "permissions" => installation.permissions,
      "repository_selection" => "selected",
      "suspended_at" => nil
    }

    stub =
      FakeGitHub.start!(%{
        installation: installation_json,
        organization: %{"id" => 1, "login" => "source-org"},
        repos: repositories
      })

    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repositories"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)

    %{
      owner: owner,
      org: org,
      config: config,
      connection: connection,
      credential: credential,
      stub: stub,
      tmp_dir: tmp_dir,
      payload: "organization owned LFS object bytes",
      source:
        GitRemoteFixture.bare_repo!(tmp_dir,
          extra_files:
            if(Map.get(context, :without_lfs, false),
              do: [],
              else: [{"asset.bin", lfs_pointer("organization owned LFS object bytes")}]
            )
        )
    }
  end

  test "committed organization work discovers, stages metadata and Git, and publishes after the authorizer leaves",
       c do
    {job, run} = begin_import(c, deactivate: true)
    assert Repo.get!(ImportRun, run.id).state == :running
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    finish_item(c, item)
    assert :ok = PatSyncWorker.perform(job.id)
    assert Repo.get!(PatSyncRun, job.id).state == "succeeded"
    published = Repo.get!(RepositoryItem, item.id)
    assert published.publication_evidence["state"] == "committed"
    assert {:ok, repository} = ForgeRepos.fetch_live_repository(published.hidden_repository_id)
    assert repository.owner_user_id == c.org.id

    assert {:ok, oid} =
             GitCore.exact_ref(ForgeRepos.absolute_storage_path(repository), "refs/heads/main")

    assert {:ok, blob} =
             GitCore.read_blob(ForgeRepos.absolute_storage_path(repository), oid, "README.md")

    assert blob.data == "# Imported repository\n"
    GitCore.release_blob(blob)
    oid = lfs_oid(c.payload)
    assert :ok = GitLFS.verify_object(repository, oid, byte_size(c.payload))
    assert {:ok, object, _} = GitLFS.open_object(repository, oid, byte_size(c.payload), :all)
    assert {:ok, payload, object} = GitLFS.read(object, byte_size(c.payload))
    assert payload == c.payload
    assert :ok = GitLFS.close(object)
    assert Repo.get!(ImportRun, run.id).credential_source == :organization_device
    refute Repo.exists?(ForgeAccounts.GitHubCredential)

    target = advance_remote(c)
    config = Repo.get!(ForgeMirrors.PatConfiguration, c.config.id)
    assert {:ok, next_job} = OrganizationPatSettings.sync_organization_configuration(config, %{})
    assert :pending = PatSyncWorker.perform(next_job.id)
    next_job = Repo.get!(PatSyncRun, next_job.id)
    assert next_job.import_run_id != run.id

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(next_job.import_run_id, "second-org-discovery",
               client_options: provider_options(c)
             )

    assert :pending = PatSyncWorker.perform(next_job.id)

    Enum.reduce_while(1..8, nil, fn _, _ ->
      result = PatSyncWorker.perform(next_job.id, repository_options: repository_options(c))

      if Repo.get!(PatSyncRun, next_job.id).state == "succeeded",
        do: {:halt, result},
        else:
          (
            assert result == :pending, inspect(result)
            {:cont, result}
          )
    end)

    assert Repo.get!(PatSyncRun, next_job.id).state == "succeeded"
    assert {:ok, updated} = ForgeRepos.fetch_live_repository(repository.id)
    assert updated.owner_user_id == repository.owner_user_id
    assert updated.generation == repository.generation
    assert updated.write_version > repository.write_version

    assert {:ok, ^target} =
             GitCore.exact_ref(ForgeRepos.absolute_storage_path(updated), "refs/heads/main")

    assert {:ok, changed} =
             GitCore.read_blob(ForgeRepos.absolute_storage_path(updated), target, "README.md")

    assert changed.data == "# Organization sync advanced\n"
    GitCore.release_blob(changed)
    assert :ok = GitLFS.verify_object(updated, oid, byte_size(c.payload))

    assert Repo.exists?(
             from op in ForgeRepos.GitWriteOperation,
               where:
                 op.repository_id == ^repository.id and op.actor_user_id == ^c.owner.id and
                   op.proposed_oid == ^target and op.state == :bookkeeping_complete
           )
  end

  test "organization repository sync returns safe provider and Git error kinds through credential guards",
       c do
    {job, run} = begin_import(c, deactivate: true)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    finish_item(c, item)
    published = Repo.get!(RepositoryItem, item.id)
    assert {:ok, repository} = ForgeRepos.fetch_live_repository(published.hidden_repository_id)

    assert {:ok, execution} =
             ForgeImports.OrganizationExecution.for_sync(Repo.get!(PatSyncRun, job.id))

    config = Repo.get!(ForgeMirrors.PatConfiguration, c.config.id)
    sensitive_detail = @access <> " organization-worker-refresh-secret"

    for {expected, override} <- [
          {:forbidden,
           [
             lookup_repository: fn _, _, _, _ ->
               {:error, %ForgeGitHub.Error{kind: :forbidden, detail: sensitive_detail}}
             end
           ]},
          {:process_exit,
           [
             fetch_refs: fn _, _, _ ->
               {:error, %GitCore.Remote.Error{kind: :process_exit, detail: sensitive_detail}}
             end
           ]}
        ] do
      options = [github_repository_id: 501] ++ Keyword.merge(repository_options(c), override)

      assert {:error, ^expected} =
               ForgeImports.PatRepositorySync.sync(
                 execution,
                 config,
                 repository,
                 "source-org/project",
                 options
               )
    end

    refute Repo.exists?(ForgeAccounts.GitHubCredential)
  end

  test "disconnect after staging fences publication without publishing the shadow", c do
    {_job, run} = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    stage_until(c, item, :ready_to_publish)

    assert {:ok, _} =
             ForgeImports.OrganizationGitHubConnection.disconnect(
               c.owner,
               c.org.id,
               c.connection.lock_version,
               %{}
             )

    assert {:error, _} = Worker.run(item.id, "organization-test", worker_options(c))
    current = Repo.get!(RepositoryItem, item.id)
    refute current.state in [:published, :completed]
    refute current.publication_evidence["state"] == "committed"
    assert Repo.get!(ForgeRepos.Repository, current.hidden_repository_id).lifecycle == :importing
  end

  test "cancel requested import keeps the organization parent pending", c do
    {job, run} = begin_import(c)
    assert {:ok, _} = ForgeImports.request_cancel(c.owner, run.id, %{})

    assert :pending = PatSyncWorker.perform(job.id)
    assert Repo.get!(PatSyncRun, job.id).state == "running"
  end

  test "failed organization parent reopens its canceled child's admitted intent without publication",
       c do
    {job, run, item} = admitted_item(c)
    shadow = Repo.get!(ForgeRepos.Repository, item.hidden_repository_id)
    path = ForgeRepos.absolute_storage_path(shadow)
    assert File.dir?(path)
    assert {:ok, _} = ForgeImports.request_cancel(c.owner, run.id, %{})
    Repo.update!(Ecto.Changeset.change(job, state: "failed", error: "import_failed"))
    make_publication_due!(item)

    assert {:error, :destination_changed} = ForgeImports.RepositoryPublisher.recover(item.id)
    current = Repo.get!(RepositoryItem, item.id)
    assert current.state == :cancel_requested
    assert current.publication_evidence == %{}
    assert current.lease_owner == nil
    assert current.hidden_repository_id == shadow.id
    assert current.staged_storage_path == item.staged_storage_path
    assert Repo.get!(ForgeRepos.Repository, shadow.id) == shadow
    assert File.dir?(path)
    assert Repo.get!(ImportRun, run.id).published_count == 0

    assert %{state: :destination_changed, terminal_at: %DateTime{}} =
             Repo.get_by!(ForgeImports.ImportAttempt,
               repository_item_id: item.id,
               attempt_number: item.attempt_count
             )
  end

  test "organization credential gate contention retries staging with the same shadow and attempt",
       c do
    {job, run} = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)

    attempt =
      Repo.get_by!(ForgeImports.ImportAttempt,
        repository_item_id: item.id,
        attempt_number: item.attempt_count
      )

    options =
      Keyword.update!(worker_options(c), :repository_worker_options, fn options ->
        Keyword.put(options, :client, BusyInstallationClient)
      end)

    assert {:error, :request_gate_busy} = Worker.run(item.id, "organization-test", options)
    assert_received :organization_installation_gate_busy

    waiting = Repo.get!(RepositoryItem, item.id)
    assert waiting.state == :staging_git
    assert is_integer(waiting.hidden_repository_id)
    assert waiting.next_attempt_at != nil
    assert waiting.wait_reason == nil
    assert waiting.failure_kind == "request_gate_busy"
    assert waiting.attempt_count == item.attempt_count
    assert Repo.get!(ImportRun, run.id).state == :running
    assert Repo.get!(PatSyncRun, job.id).state == "running"

    assert %{state: :running, terminal_at: nil} =
             Repo.get!(ForgeImports.ImportAttempt, attempt.id)

    make_publication_due!(waiting)
    finish_item(c, waiting)
    assert :ok = PatSyncWorker.perform(job.id)

    published = Repo.get!(RepositoryItem, item.id)
    assert published.hidden_repository_id == waiting.hidden_repository_id
    assert published.staged_storage_path == waiting.staged_storage_path
    assert published.attempt_count == item.attempt_count
    assert Repo.get!(ForgeImports.ImportAttempt, attempt.id).state == :completed
    assert Repo.get!(PatSyncRun, job.id).state == "succeeded"
  end

  test "failed organization parent reopens an admitted running child for resolution", c do
    {job, run, item} = admitted_item(c)
    Repo.update!(Ecto.Changeset.change(job, state: "failed", error: "import_failed"))
    make_publication_due!(item)

    assert {:error, :destination_changed} = ForgeImports.RepositoryPublisher.recover(item.id)

    assert %{state: :awaiting_resolution, publication_evidence: %{}} =
             Repo.get!(RepositoryItem, item.id)

    assert Repo.get!(ImportRun, run.id).published_count == 0
    assert Repo.get!(ForgeRepos.Repository, item.hidden_repository_id).lifecycle == :importing
  end

  test "organization cancellation after admission still publishes with current authority", c do
    {_job, run, item} = admitted_item(c)
    assert {:ok, _} = ForgeImports.request_cancel(c.owner, run.id, %{})
    make_publication_due!(item)

    assert {:ok, %{repository: repository}} =
             ForgeImports.SyncJobs.Execution.with_options(
               [publication: provider_options(c)],
               fn ->
                 ForgeImports.RepositoryPublisher.recover(item.id)
               end
             )

    assert repository.id == item.hidden_repository_id
    assert Repo.get!(RepositoryItem, item.id).publication_evidence["state"] == "committed"
  end

  test "temporary organization provider failures retain the admitted intent", c do
    {_job, _run, item} = admitted_item(c)
    make_publication_due!(item)
    stub = FakeGitHub.start!(%{rate_limit?: true})
    options = Keyword.delete(FakeGitHub.client_opts(stub), :gate_key)

    assert {:error, :primary_rate_limit} =
             ForgeImports.SyncJobs.Execution.with_options([publication: options], fn ->
               ForgeImports.RepositoryPublisher.recover(item.id)
             end)

    current = Repo.get!(RepositoryItem, item.id)
    assert current.state == :publishing
    assert current.publication_evidence == item.publication_evidence
    assert Repo.get!(ForgeRepos.Repository, item.hidden_repository_id).lifecycle == :importing

    assert %{state: :running, terminal_at: nil} =
             Repo.get_by!(ForgeImports.ImportAttempt,
               repository_item_id: item.id,
               attempt_number: item.attempt_count
             )
  end

  test "canceled organization import retries an allocated unproved shadow with fresh staging",
       c do
    {job, run} = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)

    {:ok, %{shadow: shadow}} =
      Ecto.Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, c.org.id, %{item_id: item.id, generation: 1})
      |> Repo.transaction()

    path = ForgeRepos.absolute_storage_path(shadow)
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    File.write!(Path.join(path, "partial"), "unproved bytes")
    now = DateTime.utc_now(:second)

    Repo.update!(
      Ecto.Changeset.change(item,
        state: :canceled,
        hidden_repository_id: shadow.id,
        staged_storage_path: path,
        lease_owner: nil,
        lease_expires_at: nil
      )
    )

    Repo.update_all(
      from(a in ForgeImports.ImportAttempt, where: a.repository_item_id == ^item.id),
      set: [state: :canceled, terminal_at: now]
    )

    Repo.update!(Ecto.Changeset.change(run, state: :canceled, terminal_at: now))
    Repo.update!(Ecto.Changeset.change(job, state: "failed", error: "credential_unavailable"))

    assert {:ok, retry} =
             OrganizationPatSettings.sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{}
             )

    successor = Repo.get!(ImportRun, retry.import_run_id)
    assert successor.predecessor_run_id == run.id
    [fresh] = Repo.all(from i in RepositoryItem, where: i.import_run_id == ^successor.id)
    assert fresh.predecessor_item_id == item.id
    assert fresh.state == :queued
    assert fresh.hidden_repository_id == nil
    assert fresh.staged_storage_path == nil
    assert fresh.checkpoint == %{}
    assert fresh.source_git == %{}
    assert File.read!(Path.join(path, "partial")) == "unproved bytes"

    assert :pending = PatSyncWorker.perform(retry.id)
    stage_until(c, Repo.get!(RepositoryItem, fresh.id), :ready_to_publish)
    fresh = Repo.get!(RepositoryItem, fresh.id)
    assert fresh.hidden_repository_id != shadow.id
    fresh_path = fresh.staged_storage_path
    assert File.dir?(fresh_path)

    assert :attempted =
             ForgeImports.RepositoryCleanup.reconcile_kind(
               :unpublished_shadow,
               now,
               System.monotonic_time(:millisecond) + 5_000
             )

    operation = Repo.get_by!(ForgeImports.CleanupOperation, repository_id: shadow.id)
    assert operation.state == :cleanup_pending

    assert :attempted =
             ForgeImports.RepositoryCleanup.reconcile_kind(
               :unpublished_shadow,
               operation.eligible_at,
               System.monotonic_time(:millisecond) + 5_000
             )

    refute File.exists?(path)
    assert File.dir?(fresh_path)
    assert Repo.reload!(operation).state == :cleanup_complete
    finish_item(c, fresh)
    assert :ok = PatSyncWorker.perform(retry.id)
    assert Repo.get!(PatSyncRun, retry.id).state == "succeeded"
  end

  @tag repository_count: 14, without_lfs: true
  test "retry preparation retains successful and pending ancestor updates with twelve current imports",
       c do
    {job, run} = begin_import(c)

    [update_item, succeeded_item | canceled] =
      Repo.all(
        from i in RepositoryItem,
          where: i.import_run_id == ^run.id,
          order_by: i.github_repository_id
      )

    finish_item(c, update_item)
    update_item = Repo.reload!(update_item)
    repository = Repo.get!(ForgeRepos.Repository, update_item.hidden_repository_id)

    {:ok, succeeded_repository} =
      ForgeRepos.create_repository(c.org, %{
        slug: succeeded_item.source_name,
        name: succeeded_item.source_name
      })

    Repo.update!(Ecto.Changeset.change(succeeded_item, state: :skipped, conflict_action: :skip))
    now = DateTime.utc_now(:second)
    canceled_ids = Enum.map(canceled, & &1.id)

    Repo.update_all(from(i in RepositoryItem, where: i.id in ^canceled_ids),
      set: [state: :canceled]
    )

    Repo.update_all(
      from(a in ForgeImports.ImportAttempt, where: a.repository_item_id in ^canceled_ids),
      set: [state: :canceled, terminal_at: now]
    )

    Repo.update!(Ecto.Changeset.change(run, state: :canceled, terminal_at: now))

    pending = %{
      "github_repository_id" => update_item.github_repository_id,
      "source_full_name" => update_item.source_full_name,
      "mode" => "update",
      "repository_id" => repository.id,
      "generation" => repository.generation,
      "status" => "pending",
      "error" => "configuration_changed"
    }

    succeeded = %{
      "github_repository_id" => succeeded_item.github_repository_id,
      "source_full_name" => succeeded_item.source_full_name,
      "mode" => "update",
      "repository_id" => succeeded_repository.id,
      "generation" => succeeded_repository.generation,
      "status" => "succeeded"
    }

    pending_id = to_string(update_item.id)
    succeeded_id = to_string(succeeded_item.id)
    progress = job.progress |> Map.put(pending_id, pending) |> Map.put(succeeded_id, succeeded)

    Repo.update!(
      Ecto.Changeset.change(job,
        state: "failed",
        error: "credential_unavailable",
        progress: progress
      )
    )

    target = advance_remote(c)

    assert {:ok, retry} =
             OrganizationPatSettings.sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{}
             )

    assert map_size(retry.progress) == 14
    assert retry.progress[pending_id] == pending
    assert retry.progress[succeeded_id] == succeeded
    current = Repo.all(from i in RepositoryItem, where: i.import_run_id == ^retry.import_run_id)
    assert length(current) == 12
    assert Repo.get!(ImportRun, retry.import_run_id).state == :awaiting_resolution

    assert :pending = PatSyncWorker.perform(retry.id)
    prepared = Repo.reload!(retry)
    assert map_size(prepared.progress) == 14
    assert prepared.progress[pending_id] == pending
    assert prepared.progress[succeeded_id] == succeeded
    assert Repo.get!(ImportRun, retry.import_run_id).state == :running

    assert :pending = PatSyncWorker.perform(retry.id, repository_options: repository_options(c))
    updated = Repo.reload!(retry)
    assert updated.progress[pending_id]["status"] == "succeeded"
    refute Map.has_key?(updated.progress[pending_id], "error")
    assert updated.progress[succeeded_id] == succeeded

    assert {:ok, ^target} =
             GitCore.exact_ref(ForgeRepos.absolute_storage_path(repository), "refs/heads/main")

    assert Repo.reload!(repository).write_version > repository.write_version

    Enum.each(current, &finish_item(c, &1))
    assert :ok = PatSyncWorker.perform(retry.id)
    finished = Repo.reload!(retry)
    assert finished.state == "succeeded"
    assert map_size(finished.progress) == 14
    assert Enum.all?(finished.progress, fn {_id, row} -> row["status"] == "succeeded" end)
    assert Repo.get!(ImportRun, retry.import_run_id).published_count == 12
  end

  for phase <- [:git_staged, :ready_to_publish] do
    @tag staged_phase: phase
    test "organization retry admits fresh attempts and publishes adopted #{phase} staging", c do
      {job, run} = begin_import(c)
      [item] = Repo.all(from i in RepositoryItem, where: i.import_run_id == ^run.id)
      stage_until(c, item, c.staged_phase)
      item = Repo.get!(RepositoryItem, item.id)
      now = DateTime.utc_now(:second)
      Repo.update!(Ecto.Changeset.change(item, state: :failed))

      Repo.update_all(
        from(a in ForgeImports.ImportAttempt, where: a.repository_item_id == ^item.id),
        set: [state: :failed, terminal_at: now]
      )

      Repo.update!(Ecto.Changeset.change(run, state: :failed, terminal_at: now))
      Repo.update!(Ecto.Changeset.change(job, state: "failed", error: "import_failed"))

      assert {:ok, retry} =
               OrganizationPatSettings.sync(
                 c.owner,
                 c.org.id,
                 to_string(c.config.lock_version),
                 %{}
               )

      successor = Repo.get!(ImportRun, retry.import_run_id)
      assert successor.state == :awaiting_resolution
      [adopted] = Repo.all(from i in RepositoryItem, where: i.import_run_id == ^successor.id)
      assert adopted.state == :queued
      assert adopted.hidden_repository_id == item.hidden_repository_id
      assert adopted.source_git == item.source_git
      assert {:ok, _} = ForgeImports.RepositoryPublisher.durable_proof_state(adopted)
      assert :pending = PatSyncWorker.perform(retry.id)
      assert Repo.get!(ImportRun, successor.id).state == :running

      assert %{state: :running} =
               Repo.get_by!(ForgeImports.ImportAttempt,
                 repository_item_id: adopted.id,
                 attempt_number: 1
               )

      assert :none =
               ForgeImports.RepositoryCleanup.reconcile_kind(
                 :unpublished_shadow,
                 now,
                 System.monotonic_time(:millisecond) + 5_000
               )

      finish_item(c, adopted)
      assert :ok = PatSyncWorker.perform(retry.id)
      assert Repo.get!(PatSyncRun, retry.id).state == "succeeded"
    end
  end

  test "retry and restart preserve organization source without resolving a personal owner", c do
    {job, run} = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    Repo.update!(Ecto.Changeset.change(item, state: :failed, failure_kind: "corrupt_repository"))
    ForgeImports.RunAggregator.finish_if_terminal(run.id)
    assert {:error, :repository_sync_failed} = PatSyncWorker.perform(job.id)

    assert {:ok, retry} =
             OrganizationPatSettings.sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{}
             )

    successor = Repo.get!(ImportRun, retry.import_run_id)
    assert successor.predecessor_run_id == run.id
    assert successor.organization_sync_run_id == retry.id
    assert successor.credential_source == :organization_device
    assert successor.github_identity_id == nil

    assert {:ok, restarted} =
             OrganizationPatSettings.restart_sync(
               c.owner,
               c.org.id,
               to_string(c.config.lock_version),
               %{}
             )

    assert restarted.id != retry.id
    assert Repo.get!(ImportRun, restarted.import_run_id).predecessor_run_id == successor.id
    assert Repo.get!(PatSyncRun, retry.id).state == "failed"
  end

  defp begin_import(c, opts \\ []) do
    {:ok, job} =
      OrganizationPatSettings.sync(c.owner, c.org.id, to_string(c.config.lock_version), %{})

    assert :pending = PatSyncWorker.perform(job.id)
    job = Repo.get!(PatSyncRun, job.id)
    run = Repo.get!(ImportRun, job.import_run_id)

    if opts[:deactivate] do
      Repo.delete_all(
        from member in ForgeAccounts.OrganizationMember,
          where: member.organization_id == ^c.org.id and member.user_id == ^c.owner.id
      )

      Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))
    end

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(run.id, "organization-discovery-test",
               client_options: provider_options(c)
             )

    assert :pending = PatSyncWorker.perform(job.id)
    {Repo.get!(PatSyncRun, job.id), Repo.get!(ImportRun, run.id)}
  end

  defp admitted_item(c) do
    {job, run} = begin_import(c)
    [item] = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    stage_until(c, item, :ready_to_publish)
    assert {:ok, execution} = ForgeImports.OrganizationExecution.for_run(run)

    assert catch_exit(
             ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
               fn _capability -> exit(:response_lost) end,
               fn -> ForgeImports.RepositoryPublisher.publish(execution, item.id, %{}) end
             )
           ) == :response_lost

    admitted = Repo.get!(RepositoryItem, item.id)
    assert admitted.state == :publishing
    {job, run, admitted}
  end

  defp make_publication_due!(item) do
    Repo.update_all(from(i in RepositoryItem, where: i.id == ^item.id),
      set: [
        lease_owner: nil,
        lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1),
        next_attempt_at: nil
      ]
    )
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
    git!(work, ["add", "README.md"])
    git!(work, ["commit", "-m", "advance organization source"])
    target = git!(work, ["rev-parse", "HEAD"])
    git!(work, ["push", "origin", "main"])
    target
  end

  defp repository_options(c) do
    [
      client_options: provider_options(c),
      lookup_repository: fn token, "source-org", "project", opts ->
        assert token == @access
        assert opts[:gate_key] == {:organization_credential, c.credential.credential_id}
        {:ok, %{id: 501, owner_id: 1, owner_login: "source-org"}}
      end,
      fetch_refs: fn request, token, namespace ->
        assert token == @access
        assert request.credential_login == "x-access-token"
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
        remote_options: [source: c.source, expected_pat: @access],
        client_options: provider_options(c),
        lfs_transfer_options: [callbacks: lfs_callbacks(c)]
      ]
    ]

  defp lfs_callbacks(c) do
    %{
      batch: fn token, "source-org", "project", :download, objects, options ->
        assert token == @access
        assert options[:gate_key] == {:organization_credential, c.credential.credential_id}
        assert :ok = options[:authorize].()

        {:ok,
         Enum.map(objects, fn object ->
           assert object.oid == lfs_oid(c.payload)

           %ForgeGitHub.LFS.Object{
             oid: object.oid,
             size: object.size,
             authenticated: true,
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
      consume_download: fn _action, _object, consumer, _options ->
        case consumer.(&lfs_chunk_reader/2, [c.payload]) do
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
