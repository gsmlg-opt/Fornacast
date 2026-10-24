defmodule FornacastWeb.OrganizationPublicSyncControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  alias Fornacast.Repo
  @endpoint FornacastWeb.Endpoint

  defmodule PublicSync do
    def view(_actor, id),
      do: {:ok, %{organization: ForgeAccounts.get_organization(id), config: config()}}

    def configure(actor, id, attrs, metadata) do
      send(self(), {:public_configuration, actor.id, id, attrs, metadata})

      case Process.get(:public_web_error) do
        nil -> {:ok, config()}
        :database -> raise DBConnection.ConnectionError, "private db detail"
        reason -> {:error, reason}
      end
    end

    def sync(actor, id, version, _metadata) do
      send(self(), {:public_sync, actor.id, id, version})
      {:ok, %ForgeImports.PatSyncRun{id: 77}}
    end

    defp config,
      do:
        Process.get(:public_web_config, %ForgeMirrors.PatConfiguration{
          credential_source: :public,
          github_organization: "octo-org"
        })
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    owner = user()
    outsider = user()

    {:ok, organization} =
      ForgeAccounts.create_organization(owner, %{username: "public-settings-#{owner.id}"})

    %{
      owner: owner,
      outsider: outsider,
      organization: organization,
      path: "/organizations/#{organization.username}/settings/github/public"
    }
  end

  test "public configuration has no personal credential fields and does not start work on GET",
       c do
    html = request(c.owner) |> get(c.path) |> html_response(200)
    assert html =~ "Public repository synchronization"
    assert html =~ ~s(name="public_sync[github_organization]")
    assert html =~ ~s(name="public_sync[lock_version]" value="0")
    refute html =~ "github_identity_id"
    refute html =~ ~s(type="password")
    refute_received {:public_configuration, _, _, _, _}
    refute_received {:public_sync, _, _, _}
  end

  test "save configures a versioned public source without starting synchronization", c do
    conn =
      request(c.owner)
      |> patch(c.path, %{
        "public_sync" => %{"github_organization" => "octo-org", "lock_version" => "0"}
      })

    assert redirected_to(conn, 303) == c.path

    assert_receive {:public_configuration, _, _,
                    %{"github_organization" => "octo-org", "lock_version" => "0"}, _}

    refute_received {:public_sync, _, _, _}
  end

  test "configured public source offers an explicit sync that opens the existing task page", c do
    Process.put(:public_web_config, %ForgeMirrors.PatConfiguration{
      id: 9,
      credential_source: :public,
      github_organization: "octo-org",
      lock_version: 4,
      enabled: true
    })

    html = request(c.owner) |> get(c.path) |> html_response(200)
    assert html =~ "Synchronize now"

    conn =
      request(c.owner) |> post(c.path <> "/sync", %{"public_sync" => %{"lock_version" => "4"}})

    assert redirected_to(conn, 303) ==
             "/organizations/#{c.organization.username}/settings/github/runs/77"

    assert_receive {:public_sync, _, _, "4"}
  end

  test "public settings reject foreign organization access and mixed credential fields", c do
    assert request(c.outsider) |> get(c.path) |> response(404)

    for {method, suffix} <- [{:patch, ""}, {:post, "/sync"}] do
      assert request(c.outsider) |> send_request(method, c.path <> suffix, %{}) |> response(404)
    end

    assert request(c.owner)
           |> patch(c.path, %{
             "public_sync" => %{
               "github_organization" => "octo-org",
               "lock_version" => "0",
               "github_identity_id" => "12"
             }
           })
           |> response(422)

    refute_received {:public_configuration, _, _, _, _}
  end

  test "typed anonymous limits and database errors render safe recoverable feedback", c do
    for reason <- [:primary_rate_limit, :secondary_rate_limit] do
      Process.put(:public_web_error, reason)

      conn =
        request(c.owner)
        |> patch(c.path, %{
          "public_sync" => %{"github_organization" => "octo-org", "lock_version" => "0"}
        })

      assert html_response(conn, 429) =~ "anonymous API rate limit"
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    Process.put(:public_web_error, :database)

    conn =
      request(c.owner)
      |> patch(c.path, %{
        "public_sync" => %{"github_organization" => "octo-org", "lock_version" => "0"}
      })

    html = html_response(conn, 503)
    assert html =~ "temporarily unavailable"
    refute html =~ "private db detail"
  end

  defp send_request(conn, :patch, path, params), do: patch(conn, path, params)
  defp send_request(conn, :post, path, params), do: post(conn, path, params)

  defp request(actor),
    do:
      build_conn()
      |> Plug.Test.init_test_session(user_id: actor.id)
      |> Plug.Conn.put_private(:organization_public_sync, PublicSync)

  defp user do
    id = System.unique_integer([:positive])

    Repo.insert!(%ForgeAccounts.User{
      username: "public-settings-user-#{id}",
      email: "public-settings-user-#{id}@example.test",
      password_hash: "unused",
      kind: :user,
      role: :user,
      state: :active
    })
  end
end
