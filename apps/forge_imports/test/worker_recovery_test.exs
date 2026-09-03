defmodule ForgeImports.WorkerRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, Recovery, RepositoryItem, Worker}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @now ~U[2026-08-25 10:00:00Z]
  @pat "github_pat_worker_recovery_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<6>>, 32)}}

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      ForgeImports.RecoveryTestHelper.mark_sandbox_owner!()
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    run = running_run_fixture(actor, identity)
    item = queued_item_fixture(run, actor)
    attempt_fixture(item)

    %{actor: actor, identity: identity, run: run, item: item}
  end

  test "classify replays durable git evidence without directory existence alone", context do
    item = git_staged_item!(context.item, context.actor)

    facts = Recovery.gather_durable_facts(item)

    assert {:ok, :git_staged} = Recovery.classify(item, facts)

    queued_facts = %{
      proof: {:ok, :queued},
      publication_evidence?: false,
      terminal_report?: false,
      credential_cleared?: true
    }

    queued_item = %{
      item
      | state: :queued,
        hidden_repository_id: nil,
        staged_storage_path: nil,
        checkpoint: %{},
        source_git: %{}
    }

    assert {:ok, :queued} = Recovery.classify(queued_item, queued_facts)
  end

  test "reconcile releases an expired lease and preserves checkpointed phase", context do
    item = git_staged_item!(context.item, context.actor)

    expired_at = DateTime.add(@now, -30, :second)

    assert {1, _} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [lease_owner: "dead-worker", lease_expires_at: expired_at]
             )

    assert {:ok, recovered} = Recovery.reconcile(Repo.get!(RepositoryItem, item.id), now: @now)
    assert recovered.state == :git_staged
    assert recovered.checkpoint["git_staged"] == true
    assert is_nil(recovered.lease_owner)
    assert is_nil(recovered.lease_expires_at)
  end

  test "worker run ignores fake published return values", context do
    item = git_staged_item!(context.item, context.actor)

    assert {:ok, _fake} =
             Worker.run(item.id, "github-import-test-owner",
               repository_worker: __MODULE__.FakePublishedWorker
             )

    assert %RepositoryItem{state: :git_staged} = Repo.get!(RepositoryItem, item.id)
  end

  test "scheduler excludes future retry windows", context do
    item = git_staged_item!(context.item, context.actor)

    retry_at = DateTime.add(@now, 60, :second)

    assert {:ok, waiting} =
             Persistence.update_without_lease(
               item,
               [:git_staged],
               RepositoryItem.lease_update_changeset(item,
                 next_attempt_at: retry_at,
                 wait_reason: "rate_limit"
               ),
               @now
             )

    refute ForgeImports.Scheduler.claimable?(waiting, @now)
    assert ForgeImports.Scheduler.claimable?(waiting, retry_at)
  end

  defmodule FakePublishedWorker do
    def stage(item_id, _opts), do: {:ok, %RepositoryItem{id: item_id, state: :published}}
  end

  defp git_staged_item!(item, actor) do
    shadow = importing_shadow_fixture!(actor, item)
    staged_storage_path = ForgeRepos.absolute_storage_path(shadow)

    assert {1, _} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^item.id),
               set: [
                 state: :git_staged,
                 hidden_repository_id: shadow.id,
                 staged_storage_path: staged_storage_path,
                 checkpoint: %{"git_staged" => true, "unsupported_scan" => "complete"},
                 source_git: %{
                   "empty" => false,
                   "default_branch" => "main",
                   "refs" => 1,
                   "bytes" => 10,
                   "lfs_detected" => false,
                   "submodules_detected" => false,
                   "scan_truncated" => false
                 },
                 updated_at: @now
               ]
             )

    Repo.get!(RepositoryItem, item.id)
  end

  defp importing_shadow_fixture!(actor, item) do
    %Repository{}
    |> Repository.import_changeset(%{
      owner_user_id: actor.id,
      slug: "shadow-#{item.id}-#{System.unique_integer([:positive])}",
      name: "Shadow #{item.id}",
      visibility: :private,
      storage_path: "@test/shadow-#{item.id}.git",
      lifecycle: :importing,
      generation: 1
    })
    |> Repo.insert!()
  end

  defp running_run_fixture(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_800_000_103,
        source_owner_login: "acme",
        source_repository_github_id: 9_800_000_103,
        source_repository_full_name: "acme/demo",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: request_metadata()
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

  defp queued_item_fixture(run, actor) do
    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: 9_200_000_020,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: "demo",
      destination_visibility: :private,
      state: :queued,
      attempt_count: 1
    })
    |> unwrap!()
  end

  defp attempt_fixture(item) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: @now
    })
    |> Repo.insert!()

    item
  end

  defp identity_fixture(actor) do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 81_003,
          login: "worker-recovery-actor",
          avatar_url: nil,
          profile_url: "https://github.com/worker-recovery-actor"
        },
        @now
      )

    {:ok, linked} = ForgeAccounts.link_github_identity(actor, identity)
    linked
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      username: "worker-recovery-#{suffix}",
      email: "worker-recovery-#{suffix}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, %Ecto.Changeset{} = changeset}) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

  defp request_metadata do
    %{
      "request_id" => "worker-recovery-#{System.unique_integer([:positive])}",
      "operation_id" => "worker-recovery-operation-#{System.unique_integer([:positive])}",
      "ip_address" => "203.0.113.90",
      "user_agent" => "forge-imports-test"
    }
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp reset_database! do
    Fornacast.DataCase.reset_database!()
  rescue
    UndefinedFunctionError -> :ok
  end
end
