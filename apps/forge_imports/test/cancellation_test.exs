defmodule ForgeImports.CancellationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, User}

  alias ForgeImports.{
    Cancellation,
    CleanupReconciler,
    ImportAttempt,
    ImportRun,
    Persistence,
    Scheduler,
    Worker
  }

  alias ForgeImports.RepositoryItem
  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-25 12:00:00Z]
  @pat "github_pat_cancellation_test_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<11>>, 32)}}

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
    credential = saved_credential_fixture!(actor, identity)
    run = running_run!(actor, %{identity_id: identity.id}, credential)
    item = queued_item!(run, actor)
    attempt_fixture(item)

    %{
      actor: actor,
      identity: identity,
      view: %{identity_id: identity.id},
      credential: credential,
      run: run,
      item: item
    }
  end

  test "request_cancel persists run intent, item intents, and a sanitized audit", %{
    actor: actor,
    run: run,
    item: item
  } do
    metadata = request_metadata()

    assert {:ok, requested} =
             ForgeImports.request_cancel(actor, run.id, metadata, now: @now)

    assert requested.state == :cancel_requested
    assert requested.cancellation_requested_at == @now

    reloaded_item = Repo.get!(RepositoryItem, item.id)
    assert reloaded_item.state == :cancel_requested
    assert is_nil(reloaded_item.lease_owner)
    assert is_nil(reloaded_item.lease_expires_at)

    audit =
      Repo.one!(
        from event in AuditEvent,
          where:
            event.action == "github_import.cancel_requested" and
              event.target_id == ^to_string(run.id),
          order_by: [desc: event.id],
          limit: 1
      )

    assert audit.target_type == "github_import_run"
    assert audit.target_id == to_string(run.id)
    refute inspect(audit) =~ "github_pat_"
    refute inspect(audit.metadata) =~ "github_pat_"
  end

  test "Cancellation.request refuses foreign runs", %{run: run} do
    other = user_fixture()

    assert {:error, :not_found} =
             ForgeImports.request_cancel(other, run.id, request_metadata("foreign-cancel"))
  end

  test "scheduler stops queued work after cancellation is requested", %{
    actor: actor,
    run: run,
    item: item
  } do
    assert {:ok, _} =
             Cancellation.request(actor, run, request_metadata("stop-queued"), now: @now)

    refute item.id in Scheduler.claimable_item_ids(@now, 100)
  end

  test "Cancellation.check observes durable intent without interrupting publishing", %{
    run: run,
    actor: actor
  } do
    publishing = publishing_item!(run, actor)
    ready = ready_item!(run, actor, 9_200_000_301)

    assert {1, _} =
             Repo.update_all(
               from(candidate in ImportRun, where: candidate.id == ^run.id),
               set: [state: :cancel_requested, cancellation_requested_at: @now]
             )

    refute Cancellation.check(publishing)
    assert Cancellation.check(ready)
  end

  test "ready-to-publish items honor cancellation before fresh publication", %{
    actor: actor,
    run: run
  } do
    item = ready_item!(run, actor, 9_200_000_302)
    attempt_fixture(item)

    assert {:ok, _} =
             Cancellation.request(actor, run, request_metadata("ready-cancel"), now: @now)

    assert {:error, :cancelled} =
             ForgeImports.publish_repository(
               actor,
               item.id,
               request_metadata("publish-after-cancel")
             )

    assert Repo.get!(RepositoryItem, item.id).state == :cancel_requested
  end

  test "restart after cancellation intent keeps durable cancel_requested state", %{
    actor: actor,
    run: run,
    item: item
  } do
    assert {:ok, _} =
             Cancellation.request(actor, run, request_metadata("restart-cancel"), now: @now)

    restarted_run = Repo.get!(ImportRun, run.id)
    restarted_item = Repo.get!(RepositoryItem, item.id)

    assert restarted_run.state == :cancel_requested
    assert restarted_item.state == :cancel_requested
    assert Cancellation.check(restarted_item)
    refute Scheduler.claimable?(restarted_item, @now)
  end

  test "discovering runs terminalize immediately without cancel_requested", %{
    actor: actor,
    identity: identity
  } do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 9_000_000_301,
        source_owner_login: "acme",
        source_repository_github_id: 9_200_000_301,
        source_repository_full_name: "acme/discovering",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :discovering,
        request_metadata: request_metadata("discovering-cancel")
      }
      |> Persistence.insert_run()
      |> unwrap!()

    assert {:ok, canceled} =
             Cancellation.request(actor, run, request_metadata("discovering-cancel"), now: @now)

    assert canceled.state == :canceled
    assert canceled.credential_ciphertext == nil
    assert %DateTime{} = canceled.terminal_at
    refute Scheduler.claimable?(canceled, @now)
  end

  test "Worker ignores discovery once cancellation intent is durable", %{
    actor: actor,
    identity: identity
  } do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 9_000_000_301,
        source_owner_login: "acme",
        source_repository_github_id: 9_200_000_301,
        source_repository_full_name: "acme/discovering",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :discovering,
        request_metadata: request_metadata("discovery-worker-cancel")
      }
      |> Persistence.insert_run()
      |> unwrap!()

    assert {:ok, _} =
             Cancellation.request(actor, run, request_metadata("discovery-worker-cancel"),
               now: @now
             )

    assert {:ok, :ignored} = Worker.run_discovery(run.id, "cancel-discovery-worker")
  end

  test "CleanupReconciler settles cancel-requested runs and clears one-time envelopes", %{
    actor: actor,
    identity: identity
  } do
    run = one_time_running_run!(actor, identity)
    item = queued_item!(run, actor, 9_200_000_401)
    attempt_fixture(item)

    assert {:ok, _} =
             ForgeImports.request_cancel(actor, run.id, request_metadata("cleanup-reconcile"),
               now: @now
             )

    assert :reconciled =
             CleanupReconciler.reconcile_cancel_run(Repo.get!(ImportRun, run.id), @now)

    terminal = Repo.get!(ImportRun, run.id)
    assert terminal.state == :canceled
    assert terminal.credential_ciphertext == nil
    assert Repo.get!(RepositoryItem, item.id).state == :canceled
  end

  test "live leases observe durable cancel intent for the owning worker", %{run: run, item: item} do
    assert {:ok, leased} =
             Fornacast.OperationLease.claim(
               RepositoryItem,
               item.id,
               "live-cancel-owner",
               @now,
               60,
               allowed_states: [:queued]
             )

    assert {1, _} =
             Repo.update_all(
               from(candidate in ImportRun, where: candidate.id == ^run.id),
               set: [state: :cancel_requested, cancellation_requested_at: @now]
             )

    assert Cancellation.check(leased.id, leased.lease_owner)
    assert Cancellation.check(leased.id, "other-owner")
  end

  defp one_time_running_run!(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 9_000_000_201,
        source_owner_login: "acme",
        source_repository_github_id: 9_200_000_402,
        source_repository_full_name: "acme/one-time-cancel",
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

  defp running_run!(actor, %{identity_id: identity_id}, credential) do
    %{
      actor_user_id: actor.id,
      source_kind: :repository,
      github_identity_id: identity_id,
      credential_source: :saved,
      github_credential_id: credential.id,
      source_owner_github_id: 9_000_000_201,
      source_owner_login: "acme",
      source_repository_github_id: 9_200_000_200,
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
  end

  defp queued_item!(run, actor, github_repository_id \\ 9_200_000_200) do
    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: "demo-cancel",
      destination_visibility: :private,
      state: :queued,
      attempt_count: 1
    })
    |> unwrap!()
  end

  defp ready_item!(run, actor, github_repository_id) do
    shadow = importing_shadow!(actor)

    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/ready-#{github_repository_id}",
      source_name: "ready",
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: "ready-#{github_repository_id}",
      destination_visibility: :private,
      state: :ready_to_publish,
      hidden_repository_id: shadow.id,
      staged_storage_path: ForgeRepos.absolute_storage_path(shadow),
      attempt_count: 1,
      checkpoint: %{"git_staged" => true, "__terminal_v1__" => true}
    })
    |> unwrap!()
  end

  defp publishing_item!(run, actor) do
    ready = ready_item!(run, actor, 9_200_000_303)
    attempt_number = ready.attempt_count

    evidence = %{
      "version" => 1,
      "state" => "intent",
      "attempt_number" => attempt_number,
      "action" => "create",
      "hidden_repository_id" => ready.hidden_repository_id,
      "operation_id" => "github-import-publication-#{ready.id}-#{attempt_number}",
      "request_metadata" => request_metadata("publishing-item")
    }

    assert {1, _} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^ready.id),
               set: [state: :publishing, publication_evidence: evidence]
             )

    Repo.get!(RepositoryItem, ready.id)
  end

  defp importing_shadow!(actor) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)

    %Repository{}
    |> Repository.import_changeset(%{
      owner_user_id: actor.id,
      slug: "shadow-cancel-#{token}",
      name: "Shadow Cancel",
      visibility: :private,
      storage_path: "@test/shadow-cancel-#{token}.git",
      lifecycle: :importing,
      generation: 1
    })
    |> Repo.insert!()
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
  end

  defp saved_credential_fixture!(actor, identity) do
    case Repo.get_by(GitHubCredential, github_identity_id: identity.id) do
      %GitHubCredential{} = existing ->
        existing

      nil ->
        insert_saved_credential!(actor, identity)
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
        key_id: "test-2026-08-25",
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
          github_user_id: 9_100_000_000 + suffix,
          login: "cancel-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/cancel-#{suffix}"
        },
        @now
      )

    case ForgeAccounts.link_github_identity(actor, identity) do
      {:ok, linked} -> linked
      {:error, :already_linked} -> identity
    end
  end

  defp request_metadata(operation_id \\ nil) do
    %{
      "request_id" => "cancel-test-#{System.unique_integer([:positive])}",
      "operation_id" => operation_id || "cancel-op-#{System.unique_integer([:positive])}",
      "user_agent" => "ExUnit"
    }
  end

  defp user_fixture do
    suffix =
      Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false) <>
        "-#{System.unique_integer([:positive, :monotonic])}"

    Repo.insert!(%User{
      username: "cancel-#{suffix}",
      email: "cancel-#{suffix}@example.test",
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

  defp postgres? do
    Application.get_env(:fornacast, Fornacast.Repo)[:adapter] == Ecto.Adapters.Postgres
  end

  defp reset_database! do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM github_import_report_entries")
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM github_import_attempts")
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM github_import_repository_items")
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM github_import_runs")
  end
end
