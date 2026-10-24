defmodule FornacastWeb.GitHubDeviceControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ForgeAccounts.User
  alias ForgeGitHub.DeviceFlow
  alias Fornacast.Repo
  alias FornacastWeb.GitHubDeviceSession

  @endpoint FornacastWeb.Endpoint

  defmodule Provider do
    def client_id, do: "Iv23lizCVE3E24s7fCA0"

    def start(_opts) do
      Process.put(:device_start_count, Process.get(:device_start_count, 0) + 1)

      Process.get(
        :device_start_result,
        {:ok,
         %DeviceFlow.Authorization{
           device_code: "private-device-code",
           user_code: "ABCD-EFGH",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 1
         }}
      )
    end

    def poll(_code, _opts) do
      Process.put(:device_poll_count, Process.get(:device_poll_count, 0) + 1)
      if hook = Process.get(:device_poll_hook), do: hook.()

      Process.get(
        :device_poll_result,
        {:ok,
         %DeviceFlow.Token{
           client_id: client_id(),
           access_token: "private-access-token",
           refresh_token: "private-refresh-token",
           expires_at: DateTime.add(DateTime.utc_now(), 28_800),
           refresh_expires_at: DateTime.add(DateTime.utc_now(), 15_897_600)
         }}
      )
    end
  end

  defmodule Imports do
    def list_github_accounts(_actor) do
      accounts =
        if Process.get(:device_linked) do
          [
            %ForgeAccounts.GitHubAccountView{
              identity_id: 41,
              github_user_id: 90_041,
              login: "octocat",
              display_name: "Github:octocat",
              credential_present: true,
              credential_status: :valid,
              credential_kind: :github_app_user,
              reconnect_required: false
            }
          ]
        else
          []
        end

      {:ok, accounts}
    end

    def link_github_device_account(actor, token, _metadata, references, opts) do
      Process.put(:device_linked, {actor.id, token.client_id, references})

      case Keyword.fetch!(opts, :before_save).() do
        :ok -> {:ok, :linked}
        error -> error
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    actor =
      Repo.insert!(%User{
        username: "device-#{suffix}",
        email: "device-#{suffix}@example.test",
        password_hash: "not-used",
        kind: :user,
        role: :user,
        state: :active
      })

    %{actor: actor}
  end

  test "settings link to separate Device Flow and PAT configuration pages", %{actor: actor} do
    conn = request(actor) |> get("/settings/github")
    html = html_response(conn, 200)
    assert html =~ "Connect with GitHub"
    assert html =~ "Link GitHub account"
    assert html =~ ~s(href="/settings/github/device")
    assert html =~ ~s(href="/settings/github/link")
    refute html =~ ~s(action="/settings/github/device")
    refute html =~ ~s(name="github_account[pat]")
  end

  test "start and completion expose only safe browser data and consume authorization once", %{
    actor: actor
  } do
    started = request(actor) |> post("/settings/github/device", %{})
    assert redirected_to(started, 303) == "/settings/github/device/legacy"
    attempt = GitHubDeviceSession.view(started)
    page = started |> next_request() |> get("/settings/github/device/legacy")
    assert html_response(page, 200) =~ "ABCD-EFGH"
    refute html_response(page, 200) =~ "private-device-code"
    refute html_response(page, 200) =~ ~s(id="github-device-success")
    refute inspect(get_session(started)) =~ "private-device-code"
    assert get_resp_header(page, "cache-control") == ["private, no-store"]

    main_html = started |> next_request() |> get("/settings/github") |> html_response(200)
    refute main_html =~ "ABCD-EFGH"
    refute main_html =~ ~s(data-github-device-poll="true")

    early = poll(started, attempt.id)
    assert %{"status" => "pending"} = json_response(early, 200)
    assert Process.get(:device_poll_count, 0) == 0
    Process.sleep(1_010)

    complete = poll(early, attempt.id)

    assert %{"status" => "complete", "redirect" => "/settings/github"} =
             json_response(complete, 200)

    assert {actor_id, "Iv23lizCVE3E24s7fCA0", []} = Process.get(:device_linked)
    assert actor_id == actor.id
    assert Process.get(:device_poll_count) == 1
    assert %{"status" => "complete"} = complete |> poll(attempt.id) |> json_response(200)
    assert Process.get(:device_poll_count) == 1

    completed_page =
      complete
      |> next_request()
      |> put_req_header("accept", "text/html")
      |> get("/settings/github")

    completed_html = html_response(completed_page, 200)
    assert completed_html =~ ~s(id="github-saved-connections")
    assert completed_html =~ "@octocat"
    assert completed_html =~ "GitHub App connected"
    assert completed_html =~ "configured in organization settings"
    assert completed_html =~ "Existing personal credentials remain available for legacy imports"
    assert completed_html =~ ~s(href="/settings/github/device")
    assert completed_html =~ ~s(href="/settings/github/link")
    refute completed_html =~ ~s(action="/settings/github/device")
    refute completed_html =~ ~s(id="github-link-account")
    refute completed_html =~ ~s(data-github-device-poll="true")

    for secret <- ["private-device-code", "private-access-token", "private-refresh-token"] do
      refute inspect({complete.resp_headers, complete.resp_body, get_session(complete)}) =~ secret
      refute completed_html =~ secret
    end

    assert get_resp_header(complete, "cache-control") == ["private, no-store"]
  end

  test "another browser session and cancelled attempts cannot exchange a code", %{actor: actor} do
    started = request(actor) |> post("/settings/github/device", %{})
    attempt = GitHubDeviceSession.view(started)

    foreign =
      request(actor)
      |> put_req_header("accept", "application/json")
      |> post("/settings/github/device/#{attempt.id}/poll", %{})

    assert json_response(foreign, 404)["status"] == "failed"

    cancelled =
      started |> next_request() |> post("/settings/github/device/#{attempt.id}/cancel", %{})

    assert redirected_to(cancelled, 303) == "/settings/github"
    assert json_response(poll(cancelled, attempt.id), 404)["status"] == "failed"
    assert Process.get(:device_poll_count, 0) == 0
  end

  test "disabled Device Flow explains the GitHub App setting", %{actor: actor} do
    Process.put(:device_start_result, {:error, :device_flow_disabled})
    started = request(actor) |> post("/settings/github/device", %{})
    assert redirected_to(started, 303) == "/settings/github/device/legacy"

    html =
      started |> next_request() |> get("/settings/github/device/legacy") |> html_response(200)

    assert html =~ "Enable Device Flow in the GitHub App settings"
    refute html =~ "private-device-code"
    refute html =~ ~s(id="github-device-success")
  end

  test "start requires authentication and CSRF protection", %{actor: actor} do
    anonymous = request(nil) |> post("/settings/github/device", %{})
    assert redirected_to(anonymous) == "/login"

    for path <- [
          "/settings/github/device",
          "/settings/github/device/attempt/poll",
          "/settings/github/device/attempt/cancel"
        ] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn = request(actor) |> put_req_header("accept", "*/*")
        conn = %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
        post(conn, path, %{})
      end
    end

    assert Process.get(:device_start_count, 0) == 0
  end

  test "slow-down persists the longer server polling interval", %{actor: actor} do
    started = request(actor) |> post("/settings/github/device", %{})
    attempt = GitHubDeviceSession.view(started)
    Process.sleep(1_010)
    Process.put(:device_poll_result, {:error, {:slow_down, 10}})
    slowed = poll(started, attempt.id)
    assert %{"status" => "pending", "interval" => 10} = json_response(slowed, 200)
    assert %{"status" => "pending"} = slowed |> poll(attempt.id) |> json_response(200)
    assert Process.get(:device_poll_count) == 1
  end

  test "cancellation and logout during token exchange prevent linking", %{actor: actor} do
    for action <- [:cancel, :logout] do
      started = request(actor) |> post("/settings/github/device", %{})
      attempt = GitHubDeviceSession.view(started)
      Process.sleep(1_010)

      Process.put(:device_poll_hook, fn ->
        case action do
          :cancel ->
            GitHubDeviceSession.run(started, {:cancel, attempt.id})

          :logout ->
            logged_out = started |> next_request() |> delete("/logout")
            assert redirected_to(logged_out) == "/login"
        end
      end)

      conn = poll(started, attempt.id)
      assert json_response(conn, if(action == :cancel, do: 404, else: 422))["status"] == "failed"
      refute Process.get(:device_linked)
    end
  end

  defp request(actor) do
    conn = build_conn() |> put_req_header("user-agent", "device-flow-test") |> inject()
    if actor, do: Plug.Test.init_test_session(conn, user_id: actor.id), else: conn
  end

  defp next_request(conn), do: conn |> recycle() |> inject()

  defp inject(conn),
    do:
      conn
      |> put_private(:github_device_provider, Provider)
      |> put_private(:forge_imports, Imports)

  defp poll(conn, id),
    do:
      conn
      |> next_request()
      |> put_req_header("accept", "application/json")
      |> post("/settings/github/device/#{id}/poll", %{})
end
