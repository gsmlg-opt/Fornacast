defmodule ForgeImports.RetryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi

  alias ForgeAccounts.{GitHubCredential, User}

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    CleanupOperation,
    ObjectMapping,
    PageCheckpoint,
    Persistence,
    ReportEntry,
    RepositoryItem
  }

  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-25 12:00:00Z]
  @pat "github_pat_retry_test_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<11>>, 32)}}
  @terminal_resources ~w(labels issues comments pull_requests releases release_assets_v1 number_sequence)

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    credential = saved_credential_fixture!(actor, identity)

    %{
      actor: actor,
      identity: identity,
      credential: credential,
      view: %{identity_id: identity.id}
    }
  end

  test "retry_import creates a successor with predecessor links for partial organization success",
       %{
         actor: actor,
         identity: identity,
         credential: credential
       } do
    predecessor = terminal_org_run!(actor, identity, :completed_with_warnings)

    published = org_item!(predecessor, actor, 9_100_000_001, "alpha", state: :failed)

    {1, _} =
      Repo.update_all(
        from(item in RepositoryItem, where: item.id == ^published.id),
        set: [state: :published, publication_evidence: %{"published_repository_id" => 1}]
      )

    failed = org_item!(predecessor, actor, 9_100_000_002, "beta", state: :failed)

    skipped =
      org_item!(predecessor, actor, 9_100_000_003, "gamma", state: :skipped, selected: false)

    metadata = request_metadata("partial-org-retry")

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               metadata
             )

    assert successor.predecessor_run_id == predecessor.id
    assert successor.state == :ready
    assert length(successor.repositories) == 1

    assert [%{predecessor_item_id: predecessor_item_id, state: :queued}] =
             successor.repositories

    assert predecessor_item_id == failed.id
    refute predecessor_item_id in [published.id, skipped.id]
    assert Repo.get!(ImportRun, predecessor.id).state == :completed_with_warnings
    assert Repo.get!(RepositoryItem, published.id).state == :published
  end

  test "failed and canceled predecessors are retryable", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    for terminal_state <- [:failed, :canceled] do
      predecessor = terminal_org_run!(actor, identity, terminal_state)

      _item =
        org_item!(
          predecessor,
          actor,
          System.unique_integer([:positive]),
          "retry-#{terminal_state}"
        )

      assert {:ok, successor} =
               ForgeImports.retry_import(
                 actor,
                 predecessor.id,
                 saved_source(credential, identity),
                 request_metadata("retry-#{terminal_state}")
               )

      assert successor.predecessor_run_id == predecessor.id
      assert Enum.all?(successor.repositories, &(&1.predecessor_item_id != nil))
    end
  end

  test "retry excludes intentional skips and published repositories", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)

    _skipped =
      org_item!(predecessor, actor, 9_100_000_010, "skipped-repo",
        state: :skipped,
        selected: false
      )

    _published =
      org_item!(predecessor, actor, 9_100_000_011, "published-repo", state: :failed)

    {1, _} =
      Repo.update_all(
        from(item in RepositoryItem, where: item.source_name == "published-repo"),
        set: [state: :published, publication_evidence: %{"published_repository_id" => 42}]
      )

    retryable =
      org_item!(predecessor, actor, 9_100_000_012, "failed-repo", state: :failed)

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("exclude-published")
             )

    assert [only] = successor.repositories
    assert only.predecessor_item_id == retryable.id
  end

  test "retry adopts validated staging, checkpoints, and mappings", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "staged-retry")

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("adopt-staging")
             )

    assert [summary] = successor.repositories
    reloaded = Repo.get!(RepositoryItem, summary.id)
    assert reloaded.predecessor_item_id == item.id
    assert reloaded.state == :ready_to_publish
    assert reloaded.hidden_repository_id == item.hidden_repository_id
    assert reloaded.staged_storage_path == item.staged_storage_path
    assert reloaded.checkpoint == item.checkpoint
    assert reloaded.source_git == item.source_git

    shadow = Repo.get!(Repository, item.hidden_repository_id)
    assert shadow.slug == "import-#{reloaded.id}-#{shadow_suffix(shadow.slug)}"

    assert Repo.aggregate(
             from(mapping in ObjectMapping, where: mapping.repository_item_id == ^reloaded.id),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(
             from(checkpoint in PageCheckpoint,
               where: checkpoint.repository_item_id == ^reloaded.id
             ),
             :count,
             :id
           ) == length(@terminal_resources)

    assert Repo.get!(RepositoryItem, item.id).hidden_repository_id == item.hidden_repository_id
  end

  test "retry preserves pull candidate evidence under the successor without changing history", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "pull-evidence-retry")
    other = org_item!(predecessor, actor, 9_100_000_090, "other-evidence", selected: false)

    candidates =
      for owner <- [item, other] do
        %ReportEntry{}
        |> ReportEntry.create_changeset(%{
          import_run_id: predecessor.id,
          repository_item_id: owner.id,
          idempotency_key: "pull-candidate-#{owner.id}-7",
          scope: :object,
          object_kind: "pull_request",
          source_object_id: 7,
          outcome: :skipped,
          classification: "pull_candidate",
          summary: "Pull request deferred to pull phase",
          metadata: %{"count" => 7, "github_id" => 101},
          source_count: 0
        })
        |> Repo.insert!()
      end

    assert {:ok, successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("pull-evidence-retry")
             )

    assert [adopted] = successor.repositories

    candidate =
      Repo.get_by!(ReportEntry,
        import_run_id: successor.id,
        repository_item_id: adopted.id,
        classification: "pull_candidate"
      )

    assert candidate.idempotency_key == "pull-candidate-#{adopted.id}-7"
    assert candidate.metadata == %{"count" => 7, "github_id" => 101}
    assert candidate.source_object_id == 7
    assert Enum.map(candidates, &Repo.get!(ReportEntry, &1.id)) == candidates

    assert Repo.aggregate(from(r in ReportEntry, where: r.import_run_id == ^successor.id), :count) ==
             1
  end

  @tag :tmp_dir
  test "retry retains new Git staging after completed remote quarantine cleanup", %{
    actor: actor,
    identity: identity,
    credential: credential,
    tmp_dir: tmp_dir
  } do
    isolate_storage_root!(tmp_dir)

    for effect <- [:removed, :missing] do
      predecessor = terminal_org_run!(actor, identity, :failed)
      item = staged_item!(predecessor, actor, slug: "recloned-#{effect}")
      earlier_cleanup = completed_quarantine!(item, :removed)
      item = Repo.get!(RepositoryItem, item.id)
      cleanup = completed_quarantine!(item, effect)
      item = Repo.get!(RepositoryItem, item.id)

      assert {:ok, successor} =
               ForgeImports.retry_import(
                 actor,
                 predecessor.id,
                 saved_source(credential, identity),
                 request_metadata("recloned-#{effect}")
               )

      assert [summary] = successor.repositories
      adopted = Repo.get!(RepositoryItem, summary.id)
      assert adopted.hidden_repository_id == item.hidden_repository_id
      assert adopted.checkpoint == item.checkpoint
      assert Repo.get!(CleanupOperation, earlier_cleanup.id).state == :cleanup_complete
      assert Repo.get!(CleanupOperation, cleanup.id).state == :cleanup_complete
      assert File.dir?(item.staged_storage_path)
      assert :ok = Persistence.ensure_adoption_safe_locked(Repo, adopted)
    end
  end

  @tag :tmp_dir
  test "completed quarantine history still fences an occupied quarantine slot", %{
    actor: actor,
    identity: identity,
    credential: credential,
    tmp_dir: tmp_dir
  } do
    isolate_storage_root!(tmp_dir)
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "occupied-quarantine")
    cleanup = completed_quarantine!(item, :removed)
    File.mkdir!(cleanup.evidence["quarantine_path"])
    File.chmod!(cleanup.evidence["quarantine_path"], 0o700)

    assert {:error, :cleanup_conflict} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("occupied-quarantine")
             )

    refute Repo.exists?(from r in ImportRun, where: r.predecessor_run_id == ^predecessor.id)
    assert File.dir?(item.staged_storage_path)
  end

  @tag :tmp_dir
  test "cleanup adoption exception rejects unsafe cleanup states and reclaimed staging", %{
    actor: actor,
    identity: identity,
    tmp_dir: tmp_dir
  } do
    isolate_storage_root!(tmp_dir)
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "quarantine-fences")
    cleanup = completed_quarantine!(item, :missing)
    item = Repo.get!(RepositoryItem, item.id)

    for overrides <- [
          [state: :cleanup_pending, completed_at: nil, next_attempt_at: @now],
          [state: :cleanup_blocked, completed_at: nil, last_error: "identity_mismatch"]
        ] do
      Repo.update_all(
        from(o in CleanupOperation, where: o.id == ^cleanup.id),
        set: overrides
      )

      assert {:error, :cleanup_conflict} = Persistence.ensure_adoption_safe_locked(Repo, item)

      Repo.update_all(
        from(o in CleanupOperation, where: o.id == ^cleanup.id),
        set: [
          state: cleanup.state,
          kind: cleanup.kind,
          source_lock_version: cleanup.source_lock_version,
          evidence: cleanup.evidence,
          completed_at: cleanup.completed_at,
          next_attempt_at: cleanup.next_attempt_at,
          last_error: cleanup.last_error
        ]
      )
    end

    for kind <- [:unpublished_shadow, :replacement_tombstone] do
      refute CleanupOperation.valid_completed_quarantine?(%{cleanup | kind: kind})
    end

    unstaged = %{item | checkpoint: %{}}
    assert {:error, :cleanup_conflict} = Persistence.ensure_adoption_safe_locked(Repo, unstaged)
    in_cleanup = %{item | cleanup_state: "cleanup_pending"}
    assert {:error, :cleanup_conflict} = Persistence.ensure_adoption_safe_locked(Repo, in_cleanup)

    Repo.update_all(
      from(r in Repository, where: r.id == ^item.hidden_repository_id),
      set: [storage_reclaimed_at: @now]
    )

    assert {:error, :cleanup_conflict} = Persistence.ensure_adoption_safe_locked(Repo, item)
  end

  test "retry rejects corrupt staging evidence", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    item = staged_item!(predecessor, actor, slug: "corrupt-retry")

    Repo.update_all(
      from(candidate in RepositoryItem, where: candidate.id == ^item.id),
      set: [checkpoint: %{"git_staged" => false}]
    )

    assert {:error, :invalid_predecessor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("corrupt-staging")
             )

    refute Repo.exists?(from run in ImportRun, where: run.predecessor_run_id == ^predecessor.id)
  end

  test "retry never copies a one-time envelope and requires a replacement credential", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = terminal_one_time_run!(actor, identity)
    _item = org_item!(run, actor, 9_100_000_020, "one-time-retry", state: :failed)

    assert Repo.get!(ImportRun, run.id).credential_source == :one_time
    assert is_nil(Repo.get!(ImportRun, run.id).credential_ciphertext)

    assert {:ok, successor_view} =
             ForgeImports.retry_import(
               actor,
               run.id,
               saved_source(credential, identity),
               request_metadata("replace-one-time")
             )

    successor = Repo.get!(ImportRun, successor_view.id)
    assert successor.credential_source == :saved
    assert successor.github_credential_id == credential.id
    assert is_nil(successor.credential_ciphertext)
    assert is_nil(successor.credential_nonce)
    assert is_nil(successor.credential_tag)
    assert is_nil(successor.credential_key_id)
    assert is_nil(Repo.get!(ImportRun, run.id).credential_ciphertext)
  end

  test "retry requires an explicit saved credential for saved-source retries", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    _item = org_item!(predecessor, actor, 9_100_000_030, "needs-credential", state: :failed)

    assert {:error, :forbidden} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               %{credential_source: :saved, github_identity_id: identity.id},
               request_metadata("missing-credential")
             )

    assert {:ok, _successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("with-credential")
             )
  end

  test "restart observes a concurrent actor deactivation before acquiring run locks" do
    actor = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &user_fixture/0)
    parent = self()
    reference = make_ref()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(Repo.get!(User, actor.id))
      end)
    end)

    deactivation =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.update!(Ecto.Changeset.change(actor, state: :disabled))
            send(parent, {reference, :deactivation_pending})

            receive do
              {^reference, :commit} -> :ok
            after
              5_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    assert_receive {^reference, :deactivation_pending}

    restart =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          ForgeImports.Retry.restart(actor, %ImportRun{id: -1}, nil, %{})
        end)
      end)

    try do
      assert Task.yield(restart, 100) == nil
    after
      send(deactivation.pid, {reference, :commit})
      assert {:ok, :ok} = Task.await(deactivation, 5_000)
    end

    assert {:error, :forbidden} = Task.await(restart, 5_000)
  end

  test "concurrent retry calls allow only one successor", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :failed)
    _item = org_item!(predecessor, actor, 9_100_000_040, "concurrent-retry", state: :failed)
    parent = self()
    source = saved_source(credential, identity)
    metadata = request_metadata("concurrent-retry-#{System.unique_integer([:positive])}")

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          send(parent, {:ready, self()})

          receive do
            :go ->
              ForgeImports.retry_import(
                actor,
                predecessor.id,
                source,
                Map.put(metadata, "operation_id", "concurrent-retry-#{index}")
              )
          after
            5_000 -> {:error, :timeout}
          end
        end)
      end

    task_pids = Enum.map(tasks, & &1.pid)

    for pid <- task_pids, do: assert_receive({:ready, ^pid}, 5_000)
    Enum.each(task_pids, &send(&1, :go))

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, fn
             {:error, error} when error in [:invalid_predecessor, :duplicate_successor] -> true
             _ -> false
           end) == 1

    assert Repo.aggregate(
             from(run in ImportRun, where: run.predecessor_run_id == ^predecessor.id),
             :count,
             :id
           ) == 1
  end

  test "predecessor runs and items remain immutable after retry", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    predecessor = terminal_org_run!(actor, identity, :completed_with_warnings)
    item = org_item!(predecessor, actor, 9_100_000_050, "immutable", state: :failed)

    before_run = Repo.get!(ImportRun, predecessor.id)
    before_item = Repo.get!(RepositoryItem, item.id)
    audit_before = Repo.aggregate(AuditEvent, :count, :id)

    assert {:ok, _successor} =
             ForgeImports.retry_import(
               actor,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("immutable-predecessor")
             )

    after_run = Repo.get!(ImportRun, predecessor.id)
    after_item = Repo.get!(RepositoryItem, item.id)

    assert before_run.state == after_run.state
    assert before_run.lock_version == after_run.lock_version
    assert before_item.state == after_item.state
    assert before_item.publication_evidence == after_item.publication_evidence
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_before + 1

    audit =
      Repo.one!(
        from event in AuditEvent,
          where: event.action == "github_import.retry_created",
          order_by: [desc: event.id],
          limit: 1
      )

    assert audit.target_type == "github_import_run"
    assert audit.metadata["predecessor_run_id"] == predecessor.id
    refute inspect(audit) =~ "github_pat_"
  end

  test "retry_import masks foreign runs as not_found", %{
    identity: identity,
    credential: credential
  } do
    owner = user_fixture()
    owner_identity = identity_fixture(owner)
    _owner_credential = saved_credential_fixture!(owner, owner_identity)
    predecessor = terminal_org_run!(owner, owner_identity, :failed)
    _item = org_item!(predecessor, owner, 9_100_000_060, "foreign", state: :failed)

    other = user_fixture()

    assert {:error, :not_found} =
             ForgeImports.retry_import(
               other,
               predecessor.id,
               saved_source(credential, identity),
               request_metadata("foreign-retry")
             )
  end

  defp terminal_org_run!(actor, identity, terminal_state) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :saved,
        github_credential_id: credential_id(actor, identity),
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

    run
  end

  defp terminal_one_time_run!(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: identity.github_user_id,
        source_owner_login: identity.login,
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :discovering,
        selected_count: 0,
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

    run = ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()

    assert {:ok, run} =
             ForgeImports.transition_run(actor, run, :failed, %{terminal_at: @now})

    run
  end

  defp org_item!(run, actor, github_repository_id, slug, overrides \\ []) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/#{slug}",
      source_name: slug,
      source_metadata: %{"archived" => false},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_slug: slug,
      destination_visibility: :private,
      state: :failed,
      publication_evidence: %{},
      attempt_count: 0
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp staged_item!(run, actor, opts) do
    slug = Keyword.fetch!(opts, :slug)
    github_repository_id = System.unique_integer([:positive])

    item =
      org_item!(run, actor, github_repository_id, slug,
        state: :failed,
        attempt_count: 1
      )

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, actor.id, %{
        item_id: item.id,
        generation: 1
      })
      |> Repo.transaction()

    staged_path = ForgeRepos.absolute_storage_path(shadow)
    File.mkdir_p!(Path.dirname(staged_path))
    assert {:ok, ^staged_path} = GitCore.init_bare(staged_path)
    File.chmod!(staged_path, 0o700)

    checkpoint =
      Map.merge(
        %{"git_staged" => true, "unsupported_scan" => "complete"},
        lfs_completion_checkpoint!(shadow, item)
      )

    source_git = %{
      "empty" => true,
      "default_branch" => "main",
      "refs" => 0,
      "bytes" => 0,
      "lfs_detected" => false,
      "submodules_detected" => false,
      "scan_truncated" => false
    }

    assert {1, _} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 hidden_repository_id: shadow.id,
                 staged_storage_path: staged_path,
                 checkpoint: checkpoint,
                 source_git: source_git,
                 state: :failed
               ]
             )

    item = Repo.get!(RepositoryItem, item.id)

    %ObjectMapping{}
    |> ObjectMapping.create_changeset(%{
      repository_item_id: item.id,
      hidden_repository_id: shadow.id,
      github_repository_id: item.github_repository_id,
      object_kind: "issue",
      github_object_id: 101,
      local_resource_type: "issue",
      local_resource_id: 501
    })
    |> Repo.insert!()

    for resource <- @terminal_resources do
      %PageCheckpoint{}
      |> PageCheckpoint.create_changeset(%{
        repository_item_id: item.id,
        resource_kind: resource,
        page_key: "__terminal_v1__",
        etag: "etag-#{resource}",
        observed_at: @now,
        item_count: 1,
        cursor_metadata: %{},
        committed_at: @now
      })
      |> Repo.insert!()
    end

    item
  end

  defp isolate_storage_root!(tmp_dir) do
    previous = Application.get_env(:fornacast, :repo_storage_root)
    root = Path.join(tmp_dir, "repos")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    Application.put_env(:fornacast, :repo_storage_root, root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous) end)
  end

  defp completed_quarantine!(item, effect) do
    repository = Repo.get!(Repository, item.hidden_repository_id)
    root = Fornacast.Config.repo_storage_root()
    target = GitCore.Remote.cleanup_slot_path(item.staged_storage_path)
    relative = Path.relative_to(target, root)
    segments = String.split(relative, "/")
    File.mkdir!(target)
    File.chmod!(target, 0o700)
    assert {:ok, {:present, proof}} = GitCore.contained_tree_identity(root, segments, 1_000)
    stringify = fn identity -> Map.new(identity, fn {k, v} -> {to_string(k), v} end) end

    evidence =
      %{
        "version" => 1,
        "kind" => "remote_quarantine",
        "storage_root" => root,
        "relative_path" => relative,
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_storage_path" => repository.storage_path,
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "requested_path" => item.staged_storage_path,
        "quarantine_path" => target,
        "remote_failure_kind" => "remote_clone_failed"
      }
      |> Map.merge(stringify.(proof.target))

    operation =
      %CleanupOperation{}
      |> CleanupOperation.create_changeset(%{
        repository_id: repository.id,
        repository_item_id: item.id,
        source_lock_version: item.lock_version,
        kind: :remote_quarantine,
        operation_id:
          CleanupOperation.deterministic_operation_id(
            :remote_quarantine,
            repository.id,
            item.id,
            item.lock_version
          ),
        evidence: evidence,
        eligible_at: @now,
        next_attempt_at: @now
      })
      |> Repo.insert!()

    File.rmdir!(target)

    evidence =
      case effect do
        :removed ->
          evidence
          |> Map.put("root_identity", stringify.(proof.root))
          |> Map.put("anchored_identity", stringify.(proof.target))

        :missing ->
          Map.put(evidence, "anchored_absence", %{
            "version" => 1,
            "observed_at" => DateTime.to_iso8601(@now),
            "root_identity" => stringify.(proof.root)
          })
      end

    complete =
      operation
      |> CleanupOperation.lease_update_changeset(
        state: :cleanup_complete,
        evidence: evidence,
        next_attempt_at: nil,
        effect_started_at: @now,
        effect_finished_at: @now,
        completed_at: @now
      )
      |> Repo.update!()

    Repo.update_all(
      from(i in RepositoryItem, where: i.id == ^item.id),
      inc: [lock_version: 2]
    )

    complete
  end

  defp lfs_completion_checkpoint!(shadow, item) do
    {:ok, scan} =
      GitLFS.PointerScanner.begin_scan(
        shadow,
        "retry-fixture:#{item.id}",
        []
      )

    {:ok, published} = GitLFS.PointerScanner.publish_scan(scan)

    %{
      "lfs_import" => %{
        "status" => "complete",
        "repository_generation" => shadow.generation,
        "scan_id" => published.id,
        "scan_key" => published.scan_key,
        "baseline_fingerprint" => published.baseline_fingerprint,
        "object_cursor" => nil
      }
    }
  end

  defp saved_source(credential, identity) do
    %{
      credential_source: :saved,
      github_credential_id: credential.id,
      github_identity_id: identity.id
    }
  end

  defp credential_id(actor, identity) do
    Repo.one!(
      from credential in GitHubCredential,
        where:
          credential.local_user_id == ^actor.id and credential.github_identity_id == ^identity.id,
        select: credential.id,
        limit: 1
    )
  end

  defp shadow_suffix(slug) do
    case Regex.run(~r/\Aimport-[0-9]+-([0-9a-f]{24})\z/, slug) do
      [_, suffix] -> suffix
      _ -> flunk("unexpected shadow slug #{slug}")
    end
  end

  defp saved_credential_fixture!(actor, identity) do
    case Repo.get_by(GitHubCredential, github_identity_id: identity.id) do
      %GitHubCredential{} = existing -> existing
      nil -> insert_saved_credential!(actor, identity)
    end
  end

  defp insert_saved_credential!(actor, identity) do
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
      ForgeAccounts.GitHubCredentialVault.encrypt_saved(
        placeholder,
        identity,
        @pat,
        @keyring
      )

    {1, _rows} =
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

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_200_000_000 + suffix,
          login: "retry-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/retry-#{suffix}"
        },
        @now
      )

    case ForgeAccounts.link_github_identity(actor, identity) do
      {:ok, linked} -> linked
      {:error, :already_linked} -> identity
    end
  end

  defp request_metadata(operation_id) do
    %{
      "request_id" => "retry-test-#{System.unique_integer([:positive])}",
      "operation_id" => operation_id,
      "user_agent" => "ExUnit"
    }
  end

  defp user_fixture do
    suffix =
      Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false) <>
        "-#{System.unique_integer([:positive, :monotonic])}"

    Repo.insert!(%User{
      username: "retry-#{suffix}",
      email: "retry-#{suffix}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: flunk("expected success, got #{inspect(reason)}")

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
