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

    assert request(c.outsider) |> post(c.path <> "/repositories/refresh", %{}) |> response(404)
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
