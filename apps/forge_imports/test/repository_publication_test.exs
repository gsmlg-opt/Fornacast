defmodule ForgeImports.RepositoryPublicationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts.OrganizationMember

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    PageCheckpoint,
    Persistence,
    Reconciler,
    RepositoryItem
  }

  alias ForgePulls.{MergeOperation, PullRequest}
  alias ForgeRepos.{Collaborator, GitWriteOperation, Repository}
  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-28 01:00:00Z]
  @pat "github_pat_publication_test_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<9>>, 32)}}
  @terminal_resources ~w(labels issues comments pull_requests number_sequence)

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture("publisher")
    identity = identity_fixture(actor)
    %{actor: actor, identity: identity}
  end

  test "validates request metadata before reading publication state", %{actor: actor} do
    invalid = %{"request_id" => @pat}
    before_actor = Repo.get!(ForgeAccounts.User, actor.id)
    telemetry_id = {__MODULE__, make_ref()}
    owner = self()
    prefix = Keyword.get(Repo.config(), :telemetry_prefix, [:fornacast, :repo])

    :ok =
      :telemetry.attach(
        telemetry_id,
        prefix ++ [:query],
        fn _event, _measurements, _metadata, _config -> send(owner, :publication_query) end,
        nil
      )

    assert {:error, :invalid_request_metadata} =
             ForgeImports.publish_repository(actor, 9_223_372_036_854_775_000, invalid)

    :telemetry.detach(telemetry_id)
    refute_received :publication_query
    assert Repo.get!(ForgeAccounts.User, actor.id) == before_actor
  end

  test "requires every exact committed terminal sentinel", context do
    fixture = ready_publication_fixture(context)

    for missing <- @terminal_resources do
      fixture.item.id
      |> then(&Repo.get_by!(PageCheckpoint, repository_item_id: &1, resource_kind: missing))
      |> Repo.delete!()

      assert {:error, :metadata_not_ready} =
               ForgeImports.publish_repository(
                 context.actor,
                 fixture.item.id,
                 request_metadata("missing-#{missing}")
               )

      terminal_fixture(fixture.item, missing)
    end

    Repo.get_by!(PageCheckpoint,
      repository_item_id: fixture.item.id,
      resource_kind: "labels"
    )
    |> Repo.delete!()

    terminal_fixture(fixture.item, "labels", page_key: "ordinary-page")

    assert {:error, :metadata_not_ready} =
             ForgeImports.publish_repository(
               context.actor,
               fixture.item.id,
               request_metadata("wrong-terminal-key")
             )
  end

  test "publishes create with canonical settings, durable evidence, audit, and read-only replay",
       context do
    fixture = ready_publication_fixture(context)
    request = request_metadata("create")
    storage_path = fixture.shadow.storage_path

    assert {:ok, %{repository: published, replaced: nil}} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, request)

    assert %Repository{
             id: published_id,
             owner_user_id: owner_id,
             slug: "demo",
             name: "Demo source",
             description: "Imported description",
             visibility: :public,
             default_branch: "trunk",
             has_issues: false,
             allow_merge_commit: false,
             lifecycle: :ready,
             generation: 1,
             write_version: 0,
             storage_path: ^storage_path
           } = published

    assert published_id == fixture.shadow.id
    assert owner_id == context.actor.id

    assert %RepositoryItem{
             state: :published,
             lease_owner: nil,
             lease_expires_at: nil,
             publication_evidence: evidence
           } = Repo.get!(RepositoryItem, fixture.item.id)

    assert evidence["state"] == "committed"
    assert evidence["repository_id"] == published.id
    assert evidence["replaced_repository_id"] == nil
    assert evidence["published_count_after"] == 1
    assert evidence["operation_id"] == "github-import-publication-#{fixture.item.id}-1"
    assert evidence["request_metadata"] == Map.delete(request, "operation_id")
    refute inspect(evidence) =~ request["operation_id"]
    retained = inspect({published, evidence, Repo.all(AuditEvent)})
    refute retained =~ @pat
    refute retained =~ fixture.item.staged_storage_path
    refute retained =~ request["operation_id"]

    assert %ImportRun{published_count: 1, lock_version: run_version} =
             Repo.get!(ImportRun, fixture.run.id)

    assert run_version == evidence["run_lock_version_after"]
    assert %ImportAttempt{state: :completed} = Repo.get!(ImportAttempt, fixture.attempt.id)

    before_replay = snapshot_counts()

    assert {:ok, %{repository: replayed, replaced: nil}} =
             ForgeImports.publish_repository(
               context.actor,
               fixture.item.id,
               request_metadata("replay")
             )

    assert replayed.id == published.id
    assert snapshot_counts() == before_replay
  end

  test "replacement keeps the URL, copies collaborators, increments generation, and tombstones old",
       context do
    collaborator = user_fixture("collaborator")
    target = repository_fixture(context.actor, "replace-me", generation: 4)

    %Collaborator{}
    |> Collaborator.changeset(%{
      repository_id: target.id,
      user_id: collaborator.id,
      role: :write
    })
    |> Repo.insert!()

    fixture =
      ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

    storage_path = fixture.shadow.storage_path
    target_path = ForgeRepos.absolute_storage_path(target)
    File.mkdir_p!(Path.dirname(target_path))
    assert {:ok, ^target_path} = GitCore.init_bare(target_path)

    pending_write =
      %GitWriteOperation{}
      |> GitWriteOperation.changeset(%{
        repository_id: target.id,
        actor_user_id: context.actor.id,
        request_id: "publication-git-reconcile",
        kind: :ref_update,
        state: :prepared,
        target_ref: "refs/heads/main",
        expected_oid: nil,
        proposed_oid: String.duplicate("a", 40),
        lock_version: 0
      })
      |> Repo.insert!()

    assert {:ok, %{repository: published, replaced: replaced}} =
             ForgePulls.MergeRecovery.with_test_reconcile_observer(
               fn -> send(self(), :merge_reconciled_before_publication) end,
               fn ->
                 ForgeImports.publish_repository(
                   context.actor,
                   fixture.item.id,
                   request_metadata("replace")
                 )
               end
             )

    assert_receive :merge_reconciled_before_publication

    assert %GitWriteOperation{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(GitWriteOperation, pending_write.id)

    assert published.id == fixture.shadow.id
    refute published.id == target.id
    assert published.owner_user_id == target.owner_user_id
    assert published.slug == target.slug
    assert published.generation == 5
    assert published.storage_path == storage_path
    assert replaced.id == target.id
    assert replaced.lifecycle == :tombstoned
    assert %DateTime{} = replaced.deleted_at

    assert [%Collaborator{user_id: user_id, role: :write}] =
             Repo.all(
               from collaborator_row in Collaborator,
                 where: collaborator_row.repository_id == ^published.id
             )

    assert user_id == collaborator.id

    assert {:ok, %{repository: replayed, replaced: replayed_old}} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert {replayed.id, replayed_old.id} == {published.id, target.id}
  end

  test "rename publishes its current shadow at generation one", context do
    fixture = ready_publication_fixture(context, action: :rename, slug: "renamed-publication")

    assert {:ok, %{repository: published, replaced: nil}} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert published.id == fixture.shadow.id
    assert published.slug == "renamed-publication"
    assert published.generation == 1
  end

  test "replacement fingerprint drift reopens only the item and closes its current attempt",
       context do
    target = repository_fixture(context.actor, "drift-target")

    fixture =
      ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

    assert {1, _rows} =
             Repo.update_all(
               from(repository in Repository, where: repository.id == ^target.id),
               inc: [write_version: 1]
             )

    assert {:error, :destination_changed} =
             ForgeImports.publish_repository(
               context.actor,
               fixture.item.id,
               request_metadata("drift")
             )

    assert %RepositoryItem{
             state: :awaiting_resolution,
             wait_reason: "destination_changed",
             hidden_repository_id: hidden_id,
             publication_evidence: %{},
             lease_owner: nil
           } = Repo.get!(RepositoryItem, fixture.item.id)

    assert hidden_id == fixture.shadow.id

    assert %ImportAttempt{state: :destination_changed} =
             Repo.get!(ImportAttempt, fixture.attempt.id)

    assert Repo.get!(ImportRun, fixture.run.id).published_count == 0
    assert Repo.get!(Repository, target.id).lifecycle == :ready
    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
  end

  test "audit collision and post-tombstone failure roll back the complete publication", context do
    target = repository_fixture(context.actor, "rollback-target")

    fixture =
      ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

    operation_id = "github-import-publication-#{fixture.item.id}-1"

    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor_user_id: context.actor.id,
      action: "repository.replaced",
      target_type: "repository",
      target_id: Integer.to_string(target.id),
      operation_id: operation_id,
      metadata: %{"collision" => true}
    })
    |> Repo.insert!()

    assert {:error, :persistence_unavailable} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert Repo.get!(Repository, target.id).lifecycle == :ready
    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
    assert Repo.get!(ImportRun, fixture.run.id).published_count == 0

    Repo.get_by!(AuditEvent, operation_id: operation_id) |> Repo.delete!()
    make_publication_due!(fixture.item.id)

    assert {:error, :persistence_unavailable} =
             ForgeRepos.with_test_after_import_tombstone_hook(
               fn _repository -> raise "injected tombstone failure" end,
               fn -> ForgeImports.RepositoryPublisher.recover(fixture.item.id) end
             )

    assert Repo.get!(Repository, target.id).lifecycle == :ready
    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
    assert Repo.get!(ImportRun, fixture.run.id).published_count == 0
  end

  test "expired intent recovers without credential checkout under cancel requested", context do
    fixture = ready_publication_fixture(context)
    admitted = admit_without_finish!(context.actor, fixture.item)
    assert admitted.state == :publishing
    intent = admitted.publication_evidence

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^fixture.run.id),
               set: [state: :cancel_requested],
               inc: [lock_version: 1]
             )

    make_publication_due!(fixture.item.id)

    assert {:ok, %{repository: repository}} =
             ForgeImports.RepositoryPublisher.recover(fixture.item.id)

    assert repository.id == fixture.shadow.id

    assert Repo.get!(RepositoryItem, fixture.item.id).publication_evidence["operation_id"] ==
             intent["operation_id"]
  end

  test "disabled actors and foreign actors cannot replay committed publication", context do
    fixture = ready_publication_fixture(context)
    foreign = user_fixture("foreign")

    assert {:ok, %{repository: _repository}} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    before = snapshot_counts()
    assert {:error, :not_found} = ForgeImports.publish_repository(foreign, fixture.item.id, %{})
    assert snapshot_counts() == before

    assert {1, _rows} =
             Repo.update_all(
               from(user in ForgeAccounts.User, where: user.id == ^context.actor.id),
               set: [state: :disabled]
             )

    assert {:error, :not_found} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert snapshot_counts() == before
  end

  test "disabled actor recovery reopens the admitted item without touching repositories",
       context do
    fixture = ready_publication_fixture(context, slug: "disabled-recovery")
    _admitted = admit_without_finish!(context.actor, fixture.item)

    assert {1, _rows} =
             Repo.update_all(
               from(user in ForgeAccounts.User, where: user.id == ^context.actor.id),
               set: [state: :disabled]
             )

    make_publication_due!(fixture.item.id)

    assert {:error, :destination_changed} =
             ForgeImports.RepositoryPublisher.recover(fixture.item.id)

    assert %RepositoryItem{state: :awaiting_resolution, publication_evidence: %{}} =
             Repo.get!(RepositoryItem, fixture.item.id)

    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
    assert Repo.get!(ImportRun, fixture.run.id).published_count == 0
  end

  test "terminal parent run makes admitted recovery inconsistent without mutation", context do
    fixture = ready_publication_fixture(context, slug: "terminal-recovery")
    _admitted = admit_without_finish!(context.actor, fixture.item)
    terminal_at = DateTime.utc_now(:second)

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^fixture.run.id),
               set: [
                 state: :failed,
                 terminal_at: terminal_at,
                 failure_kind: "publication_test",
                 credential_ciphertext: nil,
                 credential_nonce: nil,
                 credential_tag: nil,
                 credential_key_id: nil
               ],
               inc: [lock_version: 1]
             )

    make_publication_due!(fixture.item.id)
    before = Repo.get!(RepositoryItem, fixture.item.id)

    assert {:error, :publication_inconsistent} =
             ForgeImports.RepositoryPublisher.recover(fixture.item.id)

    assert Repo.get!(RepositoryItem, fixture.item.id) == before
    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
  end

  test "response loss after commit replays read-only across higher run snapshots and rejects corruption",
       context do
    fixture = ready_publication_fixture(context, slug: "response-loss")
    parent = self()

    {_pid, monitor} =
      spawn_monitor(fn ->
        ForgeImports.RepositoryPublisher.with_test_after_commit_hook(
          fn _result ->
            send(parent, :publication_committed)
            exit(:response_lost)
          end,
          fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
        )
      end)

    assert_receive :publication_committed, 2_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :response_lost}, 1_000
    committed = Repo.get!(RepositoryItem, fixture.item.id)
    assert committed.state == :published

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^fixture.run.id),
               inc: [published_count: 2, lock_version: 2]
             )

    before_replay = snapshot_counts()

    assert {:ok, %{repository: repository}} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert repository.id == fixture.shadow.id
    assert snapshot_counts() == before_replay

    corrupted =
      Map.put(
        committed.publication_evidence,
        "published_count_after",
        Repo.get!(ImportRun, fixture.run.id).published_count + 1
      )

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [publication_evidence: corrupted]
             )

    assert {:error, :publication_inconsistent} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [publication_evidence: committed.publication_evidence]
             )

    audit = Repo.get_by!(AuditEvent, operation_id: committed.publication_evidence["operation_id"])

    assert {1, _rows} =
             Repo.update_all(
               from(event in AuditEvent, where: event.id == ^audit.id),
               set: [metadata: Map.put(audit.metadata, "run_lock_version_after", 0)]
             )

    assert {:error, :publication_inconsistent} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})
  end

  test "concurrent callers expose one admitted winner and one busy loser", context do
    fixture = ready_publication_fixture(context, slug: "concurrent-publication")
    parent = self()

    {_pid, monitor} =
      spawn_monitor(fn ->
        result =
          ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
            fn _capability ->
              send(parent, {:publication_admitted, self()})
              receive do: (:continue_publication -> :ok)
            end,
            fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
          )

        send(parent, {:publication_result, result})
      end)

    assert_receive {:publication_admitted, publisher}, 1_000

    assert {:error, :busy} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    send(publisher, :continue_publication)
    assert_receive {:publication_result, {:ok, %{repository: repository}}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
    assert repository.id == fixture.shadow.id
    assert Repo.get!(ImportRun, fixture.run.id).published_count == 1
  end

  test "replacement serializes queued writers before or after activation without stale writes",
       context do
    first_target = repository_fixture(context.actor, "writer-first")

    first =
      ready_publication_fixture(context,
        action: :replace,
        target: first_target,
        slug: first_target.slug
      )

    deadline = System.monotonic_time(:millisecond) + 10_000
    assert {:ok, lease} = GitCore.RepositoryWriteLimiter.acquire(first_target.id, deadline)

    writer =
      Task.async(fn ->
        ForgeRepos.with_write_fence(first_target, :content, fn _path, _remaining ->
          ForgeRepos.mark_pushed(first_target)
        end)
      end)

    wait_for_write_waiters(1)

    publisher =
      Task.async(fn -> ForgeImports.publish_repository(context.actor, first.item.id, %{}) end)

    wait_for_write_waiters(2)
    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    assert {:ok, %Repository{write_version: 1}} = Task.await(writer, 5_000)
    assert {:error, :destination_changed} = Task.await(publisher, 5_000)
    assert Repo.get!(Repository, first_target.id).lifecycle == :ready
    assert Repo.get!(Repository, first.shadow.id).lifecycle == :importing

    second_target = repository_fixture(context.actor, "publisher-first")

    second =
      ready_publication_fixture(context,
        action: :replace,
        target: second_target,
        slug: second_target.slug
      )

    deadline = System.monotonic_time(:millisecond) + 10_000
    assert {:ok, lease} = GitCore.RepositoryWriteLimiter.acquire(second_target.id, deadline)

    publisher =
      Task.async(fn -> ForgeImports.publish_repository(context.actor, second.item.id, %{}) end)

    wait_for_write_waiters(1)

    writer =
      Task.async(fn ->
        ForgeRepos.with_write_fence(second_target, :content, fn _path, _remaining ->
          flunk("stale queued writer reached repository bytes")
        end)
      end)

    wait_for_write_waiters(2)
    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    assert {:ok, %{repository: published}} = Task.await(publisher, 5_000)
    assert {:error, {:unavailable, :stale_repository}} = Task.await(writer, 5_000)
    assert published.id == second.shadow.id
  end

  test "every immutable replacement fingerprint dimension fails closed", context do
    foreign_owner = user_fixture("fingerprint-owner")

    dimensions = [
      :target_id,
      :owner_id,
      :slug,
      :storage_path,
      :lifecycle_deletion,
      :generation,
      :write_version,
      :updated_at,
      :last_pushed_nil_to_value,
      :last_pushed_value_to_nil
    ]

    for dimension <- dimensions do
      slug = "fingerprint-#{dimension}"

      target =
        repository_fixture(context.actor, slug,
          last_pushed_at:
            if(dimension == :last_pushed_value_to_nil,
              do: DateTime.add(@now, 30, :second),
              else: nil
            )
        )

      fixture =
        ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

      drift_replacement!(fixture, dimension, foreign_owner)

      assert {:error, :destination_changed} =
               ForgeImports.publish_repository(context.actor, fixture.item.id, %{}),
             "expected #{dimension} drift to fail closed"

      assert %RepositoryItem{state: :awaiting_resolution, publication_evidence: %{}} =
               Repo.get!(RepositoryItem, fixture.item.id)

      assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
      assert Repo.get!(ImportRun, fixture.run.id).published_count == 0
    end
  end

  test "shadow identity, storage, settings, and collaborator drift after intent fail closed",
       context do
    collaborator = user_fixture("shadow-collaborator")

    mutations = [
      slug: fn fixture ->
        Repo.update_all(
          from(repository in Repository, where: repository.id == ^fixture.shadow.id),
          set: [slug: "changed-shadow-#{fixture.shadow.id}"]
        )
      end,
      storage: fn fixture ->
        Repo.update_all(
          from(repository in Repository, where: repository.id == ^fixture.shadow.id),
          set: [storage_path: "@test/changed-shadow-#{fixture.shadow.id}.git"]
        )
      end,
      write_version: fn fixture ->
        Repo.update_all(
          from(repository in Repository, where: repository.id == ^fixture.shadow.id),
          inc: [write_version: 1]
        )
      end,
      settings: fn fixture ->
        Repo.update_all(
          from(repository in Repository, where: repository.id == ^fixture.shadow.id),
          set: [name: "changed importing shadow", default_branch: "changed"]
        )
      end,
      collaborator: fn fixture ->
        %Collaborator{}
        |> Collaborator.changeset(%{
          repository_id: fixture.shadow.id,
          user_id: collaborator.id,
          role: :read
        })
        |> Repo.insert!()

        {1, nil}
      end
    ]

    for {dimension, mutate} <- mutations do
      fixture = ready_publication_fixture(context, slug: "shadow-drift-#{dimension}")

      assert {:error, :destination_changed} =
               ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
                 fn _capability ->
                   assert match?({1, _rows}, mutate.(fixture))
                   :ok
                 end,
                 fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
               )

      assert %RepositoryItem{state: :awaiting_resolution, publication_evidence: %{}} =
               Repo.get!(RepositoryItem, fixture.item.id)

      assert Repo.get!(ImportRun, fixture.run.id).published_count == 0
    end
  end

  test "namespace drift after durable intent reopens without activating the shadow", context do
    fixture = ready_publication_fixture(context, slug: "namespace-drift")

    assert {:error, :destination_changed} =
             ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
               fn _capability ->
                 assert {1, _rows} =
                          Repo.update_all(
                            from(user in ForgeAccounts.User,
                              where: user.id == ^context.actor.id
                            ),
                            set: [username: "changed-namespace-#{context.actor.id}"]
                          )

                 :ok
               end,
               fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
             )

    assert %RepositoryItem{state: :awaiting_resolution, publication_evidence: %{}} =
             Repo.get!(RepositoryItem, fixture.item.id)

    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
  end

  test "organization authorization drift after intent reopens without live mutation", context do
    suffix = System.unique_integer([:positive])

    assert {:ok, organization} =
             ForgeAccounts.create_organization(context.actor, %{
               username: "publication-org-#{suffix}",
               display_name: "Publication organization"
             })

    fixture = ready_publication_fixture(context, slug: "authorization-drift", owner: organization)

    assert {:error, :destination_changed} =
             ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
               fn _capability ->
                 Repo.get_by!(OrganizationMember,
                   organization_id: organization.id,
                   user_id: context.actor.id
                 )
                 |> Repo.delete!()

                 :ok
               end,
               fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
             )

    assert %RepositoryItem{state: :awaiting_resolution, publication_evidence: %{}} =
             Repo.get!(RepositoryItem, fixture.item.id)

    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
  end

  test "destination resolution derives ready and git-staged successors from durable proof",
       context do
    for {mode, expected_state} <- [complete: :ready_to_publish, incomplete: :git_staged] do
      target = repository_fixture(context.actor, "resume-#{mode}")

      fixture =
        ready_publication_fixture(context,
          action: :replace,
          target: target,
          slug: target.slug
        )

      assert {:error, :destination_changed} =
               ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
                 fn _capability ->
                   assert {1, _rows} =
                            Repo.update_all(
                              from(repository in Repository, where: repository.id == ^target.id),
                              inc: [write_version: 1]
                            )

                   if mode == :incomplete do
                     Repo.get_by!(PageCheckpoint,
                       repository_item_id: fixture.item.id,
                       resource_kind: "comments"
                     )
                     |> Repo.delete!()
                   end

                   :ok
                 end,
                 fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
               )

      successor_slug = "resume-successor-#{mode}"

      assert {:ok, view} =
               ForgeImports.resolve_repository_conflicts(
                 context.actor,
                 fixture.run.id,
                 %{fixture.item.id => %{action: :rename, slug: successor_slug}},
                 request_metadata("resume-#{mode}")
               )

      assert [%{state: ^expected_state, attempt_count: 2}] = view.repositories

      assert [first, successor] =
               ImportAttempt
               |> where([attempt], attempt.repository_item_id == ^fixture.item.id)
               |> order_by([attempt], asc: attempt.attempt_number)
               |> Repo.all()

      assert first.state == :destination_changed
      assert successor.state == :running
      assert successor.decision == %{"action" => "rename", "slug" => successor_slug}
    end
  end

  test "the bounded reconciler orders expired publishing intent before fresh publication",
       context do
    fresh = ready_publication_fixture(context, slug: "fresh-reconciler")
    recovering = ready_publication_fixture(context, slug: "recovering-reconciler")
    _admitted = admit_without_finish!(context.actor, recovering.item)
    make_publication_due!(recovering.item.id)

    assert [recovering.item.id] ==
             Reconciler.runnable_repository_item_ids(1, DateTime.utc_now(:second))

    assert Enum.sort([fresh.item.id, recovering.item.id]) ==
             Reconciler.runnable_repository_item_ids(10, DateTime.utc_now(:second))
             |> Enum.sort()
  end

  test "lease theft blocks the original worker and expired recovery commits exactly once",
       context do
    fixture = ready_publication_fixture(context, slug: "lease-theft")
    stolen_until = DateTime.add(DateTime.utc_now(:second), 60, :second)

    assert {:error, :persistence_unavailable} =
             ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
               fn _capability ->
                 assert {1, _rows} =
                          Repo.update_all(
                            from(item in RepositoryItem, where: item.id == ^fixture.item.id),
                            set: [
                              lease_owner: "stolen-publication",
                              lease_expires_at: stolen_until
                            ]
                          )

                 :ok
               end,
               fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
             )

    assert {:error, :busy} = ForgeImports.RepositoryPublisher.recover(fixture.item.id)
    make_publication_due!(fixture.item.id)

    assert {:ok, %{repository: repository}} =
             ForgeImports.RepositoryPublisher.recover(fixture.item.id)

    assert repository.id == fixture.shadow.id
    assert Repo.get!(ImportRun, fixture.run.id).published_count == 1
    assert Repo.aggregate(AuditEvent, :count, :id) == 1
  end

  test "cancellation before intent wins without admitting publication", context do
    fixture = ready_publication_fixture(context, slug: "cancel-before-intent")
    now = DateTime.utc_now(:second)

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^fixture.run.id),
               set: [state: :cancel_requested, cancellation_requested_at: now],
               inc: [lock_version: 1]
             )

    assert {:error, :cancelled} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert %RepositoryItem{state: :ready_to_publish, publication_evidence: %{}} =
             Repo.get!(RepositoryItem, fixture.item.id)

    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
  end

  test "recovery rejects persisted intents with noncanonical request metadata", context do
    invalid_metadata = [
      %{"extra" => "not-allowlisted"},
      %{"request_id" => "/absolute/private/path"},
      %{"user_agent" => "github_pat_persisted_secret"}
    ]

    for {metadata, index} <- Enum.with_index(invalid_metadata) do
      fixture = ready_publication_fixture(context, slug: "intent-corruption-#{index}")
      admitted = admit_without_finish!(context.actor, fixture.item)
      corrupted = put_in(admitted.publication_evidence, ["request_metadata"], metadata)

      assert {1, _rows} =
               Repo.update_all(
                 from(item in RepositoryItem, where: item.id == ^fixture.item.id),
                 set: [publication_evidence: corrupted]
               )

      make_publication_due!(fixture.item.id)

      assert {:error, :publication_inconsistent} =
               ForgeImports.RepositoryPublisher.recover(fixture.item.id)

      assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
    end
  end

  test "replay rejects committed evidence with noncanonical request metadata", context do
    fixture = ready_publication_fixture(context, slug: "replay-metadata-corruption")
    assert {:ok, _result} = ForgeImports.publish_repository(context.actor, fixture.item.id, %{})
    committed = Repo.get!(RepositoryItem, fixture.item.id)

    corrupted =
      put_in(committed.publication_evidence, ["request_metadata"], %{
        "request_id" => "/private/replay/path"
      })

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [publication_evidence: corrupted]
             )

    assert {:error, :publication_inconsistent} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})
  end

  test "different-action audit collision rolls back and corrupts replay", context do
    rollback = ready_publication_fixture(context, slug: "cross-action-rollback")
    operation_id = "github-import-publication-#{rollback.item.id}-1"

    audit_fixture(context.actor, operation_id, "repository.unrelated", rollback.shadow.id)

    assert {:error, :persistence_unavailable} =
             ForgeImports.publish_repository(context.actor, rollback.item.id, %{})

    assert Repo.get!(Repository, rollback.shadow.id).lifecycle == :importing
    assert Repo.get!(ImportRun, rollback.run.id).published_count == 0

    replay = ready_publication_fixture(context, slug: "cross-action-replay")

    assert {:ok, %{repository: repository}} =
             ForgeImports.publish_repository(context.actor, replay.item.id, %{})

    evidence = Repo.get!(RepositoryItem, replay.item.id).publication_evidence
    audit_fixture(context.actor, evidence["operation_id"], "repository.corrupt", repository.id)

    assert {:error, :publication_inconsistent} =
             ForgeImports.publish_repository(context.actor, replay.item.id, %{})
  end

  test "replacement fence durably reconciles persisted Git writes and pull merges before drift",
       context do
    target = repository_fixture(context.actor, "durable-fence")
    path = ForgeRepos.absolute_storage_path(target)
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, ^path} = GitCore.init_bare(path)
    %{base: base_oid, head: head_oid, merge: merge_oid} = create_merge_graph!(path)

    assert {:ok, pull} =
             ForgePulls.create_pull_request(
               target,
               context.actor,
               %{title: "Pending import merge", head: "feature", base: "main"},
               %{"request_id" => "publication-pending-pull"}
             )

    merge_operation =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: pull.id,
        repository_id: target.id,
        actor_user_id: context.actor.id,
        request_id: "publication-pending-merge",
        api_version: "2026-03-10",
        ip_address: "203.0.113.82",
        user_agent: "publication-fence-test",
        token_id: "test-token",
        base_ref: pull.base_ref,
        head_ref: pull.head_ref,
        expected_base_oid: base_oid,
        expected_head_oid: head_oid,
        state: :prepared
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(state: :merge_written, merge_oid: merge_oid)
      |> Repo.update!()
      |> Ecto.Changeset.change(state: :ref_advanced)
      |> Repo.update!()

    update_ref!(path, merge_oid, pull.base_ref)
    pending_ref = "refs/heads/pending-import-write"
    update_ref!(path, merge_oid, pending_ref)

    git_operation =
      %GitWriteOperation{}
      |> GitWriteOperation.changeset(%{
        repository_id: target.id,
        actor_user_id: context.actor.id,
        request_id: "publication-pending-write",
        kind: :ref_create,
        state: :ref_advanced,
        target_ref: pending_ref,
        expected_oid: nil,
        proposed_oid: merge_oid,
        lock_version: 0
      })
      |> Repo.insert!()

    fixture =
      ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

    assert {:error, :destination_changed} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert Repo.get!(GitWriteOperation, git_operation.id).state == :bookkeeping_complete
    assert Repo.get!(MergeOperation, merge_operation.id).state == :completed
    assert %PullRequest{merge_commit_sha: ^merge_oid} = Repo.get!(PullRequest, pull.id)
    assert Repo.get!(Repository, target.id).write_version == 2
    assert Repo.get_by!(AuditEvent, operation_id: "git_write:#{git_operation.id}")
    assert Repo.get_by!(AuditEvent, operation_id: "pull_merge:#{merge_operation.id}")
    assert Repo.get!(RepositoryItem, fixture.item.id).state == :awaiting_resolution
    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
  end

  test "fresh direct publication respects a future due time without writing intent", context do
    fixture = ready_publication_fixture(context, slug: "future-due")
    due_at = DateTime.add(DateTime.utc_now(:second), 60, :second)

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [next_attempt_at: due_at]
             )

    assert {:error, :busy} =
             ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

    assert %RepositoryItem{state: :ready_to_publish, publication_evidence: %{}} =
             Repo.get!(RepositoryItem, fixture.item.id)
  end

  test "public publishing under every terminal run is inconsistent rather than busy", context do
    for state <- [:completed, :completed_with_warnings, :canceled, :failed] do
      fixture = ready_publication_fixture(context, slug: "terminal-public-#{state}")
      _admitted = admit_without_finish!(context.actor, fixture.item)
      terminal_run!(fixture.run, state)

      assert {:error, :publication_inconsistent} =
               ForgeImports.publish_repository(context.actor, fixture.item.id, %{})

      assert Repo.get!(RepositoryItem, fixture.item.id).state == :publishing
    end
  end

  test "successor proof rejects noncanonical shadows and terminal-only partial evidence",
       context do
    for {field, value} <- [
          name: "changed shadow name",
          description: "unexpected",
          visibility: :public,
          default_branch: "changed",
          has_issues: false,
          allow_merge_commit: false,
          last_pushed_at: @now,
          storage_reclaimed_at: @now
        ] do
      target = repository_fixture(context.actor, "proof-#{field}")

      fixture =
        ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

      reopen_with_drift!(context.actor, fixture, fn ->
        Repo.update_all(
          from(repository in Repository, where: repository.id == ^fixture.shadow.id),
          set: [{field, value}]
        )
      end)

      assert {:error, :stale} =
               ForgeImports.resolve_repository_conflicts(
                 context.actor,
                 fixture.run.id,
                 %{fixture.item.id => %{action: :rename, slug: "proof-fixed-#{field}"}},
                 request_metadata("proof-#{field}")
               )
    end

    target = repository_fixture(context.actor, "terminal-only-proof")

    fixture =
      ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

    reopen_with_drift!(context.actor, fixture, fn -> {1, nil} end)

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [
                 hidden_repository_id: nil,
                 staged_storage_path: nil,
                 source_git: %{},
                 checkpoint: %{}
               ]
             )

    assert {:error, :stale} =
             ForgeImports.resolve_repository_conflicts(
               context.actor,
               fixture.run.id,
               %{fixture.item.id => %{action: :rename, slug: "terminal-only-fixed"}},
               request_metadata("terminal-only")
             )
  end

  test "admission due clock is sampled after blocking capability locks", context do
    fixture = ready_publication_fixture(context, slug: "post-lock-clock")
    due_at = DateTime.add(DateTime.utc_now(:second), 1, :second)

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [next_attempt_at: due_at]
             )

    assert {:ok, %{repository: repository}} =
             ForgeImports.RepositoryPublisher.with_test_after_admission_locks_hook(
               fn -> Process.sleep(2_000) end,
               fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end
             )

    assert repository.id == fixture.shadow.id
  end

  test "final item CAS rejects a lease that expires while replacement waits on its fence",
       context do
    target = repository_fixture(context.actor, "fence-expiry")

    fixture =
      ready_publication_fixture(context, action: :replace, target: target, slug: target.slug)

    deadline = System.monotonic_time(:millisecond) + 10_000
    assert {:ok, lease} = GitCore.RepositoryWriteLimiter.acquire(target.id, deadline)

    publisher =
      Task.async(fn -> ForgeImports.publish_repository(context.actor, fixture.item.id, %{}) end)

    wait_for_write_waiters(1)
    expires_at = DateTime.add(DateTime.utc_now(:second), 1, :second)

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [lease_expires_at: expires_at]
             )

    Process.sleep(2_000)
    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    assert {:error, :persistence_unavailable} = Task.await(publisher, 5_000)
    assert Repo.get!(Repository, target.id).lifecycle == :ready
    assert Repo.get!(Repository, fixture.shadow.id).lifecycle == :importing
    assert Repo.get!(ImportRun, fixture.run.id).published_count == 0
  end

  test "reconciler orders publishing then all never-attempted work then oldest due", context do
    queued = ready_publication_fixture(context, slug: "order-queued")
    make_unstaged_queued!(queued)
    fresh = ready_publication_fixture(context, slug: "order-fresh")
    newer_retry = ready_publication_fixture(context, slug: "order-newer-retry")
    older_retry = ready_publication_fixture(context, slug: "order-older-retry")
    cleanup = ready_publication_fixture(context, slug: "order-cleanup")
    publishing = ready_publication_fixture(context, slug: "order-publishing")
    _admitted = admit_without_finish!(context.actor, publishing.item)
    now = DateTime.utc_now(:second)
    make_publication_due!(publishing.item.id)
    make_staging_retry!(newer_retry.item.id, DateTime.add(now, -10, :second))
    make_staging_retry!(older_retry.item.id, DateTime.add(now, -20, :second))
    make_cleanup_pending!(cleanup.item.id, now)

    assert [
             publishing.item.id,
             queued.item.id,
             fresh.item.id,
             older_retry.item.id,
             newer_retry.item.id
           ] == Reconciler.runnable_repository_item_ids(10, now)

    refute cleanup.item.id in Reconciler.runnable_repository_item_ids(10, now)
  end

  defp ready_publication_fixture(context, opts \\ []) do
    owner = Keyword.get(opts, :owner, context.actor)
    run = running_run_fixture(context.actor, context.identity, owner)
    action = Keyword.get(opts, :action, :create)
    target = Keyword.get(opts, :target)
    slug = Keyword.get(opts, :slug, "demo")

    item =
      %{
        import_run_id: run.id,
        github_repository_id: 9_950_000_000 + System.unique_integer([:positive]),
        source_full_name: "acme/#{slug}",
        source_name: "Demo source",
        source_metadata: %{
          "default_branch" => "trunk",
          "visibility" => "public",
          "description" => "Imported description",
          "has_issues" => false,
          "allow_merge_commit" => false,
          "fork" => false,
          "archived" => false
        },
        source_observed_at: @now,
        selected: true,
        destination_owner_id: owner.id,
        destination_slug: slug,
        destination_visibility: :public,
        conflict_action: if(action == :replace, do: :replace),
        replacement_repository_id: target && target.id,
        replacement_owner_id: target && target.owner_user_id,
        replacement_storage_path: target && target.storage_path,
        replacement_generation: target && target.generation,
        replacement_write_version: target && target.write_version,
        replacement_updated_at: target && target.updated_at,
        replacement_last_pushed_at: target && target.last_pushed_at,
        state: :queued,
        attempt_count: 1
      }
      |> Persistence.insert_repository_item()
      |> unwrap!()

    generation = if target, do: target.generation + 1, else: 1

    {:ok, %{shadow: shadow}} =
      Multi.new()
      |> ForgeRepos.create_import_shadow(:shadow, owner.id, %{
        item_id: item.id,
        generation: generation
      })
      |> Repo.transaction()

    staged_path = ForgeRepos.absolute_storage_path(shadow)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :ready_to_publish,
                 hidden_repository_id: shadow.id,
                 staged_storage_path: staged_path,
                 source_git: %{
                   "empty" => false,
                   "default_branch" => "trunk",
                   "refs" => 3,
                   "bytes" => 512,
                   "lfs_detected" => false,
                   "submodules_detected" => false,
                   "scan_truncated" => false
                 },
                 checkpoint: %{
                   "git_staged" => true,
                   "unsupported_scan" => "complete"
                 }
               ]
             )

    item = Repo.get!(RepositoryItem, item.id)
    attempt = attempt_fixture(item, action, target)
    Enum.each(@terminal_resources, &terminal_fixture(item, &1))
    %{run: run, item: item, attempt: attempt, shadow: shadow, target: target}
  end

  defp running_run_fixture(actor, identity, owner) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_950_000_001,
        source_owner_login: "acme",
        source_repository_github_id: 9_950_000_001,
        source_repository_full_name: "acme/demo",
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

  defp attempt_fixture(item, :replace, target) do
    decision = %{
      "action" => "replace",
      "slug" => item.destination_slug,
      "replacement_repository_id" => target.id,
      "replacement_owner_id" => target.owner_user_id,
      "replacement_storage_path" => target.storage_path,
      "replacement_generation" => target.generation,
      "replacement_write_version" => target.write_version,
      "replacement_updated_at" => target.updated_at,
      "replacement_last_pushed_at" => target.last_pushed_at
    }

    insert_attempt(item, decision)
  end

  defp attempt_fixture(item, action, _target) when action in [:create, :rename] do
    insert_attempt(item, %{"action" => Atom.to_string(action), "slug" => item.destination_slug})
  end

  defp insert_attempt(item, decision) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: decision,
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp terminal_fixture(item, resource, opts \\ []) do
    %PageCheckpoint{}
    |> PageCheckpoint.create_changeset(%{
      repository_item_id: item.id,
      resource_kind: resource,
      page_key: Keyword.get(opts, :page_key, "__terminal_v1__"),
      item_count: 0,
      cursor_metadata: %{},
      committed_at: @now
    })
    |> Repo.insert!()
  end

  defp repository_fixture(owner, slug, opts \\ []) do
    suffix = System.unique_integer([:positive])

    %Repository{
      owner_user_id: owner.id,
      storage_path: "@test/#{slug}-#{suffix}.git",
      generation: Keyword.get(opts, :generation, 1),
      last_pushed_at: Keyword.get(opts, :last_pushed_at)
    }
    |> Repository.create_changeset(%{
      slug: slug,
      name: slug,
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true
    })
    |> Ecto.Changeset.put_change(:generation, Keyword.get(opts, :generation, 1))
    |> Repo.insert!()
  end

  defp drift_replacement!(fixture, :target_id, _foreign_owner) do
    decision =
      fixture.attempt.decision
      |> Map.put("replacement_repository_id", fixture.target.id + 9_000_000_000)

    assert {1, _rows} =
             Repo.update_all(
               from(attempt in ImportAttempt, where: attempt.id == ^fixture.attempt.id),
               set: [decision: decision]
             )
  end

  defp drift_replacement!(fixture, dimension, foreign_owner) do
    changes =
      case dimension do
        :owner_id -> [owner_user_id: foreign_owner.id]
        :slug -> [slug: "changed-#{fixture.target.id}"]
        :storage_path -> [storage_path: "@test/changed-#{fixture.target.id}.git"]
        :lifecycle_deletion -> [lifecycle: :tombstoned, deleted_at: @now]
        :generation -> [generation: fixture.target.generation + 1]
        :write_version -> [write_version: fixture.target.write_version + 1]
        :updated_at -> [updated_at: DateTime.add(fixture.target.updated_at, 1, :second)]
        :last_pushed_nil_to_value -> [last_pushed_at: @now]
        :last_pushed_value_to_nil -> [last_pushed_at: nil]
      end

    assert {1, _rows} =
             Repo.update_all(
               from(repository in Repository, where: repository.id == ^fixture.target.id),
               set: changes
             )
  end

  defp create_merge_graph!(path) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    merge = git!(path, ["commit-tree", tree, "-p", base, "-p", head, "-m", "merge"])
    update_ref!(path, base, "refs/heads/main")
    update_ref!(path, head, "refs/heads/feature")
    %{base: base, head: head, merge: merge}
  end

  defp update_ref!(path, oid, ref), do: git!(path, ["update-ref", ref, oid])

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Publication Test"},
      {"GIT_AUTHOR_EMAIL", "publication@example.test"},
      {"GIT_COMMITTER_NAME", "Publication Test"},
      {"GIT_COMMITTER_EMAIL", "publication@example.test"}
    ]

    {output, 0} = System.cmd("git", ["--git-dir", path | args], env: env, stderr_to_stdout: true)
    String.trim(output)
  end

  defp user_fixture(prefix) do
    suffix = System.unique_integer([:positive])

    ForgeAccounts.create_user(%{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.test",
      password: "correct horse battery staple"
    })
    |> unwrap!()
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_960_000_000 + suffix,
          login: "publisher-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    ForgeAccounts.link_github_identity(actor, identity) |> unwrap!()
  end

  defp request_metadata(prefix) do
    %{
      "request_id" => "#{prefix}-request",
      "operation_id" => "caller-controlled-#{prefix}",
      "ip_address" => "203.0.113.81",
      "user_agent" => "forge-import-publication-test"
    }
  end

  defp make_publication_due!(item_id) do
    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^item_id),
               set: [
                 lease_owner: nil,
                 lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second),
                 next_attempt_at: nil
               ]
             )
  end

  defp make_unstaged_queued!(fixture) do
    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^fixture.item.id),
               set: [
                 state: :queued,
                 hidden_repository_id: nil,
                 staged_storage_path: nil,
                 source_git: %{},
                 checkpoint: %{},
                 next_attempt_at: nil
               ]
             )

    PageCheckpoint
    |> where([checkpoint], checkpoint.repository_item_id == ^fixture.item.id)
    |> Repo.all()
    |> Enum.each(&Repo.delete!/1)

    Repo.delete!(fixture.shadow)
    :ok
  end

  defp make_staging_retry!(item_id, due_at) do
    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^item_id),
               set: [state: :staging_git, next_attempt_at: due_at]
             )
  end

  defp make_cleanup_pending!(item_id, now) do
    cleanup_identity = %{
      "mode" => 0o700,
      "major_device" => 1,
      "minor_device" => 1,
      "inode" => item_id
    }

    item = Repo.get!(RepositoryItem, item_id)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item_id),
               set: [
                 state: :staging_git,
                 next_attempt_at: nil,
                 cleanup_state: "cleanup_pending",
                 cleanup_eligible_at: now,
                 cleanup_error: "publication_test",
                 checkpoint: Map.put(item.checkpoint, "cleanup_identity", cleanup_identity)
               ]
             )
  end

  defp audit_fixture(actor, operation_id, action, target_id) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor_user_id: actor.id,
      action: action,
      target_type: "repository",
      target_id: Integer.to_string(target_id),
      operation_id: operation_id,
      metadata: %{"corrupt" => true}
    })
    |> Repo.insert!()
  end

  defp terminal_run!(run, state) do
    now = DateTime.utc_now(:second)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in ImportRun, where: candidate.id == ^run.id),
               set: [
                 state: state,
                 terminal_at: now,
                 lease_owner: nil,
                 lease_expires_at: nil,
                 credential_ciphertext: nil,
                 credential_nonce: nil,
                 credential_tag: nil,
                 credential_key_id: nil
               ],
               inc: [lock_version: 1]
             )
  end

  defp reopen_with_drift!(actor, fixture, mutate) do
    assert {:error, :destination_changed} =
             ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
               fn _capability ->
                 assert {1, _rows} =
                          Repo.update_all(
                            from(repository in Repository,
                              where: repository.id == ^fixture.target.id
                            ),
                            inc: [write_version: 1]
                          )

                 assert match?({1, _rows}, mutate.())
                 :ok
               end,
               fn -> ForgeImports.publish_repository(actor, fixture.item.id, %{}) end
             )

    assert Repo.get!(RepositoryItem, fixture.item.id).state == :awaiting_resolution
  end

  defp admit_without_finish!(actor, item) do
    parent = self()

    {_pid, monitor} =
      spawn_monitor(fn ->
        ForgeImports.RepositoryPublisher.with_test_after_admission_hook(
          fn _capability ->
            send(parent, :admitted)
            exit(:response_lost)
          end,
          fn -> ForgeImports.publish_repository(actor, item.id, %{}) end
        )
      end)

    assert_receive :admitted, 1_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :response_lost}, 1_000
    Repo.get!(RepositoryItem, item.id)
  end

  defp snapshot_counts do
    %{
      repositories: Repo.aggregate(Repository, :count),
      items: Repo.aggregate(RepositoryItem, :count),
      attempts: Repo.aggregate(ImportAttempt, :count),
      audits: Repo.aggregate(AuditEvent, :count)
    }
  end

  defp wait_for_write_waiters(expected, attempts \\ 200)

  defp wait_for_write_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(GitCore.RepositoryWriteLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_write_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_write_waiters(expected, 0),
    do: flunk("expected #{expected} queued repository writers")

  defp unwrap!({:ok, value}), do: value

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
