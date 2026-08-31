defmodule ForgeImports.DiscoveryRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForgeAccounts.GitHubIdentity

  alias ForgeImports.{
    DiscoveryWorker,
    ImportRun,
    Reconciler,
    RecoverySupervisor,
    ReportEntry,
    RepositoryItem,
    RunView
  }

  alias ForgeImports.GitHub.{Organization, Repository, User}
  alias Fornacast.{OperationLease, Repo}

  @pat "github_pat_ZYXWVUTSRQPONMLK"
  @now ~U[2026-08-26 09:00:00Z]

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    {:ok, state} = Agent.start_link(fn -> %{repository_calls: 0, gates: []} end)

    %{actor: actor, state: state}
  end

  test "a crashed supervised worker leaves discovering state and the bounded reconciler reclaims it",
       %{actor: actor, state: state} do
    supervisor =
      start_supervised!(
        {RecoverySupervisor,
         name: __MODULE__.RecoverySupervisor,
         task_supervisor: __MODULE__.TaskSupervisor,
         reconciler_name: __MODULE__.Reconciler,
         enabled: true,
         interval_ms: 50,
         batch_size: 10,
         lease_seconds: 1,
         client: __MODULE__.CrashOnceClient,
         client_options: [state: state]}
      )

    log =
      capture_log(fn ->
        assert {:ok, %RunView{state: :discovering, id: run_id}} =
                 ForgeImports.create_repository_discovery(
                   actor,
                   %{source: "octocat/recovery", credential_source: :one_time, pat: @pat},
                   request_metadata(),
                   dispatch: :async,
                   task_supervisor: __MODULE__.TaskSupervisor,
                   reconciler: __MODULE__.Reconciler,
                   lease_seconds: 1,
                   client: __MODULE__.CrashOnceClient,
                   client_options: [state: state]
                 )

        recovered? =
          eventually(fn ->
            match?(
              {:ok, %RunView{state: :awaiting_resolution}},
              ForgeImports.get_run(actor, run_id)
            )
          end)

        raw = Repo.get(ImportRun, run_id)

        assert recovered?,
               "recovery did not converge: #{inspect(raw)} failure=#{inspect(raw.failure_kind)} " <>
                 inspect(Agent.get(state, & &1))
      end)

    refute log =~ @pat
    refute log =~ "Bearer"

    %{repository_calls: calls, gates: gates} = Agent.get(state, & &1)
    assert calls >= 2
    assert {:import_setup, actor.id} in gates

    assert Enum.all?(Enum.reject(gates, &match?({:import_setup, _}, &1)), fn
             {:one_time_run, run_id} when is_integer(run_id) and run_id > 0 -> true
             _ -> false
           end)

    old_task_supervisor = Process.whereis(__MODULE__.TaskSupervisor)
    old_reconciler = Process.whereis(__MODULE__.Reconciler)
    assert is_pid(old_task_supervisor)
    assert is_pid(old_reconciler)

    restart_log =
      capture_log(fn ->
        Process.exit(old_reconciler, :kill)

        assert eventually(fn ->
                 case Process.whereis(__MODULE__.TaskSupervisor) do
                   pid when is_pid(pid) -> pid != old_task_supervisor
                   _ -> false
                 end
               end)
      end)

    refute restart_log =~ @pat

    assert Process.alive?(supervisor)
    :ok = stop_supervised(RecoverySupervisor)
  end

  test "recovery terminal-cleans a discovering run whose one-time envelope is missing", %{
    actor: actor
  } do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 73_001,
          login: "missing-envelope",
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    assert %GitHubIdentity{local_user_id: nil} = identity

    assert {:ok, run} =
             ForgeImports.create_run(actor, %{
               source_kind: :repository,
               github_identity_id: identity.id,
               credential_source: :one_time,
               source_owner_login: "octocat",
               source_repository_full_name: "octocat/missing-envelope",
               request_metadata: request_metadata()
             })

    assert {:ok, :failed} =
             DiscoveryWorker.perform(run.id,
               owner: "missing-envelope-worker",
               lease_seconds: 2_400,
               client: __MODULE__.CrashOnceClient,
               client_options: [state: self()]
             )

    assert {:ok, %RunView{state: :failed, reports: [report]}} =
             ForgeImports.get_run(actor, run.id)

    assert report.classification == "credential_service_unavailable"

    raw = Repo.get!(ImportRun, run.id)
    assert raw.credential_ciphertext == nil
    assert raw.lease_owner == nil
    assert raw.lease_expires_at == nil
  end

  test "reconciler serializes one scan task and only selects discovering runs", %{actor: actor} do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{github_user_id: 73_002, login: "scan-only", avatar_url: nil, profile_url: nil},
        @now
      )

    {:ok, discovering} = provisional_run(actor, identity, "discovering")
    {:ok, failed} = provisional_run(actor, identity, "failed")
    discovering_id = discovering.id

    assert [^discovering_id] =
             Reconciler.discovering_run_ids(10, DateTime.utc_now(:second))

    refute failed.id in Reconciler.discovering_run_ids(10, DateTime.utc_now(:second))
  end

  test "lease claims atomically reject a run outside discovering state", %{
    actor: actor,
    state: state
  } do
    Agent.update(state, &%{&1 | repository_calls: 1})

    assert {:ok, %RunView{id: run_id, state: :awaiting_resolution}} =
             ForgeImports.create_repository_discovery(
               actor,
               %{source: "octocat/recovery", credential_source: :one_time, pat: @pat},
               request_metadata(),
               dispatch: :inline,
               lease_seconds: 60,
               client: __MODULE__.CrashOnceClient,
               client_options: [state: state]
             )

    assert :busy =
             OperationLease.claim(
               ImportRun,
               run_id,
               "wrong-state-worker",
               DateTime.utc_now(:second),
               60,
               allowed_states: [:discovering]
             )

    raw = Repo.get!(ImportRun, run_id)
    assert raw.state == :awaiting_resolution
    assert raw.lease_owner == nil
    assert raw.lease_expires_at == nil
  end

  test "an expired unreclaimed worker cannot commit discovery or failure evidence", %{
    actor: actor
  } do
    before_audits = Repo.aggregate(Fornacast.AuditEvent, :count)

    assert {:error, :discovery_failed} =
             ForgeImports.create_repository_discovery(
               actor,
               %{source: "octocat/slow-source", credential_source: :one_time, pat: @pat},
               request_metadata(),
               dispatch: :inline,
               lease_seconds: 1,
               client: __MODULE__.SlowClient,
               client_options: []
             )

    [run] = Repo.all(ImportRun)
    assert run.state == :discovering
    assert DateTime.compare(run.lease_expires_at, DateTime.utc_now(:second)) != :gt
    assert Repo.aggregate(RepositoryItem, :count) == 0
    assert Repo.aggregate(ReportEntry, :count) == 0
    assert Repo.aggregate(Fornacast.AuditEvent, :count) == before_audits
  end

  test "saved worker rejects a credential invalidated before checkout without provider access", %{
    actor: actor
  } do
    {:ok, account} =
      ForgeAccounts.save_github_account(
        actor,
        %{
          github_user_id: 73_015,
          login: "saved-checkout",
          avatar_url: nil,
          profile_url: "https://github.com/saved-checkout"
        },
        "unrelated-checkout-value",
        request_metadata()
      )

    {:ok, reference} = ForgeAccounts.github_account_reference(actor, account.identity_id)

    assert {:ok, run} =
             ForgeImports.create_run(actor, %{
               source_kind: :repository,
               github_identity_id: account.identity_id,
               credential_source: :saved,
               github_credential_id: reference.credential.credential_id,
               source_owner_login: "octocat",
               source_repository_full_name: "octocat/saved-checkout",
               request_metadata: request_metadata()
             })

    assert {:ok, invalid} =
             ForgeAccounts.mark_github_credential_invalid(
               actor,
               account.identity_id,
               reference.credential,
               request_metadata()
             )

    assert invalid.credential_status == :invalid

    assert {:ok, :failed} =
             DiscoveryWorker.perform(run.id,
               client: __MODULE__.CheckoutProbeClient,
               client_options: [test_pid: self()]
             )

    refute_receive :saved_provider_called, 50

    assert {:ok, %RunView{state: :failed, reports: [report]}} =
             ForgeImports.get_run(actor, run.id)

    assert report.classification == "github_invalid_credential"
  end

  test "recovery preserves an explicitly invalid organization destination and observation", %{
    actor: actor
  } do
    {:ok, state} = Agent.start_link(fn -> %{organization_calls: 0} end)

    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.OrganizationRecoverySupervisor,
       task_supervisor: __MODULE__.OrganizationTaskSupervisor,
       reconciler_name: __MODULE__.OrganizationReconciler,
       enabled: true,
       interval_ms: 60_000,
       batch_size: 10,
       lease_seconds: 1,
       client: __MODULE__.CrashOnceOrganizationClient,
       client_options: [state: state]}
    )

    log =
      capture_log(fn ->
        assert {:ok, %RunView{id: run_id, state: :discovering}} =
                 ForgeImports.create_organization_discovery(
                   actor,
                   %{
                     organization: "github",
                     credential_source: :one_time,
                     pat: @pat,
                     destination_organization: %{action: :new, slug: nil}
                   },
                   request_metadata(),
                   dispatch: :async,
                   reconciler: __MODULE__.OrganizationReconciler,
                   lease_seconds: 1,
                   client: __MODULE__.CrashOnceOrganizationClient,
                   client_options: [state: state]
                 )

        assert eventually(fn -> Agent.get(state, & &1.organization_calls) == 1 end)
        # Reconciler clamps worker leases to the shared two-second safety minimum.
        Process.sleep(2_100)

        assert {:ok, :awaiting_resolution} =
                 DiscoveryWorker.perform(run_id,
                   lease_seconds: 60,
                   client: __MODULE__.CrashOnceOrganizationClient,
                   client_options: [state: state]
                 )

        assert {:ok, %RunView{repositories: [item]} = view} = ForgeImports.get_run(actor, run_id)
        assert item.state == :awaiting_resolution
        assert item.wait_reason == "invalid_namespace"
        assert item.destination_slug == nil

        assert {:ok, _observed_at, 0} =
                 DateTime.from_iso8601(view.source.provenance["observed_at"])
      end)

    refute log =~ @pat
  end

  defmodule CrashOnceClient do
    def authenticated_user(_pat, opts) do
      record_gate(opts)

      {:ok,
       %User{
         id: 73_000,
         login: "recovery-user",
         name: nil,
         avatar_url: nil,
         html_url: "https://github.com/recovery-user"
       }}
    end

    def repository(_pat, _owner, _repository, opts) do
      record_gate(opts)

      case Keyword.fetch!(opts, :state) do
        pid when is_pid(pid) ->
          if Process.info(pid, :dictionary) == nil do
            {:error, ForgeImports.GitHub.Error.new(:upstream_unavailable)}
          else
            call =
              Agent.get_and_update(pid, fn state ->
                next = state.repository_calls + 1
                {next, %{state | repository_calls: next}}
              end)

            if call == 1, do: raise("simulated worker crash"), else: {:ok, repository()}
          end
      end
    end

    defp record_gate(opts) do
      gate = Keyword.fetch!(opts, :gate_key)

      case Keyword.fetch!(opts, :state) do
        pid when is_pid(pid) ->
          if Process.info(pid, :dictionary) != nil do
            Agent.update(pid, fn state -> %{state | gates: [gate | state.gates]} end)
          end
      end
    end

    defp repository do
      %Repository{
        id: 93_001,
        owner_id: 83_001,
        name: "recovery",
        full_name: "octocat/recovery",
        owner_login: "octocat",
        description: nil,
        visibility: :private,
        default_branch: "main",
        has_issues: true,
        allow_merge_commit: true,
        fork: false,
        archived: false,
        html_url: "https://github.com/octocat/recovery",
        updated_at: ~U[2026-08-26 09:00:00Z],
        pushed_at: ~U[2026-08-26 09:00:00Z]
      }
    end
  end

  defmodule SlowClient do
    def authenticated_user(_pat, _opts) do
      {:ok,
       %User{
         id: 73_010,
         login: "slow-user",
         name: nil,
         avatar_url: nil,
         html_url: "https://github.com/slow-user"
       }}
    end

    def repository(_pat, _owner, _repository, _opts) do
      Process.sleep(1_200)

      {:ok,
       %Repository{
         id: 93_010,
         owner_id: 83_010,
         name: "slow-source",
         full_name: "octocat/slow-source",
         owner_login: "octocat",
         description: nil,
         visibility: :private,
         default_branch: "main",
         has_issues: true,
         allow_merge_commit: true,
         fork: false,
         archived: false,
         html_url: "https://github.com/octocat/slow-source",
         updated_at: ~U[2026-08-26 09:00:00Z],
         pushed_at: ~U[2026-08-26 09:00:00Z]
       }}
    end
  end

  defmodule CrashOnceOrganizationClient do
    def authenticated_user(_pat, _opts) do
      {:ok,
       %User{
         id: 73_020,
         login: "organization-user",
         name: nil,
         avatar_url: nil,
         html_url: "https://github.com/organization-user"
       }}
    end

    def organization(_pat, _login, opts) do
      call =
        Agent.get_and_update(Keyword.fetch!(opts, :state), fn state ->
          next = state.organization_calls + 1
          {next, %{state | organization_calls: next}}
        end)

      if call == 1 do
        raise "simulated organization worker crash"
      else
        {:ok,
         %Organization{
           id: 83_020,
           login: "github",
           name: "GitHub",
           description: nil,
           avatar_url: nil,
           html_url: "https://github.com/github"
         }}
      end
    end

    def organization_repositories(_pat, _login, _opts) do
      {:ok,
       [
         %Repository{
           id: 93_020,
           owner_id: 83_020,
           name: "organization-repo",
           full_name: "github/organization-repo",
           owner_login: "github",
           description: nil,
           visibility: :private,
           default_branch: "main",
           has_issues: true,
           allow_merge_commit: true,
           fork: false,
           archived: false,
           html_url: "https://github.com/github/organization-repo",
           updated_at: ~U[2026-08-26 09:00:00Z],
           pushed_at: ~U[2026-08-26 09:00:00Z]
         }
       ]}
    end
  end

  defmodule CheckoutProbeClient do
    def repository(_pat, _owner, _repository, opts) do
      send(Keyword.fetch!(opts, :test_pid), :saved_provider_called)
      {:error, ForgeImports.GitHub.Error.new(:forbidden)}
    end
  end

  defp provisional_run(actor, identity, state) do
    attrs = %{
      actor_user_id: actor.id,
      source_kind: :repository,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_login: "octocat",
      source_repository_full_name: "octocat/#{state}",
      state: String.to_existing_atom(state),
      terminal_at: if(state == "failed", do: @now),
      request_metadata: request_metadata()
    }

    ForgeImports.Persistence.insert_run(attrs)
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "recovery-user-#{suffix}",
        email: "recovery-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    actor
  end

  defp request_metadata do
    suffix = System.unique_integer([:positive])

    %{
      "request_id" => "recovery-request-#{suffix}",
      "operation_id" => "recovery-operation-#{suffix}",
      "ip_address" => "203.0.113.9",
      "user_agent" => "Fornacast recovery test"
    }
  end

  defp eventually(fun, attempts \\ 120)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
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
