defmodule ForgeImports.ImportPersistenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.GitHubCredential

  alias ForgeImports.{
    CleanupOperation,
    ImportAttempt,
    ImportRun,
    ObjectMapping,
    OneTimeCredential,
    PageCheckpoint,
    Persistence,
    ReportEntry,
    RepositoryItem,
    RunView
  }

  alias ForgeRepos.Repository
  alias Fornacast.{OperationLease, Repo}

  @moduletag :persistence
  @now ~U[2026-08-25 12:00:00Z]
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<7>>, 32)}}
  @run_transitions %{
    discovering: [:awaiting_resolution, :failed, :canceled],
    awaiting_resolution: [:ready, :awaiting_credential, :canceled],
    ready: [:running, :awaiting_credential, :canceled],
    running: [
      :awaiting_credential,
      :cancel_requested,
      :completed,
      :completed_with_warnings,
      :failed
    ],
    awaiting_credential: [
      :awaiting_resolution,
      :ready,
      :running,
      :cancel_requested,
      :canceled
    ],
    cancel_requested: [:canceled, :completed, :completed_with_warnings]
  }
  @item_transitions %{
    queued: [
      :awaiting_resolution,
      :staging_git,
      :awaiting_credential,
      :cancel_requested,
      :skipped,
      :canceled,
      :failed
    ],
    awaiting_resolution: [
      :queued,
      :awaiting_credential,
      :cancel_requested,
      :skipped,
      :canceled,
      :failed
    ],
    staging_git: [:git_staged, :awaiting_credential, :cancel_requested, :failed],
    git_staged: [:staging_metadata, :awaiting_credential, :cancel_requested, :failed],
    staging_metadata: [:ready_to_publish, :awaiting_credential, :cancel_requested, :failed],
    ready_to_publish: [:publishing, :awaiting_credential, :cancel_requested, :failed],
    publishing: [:published],
    published: [:completed],
    awaiting_credential: [
      :queued,
      :awaiting_resolution,
      :staging_git,
      :git_staged,
      :staging_metadata,
      :ready_to_publish,
      :publishing,
      :cancel_requested,
      :canceled,
      :failed
    ],
    cancel_requested: [:canceled, :published, :completed]
  }

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    %{actor: actor, identity: identity}
  end

  test "schemas expose the durable table and field shape" do
    assert ImportRun.__schema__(:source) == "github_import_runs"
    assert RepositoryItem.__schema__(:source) == "github_import_repository_items"
    assert ImportAttempt.__schema__(:source) == "github_import_attempts"
    assert ObjectMapping.__schema__(:source) == "github_import_object_mappings"
    assert PageCheckpoint.__schema__(:source) == "github_import_page_checkpoints"
    assert ReportEntry.__schema__(:source) == "github_import_report_entries"

    for field <- [
          :actor_user_id,
          :predecessor_run_id,
          :source_kind,
          :github_identity_id,
          :credential_source,
          :github_credential_id,
          :source_owner_github_id,
          :source_owner_login,
          :source_repository_github_id,
          :source_repository_full_name,
          :destination_organization_action,
          :destination_organization_slug,
          :destination_organization_id,
          :destination_organization_status,
          :destination_organization_classification,
          :state,
          :resume_state,
          :wait_reason,
          :next_attempt_at,
          :cancellation_requested_at,
          :terminal_at,
          :report_finalized_at,
          :selected_count,
          :published_count,
          :skipped_count,
          :warning_count,
          :failure_count,
          :request_metadata,
          :credential_ciphertext,
          :credential_nonce,
          :credential_tag,
          :credential_key_id,
          :lease_owner,
          :lease_expires_at,
          :lock_version
        ] do
      assert field in ImportRun.__schema__(:fields)
    end

    for field <- [
          :import_run_id,
          :predecessor_item_id,
          :github_repository_id,
          :source_full_name,
          :source_name,
          :source_metadata,
          :source_observed_at,
          :selected,
          :destination_owner_id,
          :destination_slug,
          :destination_visibility,
          :conflict_action,
          :replacement_repository_id,
          :replacement_owner_id,
          :replacement_storage_path,
          :replacement_generation,
          :replacement_write_version,
          :replacement_updated_at,
          :replacement_last_pushed_at,
          :hidden_repository_id,
          :staged_storage_path,
          :state,
          :resume_state,
          :wait_reason,
          :next_attempt_at,
          :lease_owner,
          :lease_expires_at,
          :lock_version,
          :attempt_count,
          :failure_kind,
          :failure_detail,
          :checkpoint,
          :source_git,
          :publication_evidence,
          :imported_count,
          :skipped_count,
          :warning_count,
          :failure_count,
          :cleanup_state,
          :cleanup_eligible_at,
          :cleanup_attempt_count,
          :cleanup_error
        ] do
      assert field in RepositoryItem.__schema__(:fields)
    end
  end

  test "database rejects a negative replacement write version", %{
    actor: actor,
    identity: identity
  } do
    run = run_fixture(actor, identity)
    item = item_fixture(run)
    [value_placeholder, id_placeholder] = database_placeholders(2)

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "update github_import_repository_items " <>
                 "set replacement_write_version = #{value_placeholder} " <>
                 "where id = #{id_placeholder}",
               [-1, item.id]
             )

    assert Exception.message(error) =~
             "github_import_items_replacement_write_version_nonnegative_check"
  end

  test "saved and one-time credentials are mutually consistent", %{
    actor: actor,
    identity: identity
  } do
    credential = credential_fixture(actor, identity)

    assert {:ok, saved} =
             %ImportRun{}
             |> ImportRun.persistence_changeset(
               run_attrs(actor, identity,
                 credential_source: :saved,
                 github_credential_id: credential.id
               )
             )
             |> Repo.insert()

    assert saved.github_credential_id == credential.id

    assert {:ok, one_time} =
             %ImportRun{}
             |> ImportRun.persistence_changeset(
               run_attrs(actor, identity,
                 source_owner_github_id: 9_000_000_002,
                 credential_source: :one_time
               )
             )
             |> Repo.insert()

    assert one_time.github_credential_id == nil

    invalid = [
      run_attrs(actor, identity, credential_source: :saved, github_credential_id: nil),
      run_attrs(actor, identity,
        credential_source: :saved,
        github_credential_id: credential.id,
        credential_ciphertext: <<1>>,
        credential_nonce: :binary.copy(<<2>>, 12),
        credential_tag: :binary.copy(<<3>>, 16),
        credential_key_id: "test-v1"
      ),
      run_attrs(actor, identity,
        credential_source: :one_time,
        github_credential_id: credential.id
      ),
      run_attrs(actor, identity,
        credential_source: :one_time,
        credential_ciphertext: <<1>>,
        credential_nonce: :binary.copy(<<2>>, 12)
      )
    ]

    for attrs <- invalid do
      refute ImportRun.persistence_changeset(%ImportRun{}, attrs).valid?
    end
  end

  test "one-time encrypt attach and terminal transition clear the envelope atomically", %{
    actor: actor,
    identity: identity
  } do
    run = run_fixture(actor, identity, state: :running)

    assert {:ok, envelope} =
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               run.id,
               actor.id,
               identity.github_user_id,
               "github_pat_secret",
               @keyring
             )

    assert {:ok, run} =
             ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring)

    assert run.credential_ciphertext == envelope.ciphertext
    refute inspect(run) =~ Base.encode16(envelope.ciphertext)

    now = DateTime.utc_now(:second)
    assert {:ok, claimed} = OperationLease.claim(ImportRun, run.id, "worker-a", now, 60)

    assert {:ok, :acknowledged} =
             OneTimeCredential.with_credential(
               actor,
               claimed,
               fn plaintext ->
                 assert plaintext == "github_pat_secret"
                 :ok
               end,
               @keyring
             )

    assert :ok = OperationLease.release(ImportRun, claimed)
    run = Repo.get!(ImportRun, run.id)

    assert {:ok, terminal} =
             ForgeImports.transition_run(actor, run, :failed, %{terminal_at: @now})

    assert terminal.state == :failed
    assert terminal.terminal_at == @now
    assert terminal.credential_ciphertext == nil
    assert terminal.credential_nonce == nil
    assert terminal.credential_tag == nil
    assert terminal.credential_key_id == nil
    assert Repo.get!(ImportRun, run.id) == terminal
  end

  test "one-time callback custody rejects secret-shaped results and permits only safe results", %{
    actor: actor,
    identity: identity
  } do
    run = one_time_run_with_envelope(actor, identity)

    for callback <- [
          fn pat -> pat end,
          fn pat ->
            {:error, [binary_part(pat, 0, 6), binary_part(pat, 6, byte_size(pat) - 6)]}
          end,
          fn pat -> {:error, String.to_charlist(pat)} end,
          fn _pat -> {:error, :github_pat_secret} end
        ] do
      assert {:error, :unsafe_credential_result} =
               OneTimeCredential.with_credential(actor, run, callback, @keyring)
    end

    assert {:ok, :acknowledged} =
             OneTimeCredential.with_credential(
               actor,
               run,
               fn _pat -> {:error, {:rate_limited, 429, [:retryable, 3]}} end,
               @keyring
             )

    assert {:ok, :acknowledged} =
             OneTimeCredential.with_credential(actor, run, fn _pat -> :ok end, @keyring)
  end

  test "one-time callback exceptions and captured stack arguments never expose plaintext", %{
    actor: actor,
    identity: identity
  } do
    run = one_time_run_with_envelope(actor, identity)

    raised =
      assert_raise ForgeAccounts.GitHubAccounts.CredentialCallbackError,
                   "credential callback failed",
                   fn ->
                     OneTimeCredential.with_credential(
                       actor,
                       run,
                       fn pat -> raise pat end,
                       @keyring
                     )
                   end

    refute Exception.message(raised) =~ "github_pat_secret"
    refute inspect(raised) =~ "github_pat_secret"

    {error, stacktrace} =
      try do
        OneTimeCredential.with_credential(
          actor,
          run,
          fn pat -> String.to_integer(pat) end,
          @keyring
        )

        flunk("credential-bearing stack was not sanitized")
      rescue
        error -> {error, __STACKTRACE__}
      end

    assert %ForgeAccounts.GitHubAccounts.CredentialCallbackError{} = error
    refute Exception.format(:error, error, stacktrace) =~ "github_pat_secret"
    refute inspect({error, stacktrace}) =~ "github_pat_secret"
  end

  test "terminal runs reject one-time credential attachment through every public changeset", %{
    actor: actor,
    identity: identity
  } do
    for terminal <- [:failed, :completed, :canceled] do
      run =
        run_fixture(actor, identity,
          state: terminal,
          terminal_at: @now,
          source_owner_github_id: terminal_id(terminal)
        )

      assert {:ok, envelope} =
               ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
                 run.id,
                 actor.id,
                 identity.github_user_id,
                 "github_pat_secret",
                 @keyring
               )

      refute OneTimeCredential.attach_changeset(run, envelope).valid?

      refute ImportRun.one_time_credential_changeset(run, %{
               credential_ciphertext: envelope.ciphertext,
               credential_nonce: envelope.nonce,
               credential_tag: envelope.tag,
               credential_key_id: envelope.key_id
             }).valid?
    end
  end

  test "run transition map is exact and terminal runs are immutable" do
    assert ImportRun.states() == [
             :discovering,
             :awaiting_resolution,
             :ready,
             :running,
             :awaiting_credential,
             :cancel_requested,
             :completed,
             :completed_with_warnings,
             :canceled,
             :failed
           ]

    for from <- ImportRun.states(), to <- ImportRun.states(), from != to do
      resume_state =
        if from == :awaiting_credential and to in [:awaiting_resolution, :ready, :running],
          do: to,
          else: nil

      changeset =
        ImportRun.transition_changeset(
          struct(ImportRun, state: from, resume_state: resume_state),
          to,
          %{}
        )

      assert changeset.valid? == to in Map.get(@run_transitions, from, []),
             "unexpected run transition #{from} -> #{to}: #{inspect(changeset.errors)}"
    end

    for terminal <- ImportRun.terminal_states() do
      changeset =
        ImportRun.transition_changeset(struct(ImportRun, state: terminal), :running, %{})

      refute changeset.valid?
    end
  end

  test "repository item transition map is exact and terminal items are immutable" do
    assert RepositoryItem.states() == [
             :queued,
             :awaiting_resolution,
             :staging_git,
             :git_staged,
             :staging_metadata,
             :ready_to_publish,
             :publishing,
             :published,
             :completed,
             :awaiting_credential,
             :cancel_requested,
             :skipped,
             :canceled,
             :failed
           ]

    for from <- RepositoryItem.states(), to <- RepositoryItem.states(), from != to do
      resume_state =
        if from == :awaiting_credential and
             to in [
               :queued,
               :awaiting_resolution,
               :staging_git,
               :git_staged,
               :staging_metadata,
               :ready_to_publish,
               :publishing
             ],
           do: to,
           else: nil

      changeset =
        RepositoryItem.transition_changeset(
          struct(RepositoryItem, state: from, resume_state: resume_state),
          to,
          %{}
        )

      assert changeset.valid? == to in Map.get(@item_transitions, from, []),
             "unexpected item transition #{from} -> #{to}: #{inspect(changeset.errors)}"
    end
  end

  test "publication changesets enforce exact canonical intent and committed evidence" do
    item = %RepositoryItem{
      id: 71,
      import_run_id: 81,
      selected: true,
      state: :ready_to_publish,
      hidden_repository_id: 91,
      publication_evidence: %{},
      cleanup_state: nil,
      lock_version: 1,
      cleanup_attempt_count: 0
    }

    intent = %{
      "version" => 1,
      "state" => "intent",
      "attempt_number" => 1,
      "action" => "create",
      "hidden_repository_id" => 91,
      "operation_id" => "github-import-publication-71-1",
      "request_metadata" => %{"request_id" => "publication-shape"}
    }

    expires_at = DateTime.add(@now, 30, :second)
    valid_intent = RepositoryItem.publication_intent_changeset(item, intent, "owner", expires_at)
    assert valid_intent.valid?

    refute RepositoryItem.publication_intent_changeset(
             item,
             Map.put(intent, "extra", true),
             "owner",
             expires_at
           ).valid?

    refute RepositoryItem.publication_intent_changeset(
             item,
             put_in(intent, ["request_metadata"], %{"request_id" => "/private/path"}),
             "owner",
             expires_at
           ).valid?

    publishing = Ecto.Changeset.apply_changes(valid_intent)

    committed =
      intent
      |> Map.put("state", "committed")
      |> Map.merge(%{
        "repository_id" => 91,
        "owner_user_id" => 1,
        "slug" => "published",
        "generation" => 1,
        "replaced_repository_id" => nil,
        "run_id" => 81,
        "published_count_after" => 1,
        "run_lock_version_after" => 2
      })

    assert RepositoryItem.publication_commit_changeset(publishing, committed).valid?

    refute RepositoryItem.publication_commit_changeset(
             publishing,
             Map.put(committed, "state", "intent")
           ).valid?
  end

  test "positive signed 64-bit IDs and nonnegative counts are enforced", %{
    actor: actor,
    identity: identity
  } do
    for github_id <- [0, -1, 9_223_372_036_854_775_808] do
      changeset =
        ImportRun.persistence_changeset(
          %ImportRun{},
          run_attrs(actor, identity, source_owner_github_id: github_id)
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :source_owner_github_id)
    end

    assert ImportRun.persistence_changeset(
             %ImportRun{},
             run_attrs(actor, identity, source_owner_github_id: 9_223_372_036_854_775_807)
           ).valid?

    for field <- [
          :selected_count,
          :published_count,
          :skipped_count,
          :warning_count,
          :failure_count
        ] do
      refute ImportRun.persistence_changeset(
               %ImportRun{},
               run_attrs(actor, identity, [{field, -1}])
             ).valid?
    end
  end

  test "predecessor links persist and deletion nilifies successors", %{
    actor: actor,
    identity: identity
  } do
    predecessor = run_fixture(actor, identity)

    successor =
      run_fixture(actor, identity, predecessor_run_id: predecessor.id, source_owner_github_id: 2)

    old_item = item_fixture(predecessor, github_repository_id: 11)
    new_item = item_fixture(successor, github_repository_id: 12, predecessor_item_id: old_item.id)

    Repo.delete!(old_item)
    assert Repo.get!(RepositoryItem, new_item.id).predecessor_item_id == nil

    Repo.delete!(predecessor)
    assert Repo.get!(ImportRun, successor.id).predecessor_run_id == nil
  end

  test "cleanup intent permanently fences successor adoption", %{actor: actor, identity: identity} do
    predecessor = run_fixture(actor, identity, state: :failed, terminal_at: @now)
    repository = repository_fixture(actor)
    item = item_fixture(predecessor, state: :failed)

    Repo.update_all(
      from(candidate in RepositoryItem, where: candidate.id == ^item.id),
      set: [hidden_repository_id: repository.id]
    )

    item = Repo.get!(RepositoryItem, item.id)
    attrs = remote_cleanup_attrs(repository, item)

    assert {:ok, cleanup} = Persistence.create_cleanup_operation(item, attrs)

    root = %{"mode" => 16_384, "major_device" => 8, "minor_device" => 1, "inode" => 16}
    finished = DateTime.add(@now, 1, :second)

    evidence =
      Map.put(cleanup.evidence, "anchored_absence", %{
        "version" => 1,
        "observed_at" => DateTime.to_iso8601(@now),
        "root_identity" => root
      })

    cleanup =
      cleanup
      |> CleanupOperation.lease_update_changeset(
        state: :cleanup_complete,
        evidence: evidence,
        next_attempt_at: nil,
        effect_started_at: @now,
        effect_finished_at: finished,
        completed_at: finished
      )
      |> Repo.update!()

    assert cleanup.state == :cleanup_complete

    successor =
      run_fixture(actor, identity,
        predecessor_run_id: predecessor.id,
        source_owner_github_id: 9_000_000_002
      )

    assert {:error, :invalid_predecessor} =
             ForgeImports.create_repository_item(actor, successor, %{
               predecessor_item_id: item.id,
               github_repository_id: 9_000_000_102,
               source_full_name: "acme/successor",
               source_name: "successor",
               source_metadata: %{},
               source_observed_at: @now
             })
  end

  test "cleanup intent preserves persistence outages without mutating its item", %{
    actor: actor,
    identity: identity
  } do
    run = run_fixture(actor, identity, state: :failed, terminal_at: @now)
    repository = repository_fixture(actor)
    item = item_fixture(run, state: :failed)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [hidden_repository_id: repository.id]
             )

    item = Repo.get!(RepositoryItem, item.id)
    attrs = remote_cleanup_attrs(repository, item)

    for failure <- [
          fn -> raise DBConnection.ConnectionError, "injected cleanup intent query failure" end,
          fn -> raise Turso.Error, code: :io, message: "injected cleanup intent query failure" end
        ] do
      assert {:error, :persistence_unavailable} =
               Persistence.with_test_after_adoption_safety_hook(failure, fn ->
                 Persistence.create_cleanup_operation(item, attrs)
               end)

      assert Repo.get!(RepositoryItem, item.id) == item

      assert Repo.aggregate(
               from(cleanup in CleanupOperation,
                 where: cleanup.repository_item_id == ^item.id
               ),
               :count,
               :id
             ) == 0
    end
  end

  test "only the current cleanup lease owner can complete a claimed cleanup", %{
    actor: actor,
    identity: identity
  } do
    cleanup = cleanup_fixture(actor, identity)

    assert {:ok, stale} =
             OperationLease.claim(CleanupOperation, cleanup.id, "cleanup-worker-a", @now, 5)

    assert {:ok, claimed} =
             OperationLease.claim(
               CleanupOperation,
               cleanup.id,
               "cleanup-worker-b",
               DateTime.add(@now, 6, :second),
               30
             )

    assert {:error, :lost_lease} =
             OperationLease.update_owned(CleanupOperation, stale,
               state: :cleanup_blocked,
               next_attempt_at: nil,
               last_error: "identity_mismatch"
             )

    finished = DateTime.add(@now, 7, :second)

    evidence =
      Map.put(claimed.evidence, "anchored_absence", %{
        "version" => 1,
        "observed_at" => DateTime.to_iso8601(finished),
        "root_identity" => %{
          "mode" => 16_384,
          "major_device" => 8,
          "minor_device" => 1,
          "inode" => 16
        }
      })

    assert {:ok, complete} =
             OperationLease.update_owned(CleanupOperation, claimed,
               state: :cleanup_complete,
               evidence: evidence,
               next_attempt_at: nil,
               effect_started_at: finished,
               effect_finished_at: finished,
               completed_at: finished
             )

    assert complete.state == :cleanup_complete
    assert complete.lease_owner == nil
    assert complete.lease_expires_at == nil
  end

  test "claimed cleanup can block after the live storage root changes", %{
    actor: actor,
    identity: identity
  } do
    cleanup = cleanup_fixture(actor, identity)
    original_evidence = cleanup.evidence

    assert {:ok, claimed} =
             OperationLease.claim(CleanupOperation, cleanup.id, "cleanup-worker", @now, 30)

    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(original_root, "moved"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    assert {:ok, blocked} =
             OperationLease.update_owned(CleanupOperation, claimed,
               state: :cleanup_blocked,
               next_attempt_at: nil,
               last_error: "storage_root_changed"
             )

    assert blocked.state == :cleanup_blocked
    assert blocked.evidence == original_evidence
    assert blocked.lease_owner == nil
    assert blocked.lease_expires_at == nil
  end

  test "repository items default selected and selection is mutable only before work", %{
    actor: actor,
    identity: identity
  } do
    run = run_fixture(actor, identity)
    item = item_fixture(run)
    assert item.selected
    assert {:ok, run} = ForgeImports.transition_run(actor, run, :awaiting_resolution)

    assert {:ok, %{run: run, item: deselected}} =
             ForgeImports.select_repository_item(actor, run, item, false)

    refute deselected.selected
    assert run.selected_count == 0

    working = %{deselected | state: :staging_git}
    refute RepositoryItem.selection_changeset(working, %{selected: true}).valid?
  end

  test "run and item leases claim renew update and release", %{actor: actor, identity: identity} do
    run = run_fixture(actor, identity, state: :ready)
    item = item_fixture(run)

    for {module, row, update} <- [
          {ImportRun, run, [state: :running]},
          {RepositoryItem, item, [state: :staging_git]}
        ] do
      assert {:ok, claimed} = OperationLease.claim(module, row.id, "worker-a", @now, 30)

      assert {:ok, renewed} =
               OperationLease.renew_owned(module, claimed,
                 now: DateTime.add(@now, 5, :second),
                 lease_seconds: 30
               )

      assert {:ok, updated} = OperationLease.update_owned(module, renewed, update)
      assert updated.state == Keyword.fetch!(update, :state)
      assert updated.lease_owner == nil
      assert updated.lease_expires_at == nil
      assert {:ok, released_claim} = OperationLease.claim(module, row.id, "worker-b", @now, 30)
      assert :ok = OperationLease.release(module, released_claim)
    end
  end

  test "lease-owned terminal run update clears envelope and releases exactly once", %{
    actor: actor,
    identity: identity
  } do
    claimed = one_time_run_with_envelope(actor, identity)

    assert {:ok, terminal} = OperationLease.update_owned(ImportRun, claimed, state: :failed)
    assert terminal.state == :failed
    assert %DateTime{} = terminal.terminal_at
    assert terminal.credential_ciphertext == nil
    assert terminal.credential_nonce == nil
    assert terminal.credential_tag == nil
    assert terminal.credential_key_id == nil
    assert terminal.lease_owner == nil
    assert terminal.lease_expires_at == nil
  end

  test "lease-owned terminal item update releases exactly once", %{
    actor: actor,
    identity: identity
  } do
    run = run_fixture(actor, identity)
    item = item_fixture(run, state: :ready_to_publish)
    assert {:ok, claimed} = OperationLease.claim(RepositoryItem, item.id, "worker-a", @now, 30)

    assert {:ok, terminal} =
             OperationLease.update_owned(RepositoryItem, claimed, state: :failed)

    assert terminal.state == :failed
    assert terminal.lease_owner == nil
    assert terminal.lease_expires_at == nil
  end

  test "uniqueness boundaries return named changeset errors", %{actor: actor, identity: identity} do
    run = run_fixture(actor, identity)
    item = item_fixture(run)
    hidden = repository_fixture(actor)

    assert_unique(fn -> insert_item(run, %{}) end, :github_repository_id)

    attempt_fixture(item, 1)
    assert_unique(fn -> attempt_fixture(item, 1) end, :attempt_number)

    mapping_fixture(item, hidden)
    assert_unique(fn -> mapping_fixture(item, hidden) end, :github_object_id)

    checkpoint_fixture(item)
    assert_unique(fn -> checkpoint_fixture(item) end, :page_key)

    report_fixture(run, item)
    assert_unique(fn -> report_fixture(run, item) end, :idempotency_key)
  end

  test "object mappings require a hidden repository", %{actor: actor, identity: identity} do
    run = run_fixture(actor, identity)
    item = item_fixture(run)

    changeset =
      ObjectMapping.create_changeset(%ObjectMapping{}, %{
        repository_item_id: item.id,
        github_repository_id: item.github_repository_id,
        object_kind: "issue",
        github_object_id: 99,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: 1,
        source_url: "https://github.com/acme/demo/issues/99"
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :hidden_repository_id)

    placeholders = database_placeholders(8)

    assert {:error, _reason} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_object_mappings " <>
                 "(repository_item_id, hidden_repository_id, github_repository_id, object_kind, github_object_id, local_resource_type, local_resource_id, inserted_at, updated_at) " <>
                 "values (#{Enum.at(placeholders, 0)}, null, #{Enum.drop(placeholders, 1) |> Enum.join(", ")})",
               [
                 item.id,
                 item.github_repository_id,
                 "issue",
                 100,
                 "ForgeIssues.Issue",
                 2,
                 @now,
                 @now
               ]
             )
  end

  test "checkpoint and report fields are bounded and report metadata rejects secrets", %{
    actor: actor,
    identity: identity
  } do
    run = run_fixture(actor, identity)
    item = item_fixture(run)

    refute PageCheckpoint.create_changeset(%PageCheckpoint{}, %{
             repository_item_id: item.id,
             resource_kind: String.duplicate("a", 121),
             page_key: "1",
             item_count: -1,
             cursor_metadata: %{}
           }).valid?

    for metadata <- [
          %{"token" => "secret"},
          %{"nested" => %{"storage_path" => "/private/repo.git"}},
          %{"authorization" => "Bearer secret"},
          %{"raw_body" => "secret"}
        ] do
      changeset =
        ReportEntry.create_changeset(%ReportEntry{}, %{
          import_run_id: run.id,
          repository_item_id: item.id,
          idempotency_key: "report-#{System.unique_integer([:positive])}",
          scope: :repository,
          outcome: :warning,
          classification: "unsupported",
          summary: "bounded summary",
          metadata: metadata,
          source_count: 1
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :metadata)
    end

    for metadata <- [
          %{"nested" => {"authorization", "Bearer secret"}},
          %{"nested" => [Authorization: "Bearer secret"]},
          %{"nested" => [{"AuThOrIzAtIoN", "Bearer secret"}]}
        ] do
      changeset =
        ReportEntry.create_changeset(%ReportEntry{}, %{
          import_run_id: run.id,
          repository_item_id: item.id,
          idempotency_key: "report-#{System.unique_integer([:positive])}",
          scope: :repository,
          outcome: :warning,
          classification: "unsupported",
          summary: "bounded summary",
          metadata: metadata,
          source_count: 1
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :metadata)
    end
  end

  test "import attempt Inspect never renders immutable decision evidence" do
    attempt = %ImportAttempt{
      decision: %{
        "conflict_action" => "replace",
        "replacement_storage_path" => "/absolute/secret/repository.git"
      }
    }

    inspected = inspect(attempt)
    refute inspected =~ "decision"
    refute inspected =~ "replacement_storage_path"
    refute inspected =~ "/absolute/secret/repository.git"
  end

  test "foreign keys cascade, restrict, and nilify as specified", %{
    actor: actor,
    identity: identity
  } do
    credential = credential_fixture(actor, identity)

    run =
      run_fixture(actor, identity,
        state: :ready,
        credential_source: :saved,
        github_credential_id: credential.id
      )

    terminal_run =
      run_fixture(actor, identity,
        state: :failed,
        terminal_at: @now,
        credential_source: :saved,
        github_credential_id: credential.id,
        source_owner_github_id: 9_000_000_099
      )

    item = item_fixture(run)
    hidden = repository_fixture(actor)
    mapping = mapping_fixture(item, hidden)
    attempt_fixture(item, 1)
    checkpoint_fixture(item)
    report_fixture(run, item)

    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(hidden) end
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(identity) end
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(actor) end

    assert {:ok, run} = ForgeImports.transition_run(actor, run, :awaiting_credential)
    Repo.delete!(credential)
    recovery_input = Repo.get!(ImportRun, run.id)
    assert recovery_input.credential_source == :saved
    assert recovery_input.github_credential_id == nil
    assert Repo.get!(ImportRun, terminal_run.id).github_credential_id == nil

    Repo.delete!(run)
    assert Repo.get(RepositoryItem, item.id) == nil
    assert Repo.get(ObjectMapping, mapping.id) == nil
  end

  test "actor-scoped RunView and Inspect never expose credentials paths or secret metadata", %{
    actor: actor,
    identity: identity
  } do
    run =
      run_fixture(actor, identity,
        state: :running,
        request_metadata: %{"request_id" => "safe"},
        destination_organization_status: :invalid,
        destination_organization_classification: "reserved_namespace"
      )

    staged_path = Path.join(Fornacast.Config.repo_storage_root(), "private/secret/repository.git")
    item = item_fixture(run, staged_storage_path: staged_path)
    other = user_fixture()

    assert {:ok, owned} = ForgeImports.get_run(actor, run.id)
    assert owned.id == run.id
    assert {:error, :not_found} = ForgeImports.get_run(other, run.id)

    view = RunView.from_run(run, [item])
    inspected = inspect(view)
    assert view.actor_user_id == actor.id
    assert view.source.owner_login == "acme"
    assert view.destination.organization_status == :invalid
    assert view.destination.organization_classification == "reserved_namespace"
    assert [%{github_repository_id: 9_000_000_101}] = view.repositories

    for forbidden <- [
          "credential_ciphertext",
          "credential_nonce",
          "credential_tag",
          "credential_key_id",
          "github_credential_id",
          staged_path,
          "storage_path"
        ] do
      refute inspected =~ forbidden
      refute forbidden in Enum.map(Map.keys(Map.from_struct(view)), &Atom.to_string/1)
    end
  end

  defp run_fixture(actor, identity, overrides \\ []) do
    attrs = run_attrs(actor, identity, overrides)

    attrs
    |> Persistence.insert_run()
    |> unwrap_or_raise()
  end

  defp one_time_run_with_envelope(actor, identity) do
    run = run_fixture(actor, identity, state: :running)

    assert {:ok, envelope} =
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               run.id,
               actor.id,
               identity.github_user_id,
               "github_pat_secret",
               @keyring
             )

    attached =
      ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap_or_raise()

    OperationLease.claim(
      ImportRun,
      attached.id,
      "test-worker-#{System.unique_integer([:positive])}",
      DateTime.utc_now(:second),
      60
    )
    |> unwrap_or_raise()
  end

  defp terminal_id(:failed), do: 9_100_000_001
  defp terminal_id(:completed), do: 9_100_000_002
  defp terminal_id(:canceled), do: 9_100_000_003

  defp run_attrs(actor, identity, overrides) do
    defaults = %{
      actor_user_id: actor.id,
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: 9_000_000_001,
      source_owner_login: "acme",
      state: :discovering,
      request_metadata: %{}
    }

    overrides = if Keyword.keyword?(overrides), do: Map.new(overrides), else: Map.new(overrides)
    Map.merge(defaults, overrides)
  end

  defp item_fixture(run, overrides \\ []) do
    case insert_item(run, Map.new(overrides)) do
      {:ok, item} ->
        item

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp remote_cleanup_attrs(repository, item) do
    storage_root = Fornacast.Config.repo_storage_root()
    requested_path = Path.join(storage_root, repository.storage_path)
    quarantine_path = GitCore.Remote.cleanup_slot_path(requested_path)

    %{
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
      evidence: %{
        "version" => 1,
        "kind" => "remote_quarantine",
        "storage_root" => storage_root,
        "relative_path" => Path.relative_to(quarantine_path, storage_root),
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_storage_path" => repository.storage_path,
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "requested_path" => requested_path,
        "quarantine_path" => quarantine_path,
        "mode" => 0o700,
        "major_device" => 8,
        "minor_device" => 1,
        "inode" => 99,
        "remote_failure_kind" => "remote_clone_failed"
      },
      eligible_at: @now,
      next_attempt_at: @now
    }
  end

  defp insert_item(run, overrides) do
    attrs =
      %{
        import_run_id: run.id,
        github_repository_id: 9_000_000_101,
        source_full_name: "acme/demo",
        source_name: "demo",
        source_metadata: %{"archived" => false, "fork" => false},
        source_observed_at: @now
      }
      |> Map.merge(overrides)

    Persistence.insert_repository_item(attrs)
  end

  defp attempt_fixture(item, number) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: number,
      state: :running,
      decision: %{"action" => "skip"},
      started_at: @now
    })
    |> Repo.insert()
    |> unwrap_or_changeset()
  end

  defp mapping_fixture(item, hidden) do
    %ObjectMapping{}
    |> ObjectMapping.create_changeset(%{
      repository_item_id: item.id,
      hidden_repository_id: hidden.id,
      github_repository_id: item.github_repository_id,
      object_kind: "issue",
      github_object_id: 99,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: 1,
      source_url: "https://github.com/acme/demo/issues/99"
    })
    |> Repo.insert()
    |> unwrap_or_changeset()
  end

  defp checkpoint_fixture(item) do
    %PageCheckpoint{}
    |> PageCheckpoint.create_changeset(%{
      repository_item_id: item.id,
      resource_kind: "issues",
      page_key: "page:1",
      etag: "etag-1",
      observed_at: @now,
      item_count: 10,
      cursor_metadata: %{"next_url" => nil},
      committed_at: @now
    })
    |> Repo.insert()
    |> unwrap_or_changeset()
  end

  defp report_fixture(run, item) do
    %ReportEntry{}
    |> ReportEntry.create_changeset(%{
      import_run_id: run.id,
      repository_item_id: item.id,
      idempotency_key: "repository:#{item.github_repository_id}",
      scope: :repository,
      outcome: :imported,
      classification: "repository_imported",
      summary: "Repository imported",
      metadata: %{"visibility" => "private"},
      source_count: 1
    })
    |> Repo.insert()
    |> unwrap_or_changeset()
  end

  defp repository_fixture(actor) do
    suffix = System.unique_integer([:positive])

    %Repository{owner_user_id: actor.id, storage_path: "@test/import-hidden-#{suffix}.git"}
    |> Repository.create_changeset(%{
      slug: "import-hidden-#{suffix}",
      name: "hidden",
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp cleanup_fixture(actor, identity) do
    run = run_fixture(actor, identity, state: :failed, terminal_at: @now)
    repository = repository_fixture(actor)
    item = item_fixture(run, state: :failed)

    Repo.update_all(
      from(candidate in RepositoryItem, where: candidate.id == ^item.id),
      set: [hidden_repository_id: repository.id]
    )

    item = Repo.get!(RepositoryItem, item.id)

    Persistence.create_cleanup_operation(item, remote_cleanup_attrs(repository, item))
    |> unwrap_or_raise()
  end

  defp credential_fixture(actor, identity) do
    %GitHubCredential{}
    |> GitHubCredential.changeset(%{
      local_user_id: actor.id,
      github_identity_id: identity.id,
      ciphertext: <<1>>,
      nonce: :binary.copy(<<2>>, 12),
      tag: :binary.copy(<<3>>, 16),
      key_id: "test-v1",
      status: :valid
    })
    |> Repo.insert!()
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(
               %{
                 github_user_id: 8_000_000_000 + suffix,
                 login: "importer-#{suffix}",
                 avatar_url: nil,
                 profile_url: nil
               },
               @now
             )

    assert {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)
    identity
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "import-user-#{suffix}",
               email: "import-user-#{suffix}@example.test",
               password: "correct horse battery staple"
             })

    user
  end

  defp assert_unique(fun, field) do
    assert {:error, changeset} = fun.()
    assert Keyword.has_key?(changeset.errors, field)
  end

  defp unwrap_or_changeset({:ok, row}), do: row
  defp unwrap_or_changeset({:error, changeset}), do: {:error, changeset}

  defp unwrap_or_raise({:ok, row}), do: row

  defp unwrap_or_raise({:error, %Ecto.Changeset{} = changeset}) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

  defp unwrap_or_raise({:error, reason}), do: raise("fixture failed: #{inspect(reason)}")

  defp reset_database! do
    for table <- [
          "github_import_repository_cleanups",
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
          "api_keys",
          "ssh_keys",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp database_placeholders(count) do
    if postgres?(), do: Enum.map(1..count, &"$#{&1}"), else: List.duplicate("?", count)
  end
end
