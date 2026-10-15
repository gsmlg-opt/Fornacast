defmodule ForgeImports.AdminJobsTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{GitHubIdentity, User}
  alias ForgeImports.{AdminJobs, ImportRun, PatSyncRepositoryResult, PatSyncRun, RepositoryItem}

  alias ForgeImports.SyncJobs.{
    ControlWorker,
    DiscoveryWorker,
    PatRepositoryWorker,
    RepositoryWorker
  }

  alias ForgeMirrors.PatConfiguration
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{admin: user!(role: :admin)}
  end

  test "requires a persisted active human administrator", %{admin: admin} do
    user = user!()
    disabled = user!(role: :admin, state: :disabled)
    organization = user!(kind: :organization, role: :admin)

    for actor <- [
          nil,
          %{},
          %{id: admin.id},
          %User{id: nil, role: :admin},
          %User{id: -1, role: :admin},
          %User{id: 9_223_372_036_854_775_808, role: :admin},
          %User{id: "invalid", role: :admin},
          %{user | role: :admin},
          %{disabled | state: :active},
          %{organization | kind: :user}
        ] do
      assert {:error, :forbidden} = AdminJobs.list_jobs(actor)
    end

    assert {:ok, %{jobs: [], page: 1, has_next?: false}} = AdminJobs.list_jobs(admin)
  end

  test "reloads demoted, disabled and deleted administrators", %{admin: admin} do
    Repo.update!(Ecto.Changeset.change(admin, role: :user))
    assert {:error, :forbidden} = AdminJobs.list_jobs(admin)

    Repo.update!(Ecto.Changeset.change(admin, role: :admin, state: :disabled))
    assert {:error, :forbidden} = AdminJobs.list_jobs(admin)

    Repo.delete!(admin)
    assert {:error, :forbidden} = AdminJobs.list_jobs(admin)
  end

  test "returns only bounded operational metadata and counts errors", %{admin: admin} do
    secret = "github_pat_admin_jobs_secret_sentinel"
    now = DateTime.utc_now()

    job =
      job!(%{
        state: "discarded",
        args: %{"token" => secret},
        meta: %{"credential" => secret},
        errors: [%{"error" => secret}, %{"stacktrace" => secret}],
        attempt: 3,
        max_attempts: 3,
        priority: 2,
        attempted_at: now,
        completed_at: now,
        discarded_at: now,
        cancelled_at: now
      })

    assert {:ok, %{jobs: [row]}} = AdminJobs.list_jobs(admin)

    assert Map.keys(row) |> Enum.sort() ==
             Enum.sort([
               :id,
               :state,
               :queue,
               :worker,
               :attempt,
               :max_attempts,
               :priority,
               :inserted_at,
               :scheduled_at,
               :attempted_at,
               :completed_at,
               :discarded_at,
               :cancelled_at,
               :error_count,
               :task_path
             ])

    assert row.id == job.id
    assert row.error_count == 2
    assert row.attempt == 3
    assert row.max_attempts == 3
    assert row.priority == 2
    assert row.task_path == nil
    assert row.attempted_at == now
    refute Jason.encode!(row) =~ secret
    assert Repo.get!(Styx.Job, job.id).errors == job.errors
  end

  test "filters each supported state and normalizes blank filters", %{admin: admin} do
    for state <- Styx.Job.states(), do: job!(%{state: to_string(state)})

    for state <- Styx.Job.states() do
      state = to_string(state)

      assert {:ok, %{jobs: [job], filters: %{queue: nil, state: ^state}}} =
               AdminJobs.list_jobs(admin, %{"state" => state})

      assert job.state == state
    end

    assert {:ok, %{filters: %{queue: nil, state: nil}}} =
             AdminJobs.list_jobs(admin, %{"queue" => "", "state" => ""})
  end

  test "keeps configured and historical queues and combines queue and state", %{admin: admin} do
    original = Application.fetch_env!(:forge_imports, Styx)
    Application.put_env(:forge_imports, Styx, Keyword.put(original, :queues, future_queue: 1))
    on_exit(fn -> Application.put_env(:forge_imports, Styx, original) end)

    job!(%{queue: "retired_queue", state: "completed"})
    expected = job!(%{queue: "retired_queue", state: "retryable"})
    job!(%{queue: "other_queue", state: "retryable"})

    assert {:ok, %{jobs: [job], queues: queues, filters: filters}} =
             AdminJobs.list_jobs(admin, %{"queue" => "retired_queue", "state" => "retryable"})

    assert job.id == expected.id
    assert filters == %{queue: "retired_queue", state: "retryable"}
    assert queues == ["future_queue", "other_queue", "retired_queue"]
    assert {:ok, %{jobs: []}} = AdminJobs.list_jobs(admin, %{"queue" => "future_queue"})
  end

  test "rejects unknown keys, malformed values, and unbounded pages", %{admin: admin} do
    for params <- [
          nil,
          [],
          %{"unknown" => "value"},
          %{state: "available"},
          %{"state" => :available},
          %{"state" => ["available"]},
          %{"state" => nil},
          %{"state" => "unknown_state"},
          %{"queue" => :github_control},
          %{"queue" => %{}},
          %{"queue" => nil},
          %{"queue" => "unknown_queue"},
          %{"queue" => String.duplicate("a", 256)},
          %{"queue" => <<0>>},
          %{"queue" => <<255>>},
          %{"page" => ""},
          %{"page" => "0"},
          %{"page" => "-1"},
          %{"page" => "10001"},
          %{"page" => "1x"},
          %{"page" => "1.0"},
          %{"page" => "1 OR TRUE"},
          %{"page" => 0},
          %{"page" => 10_001},
          %{"page" => nil},
          %{"page" => %{}}
        ] do
      assert {:error, :invalid_filter} = AdminJobs.list_jobs(admin, params)
    end

    assert {:ok, %{page: 10_000, jobs: []}} = AdminJobs.list_jobs(admin, %{"page" => "10000"})
  end

  test "paginates newest jobs first with fifty rows and retains filters", %{admin: admin} do
    jobs = for _ <- 1..51, do: job!(%{queue: "page_queue", state: "completed"})
    job!(%{queue: "other_queue", state: "completed"})
    params = %{"queue" => "page_queue", "state" => "completed"}

    assert {:ok, first} = AdminJobs.list_jobs(admin, params)
    assert length(first.jobs) == 50
    assert first.has_next?

    assert Enum.map(first.jobs, & &1.id) ==
             jobs |> Enum.reverse() |> Enum.take(50) |> Enum.map(& &1.id)

    assert {:ok, second} = AdminJobs.list_jobs(admin, Map.put(params, "page", "2"))
    assert Enum.map(second.jobs, & &1.id) == [hd(jobs).id]
    refute second.has_next?
    assert second.page == 2
    assert second.filters == first.filters

    assert {:ok, %{jobs: [], has_next?: false}} =
             AdminJobs.list_jobs(admin, Map.put(params, "page", 3))
  end

  test "links the four known worker kinds through persisted task associations", %{admin: admin} do
    {run, item, result, organization} = task_fixture!(admin)

    jobs = [
      job!(%{worker: inspect(ControlWorker), args: %{"pat_sync_run_id" => run.id}}),
      job!(%{worker: inspect(DiscoveryWorker), args: %{"import_run_id" => run.import_run_id}}),
      job!(%{worker: inspect(RepositoryWorker), args: %{"repository_item_id" => item.id}}),
      job!(%{worker: inspect(PatRepositoryWorker), args: %{"result_id" => result.id}})
    ]

    for _ <- 1..3 do
      job!(%{worker: inspect(ControlWorker), args: %{"pat_sync_run_id" => to_string(run.id)}})
    end

    path = "/organizations/#{organization.username}/settings/github/runs/#{run.id}"
    assert {:ok, %{jobs: rows}} = AdminJobs.list_jobs(admin)
    assert Enum.all?(rows, &(&1.task_path == path))
    assert Enum.all?(jobs, fn job -> Enum.any?(rows, &(&1.id == job.id)) end)
  end

  test "does not invent task links for unknown workers or invalid identifiers", %{admin: admin} do
    {run, _item, _result, _organization} = task_fixture!(admin)

    job!(%{worker: "Unrelated.Worker", args: %{"pat_sync_run_id" => run.id}})

    job!(%{
      worker: "ForgeImports.SyncJobs.MaintenanceWorker",
      args: %{"pat_sync_run_id" => run.id}
    })

    job!(%{worker: "Elixir." <> inspect(ControlWorker), args: %{"pat_sync_run_id" => run.id}})

    for id <- [
          nil,
          false,
          %{},
          [],
          -1,
          0,
          "unknown",
          "9223372036854775808",
          String.duplicate("9", 1000)
        ] do
      job!(%{worker: inspect(ControlWorker), args: %{"pat_sync_run_id" => id}})
    end

    job!(%{worker: inspect(ControlWorker), args: %{"pat_sync_run_id" => run.id + 1}})
    job!(%{worker: inspect(DiscoveryWorker), args: %{"pat_sync_run_id" => run.id}})

    assert {:ok, %{jobs: rows}} = AdminJobs.list_jobs(admin)
    assert Enum.all?(rows, &is_nil(&1.task_path))
  end

  defp user!(attrs \\ []) do
    n = System.unique_integer([:positive, :monotonic])

    Repo.insert!(
      struct!(
        %User{
          username: "adminjobs#{n}",
          email: "adminjobs#{n}@test.local",
          password_hash: "unused",
          kind: :user,
          role: :user,
          state: :active
        },
        attrs
      )
    )
  end

  defp job!(attrs) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct!(
        %Styx.Job{
          worker: "Example.Worker",
          queue: "github_control",
          args: %{},
          priority: 0,
          inserted_at: now,
          scheduled_at: now
        },
        attrs
      )
    )
  end

  defp task_fixture!(owner) do
    organization = user!(kind: :organization)
    n = System.unique_integer([:positive, :monotonic])

    identity =
      Repo.insert!(%GitHubIdentity{kind: :user, github_user_id: n, login: "adminjobs#{n}"})

    configuration =
      Repo.insert!(%PatConfiguration{
        organization_id: organization.id,
        owner_user_id: owner.id,
        github_identity_id: identity.id,
        github_organization: "source-org"
      })

    import_run =
      Repo.insert!(%ImportRun{
        actor_user_id: owner.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: n,
        source_owner_login: "source-org"
      })

    item =
      Repo.insert!(%RepositoryItem{
        import_run_id: import_run.id,
        github_repository_id: n,
        source_full_name: "source-org/example",
        source_name: "example",
        source_observed_at: DateTime.utc_now(:second)
      })

    run =
      Repo.insert!(%PatSyncRun{
        configuration_id: configuration.id,
        organization_id: organization.id,
        owner_user_id: owner.id,
        github_identity_id: identity.id,
        github_organization: "source-org",
        import_run_id: import_run.id
      })

    result =
      Repo.insert!(%PatSyncRepositoryResult{
        pat_sync_run_id: run.id,
        repository_item_id: item.id,
        item_key: "import:#{item.id}"
      })

    {run, item, result, organization}
  end
end
