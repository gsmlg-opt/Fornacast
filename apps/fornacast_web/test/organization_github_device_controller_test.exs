defmodule FornacastWeb.OrganizationGitHubDeviceControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias ForgeAccounts.User
  alias Fornacast.Repo
  alias FornacastWeb.OrganizationGitHubDeviceSession, as: Session
  @endpoint FornacastWeb.Endpoint

  defmodule Provider do
    def client_id, do: ForgeGitHub.DeviceFlow.client_id()

    def start(_opts),
      do:
        {:ok,
         %ForgeGitHub.DeviceFlow.Authorization{
           device_code: "org-private-code",
           user_code: "ABCD-EFGH",
           verification_uri: "https://github.com/login/device",
           expires_in: 900,
           interval: 1
         }}

    def poll(_code, _opts) do
      Process.put(:org_polled, true)
      if hook = Process.get(:org_poll_hook), do: hook.()

      {:ok,
       %{
         client_id: client_id(),
         access_token: "org-private-access",
         refresh_token: "org-private-refresh"
       }}
    end
  end

  defmodule Service do
    def reference(_actor, organization_id),
      do:
        {:ok,
         %{
           organization_id: organization_id,
           connection_version: Process.get(:org_version, 0),
           credential: %{
             organization_id: organization_id,
             credential_id: nil,
             verification_version: nil,
             status: :absent
           }
         }}

    def view(actor, organization_id) do
      {:ok, reference} = reference(actor, organization_id)

      {:ok,
       Process.get(
         :org_view_override,
         %{
           connection: nil,
           credential: reference.credential,
           state: :disconnected,
           connection_version: reference.connection_version,
           installation_url: ForgeImports.OrganizationGitHubConnection.installation_url()
         }
       )}
    end

    def scope(_id), do: {:ok, Process.get(:org_scope)}

    def connect(actor, organization_id, _token, expected, _metadata, opts) do
      with true <- expected.connection_version == Process.get(:org_version, 0),
           :ok <- Keyword.fetch!(opts, :before_save).() do
        Process.put(:org_connected, {actor.id, organization_id, expected})
        {:ok, :installation_required}
      else
        false -> {:error, :stale}
        error -> error
      end
    end

    def installations(_, _, _), do: {:ok, []}

    def bind(_, organization_id, id, version, _, _) do
      Process.put(:org_bound, {organization_id, id, version})
      {:ok, :ready}
    end
  end

  defmodule SyncSettings do
    def activate_organization_connection(_, _, _, _, _) do
      Process.put(:org_activated, true)
      {:ok, :activated}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    actor =
      Repo.insert!(%User{
        username: "org-device-#{suffix}",
        email: "org-device-#{suffix}@example.test",
        password_hash: "unused",
        kind: :user,
        role: :user,
        state: :active
      })

    {:ok, organization} =
      ForgeAccounts.create_organization(actor, %{username: "org-flow-#{suffix}"})

    {:ok, other} = ForgeAccounts.create_organization(actor, %{username: "other-flow-#{suffix}"})
    %{actor: actor, organization: organization, other: other}
  end

  test "canonical overview is compact and app bookmark shows organization connection", ctx do
    for suffix <- ["", "/app", "/connection"] do
      html = request(ctx.actor) |> get(base(ctx.organization) <> suffix) |> html_response(200)
      assert html =~ "data-organization-github-connection"
      refute html =~ "Credential owner"
      refute html =~ "github_identity_id"
      refute html =~ "private-device"
    end

    conn = request(ctx.actor) |> get(base(ctx.organization))
    html = html_response(conn, 200)
    assert html =~ ~s(href="#{base(ctx.organization)}/connection")
    assert html =~ ~s(href="#{base(ctx.organization)}/legacy")
    refute html =~ ~s(action="#{base(ctx.organization)}/device")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "organization grant stays session-private and completion uses captured organization reference",
       ctx do
    started = request(ctx.actor) |> post(base(ctx.organization) <> "/device", %{})
    assert redirected_to(started, 303) == base(ctx.organization) <> "/connection"
    attempt = Session.view(started, ctx.organization.id)
    html = next(started) |> get(base(ctx.organization) <> "/connection") |> html_response(200)
    assert html =~ "ABCD-EFGH"

    assert html =~
             ~s(data-github-device-poll-path="#{base(ctx.organization)}/device/#{attempt.id}/poll")

    assert html =~ ~s(data-github-device-return-path="#{base(ctx.organization)}/connection")
    refute inspect({html, get_session(started)}) =~ "org-private-code"
    assert json_response(poll(started, ctx.other, attempt.id), 404)["status"] == "failed"

    assert json_response(poll(request(ctx.actor), ctx.organization, attempt.id), 404)["status"] ==
             "failed"

    assert json_response(poll(started, ctx.organization, attempt.id), 200)["status"] == "pending"
    refute Process.get(:org_polled)
    Process.sleep(1_010)
    complete = poll(started, ctx.organization, attempt.id)

    assert json_response(complete, 200) == %{
             "status" => "complete",
             "redirect" => base(ctx.organization) <> "/connection"
           }

    assert {actor_id, organization_id, %{organization_id: organization_id}} =
             Process.get(:org_connected)

    assert actor_id == ctx.actor.id
    assert organization_id == ctx.organization.id
    assert ForgeAccounts.list_github_accounts(ctx.actor) == {:ok, []}

    assert json_response(poll(complete, ctx.organization, attempt.id), 200)["status"] ==
             "complete"

    for secret <- ["org-private-code", "org-private-access", "org-private-refresh"] do
      refute inspect({complete.resp_headers, complete.resp_body, get_session(complete)}) =~ secret
    end

    assert get_resp_header(complete, "cache-control") == ["private, no-store"]
  end

  test "supersession cancellation and changed organization reference reject late grants", ctx do
    for action <- [:supersede, :cancel, :changed, :logout] do
      Process.delete(:org_connected)
      Process.delete(:org_version)
      started = request(ctx.actor) |> post(base(ctx.organization) <> "/device", %{})
      attempt = Session.view(started, ctx.organization.id)
      Process.sleep(1_010)

      Process.put(:org_poll_hook, fn ->
        case action do
          :supersede -> Session.run(started, ctx.organization.id, :begin)
          :cancel -> Session.run(started, ctx.organization.id, {:cancel, attempt.id})
          :changed -> Process.put(:org_version, 1)
          :logout -> next(started) |> delete("/logout")
        end
      end)

      failed = poll(started, ctx.organization, attempt.id)
      assert failed.status in [404, 422]
      assert Jason.decode!(failed.resp_body)["status"] == "failed"
      refute Process.get(:org_connected)
    end
  end

  test "membership removal denies polling before provider access and binds never run from GET",
       ctx do
    started = request(ctx.actor) |> post(base(ctx.organization) <> "/device", %{})
    attempt = Session.view(started, ctx.organization.id)
    import Ecto.Query

    Repo.delete_all(
      from member in ForgeAccounts.OrganizationMember,
        where: member.organization_id == ^ctx.organization.id and member.user_id == ^ctx.actor.id
    )

    assert json_response(poll(started, ctx.organization, attempt.id), 404)["status"] == "failed"
    refute Process.get(:org_polled)
    refute Process.get(:org_bound)
  end

  test "organization mutation routes require CSRF and anonymous poll returns safe JSON", ctx do
    for suffix <- [
          "/device",
          "/device/attempt/poll",
          "/device/attempt/cancel",
          "/connection/bind",
          "/connection/activate",
          "/connection/disconnect"
        ] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn = request(ctx.actor) |> put_req_header("accept", "*/*")
        conn = %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
        post(conn, base(ctx.organization) <> suffix, %{})
      end
    end

    anonymous =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post(base(ctx.organization) <> "/device/attempt/poll", %{})

    assert json_response(anonymous, 404)["status"] == "failed"
  end

  test "activation rejects a connection rechecked between view and scope capture", ctx do
    Process.put(:org_view_override, %{state: :ready, connection_version: 1, connection: %{id: 70}})

    Process.put(:org_scope, %{connection_version: 2, organization_id: ctx.organization.id})

    conn =
      request(ctx.actor)
      |> put_private(:organization_github_sync_settings, SyncSettings)
      |> post(base(ctx.organization) <> "/connection/activate", %{
        "connection" => %{"connection_version" => "1", "config_version" => "1"}
      })

    assert html_response(conn, 404) =~ "connection or authorization changed"
    refute Process.get(:org_activated)
  end

  test "personal connect navigation chooses an organization", ctx do
    html = request(ctx.actor) |> get("/settings/github/device") |> html_response(200)
    assert html =~ "Choose an organization"
    assert html =~ ~s(href="#{base(ctx.organization)}/connection")
    refute html =~ ~s(action="/settings/github/device")
  end

  defp base(organization), do: "/organizations/#{organization.username}/settings/github"

  defp request(actor),
    do:
      build_conn()
      |> put_req_header("user-agent", "org-device-test")
      |> Plug.Test.init_test_session(user_id: actor.id)
      |> inject()

  defp next(conn), do: conn |> recycle() |> inject()

  defp inject(conn),
    do:
      conn
      |> put_private(:github_device_provider, Provider)
      |> put_private(:organization_github_connection, Service)

  defp poll(conn, organization, id),
    do:
      next(conn)
      |> put_req_header("accept", "application/json")
      |> post(base(organization) <> "/device/#{id}/poll", %{})
end
