defmodule ForgeImports.DiscoveryLeaseDurationTest do
  use ExUnit.Case, async: false

  alias ForgeImports.{DiscoveryWorker, ImportRun, Persistence, ReportEntry, RepositoryItem}
  alias ForgeImports.GitHub.Repository
  alias Fornacast.{AuditEvent, OperationLease, Repo}

  @lease_seconds 2
  @now ~U[2026-08-26 10:30:00Z]

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    account = saved_account_fixture(actor)
    {:ok, reference} = ForgeAccounts.github_account_reference(actor, account.identity_id)

    {:ok, run} =
      ForgeImports.create_run(actor, %{
        source_kind: :repository,
        github_identity_id: account.identity_id,
        credential_source: :saved,
        github_credential_id: reference.credential.credential_id,
        source_owner_login: "octocat",
        source_repository_full_name: "octocat/lease-boundary",
        request_metadata: request_metadata()
      })

    {:ok, _duplicate} =
      Persistence.insert_repository_item(%{
        import_run_id: run.id,
        github_repository_id: 95_001,
        source_full_name: "octocat/preexisting-plan",
        source_name: "preexisting-plan",
        source_metadata: %{},
        source_observed_at: @now
      })

    %{actor: actor, run: run}
  end

  test "failed final persistence retains only the configured renewed lease boundary", %{
    run: run
  } do
    before_audits = Repo.aggregate(AuditEvent, :count)
    started_at = DateTime.utc_now(:second)

    assert {:error, :persistence_unavailable} =
             DiscoveryWorker.perform(run.id,
               owner: "short-renewal-worker",
               lease_seconds: @lease_seconds,
               client: __MODULE__.DuplicateRepositoryClient,
               client_options: []
             )

    raw = Repo.get!(ImportRun, run.id)
    assert raw.state == :discovering
    assert raw.lock_version == run.lock_version + 2
    assert raw.lease_owner == "short-renewal-worker"
    assert DateTime.compare(raw.lease_expires_at, started_at) == :gt
    assert DateTime.diff(raw.lease_expires_at, started_at, :second) <= @lease_seconds + 1
    assert Repo.aggregate(RepositoryItem, :count) == 1
    assert Repo.aggregate(ReportEntry, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == before_audits

    reclaim_at = DateTime.add(started_at, @lease_seconds + 2, :second)

    assert {:ok, reclaimed} =
             OperationLease.claim(
               ImportRun,
               run.id,
               "recovery-worker",
               reclaim_at,
               @lease_seconds,
               allowed_states: [:discovering]
             )

    assert reclaimed.lease_owner == "recovery-worker"
    assert Repo.aggregate(RepositoryItem, :count) == 1
    assert Repo.aggregate(ReportEntry, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == before_audits
  end

  defmodule DuplicateRepositoryClient do
    @observed_at ~U[2026-08-26 10:30:00Z]

    def repository(_pat, "octocat", "lease-boundary", _opts) do
      {:ok,
       %Repository{
         id: 95_001,
         owner_id: 85_001,
         name: "lease-boundary",
         full_name: "octocat/lease-boundary",
         owner_login: "octocat",
         description: nil,
         visibility: :private,
         default_branch: "main",
         has_issues: true,
         allow_merge_commit: true,
         fork: false,
         archived: false,
         html_url: "https://github.com/octocat/lease-boundary",
         updated_at: @observed_at,
         pushed_at: @observed_at
       }}
    end
  end

  defp saved_account_fixture(actor) do
    assert {:ok, account} =
             ForgeAccounts.save_github_account(
               actor,
               %{
                 github_user_id: 75_001,
                 login: "lease-account",
                 avatar_url: nil,
                 profile_url: "https://github.com/lease-account"
               },
               "unrelated-lease-token",
               request_metadata()
             )

    account
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "lease-duration-#{suffix}",
        email: "lease-duration-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp request_metadata do
    suffix = System.unique_integer([:positive])

    %{
      "request_id" => "lease-duration-request-#{suffix}",
      "operation_id" => "lease-duration-operation-#{suffix}",
      "ip_address" => "203.0.113.22",
      "user_agent" => "discovery-lease-duration-test"
    }
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
