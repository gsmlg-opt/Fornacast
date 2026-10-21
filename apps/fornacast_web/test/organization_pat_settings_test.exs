defmodule FornacastWeb.OrganizationPATSettingsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  alias ForgeAccounts.User
  alias Fornacast.Repo
  @endpoint FornacastWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    owner = user()
    outsider = user()
    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "pat-org-#{owner.id}"})

    {:ok, account} =
      ForgeAccounts.save_github_account(
        owner,
        %{github_user_id: owner.id, login: owner.username, avatar_url: nil, profile_url: nil},
        "github_pat_web_sync_test",
        %{}
      )

    %{
      owner: owner,
      account: account,
      outsider: outsider,
      org: org,
      path: "/organizations/#{org.username}/settings/github"
    }
  end

  test "canonical tab shows owner credential configuration and preserves separate App page", c do
    html = request(c.owner) |> get(c.path) |> html_response(200)
    assert html =~ "saved GitHub connection or PAT"
    assert html =~ "pause the synchronization configuration"
    assert html =~ "GitHub → Fornacast"
    assert html =~ c.path <> "/repositories"
    assert html =~ c.path <> "/app"
    refute html =~ "Installation ID"
    assert request(c.owner) |> get(c.path <> "/app") |> html_response(200) =~ "GitHub settings"
  end

  test "disabled configuration saves and reloads and repository subpage is accessible", c do
    params = %{
      "owner_user_id" => "",
      "github_identity_id" => "",
      "github_organization" => "source-org",
      "enabled" => "false",
      "lock_version" => "1"
    }

    conn = request(c.owner) |> patch(c.path <> "/pat", %{"pat_sync" => params})
    assert redirected_to(conn, 303) == c.path
    html = request(c.owner) |> get(c.path) |> html_response(200)
    assert html =~ "source-org"
    assert html =~ "No owner credential selected"

    assert request(c.owner) |> get(c.path <> "/repositories") |> html_response(200) =~
             "Refresh from GitHub"

    assert request(c.owner)
           |> patch(c.path <> "/pat", %{
             "pat_sync" => %{params | "enabled" => "true", "lock_version" => "2"}
           })
           |> html_response(422) =~ "valid saved credential"
  end

  test "private settings, inventory and mutations reject outsiders and malformed input", c do
    for suffix <- ["", "/repositories"] do
      assert request(c.outsider) |> get(c.path <> suffix) |> response(404)
    end

    for suffix <- ["/pat", "/repositories"] do
      assert request(c.outsider) |> patch(c.path <> suffix, %{}) |> response(404)
      assert request(c.owner) |> patch(c.path <> suffix, %{"pat_sync" => "bad"}) |> response(422)
    end

    for suffix <- ["/repositories/refresh", "/sync"] do
      assert request(c.outsider) |> post(c.path <> suffix, %{}) |> response(404)
    end
  end

  test "configuration forms enforce CSRF", c do
    conn = request(c.owner) |> get(c.path)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> recycle()
      |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
      |> patch(c.path <> "/pat", %{"_csrf_token" => "bad", "pat_sync" => %{}})
    end
  end

  test "Git and LFS enrollment is explicit, owner-only and validates selected local repositories",
       c do
    html = request(c.owner) |> get(c.path <> "/repositories") |> html_response(200)
    assert html =~ "Bidirectional Git and LFS"

    assert html =~
             "Import repositories into this organization with the configured saved credential first."

    assert request(c.outsider)
           |> post(c.path <> "/repositories/mirror", %{})
           |> response(404)

    for attrs <- [
          "bad",
          %{"lock_version" => "1", "repository_ids" => []},
          %{"lock_version" => "1", "repository_ids" => ["bad"]},
          %{"lock_version" => "1", "repository_ids" => ["1"], "extra" => "bad"}
        ] do
      assert request(c.owner)
             |> post(c.path <> "/repositories/mirror", %{"pat_sync" => attrs})
             |> html_response(422)
    end

    refute Repo.exists?(ForgeMirrors.OrganizationMirror)
  end

  test "repository page offers immediate all-repository synchronization separately from selection",
       c do
    html =
      request(c.owner)
      |> get(c.path <> "/repositories")
      |> html_response(200)
      |> String.replace(~r/\s+/, " ")

    assert html =~ "Sync now"
    assert html =~ c.path <> "/sync"
    assert html =~ "all credential-visible repositories"
    assert html =~ "regardless of the saved repository selection"
    assert html =~ "Saving repository selection does not synchronize repository contents."
    assert html =~ "Never synchronized"
  end

  test "stale synchronization request preserves the last completed synchronization status", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{"github_organization" => "source-org", "enabled" => "false", "lock_version" => "1"},
        %{}
      )

    config
    |> Ecto.Changeset.change(enabled: true, last_sync_status: "succeeded")
    |> Repo.update!()

    conn =
      request(c.owner)
      |> post(c.path <> "/sync", %{"pat_sync" => %{"lock_version" => "1"}})

    assert html_response(conn, 409) =~ "The configuration changed. Refresh and try again."
    {:ok, %{config: current}} = ForgeMirrors.PatSettings.view(c.owner, c.org.id)
    assert current.last_sync_status == "succeeded"
  end

  test "disabled and paused synchronization requests explain why no job can start", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{"github_organization" => "source-org", "enabled" => "false", "lock_version" => "1"},
        %{}
      )

    params = %{"pat_sync" => %{"lock_version" => to_string(config.lock_version)}}

    assert request(c.owner) |> post(c.path <> "/sync", params) |> html_response(422) =~
             "Enable the GitHub mirror before syncing."

    {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.owner, c.org.id, true, %{})

    assert request(c.owner) |> post(c.path <> "/sync", params) |> html_response(422) =~
             "Synchronization is paused. Resume it before syncing."

    {:ok, %{config: current}} = ForgeMirrors.PatSettings.view(c.owner, c.org.id)
    assert current.last_sync_status == nil
  end

  test "both PAT pages show synchronization totals and repository outcomes", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{"github_organization" => "source-org", "enabled" => "false", "lock_version" => "1"},
        %{}
      )

    task(config, c, "running", %{
      "total" => 3,
      "succeeded" => 1,
      "failed" => 1,
      "pending" => 1,
      "status" => "running",
      "repositories" => [
        %{"source_full_name" => "source-org/done", "status" => "succeeded"},
        %{
          "source_full_name" => "source-org/conflict",
          "status" => "failed",
          "error" => "repository_conflict"
        },
        %{
          "source_full_name" => "source-org/waiting",
          "status" => "pending",
          "progress" => %{"phase" => "release_assets", "completed" => 12, "total" => 30}
        }
      ]
    })

    for suffix <- ["", "/repositories"] do
      html =
        request(c.owner)
        |> get(c.path <> suffix)
        |> html_response(200)
        |> String.replace(~r/\s+/, " ")

      assert html =~ "Repositories: 3"
      assert html =~ "Succeeded: 1"
      assert html =~ "Failed: 1"
      assert html =~ "Pending: 1"
      assert html =~ "source-org/done"
      assert html =~ "source-org/conflict"
      assert html =~ "source-org/waiting"
      assert html =~ "Release assets: 12 / 30 downloaded."
      assert html =~ ~s(data-pat-sync-poll="true")
      assert html =~ "Existing repository conflicts with this GitHub source."
    end
  end

  test "repository reports explain pending provider and LFS failures", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{"github_organization" => "source-org", "enabled" => "false", "lock_version" => "1"},
        %{}
      )

    for {error, message} <- [
          {"request_gate_busy", "Waiting for another GitHub request using this PAT."},
          {"response_too_large", "The GitHub response exceeded the 200 MiB limit."},
          {"scan_work_limit", "Git object scanning reached its work limit."},
          {"label_normalization_conflict",
           "GitHub label metadata conflicts with an imported label."},
          {"persistence_unavailable", "Repository metadata could not be saved."},
          {"corrupt_repository", "Git object integrity verification failed."}
        ] do
      task(config, c, "running", %{
        "total" => 1,
        "succeeded" => 0,
        "failed" => 0,
        "pending" => 1,
        "repositories" => [
          %{"source_full_name" => "source-org/waiting", "status" => "pending", "error" => error}
        ]
      })

      html = request(c.owner) |> get(c.path <> "/repositories") |> html_response(200)
      assert html =~ message
    end
  end

  test "job failures explain a failed synchronization before repositories are listed", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{"github_organization" => "source-org", "enabled" => "false", "lock_version" => "1"},
        %{}
      )

    for {error, message} <- [
          {"credential_unavailable", "The saved owner credential is unavailable."},
          {"configuration_changed", "The GitHub source or PAT configuration changed."},
          {"lost_lease", "Synchronization was interrupted."}
        ] do
      task(config, c, "failed", %{
        "total" => 0,
        "succeeded" => 0,
        "failed" => 0,
        "pending" => 0,
        "repositories" => [],
        "error" => error
      })

      for suffix <- ["", "/repositories"] do
        html = request(c.owner) |> get(c.path <> suffix) |> html_response(200)
        assert html =~ "Synchronization could not finish."
        assert html =~ message
      end
    end
  end

  test "sync redirects to identified task and repeated submission attaches the same task", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{
          "github_organization" => "source-org",
          "enabled" => "true",
          "lock_version" => "1",
          "owner_user_id" => to_string(c.owner.id),
          "github_identity_id" => to_string(c.account.identity_id)
        },
        %{}
      )

    params = %{"pat_sync" => %{"lock_version" => to_string(config.lock_version)}}
    conn = request(c.owner) |> post(c.path <> "/sync", params)
    destination = redirected_to(conn, 303)
    assert String.starts_with?(destination, c.path <> "/runs/")

    assert request(c.owner) |> post(c.path <> "/sync", params) |> redirected_to(303) ==
             destination

    assert request(c.owner) |> get(destination) |> html_response(200) =~
             "The task has been accepted."
  end

  test "queued task starts polling with zero repositories and ignores cached configuration status",
       c do
    config = configuration(c)

    config
    |> Ecto.Changeset.change(
      last_sync_status: "succeeded",
      last_sync_summary: %{"error" => "stale_cache"}
    )
    |> Repo.update!()

    run = task(config, c, "queued", %{"repositories" => []})
    html = request(c.owner) |> get(c.path <> "/runs/#{run.id}") |> html_response(200)
    assert html =~ "Synchronization ##{run.id}: queued"
    assert html =~ "Waiting for repository discovery"
    assert html =~ ~s(data-pat-sync-poll="true")
    assert html =~ c.path <> "/runs/#{run.id}/status"
    assert html =~ "Existing repositories refresh Git references and LFS only"
    refute html =~ "stale_cache"

    for suffix <- ["", "/repositories"] do
      page = request(c.owner) |> get(c.path <> suffix) |> html_response(200)
      assert page =~ "Synchronization ##{run.id}: queued"
      refute page =~ "stale_cache"
    end

    status =
      request(c.owner)
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> get(c.path <> "/runs/#{run.id}/status")
      |> json_response(200)

    assert status["run"]["status"] == "queued"
    assert status["run"]["total"] == 0
    assert status["run"]["terminal"] == false
    assert status["html"] =~ "Synchronization ##{run.id}: queued"
  end

  test "repository retry timing comes from its queue delivery and completed delivery is not task success",
       c do
    run = task(configuration(c), c, "running", %{"repositories" => []})

    result =
      Repo.insert!(%ForgeImports.PatSyncRepositoryResult{
        pat_sync_run_id: run.id,
        item_key: "update-1",
        state: "pending",
        data: %{
          "mode" => "update",
          "source_full_name" => "source-org/retrying",
          "status" => "pending",
          "error" => "request_gate_busy"
        }
      })

    {:ok, delivery} =
      Styx.insert(ForgeImports.SyncJobs.PatRepositoryWorker.new(%{"result_id" => result.id}))

    next = DateTime.add(DateTime.utc_now(), 60)

    delivery
    |> Ecto.Changeset.change(state: "retryable", attempt: 2, scheduled_at: next)
    |> Repo.update!()

    {:ok, view} = ForgeImports.PatSyncQueries.get_run(c.owner, c.org.id, run.id)
    [repository] = view["repositories"]
    assert repository["attempts"] == 2
    assert repository["max_attempts"] == delivery.max_attempts
    {:ok, scheduled, _} = DateTime.from_iso8601(repository["next_attempt_at"])
    assert DateTime.compare(scheduled, next) == :eq
    assert repository["status"] == "pending"
    html = request(c.owner) |> get(c.path <> "/runs/#{run.id}") |> html_response(200)
    assert html =~ "Next attempt:"
    assert html =~ "Delivery attempts: 2"

    Repo.get!(Styx.Job, delivery.id)
    |> Ecto.Changeset.change(state: "completed")
    |> Repo.update!()

    {:ok, view} = ForgeImports.PatSyncQueries.get_run(c.owner, c.org.id, run.id)
    assert view["status"] == "running"
    assert view["succeeded"] == 0
    assert view["terminal"] == false
    assert hd(view["repositories"])["execution_state"] == "completed"
  end

  test "terminal task and history remain visible and credential-free", c do
    config = configuration(c)

    run =
      task(config, c, "failed", %{
        "error" => "retry_exhausted",
        "repositories" => [
          %{
            "source_full_name" => "source-org/repo",
            "mode" => "update",
            "status" => "failed",
            "error" => "invalid_response",
            "token" => "ghp_secret",
            "progress" => %{"phase" => "ghp_secret", "token" => "ghp_secret"}
          }
        ]
      })

    status =
      request(c.owner)
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> get(c.path <> "/runs/#{run.id}/status")
      |> json_response(200)

    assert status["run"]["terminal"]
    assert status["run"]["failed"] == 1
    assert hd(status["run"]["repositories"])["attempts"] == nil
    assert status["html"] =~ "Delivery attempts: Unavailable"
    assert status["html"] =~ ~s(data-pat-sync-poll="false")
    assert status["html"] =~ "retry budget"
    assert status["html"] =~ "synchronize again"
    refute Jason.encode!(status) =~ "ghp_secret"
    html = request(c.owner) |> get(c.path <> "/runs") |> html_response(200)
    assert html =~ "Synchronization history"
    assert html =~ c.path <> "/runs/#{run.id}"
  end

  test "history, task and JSON enforce organization ownership and unauthenticated JSON is explicit",
       c do
    run = task(configuration(c), c, "queued", %{"repositories" => []})

    for suffix <- ["/runs", "/runs/#{run.id}"] do
      assert request(c.outsider) |> get(c.path <> suffix) |> response(404)
    end

    assert request(c.outsider)
           |> Plug.Conn.put_req_header("accept", "application/json")
           |> get(c.path <> "/runs/#{run.id}/status")
           |> json_response(404) == %{"error" => "not_found"}

    {:ok, other} =
      ForgeAccounts.create_organization(c.owner, %{username: "other-pat-#{c.owner.id}"})

    other_path = "/organizations/#{other.username}/settings/github/runs/#{run.id}"
    assert request(c.owner) |> get(other_path) |> response(404)
    co_owner = user()
    {:ok, _} = ForgeAccounts.add_organization_member(c.org, co_owner, :owner)

    assert request(co_owner) |> get(c.path <> "/runs/#{run.id}") |> html_response(200) =~
             "Synchronization ##{run.id}"

    co_owner_status =
      request(co_owner)
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> get(c.path <> "/runs/#{run.id}/status")
      |> json_response(200)

    assert co_owner_status["run"]["id"] == run.id

    assert build_conn()
           |> Plug.Conn.put_req_header("user-agent", "pat-settings-test")
           |> Plug.Conn.put_req_header("accept", "application/json")
           |> get(c.path <> "/runs/#{run.id}/status")
           |> json_response(401) == %{"error" => "login_required"}
  end

  test "paused configuration projects active waiting without overriding terminal results", c do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{
          "github_organization" => "source-org",
          "enabled" => "true",
          "lock_version" => "1",
          "owner_user_id" => to_string(c.owner.id),
          "github_identity_id" => to_string(c.account.identity_id)
        },
        %{}
      )

    run = task(config, c, "running", %{"repositories" => []})
    {:ok, _} = ForgeMirrors.PatSettings.set_paused(c.owner, c.org.id, true, %{})
    {:ok, active} = ForgeImports.PatSyncQueries.get_run(c.owner, c.org.id, run.id)
    assert active["status"] == "running"
    assert active["wait_reason"] == "paused"

    assert request(c.owner) |> get(c.path <> "/runs/#{run.id}") |> html_response(200) =~
             "Waiting: paused"

    run
    |> Ecto.Changeset.change(state: "succeeded", finished_at: DateTime.utc_now(:second))
    |> Repo.update!()

    {:ok, finished} = ForgeImports.PatSyncQueries.get_run(c.owner, c.org.id, run.id)
    assert finished["status"] == "succeeded"
    assert finished["wait_reason"] == nil
  end

  test "configuration check failures redirect to canonical GET and survive once", c do
    conn = request(c.owner) |> post(c.path <> "/pat/check", %{})
    assert redirected_to(conn, 303) == c.path
    follow = conn |> recycle() |> get(c.path)
    assert html_response(follow, 200) =~ "Configuration check failed"

    assert follow
           |> recycle()
           |> get(c.path)
           |> html_response(200)
           |> then(&(not String.contains?(&1, "Configuration check failed")))
  end

  defp configuration(c) do
    {:ok, config} =
      ForgeMirrors.PatSettings.save(
        c.owner,
        c.org.id,
        %{"github_organization" => "source-org", "enabled" => "false", "lock_version" => "1"},
        %{}
      )

    config
  end

  defp task(config, c, state, summary) do
    import Ecto.Query

    Repo.update_all(
      from(r in ForgeImports.PatSyncRun,
        where: r.configuration_id == ^config.id and r.state in ["queued", "running"]
      ),
      set: [state: "failed", finished_at: DateTime.utc_now(:second)]
    )

    progress =
      summary["repositories"]
      |> Enum.with_index(1)
      |> Map.new(fn {row, id} -> {to_string(id), row} end)

    Repo.insert!(%ForgeImports.PatSyncRun{
      configuration_id: config.id,
      organization_id: config.organization_id,
      owner_user_id: c.owner.id,
      github_identity_id: c.account.identity_id,
      github_organization: config.github_organization,
      state: state,
      progress: progress,
      error: summary["error"],
      finished_at: if(state in ["queued", "running"], do: nil, else: DateTime.utc_now(:second))
    })
  end

  defp request(user),
    do:
      build_conn()
      |> Plug.Conn.put_req_header("user-agent", "pat-settings-test")
      |> Plug.Test.init_test_session(%{user_id: user.id})

  defp user do
    n = System.unique_integer([:positive, :monotonic])

    Repo.insert!(%User{
      username: "patuser#{n}",
      email: "pat#{n}@test.local",
      password_hash: "unused",
      kind: :user,
      role: :user,
      state: :active
    })
  end
end
