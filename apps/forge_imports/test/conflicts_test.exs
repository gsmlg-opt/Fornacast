defmodule ForgeImports.ConflictsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, RepositoryItem, RunView}
  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, OperationLease, Repo}

  @now ~U[2026-08-27 00:00:00Z]

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

  test "a clean selected repository accepts an explicit create decision", %{
    actor: actor,
    identity: identity
  } do
    run = awaiting_resolution_run_fixture(actor, identity)
    item = repository_item_fixture(run, actor, github_repository_id: 9_700_000_001)

    assert {:ok,
            %RunView{
              state: :awaiting_resolution,
              repositories: [
                %{
                  id: item_id,
                  state: :queued,
                  conflict_action: nil,
                  destination_slug: "demo"
                }
              ]
            }} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{Integer.to_string(item.id) => %{"action" => "create"}},
               request_metadata("resolve-create")
             )

    assert item_id == item.id
    assert Repo.get!(ImportRun, run.id).lock_version == run.lock_version + 1
    assert Repo.get!(RepositoryItem, item.id).lock_version == item.lock_version + 1
  end

  test "skip apply-to-similar expands deterministically while explicit decisions win", %{
    actor: actor,
    identity: identity
  } do
    run = awaiting_resolution_run_fixture(actor, identity, selected_count: 3)

    first =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_011,
        destination_slug: "first",
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    second =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_012,
        destination_slug: "second",
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    explicit =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_013,
        destination_slug: "third",
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    decisions = %{
      first.id => %{action: :skip, apply_to_similar: true},
      Integer.to_string(explicit.id) => %{"action" => "rename", "slug" => "renamed-third"}
    }

    assert {:ok, %RunView{repositories: repositories}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               decisions,
               request_metadata("resolve-similar")
             )

    assert [
             %{id: first_id, conflict_action: :skip, state: :queued},
             %{id: second_id, conflict_action: :skip, state: :queued},
             %{
               id: explicit_id,
               conflict_action: :rename,
               destination_slug: "renamed-third",
               state: :queued
             }
           ] = repositories

    assert {first_id, second_id, explicit_id} == {first.id, second.id, explicit.id}
  end

  test "replace requires exact full-name confirmation and stores a complete safe fingerprint", %{
    actor: actor,
    identity: identity
  } do
    target = repository_fixture(actor, "replace-target")
    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_021,
        destination_slug: target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    confirmation = "#{actor.username}/#{target.slug}"

    assert {:ok,
            %RunView{
              repositories: [
                %{
                  id: item_id,
                  conflict_action: :replace,
                  replacement_repository_id: replacement_id,
                  replacement_owner_id: replacement_owner_id,
                  replacement_generation: replacement_generation,
                  replacement_write_version: replacement_write_version,
                  replacement_updated_at: replacement_updated_at,
                  replacement_last_pushed_at: replacement_last_pushed_at
                }
              ]
            } = view} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{item.id => %{action: :replace, confirmation: confirmation}},
               request_metadata("resolve-replace")
             )

    assert item_id == item.id
    assert replacement_id == target.id
    assert replacement_owner_id == actor.id
    assert replacement_generation == target.generation
    assert replacement_write_version == target.write_version
    assert replacement_updated_at == target.updated_at
    assert replacement_last_pushed_at == target.last_pushed_at

    persisted = Repo.get!(RepositoryItem, item.id)
    assert persisted.replacement_storage_path == target.storage_path
    refute inspect(view) =~ target.storage_path
    refute inspect(view) =~ confirmation
  end

  test "start freezes a clean create attempt and both audits before manual dispatch", %{
    actor: actor,
    identity: identity
  } do
    run = awaiting_resolution_run_fixture(actor, identity)
    item = repository_item_fixture(run, actor, github_repository_id: 9_700_000_031)

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{item.id => %{action: :create}},
               request_metadata("freeze-create")
             )

    assert {:ok,
            %RunView{
              state: :running,
              counts: %{selected: 1, skipped: 0},
              repositories: [
                %{id: item_id, state: :queued, attempt_count: 1, conflict_action: nil}
              ]
            }} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-create"),
               dispatch: :manual
             )

    assert item_id == item.id

    assert %ImportAttempt{
             repository_item_id: ^item_id,
             attempt_number: 1,
             state: :running,
             terminal_at: nil,
             decision: %{"action" => "create", "slug" => "demo"}
           } = Repo.get_by!(ImportAttempt, repository_item_id: item.id)

    assert ["github_import.conflicts_frozen", "github_import.started"] =
             AuditEvent
             |> Repo.all()
             |> Enum.filter(&(&1.target_id == Integer.to_string(run.id)))
             |> Enum.sort_by(& &1.id)
             |> Enum.map(& &1.action)
  end

  test "start freezes skip rename and replace before post-commit dispatch", %{
    actor: actor,
    identity: identity
  } do
    target = repository_fixture(actor, "mixed-target")
    run = awaiting_resolution_run_fixture(actor, identity, selected_count: 3)

    skipped =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_041,
        destination_slug: "skip-me",
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    renamed =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_042,
        destination_slug: "rename-me",
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    replaced =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_043,
        destination_slug: target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{
                 skipped.id => %{action: :skip},
                 renamed.id => %{action: :rename, slug: "renamed-repository"},
                 replaced.id => %{
                   action: :replace,
                   confirmation: "#{actor.username}/#{target.slug}"
                 }
               },
               request_metadata("freeze-mixed")
             )

    parent = self()

    dispatch = fn run_id ->
      send(parent, {
        :start_dispatch,
        Repo.get!(ImportRun, run_id).state,
        Repo.aggregate(ImportAttempt, :count, :id),
        Repo.aggregate(AuditEvent, :count, :id)
      })

      :ok
    end

    assert {:ok,
            %RunView{
              state: :running,
              counts: %{selected: 3, skipped: 1},
              repositories: [
                %{id: skipped_id, state: :skipped, attempt_count: 1},
                %{id: renamed_id, state: :queued, attempt_count: 1},
                %{id: replaced_id, state: :queued, attempt_count: 1}
              ]
            }} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-mixed"),
               dispatch: dispatch
             )

    assert {skipped_id, renamed_id, replaced_id} == {skipped.id, renamed.id, replaced.id}
    assert_receive {:start_dispatch, :running, 3, 2}

    assert [skip_attempt, rename_attempt, replace_attempt] =
             ImportAttempt
             |> Repo.all()
             |> Enum.sort_by(& &1.repository_item_id)

    assert %ImportAttempt{
             state: :completed,
             terminal_at: %DateTime{},
             decision: %{"action" => "skip"}
           } = skip_attempt

    assert %ImportAttempt{
             state: :running,
             decision: %{"action" => "rename", "slug" => "renamed-repository"}
           } = rename_attempt

    assert %ImportAttempt{
             state: :running,
             decision: %{
               "action" => "replace",
               "replacement_repository_id" => replacement_id,
               "replacement_storage_path" => replacement_path
             }
           } = replace_attempt

    assert replacement_id == target.id
    assert replacement_path == target.storage_path
    refute inspect(replace_attempt) =~ target.storage_path
  end

  test "decision IDs and payloads reject aliases unknown foreign and unselected items", %{
    actor: actor,
    identity: identity
  } do
    run = awaiting_resolution_run_fixture(actor, identity, selected_count: 1)
    selected = repository_item_fixture(run, actor, github_repository_id: 9_700_000_051)

    unselected =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_052,
        destination_slug: "unselected",
        selected: false
      )

    foreign_run =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_052,
        source_repository_github_id: 9_700_000_053,
        source_repository_full_name: "acme/foreign"
      )

    foreign =
      repository_item_fixture(foreign_run, actor,
        github_repository_id: 9_700_000_053,
        destination_slug: "foreign"
      )

    invalid = [
      %{selected.id => %{action: :create}, Integer.to_string(selected.id) => %{action: :create}},
      %{"0#{selected.id}" => %{action: :create}},
      %{<<255>> => %{action: :create}},
      %{9_223_372_036_854_775_808 => %{action: :create}},
      %{unselected.id => %{action: :create}},
      %{foreign.id => %{action: :create}},
      %{selected.id => %{action: :create, unknown: true}},
      %{selected.id => %{action: :skip, apply_to_similar: false}},
      %{selected.id => %{action: :rename, slug: "renamed", apply_to_similar: true}},
      %{selected.id => %{action: :replace, confirmation: "owner/repo", extra: "value"}}
    ]

    for decisions <- invalid do
      assert {:error, :invalid_selection} =
               ForgeImports.resolve_repository_conflicts(
                 actor,
                 run.id,
                 decisions,
                 request_metadata("invalid-#{System.unique_integer([:positive])}")
               )
    end

    assert Repo.get!(ImportRun, run.id).lock_version == run.lock_version
    assert Repo.get!(RepositoryItem, selected.id).lock_version == selected.lock_version
    assert Repo.get!(RepositoryItem, unselected.id).lock_version == unselected.lock_version
  end

  test "destination drift closes only the exact attempt and re-resolution freezes its successor",
       %{
         actor: actor,
         identity: identity
       } do
    target = repository_fixture(actor, "drift-target")
    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_061,
        destination_slug: target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{
                 item.id => %{
                   action: :replace,
                   confirmation: "#{actor.username}/#{target.slug}"
                 }
               },
               request_metadata("resolve-before-drift")
             )

    assert {:ok, %RunView{state: :running}} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-before-drift"),
               dispatch: :manual
             )

    first_attempt = Repo.get_by!(ImportAttempt, repository_item_id: item.id, attempt_number: 1)
    first_decision = first_attempt.decision
    running_before_drift = Repo.get!(ImportRun, run.id)

    assert {:ok,
            %RunView{
              state: :running,
              repositories: [
                %{
                  id: item_id,
                  state: :awaiting_resolution,
                  wait_reason: "destination_changed",
                  attempt_count: 1,
                  conflict_action: nil,
                  replacement_repository_id: nil,
                  replacement_owner_id: nil,
                  replacement_generation: nil,
                  replacement_write_version: nil,
                  replacement_updated_at: nil,
                  replacement_last_pushed_at: nil
                }
              ]
            }} =
             ForgeImports.mark_destination_changed(
               actor,
               run.id,
               item.id,
               request_metadata("destination-drift")
             )

    assert item_id == item.id

    assert %ImportAttempt{
             state: :destination_changed,
             failure_kind: "destination_changed",
             terminal_at: %DateTime{},
             decision: ^first_decision
           } = Repo.get!(ImportAttempt, first_attempt.id)

    assert Repo.aggregate(ImportAttempt, :count, :id) == 1
    assert Repo.get!(ImportRun, run.id).lock_version == running_before_drift.lock_version + 1

    assert {:ok,
            %RunView{
              state: :running,
              repositories: [
                %{
                  id: ^item_id,
                  state: :queued,
                  attempt_count: 2,
                  conflict_action: :rename,
                  destination_slug: "drift-successor"
                }
              ]
            }} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{item.id => %{action: :rename, slug: "drift-successor"}},
               request_metadata("resolve-after-drift")
             )

    assert [immutable_first, successor] =
             ImportAttempt
             |> Repo.all()
             |> Enum.sort_by(& &1.attempt_number)

    assert immutable_first.id == first_attempt.id
    assert immutable_first.decision == first_decision

    assert %ImportAttempt{
             attempt_number: 2,
             state: :running,
             decision: %{"action" => "rename", "slug" => "drift-successor"}
           } = successor
  end

  test "start rejects empty stale-count and duplicate-slug plans without durable work", %{
    actor: actor,
    identity: identity
  } do
    empty = awaiting_resolution_run_fixture(actor, identity, selected_count: 0)

    assert {:error, :invalid_selection} =
             ForgeImports.start_import(
               actor,
               empty.id,
               request_metadata("start-empty"),
               dispatch: :manual
             )

    stale_count =
      awaiting_resolution_run_fixture(actor, identity,
        selected_count: 2,
        source_owner_github_id: 8_700_000_071,
        source_repository_github_id: 9_700_000_071,
        source_repository_full_name: "acme/stale-count"
      )

    repository_item_fixture(stale_count, actor,
      github_repository_id: 9_700_000_071,
      destination_slug: "stale-count"
    )

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               stale_count.id,
               request_metadata("start-stale-count"),
               dispatch: :manual
             )

    duplicate =
      awaiting_resolution_run_fixture(actor, identity,
        selected_count: 2,
        source_owner_github_id: 8_700_000_072,
        source_repository_github_id: 9_700_000_072,
        source_repository_full_name: "acme/duplicate"
      )

    repository_item_fixture(duplicate, actor,
      github_repository_id: 9_700_000_072,
      destination_slug: "duplicate-final"
    )

    repository_item_fixture(duplicate, actor,
      github_repository_id: 9_700_000_073,
      destination_slug: "duplicate-final"
    )

    assert {:error, :invalid_selection} =
             ForgeImports.start_import(
               actor,
               duplicate.id,
               request_metadata("start-duplicate"),
               dispatch: :manual
             )

    assert Repo.aggregate(ImportAttempt, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
    assert Repo.get!(ImportRun, empty.id).state == :awaiting_resolution
    assert Repo.get!(ImportRun, stale_count.id).state == :awaiting_resolution
    assert Repo.get!(ImportRun, duplicate.id).state == :awaiting_resolution
  end

  test "start rejects destination drift inactive actors and live run or item leases", %{
    actor: actor,
    identity: identity
  } do
    conflicted =
      awaiting_resolution_run_fixture(actor, identity,
        destination_organization_status: :conflict,
        destination_organization_classification: "namespace_conflict",
        source_owner_github_id: 8_700_000_081,
        source_repository_github_id: 9_700_000_081,
        source_repository_full_name: "acme/conflicted"
      )

    repository_item_fixture(conflicted, actor,
      github_repository_id: 9_700_000_081,
      destination_slug: "conflicted"
    )

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               conflicted.id,
               request_metadata("start-conflicted"),
               dispatch: :manual
             )

    run_leased =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_082,
        source_repository_github_id: 9_700_000_082,
        source_repository_full_name: "acme/run-leased"
      )

    repository_item_fixture(run_leased, actor,
      github_repository_id: 9_700_000_082,
      destination_slug: "run-leased"
    )

    now = DateTime.utc_now(:second)

    assert {:ok, _claimed_run} =
             OperationLease.claim(ImportRun, run_leased.id, "run-lease", now, 60,
               allowed_states: [:awaiting_resolution]
             )

    assert {:error, :busy} =
             ForgeImports.start_import(
               actor,
               run_leased.id,
               request_metadata("start-run-leased"),
               dispatch: :manual
             )

    item_leased =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_083,
        source_repository_github_id: 9_700_000_083,
        source_repository_full_name: "acme/item-leased"
      )

    leased_item =
      repository_item_fixture(item_leased, actor,
        github_repository_id: 9_700_000_083,
        destination_slug: "item-leased"
      )

    assert {:ok, _claimed_item} =
             OperationLease.claim(RepositoryItem, leased_item.id, "item-lease", now, 60,
               allowed_states: [:queued]
             )

    assert {:error, :busy} =
             ForgeImports.start_import(
               actor,
               item_leased.id,
               request_metadata("start-item-leased"),
               dispatch: :manual
             )

    unavailable =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_084,
        source_repository_github_id: 9_700_000_084,
        source_repository_full_name: "acme/unavailable"
      )

    unavailable_item =
      repository_item_fixture(unavailable, actor,
        github_repository_id: 9_700_000_084,
        destination_slug: "became-unavailable"
      )

    repository_fixture(actor, "became-unavailable", exact_slug?: true)

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               unavailable.id,
               request_metadata("start-unavailable"),
               dispatch: :manual
             )

    assert Repo.get!(RepositoryItem, unavailable_item.id).attempt_count == 0

    inactive =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_085,
        source_repository_github_id: 9_700_000_085,
        source_repository_full_name: "acme/inactive"
      )

    repository_item_fixture(inactive, actor,
      github_repository_id: 9_700_000_085,
      destination_slug: "inactive"
    )

    from(user in ForgeAccounts.User, where: user.id == ^actor.id)
    |> Repo.update_all(set: [state: "disabled"])

    assert {:error, :forbidden} =
             ForgeImports.start_import(
               actor,
               inactive.id,
               request_metadata("start-inactive"),
               dispatch: :manual
             )

    assert Repo.aggregate(ImportAttempt, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "post-commit dispatch failure leaves recoverable running work", %{
    actor: actor,
    identity: identity
  } do
    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_091,
        destination_slug: "dispatch-failure"
      )

    assert {:error, :recovery_unavailable} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("dispatch-failure"),
               dispatch: fn _run_id -> {:error, :offline} end
             )

    assert %ImportRun{state: :running} = Repo.get!(ImportRun, run.id)

    assert %RepositoryItem{state: :queued, attempt_count: 1} =
             Repo.get!(RepositoryItem, item.id)

    assert Repo.aggregate(ImportAttempt, :count, :id) == 1
    assert Repo.aggregate(AuditEvent, :count, :id) == 2
  end

  test "an audit failure rolls back attempts item versions and run transitions", %{
    actor: actor,
    identity: identity
  } do
    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_092,
        destination_slug: "audit-rollback"
      )

    assert {:error, :persistence_unavailable} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("audit-rollback"),
               audit: __MODULE__.FailingSecondAudit,
               dispatch: :manual
             )

    assert %ImportRun{state: :awaiting_resolution, lock_version: run_version} =
             Repo.get!(ImportRun, run.id)

    assert %RepositoryItem{state: :queued, attempt_count: 0, lock_version: item_version} =
             Repo.get!(RepositoryItem, item.id)

    assert run_version == run.lock_version
    assert item_version == item.lock_version
    assert Repo.aggregate(ImportAttempt, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "start propagates adoption safety database failures without freezing work", %{
    actor: actor,
    identity: identity
  } do
    for {suffix, failure} <- [
          {"dbconnection",
           fn -> raise DBConnection.ConnectionError, "injected adoption query failure" end},
          {"turso",
           fn -> raise Turso.Error, code: :io, message: "injected adoption query failure" end}
        ] do
      run =
        awaiting_resolution_run_fixture(actor, identity,
          source_owner_github_id: System.unique_integer([:positive])
        )

      item =
        repository_item_fixture(run, actor,
          github_repository_id: System.unique_integer([:positive]),
          destination_slug: "adoption-failure-#{suffix}"
        )

      assert {:error, :persistence_unavailable} =
               Persistence.with_test_after_adoption_safety_hook(failure, fn ->
                 ForgeImports.start_import(
                   actor,
                   run.id,
                   request_metadata("adoption-failure-#{suffix}"),
                   dispatch: :manual
                 )
               end)

      assert %ImportRun{state: :awaiting_resolution, lock_version: run_lock_version} =
               Repo.get!(ImportRun, run.id)

      assert %RepositoryItem{state: :queued, attempt_count: 0, lock_version: item_lock_version} =
               Repo.get!(RepositoryItem, item.id)

      assert run_lock_version == run.lock_version
      assert item_lock_version == item.lock_version

      assert Repo.aggregate(
               from(attempt in ImportAttempt, where: attempt.repository_item_id == ^item.id),
               :count,
               :id
             ) == 0
    end
  end

  test "Turso busy retries replay the whole start transaction without duplicate work", %{
    actor: actor,
    identity: identity
  } do
    if postgres?() do
      assert Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
    else
      run = awaiting_resolution_run_fixture(actor, identity)

      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_093,
        destination_slug: "busy-retry"
      )

      key = {__MODULE__.BusyOnceAudit, :busy_once}
      Process.put(key, true)
      on_exit(fn -> Process.delete(key) end)

      assert {:ok, %RunView{state: :running}} =
               ForgeImports.start_import(
                 actor,
                 run.id,
                 request_metadata("busy-retry"),
                 audit: __MODULE__.BusyOnceAudit,
                 dispatch: :manual
               )

      assert Process.get(key) == false
      assert Repo.aggregate(ImportAttempt, :count, :id) == 1
      assert Repo.aggregate(AuditEvent, :count, :id) == 2
    end
  end

  test "a clean new-organization plan freezes without creating the organization", %{
    actor: actor,
    identity: identity
  } do
    suffix = System.unique_integer([:positive])
    organization_slug = "future-import-org-#{suffix}"

    run =
      awaiting_resolution_run_fixture(actor, identity,
        source_kind: :organization,
        source_owner_github_id: 8_700_000_094,
        source_repository_github_id: nil,
        source_repository_full_name: nil,
        destination_organization_action: :new,
        destination_organization_slug: organization_slug,
        destination_organization_id: nil
      )

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_094,
        destination_owner_id: nil,
        destination_slug: "future-repository"
      )

    refute Repo.get_by(ForgeAccounts.User, username: organization_slug)

    assert {:ok,
            %RunView{
              state: :running,
              repositories: [%{id: item_id, destination_owner_id: nil, state: :queued}]
            }} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-new-organization"),
               dispatch: :manual
             )

    assert item_id == item.id
    refute Repo.get_by(ForgeAccounts.User, username: organization_slug)
  end

  test "replace confirmation is case-sensitive and never retained on rejection", %{
    actor: actor,
    identity: identity
  } do
    target = repository_fixture(actor, "case-target")
    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_095,
        destination_slug: target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    confirmation = "#{String.upcase(actor.username)}/#{target.slug}"

    assert {:error, :invalid_selection} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{item.id => %{action: :replace, confirmation: confirmation}},
               request_metadata("replace-case")
             )

    persisted = Repo.get!(RepositoryItem, item.id)
    assert persisted.lock_version == item.lock_version
    assert persisted.conflict_action == nil
    assert persisted.replacement_repository_id == nil
    refute inspect(persisted) =~ confirmation
    refute inspect(Repo.all(AuditEvent)) =~ confirmation
  end

  test "replace start compares null-safe push evidence and rejects fingerprint drift", %{
    actor: actor,
    identity: identity
  } do
    nil_push_target = repository_fixture(actor, "nil-push-target", last_pushed_at: nil)
    nil_push_run = awaiting_resolution_run_fixture(actor, identity)

    nil_push_item =
      repository_item_fixture(nil_push_run, actor,
        github_repository_id: 9_700_000_096,
        destination_slug: nil_push_target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               nil_push_run.id,
               %{
                 nil_push_item.id => %{
                   action: :replace,
                   confirmation: "#{actor.username}/#{nil_push_target.slug}"
                 }
               },
               request_metadata("resolve-nil-push")
             )

    assert {:ok, %RunView{state: :running}} =
             ForgeImports.start_import(
               actor,
               nil_push_run.id,
               request_metadata("start-nil-push"),
               dispatch: :manual
             )

    assert %ImportAttempt{
             decision: %{"replacement_last_pushed_at" => nil}
           } = Repo.get_by!(ImportAttempt, repository_item_id: nil_push_item.id)

    drift_target = repository_fixture(actor, "fingerprint-drift")

    drift_run =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_097,
        source_repository_github_id: 9_700_000_097,
        source_repository_full_name: "acme/fingerprint-drift"
      )

    drift_item =
      repository_item_fixture(drift_run, actor,
        github_repository_id: 9_700_000_097,
        destination_slug: drift_target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               drift_run.id,
               %{
                 drift_item.id => %{
                   action: :replace,
                   confirmation: "#{actor.username}/#{drift_target.slug}"
                 }
               },
               request_metadata("resolve-fingerprint-drift")
             )

    from(repository in Repository, where: repository.id == ^drift_target.id)
    |> Repo.update_all(
      set: [
        generation: drift_target.generation + 1,
        updated_at: DateTime.add(drift_target.updated_at, 1, :second)
      ]
    )

    attempts_before = Repo.aggregate(ImportAttempt, :count, :id)
    audits_before = Repo.aggregate(AuditEvent, :count, :id)

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               drift_run.id,
               request_metadata("start-fingerprint-drift"),
               dispatch: :manual
             )

    assert Repo.aggregate(ImportAttempt, :count, :id) == attempts_before
    assert Repo.aggregate(AuditEvent, :count, :id) == audits_before
    assert Repo.get!(ImportRun, drift_run.id).state == :awaiting_resolution
    assert Repo.get!(RepositoryItem, drift_item.id).attempt_count == 0
  end

  test "an item cannot freeze under a different owner the actor also controls", %{
    actor: actor,
    identity: identity
  } do
    suffix = System.unique_integer([:positive])

    {:ok, other_owner} =
      ForgeAccounts.create_organization(actor, %{
        username: "other-import-owner-#{suffix}",
        display_name: "Other import owner"
      })

    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_098,
        destination_owner_id: other_owner.id,
        destination_slug: "wrong-owner"
      )

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("wrong-owner"),
               dispatch: :manual
             )

    assert Repo.get!(RepositoryItem, item.id).attempt_count == 0
    assert Repo.aggregate(ImportAttempt, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "same-second pushes invalidate a frozen replacement through write version", %{
    actor: actor,
    identity: identity
  } do
    inserted_target = repository_fixture(actor, "same-second-target", last_pushed_at: nil)
    completed_at = inserted_target.updated_at

    from(repository in Repository, where: repository.id == ^inserted_target.id)
    |> Repo.update_all(set: [last_pushed_at: completed_at])

    target = Repo.get!(Repository, inserted_target.id)
    run = awaiting_resolution_run_fixture(actor, identity)

    item =
      repository_item_fixture(run, actor,
        github_repository_id: 9_700_000_110,
        destination_slug: target.slug,
        state: :awaiting_resolution,
        wait_reason: "repository_conflict"
      )

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               run.id,
               %{
                 item.id => %{
                   action: :replace,
                   confirmation: "#{actor.username}/#{target.slug}"
                 }
               },
               request_metadata("freeze-same-second")
             )

    frozen = Repo.get!(RepositoryItem, item.id)
    assert frozen.replacement_write_version == 0
    assert frozen.replacement_updated_at == completed_at
    assert frozen.replacement_last_pushed_at == completed_at

    {first_push, second_push} =
      ForgeRepos.with_test_mark_pushed_clock(fn -> completed_at end, fn ->
        assert {:ok, first_push} = ForgeRepos.mark_pushed(target, completed_at)
        assert {:ok, second_push} = ForgeRepos.mark_pushed(first_push, completed_at)
        {first_push, second_push}
      end)

    assert first_push.write_version == 1
    assert second_push.write_version == 2
    assert second_push.generation == target.generation
    assert second_push.updated_at == frozen.replacement_updated_at
    assert second_push.last_pushed_at == frozen.replacement_last_pushed_at

    assert {:error, :stale} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-same-second"),
               dispatch: :manual
             )

    assert Repo.aggregate(ImportAttempt, :count, :id) == 0
    assert Repo.get!(ImportRun, run.id).state == :awaiting_resolution
  end

  test "create and rename attempts can return to resolution on typed destination drift", %{
    actor: actor,
    identity: identity
  } do
    create_run = awaiting_resolution_run_fixture(actor, identity)

    create_item =
      repository_item_fixture(create_run, actor,
        github_repository_id: 9_700_000_099,
        destination_slug: "create-drift"
      )

    assert {:ok, %RunView{state: :running}} =
             ForgeImports.start_import(
               actor,
               create_run.id,
               request_metadata("start-create-drift"),
               dispatch: :manual
             )

    assert {:ok, %RunView{state: :running, repositories: [create_after]}} =
             ForgeImports.mark_destination_changed(
               actor,
               create_run.id,
               create_item.id,
               request_metadata("mark-create-drift")
             )

    assert create_after.state == :awaiting_resolution
    assert create_after.wait_reason == "destination_changed"

    rename_run =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: 8_700_000_100,
        source_repository_github_id: 9_700_000_100,
        source_repository_full_name: "acme/rename-drift"
      )

    rename_item =
      repository_item_fixture(rename_run, actor,
        github_repository_id: 9_700_000_100,
        destination_slug: "rename-source",
        state: :awaiting_resolution,
        wait_reason: "repository_slug_normalized"
      )

    assert {:ok, %RunView{}} =
             ForgeImports.resolve_repository_conflicts(
               actor,
               rename_run.id,
               %{rename_item.id => %{action: :rename, slug: "rename-drift"}},
               request_metadata("resolve-rename-drift")
             )

    assert {:ok, %RunView{state: :running}} =
             ForgeImports.start_import(
               actor,
               rename_run.id,
               request_metadata("start-rename-drift"),
               dispatch: :manual
             )

    assert {:ok, %RunView{state: :running, repositories: [rename_after]}} =
             ForgeImports.mark_destination_changed(
               actor,
               rename_run.id,
               rename_item.id,
               request_metadata("mark-rename-drift")
             )

    assert rename_after.state == :awaiting_resolution
    assert rename_after.wait_reason == "destination_changed"

    assert Enum.all?(Repo.all(ImportAttempt), fn attempt ->
             attempt.state == :destination_changed and
               attempt.failure_kind == "destination_changed" and
               match?(%DateTime{}, attempt.terminal_at)
           end)
  end

  test "destination drift cannot reopen an item with unresolved cleanup evidence", %{
    actor: actor,
    identity: identity
  } do
    {run, item} = started_create_fixture(actor, identity, 9_700_000_110, "cleanup-fenced")
    hidden = repository_fixture(actor, "cleanup-hidden")
    root = Fornacast.Config.repo_storage_root()
    destination = Path.join([root, "@hashed", "aa", "bb", "cleanup-hidden.git"])

    digest =
      :sha256
      |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
      |> Base.url_encode64(padding: false)

    quarantine = Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :staging_git,
                 hidden_repository_id: hidden.id,
                 staged_storage_path: quarantine,
                 cleanup_state: "cleanup_pending",
                 cleanup_eligible_at: @now,
                 cleanup_attempt_count: 0,
                 cleanup_error: "previous_failure",
                 checkpoint: %{
                   "cleanup_identity" => %{
                     "mode" => 0o700,
                     "major_device" => 1,
                     "minor_device" => 2,
                     "inode" => 3
                   }
                 }
               ]
             )

    attempt = Repo.get_by!(ImportAttempt, repository_item_id: item.id, attempt_number: 1)
    run_before = Repo.get!(ImportRun, run.id)

    assert {:error, :stale} =
             ForgeImports.mark_destination_changed(
               actor,
               run.id,
               item.id,
               request_metadata("cleanup-fenced-drift")
             )

    assert %RepositoryItem{state: :staging_git, cleanup_state: "cleanup_pending"} =
             Repo.get!(RepositoryItem, item.id)

    assert %ImportAttempt{state: :running, terminal_at: nil} =
             Repo.get!(ImportAttempt, attempt.id)

    assert Repo.get!(ImportRun, run.id).lock_version == run_before.lock_version
  end

  test "destination drift cannot abandon staged ownership before cleanup evidence persists", %{
    actor: actor,
    identity: identity
  } do
    {run, item} = started_create_fixture(actor, identity, 9_700_000_119, "staging-owned")
    hidden = repository_fixture(actor, "staging-owned-hidden")
    destination = Path.join(Fornacast.Config.repo_storage_root(), hidden.storage_path)

    digest =
      :sha256
      |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
      |> Base.url_encode64(padding: false)

    quarantine = Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)
    File.mkdir_p!(quarantine)
    File.chmod!(quarantine, 0o700)
    on_exit(fn -> File.rm_rf(quarantine) end)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :staging_git,
                 hidden_repository_id: hidden.id,
                 staged_storage_path: destination,
                 cleanup_state: nil
               ]
             )

    attempt = Repo.get_by!(ImportAttempt, repository_item_id: item.id, attempt_number: 1)
    run_before = Repo.get!(ImportRun, run.id)

    assert {:error, :stale} =
             ForgeImports.mark_destination_changed(
               actor,
               run.id,
               item.id,
               request_metadata("staging-owned-drift")
             )

    assert %RepositoryItem{
             state: :staging_git,
             hidden_repository_id: hidden_id,
             staged_storage_path: ^destination,
             cleanup_state: nil
           } = Repo.get!(RepositoryItem, item.id)

    assert hidden_id == hidden.id

    assert %ImportAttempt{state: :running, terminal_at: nil} =
             Repo.get!(ImportAttempt, attempt.id)

    assert Repo.get!(ImportRun, run.id).lock_version == run_before.lock_version
    assert File.dir?(quarantine)
  end

  test "git-staged destination drift remains available to an exact owned capability", %{
    actor: actor,
    identity: identity
  } do
    {run, item} = started_create_fixture(actor, identity, 9_700_000_120, "git-staged-drift")
    hidden = repository_fixture(actor, "git-staged-hidden")
    destination = Path.join(Fornacast.Config.repo_storage_root(), hidden.storage_path)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :git_staged,
                 hidden_repository_id: hidden.id,
                 staged_storage_path: destination,
                 source_git: %{"empty" => false},
                 checkpoint: %{"git_staged" => true}
               ]
             )

    current = Repo.get!(RepositoryItem, item.id)

    assert {:ok, capability} =
             OperationLease.claim(
               RepositoryItem,
               current.id,
               "git-staged-drift-owner",
               DateTime.utc_now(:second),
               60,
               allowed_states: [:git_staged]
             )

    assert {:ok, %RunView{repositories: [view]}} =
             ForgeImports.mark_destination_changed(
               actor,
               run.id,
               capability,
               request_metadata("git-staged-owned-drift")
             )

    assert view.state == :awaiting_resolution
    assert view.wait_reason == "destination_changed"

    assert %RepositoryItem{
             state: :awaiting_resolution,
             hidden_repository_id: hidden_id,
             staged_storage_path: ^destination,
             source_git: %{"empty" => false},
             checkpoint: %{"git_staged" => true},
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, item.id)

    assert hidden_id == hidden.id
  end

  test "an exact live item lease can mark drift while forged stale and expired capabilities cannot",
       %{
         actor: actor,
         identity: identity
       } do
    {owned_run, owned_item} =
      started_create_fixture(actor, identity, 9_700_000_111, "owned-lease-drift")

    now = DateTime.utc_now(:second)

    assert {:ok, owned_capability} =
             OperationLease.claim(
               RepositoryItem,
               owned_item.id,
               "repository-worker-owned",
               now,
               60,
               allowed_states: [:queued]
             )

    assert {:ok,
            %RunView{
              state: :running,
              repositories: [
                %{
                  id: owned_item_id,
                  state: :awaiting_resolution,
                  wait_reason: "destination_changed"
                }
              ]
            }} =
             ForgeImports.mark_destination_changed(
               actor,
               owned_run.id,
               owned_capability,
               request_metadata("owned-lease-drift")
             )

    assert owned_item_id == owned_item.id

    assert %RepositoryItem{lease_owner: nil, lease_expires_at: nil} =
             Repo.get!(RepositoryItem, owned_item.id)

    {guarded_run, guarded_item} =
      started_create_fixture(actor, identity, 9_700_000_112, "guarded-lease-drift")

    assert {:ok, guarded_capability} =
             OperationLease.claim(
               RepositoryItem,
               guarded_item.id,
               "repository-worker-guarded",
               now,
               60,
               allowed_states: [:queued]
             )

    guarded_attempt =
      Repo.get_by!(ImportAttempt, repository_item_id: guarded_item.id, attempt_number: 1)

    guarded_run_before = Repo.get!(ImportRun, guarded_run.id)

    for forged <- [
          %{guarded_capability | lease_owner: "forged-owner"},
          %{guarded_capability | lock_version: guarded_capability.lock_version - 1}
        ] do
      assert {:error, :stale} =
               ForgeImports.mark_destination_changed(
                 actor,
                 guarded_run.id,
                 forged,
                 request_metadata("forged-#{forged.lock_version}")
               )
    end

    expired_at = DateTime.add(now, -1, :second)

    from(item in RepositoryItem, where: item.id == ^guarded_item.id)
    |> Repo.update_all(set: [lease_expires_at: expired_at])

    assert {:error, :stale} =
             ForgeImports.mark_destination_changed(
               actor,
               guarded_run.id,
               %{guarded_capability | lease_expires_at: expired_at},
               request_metadata("expired-capability")
             )

    assert %ImportAttempt{state: :running, terminal_at: nil} =
             Repo.get!(ImportAttempt, guarded_attempt.id)

    assert %RepositoryItem{
             state: :queued,
             lease_owner: "repository-worker-guarded",
             lock_version: guarded_lock_version
           } = Repo.get!(RepositoryItem, guarded_item.id)

    assert guarded_lock_version == guarded_capability.lock_version
    assert Repo.get!(ImportRun, guarded_run.id).lock_version == guarded_run_before.lock_version
  end

  defmodule FailingSecondAudit do
    def record(
          _actor,
          "github_import.started",
          _target_type,
          _target_id,
          _metadata,
          _opts
        ),
        do: {:error, :injected_audit_failure}

    def record(actor, action, target_type, target_id, metadata, opts),
      do: Fornacast.Audit.record(actor, action, target_type, target_id, metadata, opts)
  end

  defmodule BusyOnceAudit do
    def record(actor, action, target_type, target_id, metadata, opts) do
      key = {__MODULE__, :busy_once}

      if Process.get(key) == true do
        Process.put(key, false)
        raise %Turso.Error{code: :busy, message: "injected busy"}
      else
        Fornacast.Audit.record(actor, action, target_type, target_id, metadata, opts)
      end
    end
  end

  defp awaiting_resolution_run_fixture(actor, identity, overrides \\ %{}) do
    defaults = %{
      actor_user_id: actor.id,
      source_kind: :repository,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: 8_700_000_001,
      source_owner_login: "acme",
      source_repository_github_id: 9_700_000_001,
      source_repository_full_name: "acme/demo",
      destination_organization_action: :existing,
      destination_organization_slug: actor.username,
      destination_organization_status: :clean,
      state: :awaiting_resolution,
      selected_count: 1,
      request_metadata: %{}
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp repository_item_fixture(run, actor, overrides) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: 9_700_000_001,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_slug: "demo",
      destination_visibility: :private,
      state: :queued
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp started_create_fixture(actor, identity, github_repository_id, slug) do
    run =
      awaiting_resolution_run_fixture(actor, identity,
        source_owner_github_id: github_repository_id - 1_000_000_000,
        source_repository_github_id: github_repository_id,
        source_repository_full_name: "acme/#{slug}"
      )

    item =
      repository_item_fixture(run, actor,
        github_repository_id: github_repository_id,
        destination_slug: slug
      )

    assert {:ok, %RunView{state: :running}} =
             ForgeImports.start_import(
               actor,
               run.id,
               request_metadata("start-#{slug}"),
               dispatch: :manual
             )

    {run, item}
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_600_000_000 + suffix,
          login: "conflict-importer-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)
    identity
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "conflict-user-#{suffix}",
        email: "conflict-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp repository_fixture(owner, prefix, opts \\ []) do
    suffix = System.unique_integer([:positive])
    slug = if Keyword.get(opts, :exact_slug?, false), do: prefix, else: "#{prefix}-#{suffix}"

    %Repository{
      owner_user_id: owner.id,
      storage_path: "@test/#{slug}.git",
      last_pushed_at: Keyword.get(opts, :last_pushed_at, @now)
    }
    |> Repository.create_changeset(%{
      slug: slug,
      name: slug,
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Repo.insert!()
  end

  defp request_metadata(operation) do
    %{
      "request_id" => "#{operation}-request",
      "operation_id" => "#{operation}-operation",
      "ip_address" => "203.0.113.80",
      "user_agent" => "forge-import-conflicts-test"
    }
  end

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, %Ecto.Changeset{} = changeset}) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

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
end
