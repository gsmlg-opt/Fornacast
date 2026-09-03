defmodule ForgeImports.GitHubImportE2ETest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, Organization, User}
  alias ForgeImports.GitHub.MetadataImporter
  alias ForgeImports.TestSupport.{FakeGitHub, GitRemoteFixture, ImportReset}

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    Persistence,
    ReportEntry,
    ReportView,
    RepositoryItem,
    RunAggregator,
    RunView,
    Scheduler,
    Waits
  }

  alias ForgeIssues.Issue
  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  @moduletag :tmp_dir
  @now ~U[2026-08-29 12:00:00Z]
  @pat "github_pat_e2e_import_secret_value"
  @saved_pat "github_pat_e2e_saved_secret_value"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<17>>, 32)}}

  setup {Req.Test, :verify_on_exit!}

  setup %{tmp_dir: tmp_dir} do
    if ImportReset.postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      ForgeImports.RecoveryTestHelper.mark_sandbox_owner!()
    else
      ImportReset.reset!()
      on_exit(&ImportReset.reset!/0)
    end

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    staging_root = Path.join(tmp_dir, "repos")
    File.mkdir_p!(staging_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    actor = user_fixture("import-e2e")
    identity = identity_fixture(actor, "octocat")

    %{
      actor: actor,
      identity: identity,
      tmp_dir: tmp_dir,
      staging_root: staging_root
    }
  end

  describe "repository import workflow" do
    test "one-time PAT import publishes exact metadata without leaking credentials", %{
      actor: actor,
      identity: identity,
      tmp_dir: tmp_dir
    } do
      source = GitRemoteFixture.bare_repo!(tmp_dir, readme: "# Hello E2E\n")
      run = one_time_run!(actor, identity, "octocat", "hello-e2e")
      item = queued_item!(run, actor, 9_500_000_001, "hello-e2e", "octocat/hello-e2e")
      attempt!(item)

      staged = GitRemoteFixture.stage_item!(item, actor.id, source)

      assert {:ok, published} =
               stage_metadata_and_publish(actor, staged, owner: "octocat", repo: "hello-e2e")

      assert published.slug == "hello-e2e"
      assert published.lifecycle == :ready
      refute ForgeRepos.fetch_importing_repository(published.id) == {:ok, published}

      assert %Issue{number: 3, title: "Issue title"} =
               Repo.get_by!(Issue, repository_id: published.id, number: 3)

      report = finalize_and_load_report!(actor, run)
      assert report.state == :completed
      assert report.counts.published == 1
      refute_secrets_persisted!(run, item, published)
    end

    test "saved credential import uses the linked identity checkout", %{
      actor: actor,
      identity: identity,
      tmp_dir: tmp_dir
    } do
      credential = saved_credential!(actor, identity, @saved_pat)
      source = GitRemoteFixture.bare_repo!(tmp_dir, readme: "# Saved credential\n")
      run = saved_run!(actor, identity, credential, "acme", "saved-demo")
      item = queued_item!(run, actor, 9_500_000_002, "saved-demo", "acme/saved-demo")
      attempt!(item)

      staged = GitRemoteFixture.stage_item!(item, actor.id, source)

      assert {:ok, published} =
               stage_metadata_and_publish(actor, staged, owner: "acme", repo: "saved-demo")

      assert published.slug == "saved-demo"
      assert Repo.get!(ImportRun, run.id).github_credential_id == credential.id
      refute inspect({published, Repo.all(AuditEvent)}) =~ @saved_pat
    end
  end

  describe "organization import workflow" do
    test "activates a destination organization and aggregates mixed repository outcomes", %{
      actor: actor,
      identity: identity,
      tmp_dir: tmp_dir
    } do
      run =
        organization_run!(actor, identity,
          slug: "acme-imported",
          selected_count: 3,
          metadata: %{"name" => "Acme Imported", "description" => "Widgets"}
        )

      success =
        org_item!(run, 9_500_000_010, "alpha", selected: true)

      skipped =
        org_item!(run, 9_500_000_011, "beta", selected: false, state: :skipped)

      renamed =
        org_item!(run, 9_500_000_012, "gamma",
          selected: true,
          destination_slug: "gamma-local",
          conflict_action: :rename
        )

      failed_item = org_item!(run, 9_500_000_014, "epsilon", selected: true)

      run = Repo.get!(ImportRun, run.id)

      assert {:ok, %RunView{state: :running, destination_organization: organization}} =
               ForgeImports.start_import(
                 actor,
                 run.id,
                 request_metadata("org-start"),
                 dispatch: :manual
               )

      assert organization.username == "acme-imported"
      assert ForgeAccounts.organization_role(actor, organization) == :owner

      alpha_source = GitRemoteFixture.bare_repo!(Path.join(tmp_dir, "alpha"), readme: "# Alpha\n")
      alpha_staged = GitRemoteFixture.stage_item!(success, organization.id, alpha_source)

      assert {:ok, alpha_published} =
               stage_metadata_and_publish(actor, alpha_staged,
                 owner: "acme-imported",
                 repo: "alpha"
               )

      assert alpha_published.owner_user_id == organization.id

      gamma_source = GitRemoteFixture.bare_repo!(Path.join(tmp_dir, "gamma"), readme: "# Gamma\n")
      gamma_staged = GitRemoteFixture.stage_item!(renamed, organization.id, gamma_source)

      assert {:ok, gamma_published} =
               stage_metadata_and_publish(actor, gamma_staged,
                 owner: "acme-imported",
                 repo: "gamma",
                 destination_slug: "gamma-local"
               )

      assert gamma_published.slug == "gamma-local"

      replace_target = repository_fixture!(organization, "replace-target")
      target_path = ForgeRepos.absolute_storage_path(replace_target)
      File.mkdir_p!(Path.dirname(target_path))
      assert {:ok, ^target_path} = GitCore.init_bare(target_path)
      replace_target = Repo.get!(Repository, replace_target.id)

      replace_item =
        org_item!(run, 9_500_000_013, "delta",
          selected: true,
          destination_slug: "replace-target",
          destination_owner_id: organization.id,
          conflict_action: :replace,
          replacement_repository_id: replace_target.id,
          replacement_owner_id: replace_target.owner_user_id,
          replacement_storage_path: replace_target.storage_path,
          replacement_generation: replace_target.generation,
          replacement_write_version: replace_target.write_version,
          replacement_updated_at: replace_target.updated_at,
          replacement_last_pushed_at: replace_target.last_pushed_at
        )

      replace_attempt!(replace_item, replace_target)

      assert {1, _} =
               Repo.update_all(
                 from(candidate in RepositoryItem, where: candidate.id == ^replace_item.id),
                 set: [attempt_count: 1]
               )

      replace_item = Repo.get!(RepositoryItem, replace_item.id)

      replace_source =
        GitRemoteFixture.bare_repo!(Path.join(tmp_dir, "delta"), readme: "# Delta\n")

      replace_staged = GitRemoteFixture.stage_item!(replace_item, organization.id, replace_source)

      assert {:ok, %{repository: replace_published, replaced: replaced_repo}} =
               stage_metadata_and_publish(actor, replace_staged,
                 owner: "acme-imported",
                 repo: "delta",
                 destination_slug: "replace-target",
                 expect_replace: true
               )

      assert replace_published.id != replace_target.id
      assert replace_published.slug == "replace-target"
      assert replace_published.generation == replace_target.generation + 1
      assert replaced_repo.id == replace_target.id
      assert Repo.get!(Repository, replace_target.id).lifecycle == :tombstoned

      mark_failed!(failed_item)

      assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
      assert terminal.state == :completed_with_warnings
      assert terminal.published_count == 3

      report = finalize_and_load_report!(actor, run)
      assert report.counts.published == 3
      assert report.counts.failures >= 1
      assert report.counts.skipped == 0

      assert Repo.get!(Organization, organization.id).username == "acme-imported"
      refute Repo.get!(RepositoryItem, skipped.id).selected
      refute_secrets_persisted!(run, success, alpha_published)
    end
  end

  describe "recovery controls" do
    test "rate-limit wait preserves the exact retry boundary across restart", %{
      actor: actor,
      identity: identity
    } do
      run = one_time_run!(actor, identity, "acme", "rate-demo")
      item = queued_item!(run, actor, 9_500_000_020, "rate-demo", "acme/rate-demo")
      attempt!(item)
      retry_at = DateTime.add(@now, 3600, :second)

      assert {:ok, waiting} = Waits.rate_limited(item, retry_at, :secondary)
      assert waiting.state == :queued
      assert waiting.wait_reason == "rate_limit"

      reloaded = Repo.get!(RepositoryItem, waiting.id)
      refute Scheduler.claimable?(reloaded, DateTime.add(retry_at, -1, :second))
      assert Scheduler.claimable?(reloaded, retry_at)
    end

    test "credential replacement resumes the exact pre-wait phase", %{
      actor: actor,
      identity: identity
    } do
      credential = saved_credential!(actor, identity, @saved_pat)
      run = saved_run!(actor, identity, credential, "acme", "credential-demo")

      item =
        staging_git_item!(run, actor, 9_500_000_021, "credential-demo", "acme/credential-demo")

      assert {:ok, {_run, waiting_item}} =
               Waits.awaiting_credential(run, item, :staging_git,
                 wait_reason: "credential_invalid"
               )

      assert waiting_item.resume_state == :staging_git

      assert {:ok, resumed_run} =
               Waits.resume_with_credential(
                 actor,
                 Repo.get!(ImportRun, run.id),
                 %{
                   credential_source: :saved,
                   github_identity_id: identity.id,
                   github_credential_id: credential.id
                 },
                 request_metadata("resume-credential")
               )

      assert resumed_run.state == :running
      assert Repo.get!(RepositoryItem, item.id).state == :staging_git
    end

    test "cancellation persists intent and stops queued organization work", %{
      actor: actor,
      identity: identity
    } do
      run =
        organization_run!(actor, identity,
          slug: "cancel-org",
          selected_count: 1,
          metadata: %{"name" => "Cancel Org"}
        )

      item = org_item!(run, 9_500_000_030, "cancel-me")

      assert {:ok, %RunView{destination_organization: organization}} =
               ForgeImports.start_import(
                 actor,
                 run.id,
                 request_metadata("org-running"),
                 dispatch: :manual
               )

      item = Repo.get!(RepositoryItem, item.id)
      assert item.destination_owner_id == organization.id

      assert {:ok, requested} =
               ForgeImports.request_cancel(actor, run.id, request_metadata("cancel-org"),
                 now: @now
               )

      assert requested.state == :cancel_requested
      assert Repo.get!(RepositoryItem, item.id).state == :cancel_requested

      audit =
        Repo.one!(
          from event in AuditEvent,
            where: event.action == "github_import.cancel_requested",
            limit: 1
        )

      GitRemoteFixture.refute_pat_leaks!(inspect(audit), @pat)
      refute item.id in Scheduler.claimable_item_ids(@now, 100)
    end

    test "successor retry adopts only retryable unpublished items", %{
      actor: actor,
      identity: identity
    } do
      credential = saved_credential!(actor, identity, @saved_pat)
      predecessor = terminal_org_run!(actor, identity, credential, :completed_with_warnings)

      published =
        org_item!(predecessor, 9_500_000_040, "published",
          destination_owner_id: actor.id,
          state: :failed
        )

      {1, _} =
        Repo.update_all(
          from(item in RepositoryItem, where: item.id == ^published.id),
          set: [state: :published, publication_evidence: %{"published_repository_id" => 1}]
        )

      failed =
        org_item!(predecessor, 9_500_000_041, "retry-me",
          destination_owner_id: actor.id,
          state: :failed
        )

      _skipped =
        org_item!(predecessor, 9_500_000_042, "skipped",
          selected: false,
          state: :skipped,
          destination_owner_id: actor.id
        )

      failed_id = failed.id

      assert {:ok, successor} =
               ForgeImports.retry_import(
                 actor,
                 predecessor.id,
                 saved_source(credential, identity),
                 request_metadata("org-retry")
               )

      assert successor.predecessor_run_id == predecessor.id
      assert [%{predecessor_item_id: ^failed_id}] = successor.repositories
      assert Repo.get!(ImportRun, predecessor.id).state == :completed_with_warnings
    end
  end

  describe "privacy boundaries" do
    test "audits, reports, and publication evidence never retain PAT material", %{
      actor: actor,
      identity: identity,
      tmp_dir: tmp_dir,
      staging_root: staging_root
    } do
      source = GitRemoteFixture.bare_repo!(tmp_dir)
      run = one_time_run!(actor, identity, "octocat", "privacy-demo")
      item = queued_item!(run, actor, 9_500_000_050, "privacy-demo", "octocat/privacy-demo")
      attempt!(item)

      staged = GitRemoteFixture.stage_item!(item, actor.id, source)

      assert {:ok, published} =
               stage_metadata_and_publish(actor, staged,
                 owner: "octocat",
                 repo: "privacy-demo"
               )

      refute_secrets_persisted!(run, item, published)
      GitRemoteFixture.refute_pat_in_tree!(staging_root, @pat)
      refute Application.get_env(:fornacast, :github_credential_keyring) |> inspect() =~ @pat
    end
  end

  defp stage_metadata_and_publish(actor, item, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo_name = Keyword.fetch!(opts, :repo)
    destination_slug = Keyword.get(opts, :destination_slug, item.destination_slug)
    issue = hd(FakeGitHub.fixture!("issues_page.json")) |> Map.put("number", 3)

    stub =
      FakeGitHub.start!(%{
        repos: [
          %{
            name: repo_name,
            owner: owner,
            issues: [issue],
            labels: FakeGitHub.fixture!("labels_page.json"),
            comments: %{3 => FakeGitHub.fixture!("comments_page.json")},
            pulls: []
          }
        ]
      })

    assert :ok =
             MetadataImporter.stage(
               item,
               fn callback -> callback.(@pat) end,
               gate_key: {:one_time_run, item.import_run_id},
               client_options: FakeGitHub.client_opts(stub)
             )

    ready =
      Repo.get!(RepositoryItem, item.id)
      |> then(fn current ->
        assert {1, _} =
                 Repo.update_all(
                   from(candidate in RepositoryItem, where: candidate.id == ^current.id),
                   set: [state: :ready_to_publish]
                 )

        Repo.get!(RepositoryItem, current.id)
      end)

    assert ready.destination_slug == destination_slug

    publish_result =
      ForgeImports.publish_repository(actor, ready.id, request_metadata("publish"))

    if Keyword.get(opts, :expect_replace, false) do
      assert {:ok, %{repository: published, replaced: %Repository{} = replaced}} = publish_result
      assert published.slug == destination_slug
      {:ok, %{repository: published, replaced: replaced}}
    else
      assert {:ok, %{repository: published, replaced: nil}} = publish_result
      assert published.slug == destination_slug
      {:ok, published}
    end
  end

  defp finalize_and_load_report!(actor, run) do
    assert {:ok, finalized} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert finalized.report_finalized_at

    assert {:ok, report} = ReportView.load(actor, run.id)
    report
  end

  defp mark_failed!(item) do
    current = Repo.get!(RepositoryItem, item.id)

    {:ok, failed} =
      Persistence.update_without_lease(
        current,
        [:queued, :staging_git, :git_staged, :staging_metadata, :ready_to_publish],
        RepositoryItem.transition_changeset(current, :failed, %{
          failure_kind: "source_validation",
          failure_count: max(current.failure_count, 0) + 1
        }),
        @now
      )

    assert failed.state == :failed
  end

  defp replace_attempt!(item, target) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: max(item.attempt_count, 1),
      state: :running,
      decision: %{
        "action" => "replace",
        "slug" => item.destination_slug,
        "replacement_repository_id" => target.id,
        "replacement_owner_id" => target.owner_user_id,
        "replacement_storage_path" => target.storage_path,
        "replacement_generation" => target.generation,
        "replacement_write_version" => target.write_version,
        "replacement_updated_at" => target.updated_at,
        "replacement_last_pushed_at" => target.last_pushed_at
      },
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp refute_secrets_persisted!(run, item, published) do
    audits = Repo.all(AuditEvent) |> inspect()
    reports = Repo.all(ReportEntry) |> inspect()
    run_dump = Repo.get!(ImportRun, run.id) |> inspect()
    item_dump = Repo.get!(RepositoryItem, item.id) |> inspect()
    published_dump = inspect(published)

    for haystack <- [audits, reports, run_dump, item_dump, published_dump] do
      GitRemoteFixture.refute_pat_leaks!(haystack, @pat)
      GitRemoteFixture.refute_pat_leaks!(haystack, @saved_pat)
    end

    :ok
  end

  defp one_time_run!(actor, identity, owner, repo_name) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_500_000_001,
        source_owner_login: owner,
        source_repository_github_id: 9_500_000_000 + :erlang.phash2(repo_name, 100_000),
        source_repository_full_name: "#{owner}/#{repo_name}",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()
  end

  defp saved_run!(actor, identity, credential, owner, repo_name) do
    %{
      actor_user_id: actor.id,
      source_kind: :repository,
      github_identity_id: identity.id,
      credential_source: :saved,
      github_credential_id: credential.id,
      source_owner_github_id: 8_500_000_002,
      source_owner_login: owner,
      source_repository_github_id: 9_500_100_000 + :erlang.phash2(repo_name, 100_000),
      source_repository_full_name: "#{owner}/#{repo_name}",
      destination_organization_action: :existing,
      destination_organization_slug: actor.username,
      destination_organization_status: :clean,
      state: :running,
      selected_count: 1,
      request_metadata: %{}
    }
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp organization_run!(actor, identity, opts) when is_list(opts) do
    slug = Keyword.fetch!(opts, :slug)
    metadata = Keyword.get(opts, :metadata, %{})

    %{
      actor_user_id: actor.id,
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: 8_500_000_010,
      source_owner_login: "acme-imported",
      source_repository_github_id: nil,
      source_repository_full_name: nil,
      destination_organization_action: :new,
      destination_organization_slug: slug,
      destination_organization_id: nil,
      destination_organization_status: :clean,
      state: :awaiting_resolution,
      selected_count: Keyword.get(opts, :selected_count, 1),
      source_metadata: metadata,
      request_metadata: %{}
    }
    |> Persistence.insert_run()
    |> unwrap!()
    |> attach_one_time!()
  end

  defp organization_running_run!(actor, identity, slug) do
    run = organization_run!(actor, identity, slug: slug, metadata: %{"name" => slug})

    assert {:ok, %RunView{destination_organization: organization}} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("org-running"),
               dispatch: :manual
             )

    assert Repo.get!(ImportRun, run.id).destination_organization_id == organization.id
    Repo.get!(ImportRun, run.id)
  end

  defp terminal_org_run!(actor, identity, credential, terminal_state) do
    %{
      actor_user_id: actor.id,
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :saved,
      github_credential_id: credential.id,
      source_owner_github_id: identity.github_user_id,
      source_owner_login: identity.login,
      destination_organization_action: :existing,
      destination_organization_slug: actor.username,
      destination_organization_status: :clean,
      state: terminal_state,
      terminal_at: @now,
      selected_count: 1,
      request_metadata: %{}
    }
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp attach_one_time!(run) do
    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        run.actor_user_id,
        identity_for_run!(run).github_user_id,
        @pat,
        @keyring
      )

    ForgeImports.attach_one_time_credential(
      Repo.get!(User, run.actor_user_id),
      run,
      envelope,
      @keyring
    )
    |> unwrap!()
  end

  defp identity_for_run!(run) do
    Repo.get!(ForgeAccounts.GitHubIdentity, run.github_identity_id)
  end

  defp queued_item!(run, actor, github_id, slug, full_name, overrides \\ []) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: github_id,
      source_full_name: full_name,
      source_name: slug,
      source_metadata: %{
        "default_branch" => "main",
        "visibility" => "private",
        "description" => "Imported description",
        "has_issues" => true,
        "allow_merge_commit" => true,
        "fork" => false,
        "archived" => false
      },
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: slug,
      destination_visibility: :private,
      state: :queued,
      attempt_count: 1
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp org_item!(run, github_id, slug, overrides \\ []) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: github_id,
      source_full_name: "acme-imported/#{slug}",
      source_name: slug,
      source_metadata: %{
        "default_branch" => "main",
        "visibility" => "private",
        "has_issues" => true,
        "allow_merge_commit" => true,
        "fork" => false,
        "archived" => false
      },
      source_observed_at: @now,
      selected: true,
      destination_owner_id: nil,
      destination_slug: slug,
      destination_visibility: :private,
      state: :queued
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp attempt!(item) do
    action =
      case item.conflict_action do
        nil -> "create"
        value -> to_string(value)
      end

    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: max(item.attempt_count, 1),
      state: :running,
      decision: %{"action" => action, "slug" => item.destination_slug},
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp staging_git_item!(run, actor, github_id, slug, full_name) do
    item = queued_item!(run, actor, github_id, slug, full_name)
    attempt!(item)

    current = Repo.get!(RepositoryItem, item.id)

    {:ok, staging} =
      Persistence.update_without_lease(
        current,
        [:queued],
        RepositoryItem.transition_changeset(current, :staging_git, %{}),
        @now
      )

    staging
  end

  defp repository_fixture!(owner, slug) do
    suffix = System.unique_integer([:positive])
    owner_id = if is_struct(owner, Organization), do: owner.id, else: owner.id

    %Repository{
      owner_user_id: owner_id,
      storage_path: "@test/#{slug}-#{suffix}.git",
      generation: 2,
      lifecycle: :ready
    }
    |> Repository.create_changeset(%{
      slug: slug,
      name: String.capitalize(slug),
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp saved_credential!(actor, identity, pat) do
    placeholder =
      %GitHubCredential{}
      |> GitHubCredential.changeset(%{
        local_user_id: actor.id,
        github_identity_id: identity.id,
        ciphertext: <<1>>,
        nonce: :binary.copy(<<2>>, 12),
        tag: :binary.copy(<<3>>, 16),
        key_id: "test-v1",
        status: :valid,
        last_verified_at: @now
      })
      |> Repo.insert!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_saved(placeholder, identity, pat, @keyring)

    {1, _} =
      Repo.update_all(
        from(credential in GitHubCredential, where: credential.id == ^placeholder.id),
        set: [
          ciphertext: envelope.ciphertext,
          nonce: envelope.nonce,
          tag: envelope.tag,
          key_id: envelope.key_id
        ]
      )

    Repo.get!(GitHubCredential, placeholder.id)
  end

  defp saved_source(credential, identity) do
    %{
      credential_source: :saved,
      github_credential_id: credential.id,
      github_identity_id: identity.id
    }
  end

  defp user_fixture(prefix) do
    suffix = System.unique_integer([:positive])

    %User{}
    |> ForgeAccounts.User.registration_changeset(%{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.test",
      password: "correct horse battery staple"
    })
    |> Repo.insert!()
  end

  defp identity_fixture(actor, login) do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_500_000_000 + System.unique_integer([:positive]),
          login: login,
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    ForgeAccounts.link_github_identity(actor, identity) |> unwrap!()
  end

  defp request_metadata(operation) do
    %{
      "request_id" => "#{operation}-request",
      "operation_id" => "#{operation}-operation",
      "ip_address" => "203.0.113.90",
      "user_agent" => "forge-import-e2e-test"
    }
  end

  defp unwrap!({:ok, value}), do: value
end
