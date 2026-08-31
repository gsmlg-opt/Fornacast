defmodule ForgeImports.ImportPersistenceHardeningTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, User}

  alias ForgeImports.{
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
  @now ~U[2026-08-26 00:00:00Z]
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<7>>, 32)}}

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

  test "public run creation reloads the actor and forces safe discovery defaults", %{
    actor: actor,
    identity: identity
  } do
    unsafe = %{
      state: :failed,
      selected_count: 99,
      published_count: 98,
      failure_detail: "github_pat_secret",
      terminal_at: @now,
      credential_ciphertext: <<1>>,
      credential_nonce: :binary.copy(<<2>>, 12),
      credential_tag: :binary.copy(<<3>>, 16),
      credential_key_id: "test-v1",
      lease_owner: "forged",
      lease_expires_at: DateTime.add(@now, 60, :second),
      lock_version: 99
    }

    assert {:ok, run} = ForgeImports.create_run(actor, Map.merge(run_attrs(identity), unsafe))
    assert run.actor_user_id == actor.id
    assert run.state == :discovering
    assert run.selected_count == 0
    assert run.published_count == 0
    assert run.failure_detail == nil
    assert run.terminal_at == nil
    assert run.credential_ciphertext == nil
    assert run.credential_nonce == nil
    assert run.credential_tag == nil
    assert run.credential_key_id == nil
    assert run.lease_owner == nil
    assert run.lease_expires_at == nil
    assert run.lock_version == 1

    assert {:ok, _disabled} =
             actor
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :forbidden} = ForgeImports.create_run(actor, run_attrs(identity))
  end

  test "saved run creation verifies the complete actor credential identity chain", %{
    actor: actor,
    identity: identity
  } do
    credential = credential_fixture(actor, identity)
    other = user_fixture()
    other_identity = identity_fixture(other)
    other_credential = credential_fixture(other, other_identity)

    assert {:ok, saved} =
             ForgeImports.create_run(
               actor,
               run_attrs(identity,
                 credential_source: :saved,
                 github_credential_id: credential.id
               )
             )

    assert saved.github_credential_id == credential.id

    for attrs <- [
          run_attrs(identity,
            credential_source: :saved,
            github_credential_id: other_credential.id
          ),
          run_attrs(other_identity,
            credential_source: :saved,
            github_credential_id: other_credential.id
          ),
          run_attrs(identity,
            credential_source: :saved,
            github_credential_id: credential.id,
            github_identity_id: other_identity.id
          )
        ] do
      assert {:error, :forbidden} = ForgeImports.create_run(actor, attrs)
    end

    assert {:ok, one_time} =
             ForgeImports.create_run(
               actor,
               run_attrs(other_identity, credential_source: :one_time)
             )

    assert one_time.github_identity_id == other_identity.id
    assert one_time.github_credential_id == nil
  end

  test "run and item creation changesets do not cast worker or terminal fields", %{
    actor: actor,
    identity: identity
  } do
    run_changeset =
      ImportRun.creation_changeset(
        %ImportRun{},
        actor.id,
        Map.merge(run_attrs(identity), %{
          state: :completed,
          failure_count: 12,
          credential_ciphertext: <<1>>,
          credential_nonce: :binary.copy(<<2>>, 12),
          credential_tag: :binary.copy(<<3>>, 16),
          credential_key_id: "test-v1",
          lock_version: 42
        })
      )

    assert run_changeset.valid?
    assert Ecto.Changeset.get_field(run_changeset, :state) == :discovering
    assert Ecto.Changeset.get_field(run_changeset, :failure_count) == 0
    assert Ecto.Changeset.get_field(run_changeset, :credential_ciphertext) == nil
    assert Ecto.Changeset.get_field(run_changeset, :lock_version) == 1

    item_changeset =
      RepositoryItem.discovery_changeset(%RepositoryItem{}, %{
        import_run_id: 1,
        github_repository_id: 2,
        source_full_name: "acme/demo",
        source_name: "demo",
        source_metadata: %{},
        source_observed_at: @now,
        selected: false,
        state: :failed,
        lock_version: 99,
        attempt_count: 9,
        staged_storage_path: "/private/staged.git",
        replacement_storage_path: "/private/replacement.git",
        publication_evidence: %{"path" => "/private/published.git"},
        cleanup_state: "pending",
        cleanup_attempt_count: 8
      })

    assert item_changeset.valid?
    assert Ecto.Changeset.get_field(item_changeset, :selected)
    assert Ecto.Changeset.get_field(item_changeset, :state) == :queued
    assert Ecto.Changeset.get_field(item_changeset, :lock_version) == 1
    assert Ecto.Changeset.get_field(item_changeset, :attempt_count) == 0
    assert Ecto.Changeset.get_field(item_changeset, :staged_storage_path) == nil
    assert Ecto.Changeset.get_field(item_changeset, :replacement_storage_path) == nil
    assert Ecto.Changeset.get_field(item_changeset, :publication_evidence) == %{}
    assert Ecto.Changeset.get_field(item_changeset, :cleanup_state) == nil
    assert Ecto.Changeset.get_field(item_changeset, :cleanup_attempt_count) == 0
  end

  test "root mutations are actor/run scoped and reject stale or leased snapshots", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())
    assert {:ok, run} = ForgeImports.transition_run(actor, run, :awaiting_resolution)
    other = user_fixture()

    assert {:error, :not_found} = ForgeImports.repository_items(other, run)
    assert {:error, :not_found} = ForgeImports.select_repository_item(other, run, item, false)

    assert {:ok, %{run: selection_run, item: deselected}} =
             ForgeImports.select_repository_item(actor, run, item, false)

    assert selection_run.selected_count == 0
    assert selection_run.lock_version == run.lock_version + 1
    assert deselected.lock_version == item.lock_version + 1
    assert {:error, :stale} = ForgeImports.select_repository_item(actor, run, item, true)

    now = DateTime.utc_now(:second)

    assert {:ok, claimed} =
             OperationLease.claim(RepositoryItem, item.id, "worker-a", now, 60)

    assert {:error, :busy} =
             ForgeImports.select_repository_item(actor, selection_run, claimed, true)

    assert :ok = OperationLease.release(RepositoryItem, claimed)

    current_item = Repo.get!(RepositoryItem, item.id)

    assert {:ok, %{run: selected_run, item: selected_item}} =
             ForgeImports.select_repository_item(
               actor,
               selection_run,
               current_item,
               true
             )

    assert selected_run.selected_count == 1
    assert selected_item.selected
    assert {:ok, ready} = ForgeImports.transition_run(actor, selected_run, :ready)

    assert {:error, :invalid_selection} =
             ForgeImports.select_repository_item(actor, ready, selected_item, false)

    assert {:ok, lease_run} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, lease_item} = ForgeImports.create_repository_item(actor, lease_run, item_attrs())

    assert {:ok, lease_run} =
             ForgeImports.transition_run(actor, lease_run, :awaiting_resolution)

    assert {:ok, claimed_run} =
             OperationLease.claim(ImportRun, lease_run.id, "worker-run", now, 60)

    assert {:error, :busy} =
             ForgeImports.select_repository_item(actor, claimed_run, lease_item, false)
  end

  test "terminal transition and envelope attachment use version guards", %{
    actor: actor,
    identity: identity
  } do
    run = running_run(actor, identity)

    assert {:ok, envelope} =
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               run.id,
               actor.id,
               identity.github_user_id,
               "github_pat_secret",
               @keyring
             )

    assert {:ok, attached} =
             ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring)

    assert attached.lock_version == run.lock_version + 1
    assert {:error, :stale} = ForgeImports.transition_run(actor, run, :failed)

    assert {:ok, terminal} = ForgeImports.transition_run(actor, attached, :failed)
    assert terminal.state == :failed
    assert terminal.credential_ciphertext == nil
    assert terminal.credential_nonce == nil
    assert terminal.credential_tag == nil
    assert terminal.credential_key_id == nil
    assert terminal.lock_version == attached.lock_version + 1

    assert {:error, :stale} =
             ForgeImports.attach_one_time_credential(actor, attached, envelope, @keyring)
  end

  test "selected count is server-owned outside review snapshot and selection CAS", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, discovering} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, _first} = ForgeImports.create_repository_item(actor, discovering, item_attrs())
    assert {:ok, _second} = ForgeImports.create_repository_item(actor, discovering, item_attrs())

    assert {:error, :invalid_transition} =
             ForgeImports.transition_run(
               actor,
               discovering,
               :awaiting_resolution,
               %{selected_count: 999}
             )

    assert %ImportRun{state: :discovering, selected_count: 0} =
             Repo.get!(ImportRun, discovering.id)

    assert {:ok, review} =
             ForgeImports.transition_run(actor, discovering, :awaiting_resolution)

    assert review.selected_count == 2

    refute ImportRun.transition_changeset(review, :ready, %{selected_count: 999}).valid?
    refute ImportRun.lease_update_changeset(review, selected_count: 999).valid?

    now = DateTime.utc_now(:second)

    assert {:ok, claimed} =
             OperationLease.claim(ImportRun, review.id, "count-worker", now, 60)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(ImportRun, claimed, selected_count: 999)

    assert Repo.get!(ImportRun, review.id).selected_count == 2
  end

  test "credential wait resumes awaiting resolution without resnapshotting selection", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, discovering} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, _first} = ForgeImports.create_repository_item(actor, discovering, item_attrs())
    assert {:ok, _second} = ForgeImports.create_repository_item(actor, discovering, item_attrs())

    assert {:ok, review} =
             ForgeImports.transition_run(actor, discovering, :awaiting_resolution)

    assert review.selected_count == 2

    assert {:ok, waiting} =
             ForgeImports.transition_run(actor, review, :awaiting_credential, %{
               wait_reason: "credential_invalid",
               next_attempt_at: @now
             })

    assert waiting.resume_state == :awaiting_resolution

    assert {:error, :invalid_transition} =
             ForgeImports.transition_run(actor, waiting, :ready)

    assert {:ok, resumed} =
             ForgeImports.transition_run(actor, waiting, :awaiting_resolution)

    assert resumed.state == :awaiting_resolution
    assert resumed.selected_count == 2
    assert resumed.resume_state == nil
    assert resumed.wait_reason == nil
    assert resumed.next_attempt_at == nil
  end

  test "one-time checkout requires a current actor-scoped owned lease capability", %{
    actor: actor,
    identity: identity
  } do
    run = running_run(actor, identity)
    envelope = one_time_envelope(run, actor, identity)

    assert {:ok, attached} =
             ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring)

    assert {:error, :credential_service_unavailable} =
             OneTimeCredential.with_credential(
               actor,
               attached,
               fn _pat -> send(self(), :no_lease_checkout) end,
               @keyring
             )

    refute_received :no_lease_checkout

    now = DateTime.utc_now(:second)
    assert {:ok, claimed} = OperationLease.claim(ImportRun, attached.id, "worker-a", now, 60)

    assert {:ok, :acknowledged} =
             OneTimeCredential.with_credential(
               actor,
               claimed,
               fn pat ->
                 assert pat == "github_pat_secret"
                 :ok
               end,
               @keyring
             )

    assert {:error, :credential_service_unavailable} =
             OneTimeCredential.with_credential(
               actor,
               %{claimed | lease_owner: "worker-b"},
               fn _pat -> send(self(), :foreign_lease_checkout) end,
               @keyring
             )

    refute_received :foreign_lease_checkout

    assert {:ok, terminal} = OperationLease.update_owned(ImportRun, claimed, state: :failed)
    assert terminal.credential_ciphertext == nil

    assert {:error, :credential_service_unavailable} =
             OneTimeCredential.with_credential(
               actor,
               claimed,
               fn _pat -> send(self(), :stale_terminal_checkout) end,
               @keyring
             )

    refute_received :stale_terminal_checkout
  end

  test "one-time attachment authenticates the current run actor and identity", %{
    actor: actor,
    identity: identity
  } do
    first = running_run(actor, identity)
    second = running_run(actor, identity)
    first_envelope = one_time_envelope(first, actor, identity)

    assert {:error, :credential_service_unavailable} =
             ForgeImports.attach_one_time_credential(actor, second, first_envelope, @keyring)

    assert Repo.get!(ImportRun, second.id).credential_ciphertext == nil

    other = user_fixture()
    other_identity = identity_fixture(other)

    assert {:ok, cross_actor_envelope} =
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               second.id,
               other.id,
               identity.github_user_id,
               "github_pat_secret",
               @keyring
             )

    assert {:error, :credential_service_unavailable} =
             ForgeImports.attach_one_time_credential(
               actor,
               second,
               cross_actor_envelope,
               @keyring
             )

    assert Repo.get!(ImportRun, second.id).credential_ciphertext == nil

    assert {:ok, cross_identity_envelope} =
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               second.id,
               actor.id,
               other_identity.github_user_id,
               "github_pat_secret",
               @keyring
             )

    assert {:error, :credential_service_unavailable} =
             ForgeImports.attach_one_time_credential(
               actor,
               second,
               cross_identity_envelope,
               @keyring
             )
  end

  test "predecessor runs and items are scoped to one actor and predecessor chain", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, predecessor} = ForgeImports.create_run(actor, run_attrs(identity))

    assert {:ok, predecessor_item} =
             ForgeImports.create_repository_item(actor, predecessor, item_attrs())

    hidden = repository_fixture(actor)
    predecessor_item_id = predecessor_item.id

    Repo.update_all(
      from(item in RepositoryItem, where: item.id == ^predecessor_item_id),
      set: [state: :failed, hidden_repository_id: hidden.id]
    )

    disallowed_items =
      for updates <- [
            [state: :completed, publication_evidence: %{}],
            [state: :published, publication_evidence: %{}],
            [state: :failed, publication_evidence: %{"published_repository_id" => hidden.id}],
            [state: :failed, publication_evidence: %{}, cleanup_state: "cleanup_pending"]
          ] do
        assert {:ok, disallowed_item} =
                 ForgeImports.create_repository_item(
                   actor,
                   predecessor,
                   item_attrs(github_repository_id: System.unique_integer([:positive]))
                 )

        disallowed_item_id = disallowed_item.id

        Repo.update_all(
          from(item in RepositoryItem, where: item.id == ^disallowed_item_id),
          set: updates
        )

        Repo.get!(RepositoryItem, disallowed_item.id)
      end

    predecessor_item = Repo.get!(RepositoryItem, predecessor_item.id)
    assert {:ok, predecessor} = ForgeImports.transition_run(actor, predecessor, :failed)

    assert {:ok, successor} =
             ForgeImports.create_run(
               actor,
               run_attrs(identity, predecessor_run_id: predecessor.id)
             )

    assert {:ok, successor_item} =
             ForgeImports.create_repository_item(
               actor,
               successor,
               item_attrs(predecessor_item_id: predecessor_item.id)
             )

    assert successor_item.predecessor_item_id == predecessor_item.id

    for disallowed_item <- disallowed_items do
      assert {:error, :invalid_predecessor} =
               ForgeImports.create_repository_item(
                 actor,
                 successor,
                 item_attrs(
                   predecessor_item_id: disallowed_item.id,
                   github_repository_id: System.unique_integer([:positive])
                 )
               )
    end

    assert {:ok, nonterminal} = ForgeImports.create_run(actor, run_attrs(identity))

    assert {:error, :invalid_predecessor} =
             ForgeImports.create_run(
               actor,
               run_attrs(identity, predecessor_run_id: nonterminal.id)
             )

    assert {:ok, other_predecessor} = ForgeImports.create_run(actor, run_attrs(identity))

    assert {:ok, other_item} =
             ForgeImports.create_repository_item(actor, other_predecessor, item_attrs())

    assert {:ok, _other_predecessor} =
             ForgeImports.transition_run(actor, other_predecessor, :failed)

    assert {:error, :invalid_predecessor} =
             ForgeImports.create_repository_item(
               actor,
               successor,
               item_attrs(predecessor_item_id: other_item.id)
             )

    foreign_actor = user_fixture()
    foreign_identity = identity_fixture(foreign_actor)

    assert {:ok, foreign_run} =
             ForgeImports.create_run(foreign_actor, run_attrs(foreign_identity))

    assert {:ok, foreign_item} =
             ForgeImports.create_repository_item(foreign_actor, foreign_run, item_attrs())

    assert {:ok, foreign_run} =
             ForgeImports.transition_run(foreign_actor, foreign_run, :failed)

    assert {:error, :not_found} =
             ForgeImports.create_run(
               actor,
               run_attrs(identity, predecessor_run_id: foreign_run.id)
             )

    assert {:error, :not_found} =
             ForgeImports.create_repository_item(
               actor,
               successor,
               item_attrs(predecessor_item_id: foreign_item.id)
             )
  end

  test "adoption safety database failures remain persistence unavailable", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, predecessor} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, item} = ForgeImports.create_repository_item(actor, predecessor, item_attrs())

    for failure <- [
          fn -> raise DBConnection.ConnectionError, "injected adoption query failure" end,
          fn -> raise Turso.Error, code: :io, message: "injected adoption query failure" end
        ] do
      assert {:error, :persistence_unavailable} =
               Persistence.with_test_after_adoption_safety_hook(failure, fn ->
                 Persistence.ensure_adoption_safe_locked(Repo, item)
               end)
    end
  end

  test "successor creation propagates adoption safety database failures", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, predecessor} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, item} = ForgeImports.create_repository_item(actor, predecessor, item_attrs())
    hidden = repository_fixture(actor)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [state: :failed, hidden_repository_id: hidden.id]
             )

    item = Repo.get!(RepositoryItem, item.id)
    assert {:ok, predecessor} = ForgeImports.transition_run(actor, predecessor, :failed)

    for {suffix, failure} <- [
          {"dbconnection",
           fn -> raise DBConnection.ConnectionError, "injected adoption query failure" end},
          {"turso",
           fn -> raise Turso.Error, code: :io, message: "injected adoption query failure" end}
        ] do
      assert {:ok, successor} =
               ForgeImports.create_run(
                 actor,
                 run_attrs(identity,
                   predecessor_run_id: predecessor.id,
                   source_owner_github_id: System.unique_integer([:positive])
                 )
               )

      assert {:error, :persistence_unavailable} =
               Persistence.with_test_after_adoption_safety_hook(failure, fn ->
                 ForgeImports.create_repository_item(
                   actor,
                   successor,
                   item_attrs(
                     predecessor_item_id: item.id,
                     github_repository_id: System.unique_integer([:positive]),
                     source_full_name: "acme/#{suffix}",
                     source_name: suffix
                   )
                 )
               end)

      assert Repo.aggregate(
               from(candidate in RepositoryItem,
                 where: candidate.import_run_id == ^successor.id
               ),
               :count,
               :id
             ) == 0
    end
  end

  test "terminal import rows cannot be claimed renewed or retained as leased", %{
    actor: actor,
    identity: identity
  } do
    run = running_run(actor, identity)
    now = DateTime.utc_now(:second)
    assert {:ok, claimed_run} = OperationLease.claim(ImportRun, run.id, "worker-a", now, 60)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(
               ImportRun,
               claimed_run,
               [state: :failed],
               now: now,
               lease_seconds: 60
             )

    assert {:ok, terminal_run} =
             OperationLease.update_owned(ImportRun, claimed_run, state: :failed)

    assert terminal_run.lease_owner == nil
    assert :busy = OperationLease.claim(ImportRun, terminal_run.id, "worker-b", now, 60)

    assert {:error, :lost_lease} =
             OperationLease.renew_owned(ImportRun, terminal_run,
               now: now,
               lease_seconds: 60
             )

    assert {:ok, discovery_run} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, item} = ForgeImports.create_repository_item(actor, discovery_run, item_attrs())

    assert {:ok, claimed_item} =
             OperationLease.claim(RepositoryItem, item.id, "worker-a", now, 60)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(
               RepositoryItem,
               claimed_item,
               [state: :failed],
               now: now,
               lease_seconds: 60
             )

    assert {:ok, terminal_item} =
             OperationLease.update_owned(RepositoryItem, claimed_item, state: :failed)

    assert :busy = OperationLease.claim(RepositoryItem, terminal_item.id, "worker-b", now, 60)
  end

  test "report values are flat allowlisted and cannot persist tokens or paths", %{
    actor: actor,
    identity: identity
  } do
    assert {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())

    valid =
      report_changeset(run, item, %{
        "code" => :source_drift,
        "field" => "default_branch",
        "count" => 3,
        "expected" => true,
        "actual" => nil,
        "visibility" => "private"
      })

    assert valid.valid?

    for {field, value} <- [
          {:summary, "Bearer github_pat_secret"},
          {:classification, "ghp_abcdefghijklmnopqrstuvwxyz"},
          {:summary, "failed at /var/lib/fornacast/repos/private.git"},
          {:summary, "bad\0value"}
        ] do
      changeset = report_changeset(run, item, %{}) |> Ecto.Changeset.change(%{field => value})

      refute ReportEntry.create_changeset(
               %ReportEntry{},
               Ecto.Changeset.apply_changes(changeset) |> Map.from_struct()
             ).valid?
    end

    for metadata <- [
          %{"unknown" => "value"},
          %{"code" => %{"nested" => true}},
          %{"field" => "github_pat_secret"},
          %{"phase" => "Bearer abc"},
          %{"actual" => "/home/fornacast/private.git"},
          %{"expected" => "nul\0byte"}
        ] do
      changeset = report_changeset(run, item, metadata)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :metadata)
    end

    for attrs <- [
          %{idempotency_key: "/private/report", object_kind: nil},
          %{idempotency_key: "github_pat_secret", object_kind: nil},
          %{idempotency_key: "report-safe", object_kind: "authorization"},
          %{idempotency_key: "report-safe", object_kind: "Bearer secret"}
        ] do
      changeset =
        ReportEntry.create_changeset(%ReportEntry{}, %{
          import_run_id: run.id,
          repository_item_id: item.id,
          idempotency_key: attrs.idempotency_key,
          scope: :repository,
          object_kind: attrs.object_kind,
          outcome: :warning,
          classification: "classified_warning",
          summary: "Bounded classified warning",
          metadata: %{},
          source_count: 1
        })

      refute changeset.valid?
    end

    refute inspect(%ReportEntry{
             idempotency_key: "github_pat_secret",
             object_kind: "authorization",
             classification: "Bearer secret",
             summary: "/private/report",
             metadata: %{"code" => "ghp_secret"}
           }) =~ "github_pat_secret"
  end

  test "object source URLs and checkpoint cursors reject secrets and redact Inspect" do
    mapping_attrs = %{
      repository_item_id: 1,
      hidden_repository_id: 2,
      github_repository_id: 3,
      object_kind: "issue",
      github_object_id: 4,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: 5,
      source_url: "https://github.com/acme/demo/issues/4"
    }

    assert ObjectMapping.create_changeset(%ObjectMapping{}, mapping_attrs).valid?

    unsafe_values = [
      "https://github_pat_secret@github.com/acme/demo",
      "Bearer ghp_secret",
      "bad\0value",
      "/var/lib/fornacast/private",
      "authorization"
    ]

    for unsafe <- unsafe_values do
      refute ObjectMapping.create_changeset(
               %ObjectMapping{},
               %{mapping_attrs | source_url: unsafe}
             ).valid?
    end

    checkpoint_attrs = %{
      repository_item_id: 1,
      resource_kind: "issues",
      page_key: "page:1",
      etag: "safe-etag",
      item_count: 1,
      cursor_metadata: %{
        "cursor" => "Y3Vyc29yOnYy",
        "next_url" => "https://api.github.com/repos/acme/demo/issues?page=2"
      },
      committed_at: @now
    }

    assert PageCheckpoint.create_changeset(%PageCheckpoint{}, checkpoint_attrs).valid?

    assert PageCheckpoint.create_changeset(%PageCheckpoint{}, %{
             checkpoint_attrs
             | cursor_metadata: %{"next_url" => nil}
           }).valid?

    for unsafe <- unsafe_values,
        field <- ["cursor", "next_url"] do
      changeset =
        PageCheckpoint.create_changeset(%PageCheckpoint{}, %{
          checkpoint_attrs
          | cursor_metadata: %{field => unsafe}
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :cursor_metadata)
    end

    for field <- [:page_key, :etag], unsafe <- unsafe_values do
      refute PageCheckpoint.create_changeset(
               %PageCheckpoint{},
               Map.put(checkpoint_attrs, field, unsafe)
             ).valid?
    end

    refute inspect(%ObjectMapping{source_url: "github_pat_secret"}) =~ "github_pat_secret"

    inspected_checkpoint =
      inspect(%PageCheckpoint{
        page_key: "github_pat_secret",
        etag: "Bearer secret",
        cursor_metadata: %{"next_url" => "/private/path"}
      })

    refute inspected_checkpoint =~ "github_pat_secret"
    refute inspected_checkpoint =~ "Bearer secret"
    refute inspected_checkpoint =~ "/private/path"
  end

  test "report scope strictly separates run repository and object shapes" do
    base = %{
      import_run_id: 1,
      idempotency_key: "report:scope",
      outcome: :warning,
      classification: "classified_warning",
      summary: "Bounded warning",
      metadata: %{},
      source_count: 1
    }

    assert ReportEntry.create_changeset(%ReportEntry{}, Map.merge(base, %{scope: :run})).valid?

    assert ReportEntry.create_changeset(
             %ReportEntry{},
             Map.merge(base, %{scope: :repository, repository_item_id: 2})
           ).valid?

    assert ReportEntry.create_changeset(
             %ReportEntry{},
             Map.merge(base, %{
               scope: :object,
               repository_item_id: 2,
               object_kind: "issue",
               source_object_id: 3
             })
           ).valid?

    for attrs <- [
          %{scope: :run, object_kind: "issue"},
          %{scope: :run, source_object_id: 3},
          %{scope: :repository, repository_item_id: 2, object_kind: "issue"},
          %{scope: :repository, repository_item_id: 2, source_object_id: 3},
          %{scope: :object, repository_item_id: 2, object_kind: "issue"},
          %{scope: :object, repository_item_id: 2, source_object_id: 3}
        ] do
      refute ReportEntry.create_changeset(%ReportEntry{}, Map.merge(base, attrs)).valid?
    end
  end

  test "request metadata values reject credentials paths NUL and secret aliases", %{
    actor: actor,
    identity: identity
  } do
    for unsafe <- [
          "github_pat_secret",
          "ghp_abcdefghijklmnopqrstuvwxyz",
          "Bearer secret",
          "bad\0value",
          "/var/lib/fornacast/private",
          "authorization",
          "access_token"
        ] do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               ForgeImports.create_run(
                 actor,
                 run_attrs(identity, request_metadata: %{"request_id" => unsafe})
               )

      assert Keyword.has_key?(errors, :request_metadata)
    end
  end

  test "durable item and attempt maps recursively reject unsafe terms", %{
    actor: actor,
    identity: identity
  } do
    run_attrs = persistence_run_attrs(actor, identity)
    item_attrs = persistence_item_attrs(1)

    valid_source_metadata = %{
      "archived" => false,
      "fork" => false,
      "visibility" => "private",
      "default_branch" => "main",
      "description" => "Token authorization helper invokes /usr/bin/git safely",
      "has_issues" => true,
      "disabled" => false
    }

    valid_nested = %{
      "phase" => "git_staged",
      "github_id" => 123,
      "verified" => true,
      "source" => %{"url" => "https://github.com/acme/demo"},
      "objects" => [1, 2, "abc"]
    }

    assert RepositoryItem.persistence_changeset(
             %RepositoryItem{},
             Map.merge(item_attrs, %{
               source_metadata: valid_source_metadata,
               checkpoint: valid_nested,
               source_git: valid_nested,
               publication_evidence: %{}
             })
           ).valid?

    for {field, unsafe} <- [
          {:source_metadata, Map.put(valid_source_metadata, "description", "github_pat_secret")},
          {:source_metadata,
           Map.put(valid_source_metadata, "description", "Bearer github_pat_secret")},
          {:source_metadata, Map.put(valid_source_metadata, "description", "bad\0value")},
          {:source_metadata, Map.put(valid_source_metadata, "visibility", "secret")},
          {:source_metadata, Map.put(valid_source_metadata, "archived", "false")},
          {:checkpoint, %{"authorization" => "safe-looking"}},
          {:checkpoint, %{"phase" => "Bearer secret"}},
          {:source_git, %{"raw_body" => "secret"}},
          {:source_git, %{"path" => "/var/lib/fornacast/private"}},
          {:publication_evidence, %{"url" => "file:///var/lib/private"}},
          {:publication_evidence, %{"bad" => {:tuple, "value"}}},
          {:checkpoint, %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => "too-deep"}}}}}}
        ] do
      changeset =
        RepositoryItem.persistence_changeset(
          %RepositoryItem{},
          Map.put(item_attrs, field, unsafe)
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, field)
    end

    assert {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity))
    assert {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())

    valid_replace_decision = %{
      "action" => "replace",
      "slug" => "demo",
      "replacement_repository_id" => 101,
      "replacement_owner_id" => actor.id,
      "replacement_storage_path" => "@hashed/aa/bb/demo.git",
      "replacement_generation" => 3,
      "replacement_write_version" => 7,
      "replacement_updated_at" => @now,
      "replacement_last_pushed_at" => nil
    }

    attempt_attrs = %{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: valid_replace_decision,
      started_at: @now
    }

    valid_attempt = ImportAttempt.create_changeset(%ImportAttempt{}, attempt_attrs)
    assert valid_attempt.valid?
    assert {:ok, saved_attempt} = Repo.insert(valid_attempt)

    assert ImportAttempt.create_changeset(
             %ImportAttempt{},
             put_in(
               attempt_attrs,
               [:decision, "slug"],
               String.duplicate("a", 63)
             )
           ).valid?

    assert %{
             "replacement_updated_at" => "2026-08-26T00:00:00Z",
             "replacement_last_pushed_at" => nil
           } = saved_attempt.decision

    assert ImportAttempt.create_changeset(
             %ImportAttempt{},
             put_in(
               attempt_attrs,
               [:decision, "replacement_last_pushed_at"],
               DateTime.add(@now, -60, :second)
             )
           ).valid?

    refute ImportAttempt.create_changeset(saved_attempt, attempt_attrs).valid?

    for unsafe <- [
          %{"access_token" => "secret"},
          %{"reason" => "ghp_abcdefghijklmnopqrstuvwxyz"},
          Map.put(valid_replace_decision, "replacement_storage_path", "relative/path"),
          Map.put(
            valid_replace_decision,
            "replacement_storage_path",
            "/srv/fornacast/repositories/demo.git"
          ),
          Map.put(valid_replace_decision, "replacement_storage_path", "/tmp/github_pat_secret"),
          Map.put(
            valid_replace_decision,
            "replacement_storage_path",
            "@hashed/aa/../demo.git"
          ),
          Map.put(valid_replace_decision, "replacement_storage_path", "C:/private/demo.git"),
          Map.put(valid_replace_decision, "replacement_storage_path", "C:private/demo.git"),
          Map.put(valid_replace_decision, "replacement_storage_path", "@hashed//demo.git"),
          Map.put(valid_replace_decision, "slug", "Demo"),
          Map.put(valid_replace_decision, "slug", "."),
          Map.put(valid_replace_decision, "slug", ".."),
          Map.put(valid_replace_decision, "slug", "demo.git"),
          Map.put(valid_replace_decision, "slug", "demo."),
          Map.put(valid_replace_decision, "slug", String.duplicate("a", 64)),
          Map.put(valid_replace_decision, "replacement_updated_at", "not-a-time"),
          Map.put(valid_replace_decision, "replacement_write_version", -1),
          Map.put(valid_replace_decision, "replacement_last_pushed_at", "not-a-time"),
          Map.delete(valid_replace_decision, "replacement_owner_id"),
          Map.delete(valid_replace_decision, "replacement_last_pushed_at"),
          Map.put(valid_replace_decision, "raw_body", "secret"),
          Map.put(valid_replace_decision, "nested", self())
        ] do
      changeset =
        ImportAttempt.create_changeset(%ImportAttempt{}, %{attempt_attrs | decision: unsafe})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :decision)
    end

    valid_fingerprint =
      persistence_item_attrs(1)
      |> Map.merge(%{
        conflict_action: :replace,
        destination_slug: "demo",
        replacement_repository_id: 101,
        replacement_owner_id: actor.id,
        replacement_storage_path: "@hashed/aa/bb/demo.git",
        replacement_generation: 3,
        replacement_write_version: 7,
        replacement_updated_at: @now,
        replacement_last_pushed_at: nil
      })

    assert RepositoryItem.persistence_changeset(%RepositoryItem{}, valid_fingerprint).valid?

    for invalid <- [
          %{replacement_storage_path: "/srv/fornacast/repositories/demo.git"},
          %{replacement_storage_path: "@hashed/aa/../demo.git"},
          %{destination_slug: "Demo"}
        ] do
      changeset =
        RepositoryItem.persistence_changeset(
          %RepositoryItem{},
          Map.merge(valid_fingerprint, invalid)
        )

      refute changeset.valid?
    end

    for required <- [
          :replacement_repository_id,
          :replacement_owner_id,
          :replacement_storage_path,
          :replacement_generation,
          :replacement_write_version,
          :replacement_updated_at
        ] do
      changeset =
        RepositoryItem.persistence_changeset(
          %RepositoryItem{},
          Map.put(valid_fingerprint, required, nil)
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :conflict_action)
    end

    refute inspect(%RepositoryItem{source_metadata: %{"description" => "github_pat_secret"}}) =~
             "github_pat_secret"

    refute inspect(%ImportAttempt{decision: %{"token" => "github_pat_secret"}}) =~
             "github_pat_secret"

    assert ImportRun.persistence_changeset(%ImportRun{}, run_attrs).valid?
  end

  test "classifications reject credentials and paths and projections fail closed", %{
    actor: actor,
    identity: identity
  } do
    unsafe_values = [
      "github_pat_secret",
      "Bearer secret",
      "file:///var/lib/private",
      "[/var/lib/private]",
      "prefix,/var/lib/private",
      "prefix;/var/lib/private",
      "prefix{/var/lib/private}"
    ]

    for unsafe <- unsafe_values do
      for field <- [:wait_reason, :failure_kind] do
        changeset =
          ImportRun.persistence_changeset(
            %ImportRun{},
            Map.put(persistence_run_attrs(actor, identity), field, unsafe)
          )

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field)
      end

      destination_changeset =
        ImportRun.persistence_changeset(
          %ImportRun{},
          persistence_run_attrs(actor, identity)
          |> Map.put(:destination_organization_status, :invalid)
          |> Map.put(:destination_organization_classification, unsafe)
        )

      refute destination_changeset.valid?

      assert Keyword.has_key?(
               destination_changeset.errors,
               :destination_organization_classification
             )

      for field <- [:wait_reason, :failure_kind, :cleanup_state, :cleanup_error] do
        changeset =
          RepositoryItem.persistence_changeset(
            %RepositoryItem{},
            Map.put(persistence_item_attrs(1), field, unsafe)
          )

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, field)
      end

      changeset =
        ImportAttempt.create_changeset(%ImportAttempt{}, %{
          repository_item_id: 1,
          attempt_number: 1,
          state: :failed,
          decision: %{"action" => "skip"},
          started_at: @now,
          terminal_at: @now,
          failure_kind: unsafe
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :failure_kind)
    end

    assert ForgeImports.SafeValue.classified_value?("https://github.com/acme/demo/issues/1")

    run = %ImportRun{
      wait_reason: "github_pat_secret",
      failure_kind: "Bearer secret",
      destination_organization_status: :invalid,
      destination_organization_classification: "github_pat_destination_secret"
    }

    item = %RepositoryItem{wait_reason: "[/var/private]", failure_kind: "ghp_secret"}
    view = RunView.from_run(run, [item])

    refute inspect(run) =~ "github_pat_secret"
    refute inspect(run) =~ "github_pat_destination_secret"
    refute inspect(item) =~ "ghp_secret"
    refute inspect(%ImportAttempt{failure_kind: "github_pat_secret"}) =~ "github_pat_secret"
    assert view.wait_reason == nil
    assert view.destination.organization_status == :invalid
    assert view.destination.organization_classification == nil
    assert [%{wait_reason: nil}] = view.repositories
  end

  test "operational values and GitHub source text use distinct secret and path policies" do
    for safe <- [
          "https://github.com/acme/demo/issues/1",
          "relative/checkpoint",
          "phase repository_staged"
        ] do
      assert ForgeImports.SafeValue.classified_value?(safe)
    end

    windows_separator = <<92>>

    for unsafe <- [
          "failed at `/var/lib/private`",
          "failed at </var/lib/private>",
          "failed at [/var/lib/private]",
          "failed at (/var/lib/private)",
          "failed at {/var/lib/private}",
          "failed at,/var/lib/private",
          "failed at;/var/lib/private",
          "failed at `C:#{windows_separator}private#{windows_separator}repo.git`",
          "failed at <#{windows_separator}#{windows_separator}server#{windows_separator}share>",
          "failed at `#{windows_separator}private#{windows_separator}repo.git`",
          "Bearer token authentication library"
        ] do
      refute ForgeImports.SafeValue.classified_value?(unsafe)
    end

    for safe <- [
          "Bearer token authentication library",
          "Uses /usr/bin/git for local examples",
          "https://github.com/acme/demo"
        ] do
      assert ForgeImports.SafeValue.github_source_text?(safe, 255)

      assert RepositoryItem.persistence_changeset(
               %RepositoryItem{},
               Map.put(persistence_item_attrs(1), :source_metadata, %{"description" => safe})
             ).valid?
    end

    unsafe_source_texts =
      Enum.map(~w(github_pat_ ghp_ gho_ ghu_ ghs_ ghr_), &(&1 <> "secret")) ++
        ["Bearer github_pat_secret", "bad\0value", <<255>>]

    for unsafe <- unsafe_source_texts do
      refute ForgeImports.SafeValue.github_source_text?(unsafe, 255)

      changeset =
        RepositoryItem.persistence_changeset(
          %RepositoryItem{},
          Map.put(persistence_item_attrs(1), :source_metadata, %{"description" => unsafe})
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :source_metadata)
    end
  end

  test "repository item changesets require strict secret-free cleanup evidence" do
    base = persistence_item_attrs(1)
    root = Fornacast.Config.repo_storage_root()

    quarantine =
      Path.join(
        Path.join([root, "@hashed", "aa", "bb"]),
        ".fornacast-cleanup-v1-#{String.duplicate("A", 43)}"
      )

    valid =
      base
      |> Map.merge(%{
        state: :staging_git,
        attempt_count: 1,
        hidden_repository_id: 1,
        staged_storage_path: quarantine,
        cleanup_state: "cleanup_pending",
        cleanup_eligible_at: @now,
        cleanup_attempt_count: 0,
        cleanup_error: "source_validation",
        checkpoint: %{
          "cleanup_identity" => %{
            "mode" => 0o700,
            "major_device" => 1,
            "minor_device" => 2,
            "inode" => 3
          }
        }
      })

    assert RepositoryItem.persistence_changeset(%RepositoryItem{}, valid).valid?

    cleanup_item = %RepositoryItem{
      state: :staging_git,
      hidden_repository_id: 1,
      staged_storage_path: quarantine,
      checkpoint: %{},
      cleanup_attempt_count: 0
    }

    cleanup_attrs =
      Map.take(valid, [
        :staged_storage_path,
        :cleanup_state,
        :cleanup_eligible_at,
        :cleanup_attempt_count,
        :cleanup_error,
        :checkpoint
      ])

    for unsafe_checkpoint <- [
          Map.put(valid.checkpoint, "secret", "github_pat_cleanup_secret"),
          Map.put(valid.checkpoint, "extra", String.duplicate("x", 32_769))
        ] do
      changeset =
        RepositoryItem.cleanup_pending_changeset(
          cleanup_item,
          Map.put(cleanup_attrs, :checkpoint, unsafe_checkpoint)
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :checkpoint)
    end

    for invalid <- [
          Map.put(valid, :staged_storage_path, "/tmp/github_pat_secret"),
          Map.put(valid, :cleanup_error, "github_pat_secret"),
          Map.put(valid, :cleanup_state, "pending"),
          put_in(valid, [:checkpoint, "cleanup_identity", "mode"], 0o755),
          Map.put(valid, :state, :git_staged),
          valid |> Map.put(:cleanup_state, nil) |> Map.put(:cleanup_error, "source_validation")
        ] do
      refute RepositoryItem.persistence_changeset(%RepositoryItem{}, invalid).valid?
    end
  end

  test "persistence lifecycle requires coherent terminal lease and resume evidence", %{
    actor: actor,
    identity: identity
  } do
    base_run = persistence_run_attrs(actor, identity)

    for attrs <- [
          %{state: :failed, terminal_at: nil},
          %{state: :ready, terminal_at: @now},
          %{state: :awaiting_credential, resume_state: nil},
          %{state: :ready, resume_state: :running}
        ] do
      refute ImportRun.persistence_changeset(
               %ImportRun{},
               Map.merge(base_run, attrs)
             ).valid?
    end

    assert ImportRun.persistence_changeset(
             %ImportRun{},
             Map.merge(base_run, %{state: :failed, terminal_at: @now})
           ).valid?

    leased_terminal_run = %ImportRun{
      lease_owner: "worker",
      lease_expires_at: DateTime.add(@now, 60, :second)
    }

    refute ImportRun.persistence_changeset(
             leased_terminal_run,
             Map.merge(base_run, %{state: :failed, terminal_at: @now})
           ).valid?

    assert ImportRun.persistence_changeset(
             %ImportRun{},
             Map.merge(base_run, %{
               state: :awaiting_credential,
               resume_state: :ready
             })
           ).valid?

    ready = struct(ImportRun, state: :ready)
    awaiting = ImportRun.transition_changeset(ready, :awaiting_credential, %{})
    assert awaiting.valid?
    assert Ecto.Changeset.get_field(awaiting, :resume_state) == :ready

    resumed =
      awaiting
      |> Ecto.Changeset.apply_changes()
      |> ImportRun.transition_changeset(:ready, %{})

    assert resumed.valid?
    assert Ecto.Changeset.get_field(resumed, :resume_state) == nil

    base_item = persistence_item_attrs(1)

    leased_terminal_item = %RepositoryItem{
      lease_owner: "worker",
      lease_expires_at: DateTime.add(@now, 60, :second)
    }

    refute RepositoryItem.persistence_changeset(
             leased_terminal_item,
             Map.merge(base_item, %{state: :failed})
           ).valid?

    refute RepositoryItem.persistence_changeset(
             %RepositoryItem{},
             Map.merge(base_item, %{state: :awaiting_credential, resume_state: nil})
           ).valid?

    assert RepositoryItem.persistence_changeset(
             %RepositoryItem{},
             Map.merge(base_item, %{
               state: :awaiting_credential,
               resume_state: :staging_git
             })
           ).valid?
  end

  test "run and item Inspect omit request, failure, path, and evidence fields" do
    run = %ImportRun{
      request_metadata: %{"request_id" => "github_pat_secret"},
      failure_detail: "failed at /private/run"
    }

    item = %RepositoryItem{
      failure_detail: "github_pat_secret",
      replacement_storage_path: "/private/replacement",
      staged_storage_path: "/private/staged",
      checkpoint: %{"path" => "/private/checkpoint"},
      source_git: %{"authorization" => "Bearer secret"},
      publication_evidence: %{"path" => "/private/published"}
    }

    for secret <- [
          "request_metadata",
          "failure_detail",
          "github_pat_secret",
          "/private/run",
          "replacement_storage_path",
          "staged_storage_path",
          "checkpoint",
          "source_git",
          "publication_evidence",
          "/private/published"
        ] do
      refute inspect(run) =~ secret
      refute inspect(item) =~ secret
    end
  end

  defp report_changeset(run, item, metadata) do
    ReportEntry.create_changeset(%ReportEntry{}, %{
      import_run_id: run.id,
      repository_item_id: item.id,
      idempotency_key: "report-#{System.unique_integer([:positive])}",
      scope: :repository,
      outcome: :warning,
      classification: "classified_warning",
      summary: "Bounded classified warning",
      metadata: metadata,
      source_count: 1
    })
  end

  defp running_run(actor, identity) do
    assert {:ok, discovering} = ForgeImports.create_run(actor, run_attrs(identity))

    assert {:ok, failed_discovery} =
             ForgeImports.transition_run(actor, discovering, :awaiting_resolution)

    assert {:ok, ready} = ForgeImports.transition_run(actor, failed_discovery, :ready)
    assert {:ok, running} = ForgeImports.transition_run(actor, ready, :running)
    running
  end

  defp one_time_envelope(run, actor, identity) do
    assert {:ok, envelope} =
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               run.id,
               actor.id,
               identity.github_user_id,
               "github_pat_secret",
               @keyring
             )

    envelope
  end

  defp run_attrs(identity, overrides \\ []) do
    defaults = %{
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: identity.github_user_id,
      source_owner_login: identity.login,
      request_metadata: %{}
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp item_attrs(overrides \\ []) do
    defaults = %{
      github_repository_id: System.unique_integer([:positive]),
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{"archived" => false},
      source_observed_at: @now
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp persistence_run_attrs(actor, identity) do
    run_attrs(identity)
    |> Map.put(:actor_user_id, actor.id)
    |> Map.put(:state, :discovering)
    |> Map.put(:lock_version, 1)
  end

  defp persistence_item_attrs(run_id) do
    item_attrs()
    |> Map.merge(%{
      import_run_id: run_id,
      selected: true,
      state: :queued,
      lock_version: 1,
      attempt_count: 0,
      checkpoint: %{},
      source_git: %{},
      publication_evidence: %{},
      cleanup_attempt_count: 0
    })
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

  defp repository_fixture(actor) do
    suffix = System.unique_integer([:positive])

    %Repository{owner_user_id: actor.id, storage_path: "@test/retry-hidden-#{suffix}.git"}
    |> Repository.create_changeset(%{
      slug: "retry-hidden-#{suffix}",
      name: "hidden",
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(
               %{
                 github_user_id: 8_500_000_000 + suffix,
                 login: "hardening-#{suffix}",
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
               username: "hardening-user-#{suffix}",
               email: "hardening-user-#{suffix}@example.test",
               password: "correct horse battery staple"
             })

    user
  end

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
end
