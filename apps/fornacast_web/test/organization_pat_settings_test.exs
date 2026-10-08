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

    %{
      owner: owner,
      outsider: outsider,
      org: org,
      path: "/organizations/#{org.username}/settings/github"
    }
  end

  test "canonical tab shows owner PAT configuration and preserves separate App page", c do
    html = request(c.owner) |> get(c.path) |> html_response(200)
    assert html =~ "personal access token (PAT)"
    assert html =~ "run it manually and pause it at any time"
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
    assert html =~ "No owner PAT selected"

    assert request(c.owner) |> get(c.path <> "/repositories") |> html_response(200) =~
             "Refresh from GitHub"

    assert request(c.owner)
           |> patch(c.path <> "/pat", %{
             "pat_sync" => %{params | "enabled" => "true", "lock_version" => "2"}
           })
           |> html_response(422) =~ "valid saved PAT"
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

  test "repository page offers immediate all-repository synchronization separately from selection",
       c do
    html =
      request(c.owner)
      |> get(c.path <> "/repositories")
      |> html_response(200)
      |> String.replace(~r/\s+/, " ")

    assert html =~ "Sync now"
    assert html =~ c.path <> "/sync"
    assert html =~ "all PAT-visible repositories"
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

    config
    |> Ecto.Changeset.change(
      last_sync_status: "failed",
      last_sync_summary: %{
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
      }
    )
    |> Repo.update!()

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
      config
      |> Ecto.Changeset.change(
        last_sync_status: "running",
        last_sync_summary: %{
          "total" => 1,
          "succeeded" => 0,
          "failed" => 0,
          "pending" => 1,
          "repositories" => [
            %{"source_full_name" => "source-org/waiting", "status" => "pending", "error" => error}
          ]
        }
      )
      |> Repo.update!()

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
          {"credential_unavailable", "The saved owner PAT is unavailable."},
          {"configuration_changed", "The GitHub source or PAT configuration changed."},
          {"lost_lease", "Synchronization was interrupted."}
        ] do
      config
      |> Ecto.Changeset.change(
        last_sync_status: "failed",
        last_sync_summary: %{
          "total" => 0,
          "succeeded" => 0,
          "failed" => 0,
          "pending" => 0,
          "repositories" => [],
          "error" => error
        }
      )
      |> Repo.update!()

      for suffix <- ["", "/repositories"] do
        html = request(c.owner) |> get(c.path <> suffix) |> html_response(200)
        assert html =~ "Synchronization could not finish."
        assert html =~ message
      end
    end
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
