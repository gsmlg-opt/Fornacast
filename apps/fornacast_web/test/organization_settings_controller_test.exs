defmodule FornacastWeb.OrganizationSettingsControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  require Ecto.Query

  alias ForgeAccounts.{Organization, User}
  alias Fornacast.{AuditEvent, Repo}

  @endpoint FornacastWeb.Endpoint

  defmodule TestOrganizationSync do
    def reset do
      Process.put({__MODULE__, :calls}, [])
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def get_settings(actor, organization) do
      Process.put(
        {__MODULE__, :calls},
        [{:get_settings, [actor, organization]} | Process.get({__MODULE__, :calls}, [])]
      )

      {:error, :unavailable}
    end
  end

  setup do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    TestOrganizationSync.reset()

    owner = user_fixture("organization-general-owner")
    admin = user_fixture("organization-general-admin", :admin)
    member = user_fixture("organization-general-member")
    outsider = user_fixture("organization-general-outsider")

    assert {:ok, organization} =
             ForgeAccounts.create_organization(owner, %{
               username: unique("organization-general"),
               display_name: "Acme Engineering",
               description: "Compiler tools"
             })

    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)

    %{owner: owner, admin: admin, member: member, outsider: outsider, organization: organization}
  end

  test "the canonical General route is a PATCH before dynamic routes" do
    assert %{plug: FornacastWeb.OrganizationSettingsController, plug_opts: :update} =
             Phoenix.Router.route_info(
               FornacastWeb.Router,
               "PATCH",
               "/organizations/acme/settings",
               "localhost"
             )
  end

  test "owners and site administrators render General without a sync facade call", %{
    owner: owner,
    admin: admin,
    organization: organization
  } do
    for actor <- [owner, admin] do
      TestOrganizationSync.reset()
      conn = request_conn(actor) |> get(settings_path(organization))
      html = html_response(conn, 200)

      assert html =~ "General"
      assert html =~ ~s(name="organization[name]")
      assert html =~ ~s(name="organization[description]")
      assert html =~ organization.username
      assert html =~ ~s(href="/#{organization.username}")
      assert html =~ ~s(href="/organizations/#{organization.username}/settings/github")
      refute html =~ "People"
      refute html =~ "Teams"
      refute html =~ "Permissions"
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end
  end

  test "a valid save persists selected profile fields and records the actor metadata", %{
    owner: owner,
    organization: organization
  } do
    conn =
      request_conn(owner)
      |> patch(settings_path(organization), %{
        "organization" => %{
          "name" => "  Acme Platform  ",
          "description" => "  Build and release tooling  ",
          "username" => "forged-slug",
          "role" => "admin"
        }
      })

    assert redirected_to(conn, 303) == settings_path(organization)
    assert_private_no_store(conn)
    assert TestOrganizationSync.calls() == []

    saved = conn |> recycle_request() |> get(settings_path(organization))
    assert html_response(saved, 200) =~ "Organization settings saved."
    assert TestOrganizationSync.calls() == []

    updated = Repo.get!(Organization, organization.id)
    assert updated.display_name == "Acme Platform"
    assert updated.description == "Build and release tooling"
    assert updated.username == organization.username

    audit =
      AuditEvent
      |> Ecto.Query.where([event], event.action == "organization.updated")
      |> Ecto.Query.order_by([event], desc: event.id)
      |> Ecto.Query.limit(1)
      |> Repo.one!()

    assert audit.actor_user_id == owner.id
    assert audit.target_id == Integer.to_string(organization.id)
    assert audit.metadata["login"] == organization.username
    assert audit.metadata["result"] == "success"
    assert audit.user_agent == "organization-settings-controller-test"
  end

  test "invalid names and descriptions return 422 with escaped submitted input and no mutation",
       %{
         owner: owner,
         organization: organization
       } do
    unsafe_name = "<script>alert(1)</script>"

    conn =
      request_conn(owner)
      |> patch(settings_path(organization), %{
        "organization" => %{
          "name" => unsafe_name,
          "description" => String.duplicate("x", 501)
        }
      })

    html = html_response(conn, 422)
    assert html =~ "Description is invalid"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ unsafe_name
    assert Repo.get!(Organization, organization.id).display_name == "Acme Engineering"
    assert_private_no_store(conn)
  end

  test "non-string, overlong, and NUL field values return 422 without changes", %{
    owner: owner,
    organization: organization
  } do
    invalid_params = [
      %{"organization" => %{"name" => %{value: "Acme"}}},
      %{"organization" => %{"name" => String.duplicate("x", 121)}},
      %{"organization" => %{"description" => "bad\0description"}}
    ]

    for params <- invalid_params do
      conn = request_conn(owner) |> patch(settings_path(organization), params)
      assert html_response(conn, 422) =~ "is invalid"
      assert Repo.get!(Organization, organization.id).display_name == "Acme Engineering"
      assert_private_no_store(conn)
    end
  end

  test "malformed General payloads return 400", %{owner: owner, organization: organization} do
    for params <- [%{}, %{"organization" => "not-a-map"}] do
      conn = request_conn(owner) |> patch(settings_path(organization), params)
      assert html_response(conn, 400) =~ "Organization settings request is invalid."
      assert_private_no_store(conn)
    end
  end

  test "members, outsiders, and missing organizations remain masked", %{
    member: member,
    outsider: outsider,
    organization: organization
  } do
    for {actor, path} <- [
          {member, settings_path(organization)},
          {outsider, settings_path(organization)},
          {outsider, "/organizations/#{unique("missing")}/settings"}
        ] do
      conn = request_conn(actor) |> patch(path, %{"organization" => %{"name" => "Nope"}})
      assert html_response(conn, 404) =~ "Organization settings not found."
      assert_private_no_store(conn)
    end
  end

  test "General requires login and rejects a production CSRF-less save", %{
    owner: owner,
    organization: organization
  } do
    anonymous = request_conn(nil) |> get(settings_path(organization))
    assert redirected_to(anonymous) == "/login"
    assert_private_no_store(anonymous)

    assert_error_sent 403, fn ->
      request_conn(owner)
      |> with_production_csrf()
      |> patch(settings_path(organization), %{"organization" => %{"name" => "Nope"}})
    end
  end

  defp request_conn(user) do
    session = if user, do: [user_id: user.id], else: []

    build_conn()
    |> put_req_header("user-agent", "organization-settings-controller-test")
    |> Plug.Conn.put_private(:github_organization_sync, TestOrganizationSync)
    |> Plug.Test.init_test_session(session)
  end

  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp recycle_request(conn) do
    conn
    |> recycle()
    |> put_req_header("user-agent", "organization-settings-controller-test")
    |> Plug.Conn.put_private(:github_organization_sync, TestOrganizationSync)
  end

  defp settings_path(organization), do: "/organizations/#{organization.username}/settings"

  defp user_fixture(prefix, role \\ :user) do
    value = unique(prefix)

    Repo.insert!(%User{
      username: value,
      email: "#{value}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: role,
      state: :active
    })
  end

  defp unique(prefix) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{prefix}-#{suffix}"
  end

  defp assert_private_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
