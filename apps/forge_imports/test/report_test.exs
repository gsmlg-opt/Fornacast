defmodule ForgeImports.ReportTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, User}

  alias ForgeImports.{
    ImportRun,
    Persistence,
    Report,
    ReportEntry,
    ReportView,
    RepositoryItem,
    RunAggregator
  }

  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-25 12:00:00Z]
  @pat "github_pat_report_test_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<11>>, 32)}}

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

    %{actor: actor, identity: identity, credential: credential}
  end

  test "Report.record is idempotent on import_run_id and idempotency_key", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)

    attrs = %{
      import_run_id: run.id,
      idempotency_key: "warning-alpha",
      scope: :run,
      outcome: :warning,
      classification: "unsupported_releases",
      summary: "GitHub releases are not imported",
      metadata: %{"category" => "unsupported_releases"},
      source_count: 0
    }

    assert {:ok, first} = Report.record(Repo, attrs)
    assert {:ok, second} = Report.record(Repo, attrs)
    assert first.id == second.id
    assert Repo.aggregate(ReportEntry, :count) == 1
  end

  test "Report.record rejects unsafe metadata", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)

    assert match?(
             {:error, _},
             Report.record(Repo, %{
               import_run_id: run.id,
               idempotency_key: "unsafe-metadata",
               scope: :run,
               outcome: :warning,
               classification: "unsupported_releases",
               summary: "GitHub releases are not imported",
               metadata: %{"authorization" => "Bearer secret"},
               source_count: 0
             })
           )
  end

  test "finish_if_terminal completes an all-published organization run", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)

    for {slug, github_id} <- [{"alpha", 9_300_000_001}, {"beta", 9_300_000_002}] do
      item!(run, actor, github_id, slug, state: :published, imported_count: 3)
    end

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :completed
    assert terminal.published_count == 2
    assert terminal.report_finalized_at == @now
    assert terminal.credential_ciphertext == nil

    assert summary = run_summary!(run.id)
    assert summary.outcome == :imported
    assert summary.metadata["published"] == 2

    assert audit = completion_audit!(run.id)
    assert audit.action == "github_import.completed"
    refute inspect(audit) =~ "github_pat_"
  end

  test "finish_if_terminal records mixed success and failure as completed_with_warnings", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)
    item!(run, actor, 9_300_000_010, "good", state: :published, imported_count: 2)
    item!(run, actor, 9_300_000_011, "bad", state: :failed, failure_count: 1)

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :completed_with_warnings
    assert terminal.published_count == 1
    assert terminal.failure_count == 1

    entries =
      Repo.all(
        from entry in ReportEntry,
          where: entry.import_run_id == ^run.id and entry.scope == :repository,
          order_by: [asc: entry.id]
      )

    assert Enum.map(entries, & &1.outcome) == [:imported, :failed]
  end

  test "finish_if_terminal keeps warning counts in the terminal report", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)

    published =
      item!(run, actor, 9_300_000_020, "warned",
        state: :published,
        imported_count: 1,
        warning_count: 2
      )

    assert {:ok, _} =
             Report.record(Repo, %{
               import_run_id: run.id,
               repository_item_id: published.id,
               idempotency_key:
                 "git-warning-#{published.github_repository_id}-unsupported_releases",
               scope: :repository,
               outcome: :warning,
               classification: "unsupported_releases",
               summary: "GitHub releases are not imported",
               metadata: %{"category" => "unsupported_releases"},
               source_count: 0
             })

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :completed_with_warnings
    assert terminal.warning_count == 2
    assert run_summary!(run.id).outcome == :warning
  end

  test "finish_if_terminal completes an all-intentional-skip run", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)
    item!(run, actor, 9_300_000_030, "skip-a", state: :skipped, selected: true, skipped_count: 1)
    item!(run, actor, 9_300_000_031, "skip-b", state: :skipped, selected: true, skipped_count: 1)

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :completed
    assert terminal.skipped_count == 2
    assert terminal.published_count == 0
  end

  test "finish_if_terminal fails when nothing was published", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)
    item!(run, actor, 9_300_000_040, "broken", state: :failed, failure_count: 1)

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :failed
    assert terminal.published_count == 0
    assert terminal.failure_count == 1
    assert completion_audit!(run.id).action == "github_import.failed"
  end

  test "finish_if_terminal honors published siblings during cancellation", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run =
      running_org_run!(actor, identity, credential,
        state: :cancel_requested,
        cancellation_requested_at: @now
      )

    item!(run, actor, 9_300_000_050, "published", state: :published, imported_count: 1)
    item!(run, actor, 9_300_000_051, "canceled", state: :canceled)

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :completed_with_warnings
    assert terminal.published_count == 1
    assert completion_audit!(run.id).action == "github_import.completed_with_warnings"
  end

  test "finish_if_terminal cancels when cancellation leaves nothing published", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run =
      running_org_run!(actor, identity, credential,
        state: :cancel_requested,
        cancellation_requested_at: @now
      )

    item!(run, actor, 9_300_000_060, "canceled", state: :canceled)

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :canceled
    assert completion_audit!(run.id).action == "github_import.canceled"
  end

  test "finish_if_terminal excludes not-selected repositories from aggregation", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential, selected_count: 1)
    item!(run, actor, 9_300_000_070, "kept", state: :published, imported_count: 1)
    item!(run, actor, 9_300_000_071, "ignored", state: :queued, selected: false)

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.state == :completed

    assert Repo.exists?(
             from entry in ReportEntry,
               where:
                 entry.import_run_id == ^run.id and entry.outcome == :not_selected and
                   entry.classification == "not_selected"
           )
  end

  test "finish_if_terminal is idempotent and terminal runs stay immutable", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)
    item!(run, actor, 9_300_000_080, "done", state: :published, imported_count: 1)

    assert {:ok, first} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert {:ok, second} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert first.id == second.id
    assert Repo.aggregate(from(e in ReportEntry, where: e.scope == :run), :count) == 1
  end

  test "finish_if_terminal clears one-time envelopes atomically", %{
    actor: actor,
    identity: identity
  } do
    run = one_time_running_org_run!(actor, identity)
    item!(run, actor, 9_300_000_090, "one-time", state: :published, imported_count: 1)

    assert run.credential_ciphertext

    assert {:ok, terminal} = RunAggregator.finish_if_terminal(run.id, now: @now)
    assert terminal.credential_ciphertext == nil
    assert terminal.credential_nonce == nil
    assert terminal.credential_tag == nil
    assert terminal.credential_key_id == nil
  end

  test "ReportView.load masks foreign runs and returns safe report data", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)
    item!(run, actor, 9_300_000_100, "view", state: :published, imported_count: 1)
    assert {:ok, _} = RunAggregator.finish_if_terminal(run.id, now: @now)

    assert {:ok, view} = ReportView.load(actor, run.id)
    assert view.state == :completed
    assert view.report_finalized_at == @now
    assert [%{outcome: :imported}] = view.repositories
    assert Enum.any?(view.entries, &(&1.scope == :run and &1.outcome == :imported))

    other = user_fixture()
    assert {:error, :not_found} = ReportView.load(other, run.id)

    inspected = inspect(view)
    refute inspected =~ "credential_ciphertext"
    refute inspected =~ "github_pat_"
  end

  test "unsupported category names are stored without unsafe detail", %{
    actor: actor,
    identity: identity,
    credential: credential
  } do
    run = running_org_run!(actor, identity, credential)

    assert {:ok, entry} =
             Report.record(Repo, %{
               import_run_id: run.id,
               idempotency_key: "unsupported-category",
               scope: :run,
               outcome: :warning,
               classification: "unsupported_releases",
               summary: "GitHub releases and release assets are not enumerated or imported",
               metadata: %{"category" => "unsupported_releases"},
               source_count: 0
             })

    assert entry.classification == "unsupported_releases"
    refute entry.summary =~ "github.com"
  end

  defp running_org_run!(actor, identity, credential, overrides \\ []) do
    defaults = %{
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
      state: :running,
      selected_count: 1,
      request_metadata: request_metadata()
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp one_time_running_org_run!(actor, identity) do
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

  defp item!(run, actor, github_repository_id, slug, overrides \\ []) do
    target_state = Keyword.get(overrides, :state, :completed)

    defaults = %{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/#{slug}",
      source_name: slug,
      source_metadata: %{"default_branch" => "main"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_slug: slug,
      destination_visibility: :private,
      state: :queued,
      publication_evidence: %{},
      imported_count: 0,
      skipped_count: 0,
      warning_count: 0,
      failure_count: 0,
      attempt_count: 0
    }

    item =
      defaults
      |> Map.merge(Map.new(overrides))
      |> Map.put(:state, :queued)
      |> Map.put(:publication_evidence, %{})
      |> Persistence.insert_repository_item()
      |> unwrap!()

    if target_state == :queued do
      item
    else
      updates =
        overrides
        |> Map.new()
        |> Map.put(:state, target_state)
        |> Map.drop([:import_run_id, :github_repository_id])
        |> Enum.to_list()

      assert {1, _} =
               Repo.update_all(
                 from(candidate in RepositoryItem, where: candidate.id == ^item.id),
                 set: updates
               )

      Repo.get!(RepositoryItem, item.id)
    end
  end

  defp run_summary!(run_id) do
    Repo.one!(
      from entry in ReportEntry,
        where: entry.import_run_id == ^run_id and entry.idempotency_key == "run-summary",
        limit: 1
    )
  end

  defp completion_audit!(run_id) do
    Repo.one!(
      from event in AuditEvent,
        where:
          event.target_type == "github_import_run" and event.target_id == ^to_string(run_id) and
            event.action in [
              "github_import.completed",
              "github_import.completed_with_warnings",
              "github_import.canceled",
              "github_import.failed"
            ],
        order_by: [desc: event.id],
        limit: 1
    )
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

    assert {1, _} =
             Repo.update_all(
               from(c in GitHubCredential, where: c.id == ^placeholder.id),
               set: [
                 ciphertext: envelope.ciphertext,
                 nonce: envelope.nonce,
                 tag: envelope.tag,
                 key_id: envelope.key_id
               ]
             )

    Repo.get!(GitHubCredential, placeholder.id)
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

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_100_000_000 + suffix,
          login: "report-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/report-#{suffix}"
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
      "request_id" => "report-test-#{System.unique_integer([:positive])}",
      "operation_id" => operation_id || "report-op-#{System.unique_integer([:positive])}",
      "user_agent" => "ExUnit"
    }
  end

  defp user_fixture do
    suffix =
      Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false) <>
        "-#{System.unique_integer([:positive, :monotonic])}"

    Repo.insert!(%User{
      username: "report-#{suffix}",
      email: "report-#{suffix}@example.test",
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
