defmodule FornacastWeb.SetupWizardTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.reset!()
    on_exit(&Fornacast.Setup.reset!/0)
    :ok
  end

  test "uninitialized instance redirects browser routes to /setup" do
    conn = get(build_conn(), "/login")
    assert redirected_to(conn) == "/setup"
  end

  test "GET /setup renders the admin form" do
    conn = get(build_conn(), "/setup")
    body = html_response(conn, 200)
    assert body =~ "Create the first administrator"
    assert body =~ ~s(name="admin[username]")
  end

  test "POST /setup creates the admin, marks initialized, and unlocks routes" do
    conn =
      post_setup(%{
        "username" => "root",
        "email" => "root@example.com",
        "password" => "correct horse battery staple"
      })

    assert redirected_to(conn) == "/login"
    assert Fornacast.Setup.initialized?()
    assert ForgeAccounts.admin_exists?()

    login = get(build_conn(), "/login")
    assert html_response(login, 200) =~ "Login"
  end

  test "GET /setup returns 404 once initialized" do
    Fornacast.Setup.force_initialized!()
    conn = get(build_conn(), "/setup")
    assert html_response(conn, 404) =~ "already set up"
  end

  test "invalid submission re-renders the form with errors" do
    conn = post_setup(%{"username" => "", "email" => "", "password" => "short"})
    assert html_response(conn, 422) =~ "admin[username]"
  end

  # GET /setup to obtain a CSRF token, then POST it back with the session
  # cookie carried by recycle/1. protect_from_forgery is active on /setup.
  defp post_setup(admin_attrs) do
    get_conn = get(build_conn(), "/setup")
    token = extract_csrf_token(get_conn.resp_body)

    get_conn
    |> recycle()
    |> post("/setup", %{"_csrf_token" => token, "admin" => admin_attrs})
  end

  defp extract_csrf_token(html) do
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html)
    token
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          ["audit_events", "repository_collaborators", "repositories", "ssh_keys", "users"],
          &Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{&1}", [])
        )
    end
  end
end
