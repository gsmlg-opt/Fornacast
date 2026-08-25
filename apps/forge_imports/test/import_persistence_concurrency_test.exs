defmodule ForgeImports.ImportPersistenceConcurrencyTest do
  use ExUnit.Case, async: false

  alias ForgeImports.{ImportRun, RepositoryItem}
  alias Fornacast.{OperationLease, Repo}

  @moduletag :persistence
  @now ~U[2026-08-26 00:00:00Z]
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<7>>, 32)}}

  setup do
    database_run(&reset_database!/0)
    on_exit(fn -> database_run(&reset_database!/0) end)

    {actor, identity, run} = database_run(&fixture/0)
    %{actor: actor, identity: identity, run: run}
  end

  test "terminal and nonterminal transitions from one version cannot overwrite each other", %{
    actor: actor,
    run: run
  } do
    results =
      race([
        fn -> ForgeImports.transition_run(actor, run, :failed, %{terminal_at: @now}) end,
        fn -> ForgeImports.transition_run(actor, run, :awaiting_credential) end
      ])

    assert Enum.count(results, &match?({:ok, %ImportRun{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale})) == 1

    final = database_run(fn -> Repo.get!(ImportRun, run.id) end)
    assert final.lock_version == run.lock_version + 1

    if final.state == :failed do
      assert final.credential_ciphertext == nil
      assert final.credential_nonce == nil
      assert final.credential_tag == nil
      assert final.credential_key_id == nil
    else
      assert final.state == :awaiting_credential
    end
  end

  test "terminal transition and one-time attachment cannot create a terminal credential", %{
    actor: actor,
    identity: identity,
    run: run
  } do
    envelope =
      database_run(fn ->
        {:ok, envelope} =
          ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
            run.id,
            actor.id,
            identity.github_user_id,
            "github_pat_secret",
            @keyring
          )

        envelope
      end)

    results =
      race([
        fn -> ForgeImports.transition_run(actor, run, :failed, %{terminal_at: @now}) end,
        fn -> ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) end
      ])

    assert Enum.count(results, &match?({:ok, %ImportRun{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale})) == 1

    final = database_run(fn -> Repo.get!(ImportRun, run.id) end)
    assert final.lock_version == run.lock_version + 1

    case final.state do
      :failed ->
        assert final.credential_ciphertext == nil
        assert final.credential_nonce == nil
        assert final.credential_tag == nil
        assert final.credential_key_id == nil

      :running ->
        assert final.credential_ciphertext == envelope.ciphertext
        assert final.credential_nonce == envelope.nonce
        assert final.credential_tag == envelope.tag
        assert final.credential_key_id == envelope.key_id
    end
  end

  test "selection racing a lease claim preserves both version protocols", %{
    actor: actor,
    identity: identity
  } do
    {run, item} = database_run(fn -> selection_fixture(actor, identity, 9_600_000_001) end)

    parent = self()

    claim_task =
      Task.async(fn ->
        database_run(fn ->
          OperationLease.with_test_after_write_hook(
            fn :claim, RepositoryItem, _id, _version ->
              send(parent, {:claim_written, self()})
              receive do: (:release_claim -> :ok)
            end,
            fn -> OperationLease.claim(RepositoryItem, item.id, "worker-a", @now, 60) end
          )
        end)
      end)

    assert_receive {:claim_written, claim_pid}, 5_000

    selection_task =
      Task.async(fn ->
        database_run(fn -> ForgeImports.select_repository_item(actor, run, item, false) end)
      end)

    early_selection = Task.yield(selection_task, 50)

    assert is_nil(early_selection) or
             match?({:ok, {:error, reason}} when reason in [:busy, :stale], early_selection)

    send(claim_pid, :release_claim)
    assert {:ok, %RepositoryItem{lease_owner: "worker-a"}} = Task.await(claim_task, 5_000)

    selection_result =
      case early_selection do
        nil -> Task.await(selection_task, 5_000)
        {:ok, result} -> result
      end

    assert {:error, reason} = selection_result
    assert reason in [:busy, :stale]

    final = database_run(fn -> Repo.get!(RepositoryItem, item.id) end)
    final_run = database_run(fn -> Repo.get!(ImportRun, run.id) end)
    assert final.lease_owner == "worker-a"
    assert final.selected
    assert final.lock_version == item.lock_version + 1
    assert final.lease_expires_at == DateTime.add(@now, 60, :second)
    assert final_run.selected_count == 1
    assert final_run.lock_version == run.lock_version
  end

  test "run transition racing selection freezes one coherent plan", %{
    actor: actor,
    identity: identity
  } do
    {run, item} = database_run(fn -> selection_fixture(actor, identity, 9_610_000_001) end)

    [transition_result, selection_result] =
      race([
        fn -> ForgeImports.transition_run(actor, run, :ready) end,
        fn -> ForgeImports.select_repository_item(actor, run, item, false) end
      ])

    final_run = database_run(fn -> Repo.get!(ImportRun, run.id) end)
    final_item = database_run(fn -> Repo.get!(RepositoryItem, item.id) end)

    case {transition_result, selection_result} do
      {{:ok, %ImportRun{state: :ready}}, {:error, :stale}} ->
        assert final_run.state == :ready
        assert final_run.selected_count == 1
        assert final_item.selected

      {{:error, :stale},
       {:ok, %{run: %ImportRun{state: :awaiting_resolution}, item: selected_item}}} ->
        assert final_run.state == :awaiting_resolution
        assert final_run.selected_count == 0
        refute selected_item.selected
        refute final_item.selected
    end
  end

  defp race(callbacks) do
    parent = self()

    tasks =
      Enum.map(callbacks, fn callback ->
        Task.async(fn ->
          database_run(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> callback.())
          end)
        end)
      end)

    task_pids = Enum.map(tasks, & &1.pid)

    for pid <- task_pids do
      assert_receive {:ready, ^pid}, 5_000
    end

    Enum.each(task_pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp fixture do
    actor = user_fixture()
    identity = identity_fixture(actor)

    {:ok, discovering} = ForgeImports.create_run(actor, run_attrs(identity))

    {:ok, awaiting_resolution} =
      ForgeImports.transition_run(actor, discovering, :awaiting_resolution)

    {:ok, ready} = ForgeImports.transition_run(actor, awaiting_resolution, :ready)
    {:ok, running} = ForgeImports.transition_run(actor, ready, :running)
    {actor, identity, running}
  end

  defp selection_fixture(actor, identity, github_repository_id) do
    {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity))

    {:ok, item} =
      ForgeImports.create_repository_item(actor, run, %{
        github_repository_id: github_repository_id,
        source_full_name: "acme/demo",
        source_name: "demo",
        source_metadata: %{},
        source_observed_at: @now
      })

    {:ok, run} = ForgeImports.transition_run(actor, run, :awaiting_resolution)
    {run, item}
  end

  defp run_attrs(identity) do
    %{
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: identity.github_user_id,
      source_owner_login: identity.login,
      request_metadata: %{}
    }
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_700_000_000 + suffix,
          login: "concurrency-#{suffix}",
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
        username: "concurrency-user-#{suffix}",
        email: "concurrency-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp database_run(callback) do
    if postgres?(), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, callback), else: callback.()
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
