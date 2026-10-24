defmodule FornacastWeb.OrganizationImportControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias ForgeAccounts.User
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint

  defmodule Imports do
    def create_organization_discovery(actor, attrs, metadata) do
      send(self(), {:public_discovery, actor.id, attrs, metadata})

      case Process.get(:organization_discovery_error) do
        nil -> {:ok, %ForgeImports.RunView{id: 91, actor_user_id: actor.id}}
        :database -> raise DBConnection.ConnectionError, "private database detail"
        reason -> {:error, reason}
      end
    end

    def list_github_accounts(_actor),
      do: raise("Public onboarding must not load personal credentials")
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    actor = user()
    outsider = user()

    {:ok, owned} =
      ForgeAccounts.create_organization(actor, %{username: "public-owned-#{actor.id}"})

    {:ok, foreign} =
      ForgeAccounts.create_organization(outsider, %{username: "public-other-#{outsider.id}"})

    %{actor: actor, owned: owned, foreign: foreign}
  end

  test "chooser offers public and App entrypoints without personal credential fields", c do
    conn = request(c.actor) |> get("/organizations/import")
    html = html_response(conn, 200)
    assert html =~ ~s(href="/organizations/import/public")
    assert html =~ ~s(href="/organizations/import/app")
    refute html =~ ~s(name="import[github_identity_id]")
    refute html =~ ~s(name="import[pat]")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "public destination forms submit one branch and remain usable without JavaScript", c do
    new_html = request(c.actor) |> get("/organizations/import/public") |> html_response(200)
    assert new_html =~ ~s(action="/organizations/import/public" method="post")
    assert new_html =~ ~s(name="import[organization]")
    assert new_html =~ ~s(name="import[destination_slug]")
    refute new_html =~ ~s(name="import[destination_organization_id]")
    refute new_html =~ ~s(name="import[pat]")

    existing_html =
      request(c.actor)
      |> get("/organizations/import/public?destination=existing")
      |> html_response(200)

    assert existing_html =~ c.owned.username
    refute existing_html =~ c.foreign.username
    assert existing_html =~ ~s(name="import[destination_organization_id]")
    refute existing_html =~ ~s(name="import[destination_slug]")
    assert existing_html =~ ~s(name="_csrf_token")
  end

  test "public discovery admits an owned destination without any credential parameters", c do
    conn =
      request(c.actor)
      |> post("/organizations/import/public", %{
        "import" => %{
          "organization" => "octo-org",
          "destination_action" => "existing",
          "destination_organization_id" => Integer.to_string(c.owned.id)
        }
      })

    assert redirected_to(conn, 303) == "/imports/91"

    assert_receive {:public_discovery, actor_id,
                    %{
                      organization: "octo-org",
                      credential_source: "public",
                      destination_organization: %{action: "existing", id: organization_id}
                    }, metadata}

    assert actor_id == c.actor.id
    assert organization_id == c.owned.id
    assert metadata.user_agent == "organization-import-test"
  end

  test "public discovery rejects mixed fields and preserves safe input", c do
    for extra <- [%{"pat" => "never-render-this-token"}, %{"destination_organization_id" => "1"}] do
      attrs =
        Map.merge(
          %{
            "organization" => "octo-org",
            "destination_action" => "new",
            "destination_slug" => "octo-local"
          },
          extra
        )

      html =
        request(c.actor)
        |> post("/organizations/import/public", %{"import" => attrs})
        |> html_response(422)

      assert html =~ ~s(value="octo-org")
      assert html =~ ~s(value="octo-local")
      refute html =~ "never-render-this-token"
      refute_received {:public_discovery, _, _, _}
    end
  end

  test "public and App routes mask foreign destinations", c do
    attrs = %{
      "destination_action" => "existing",
      "destination_organization_id" => Integer.to_string(c.foreign.id)
    }

    for path <- ["public", "app"] do
      params = if path == "public", do: Map.put(attrs, "organization", "octo-org"), else: attrs

      assert request(c.actor)
             |> post("/organizations/import/" <> path, %{"import" => params})
             |> response(404)
    end

    refute_received {:public_discovery, _, _, _}
  end

  test "public errors preserve safe fields and explain anonymous rate limits", c do
    Process.put(:organization_discovery_error, %{kind: :rate_limited})

    html =
      request(c.actor)
      |> post("/organizations/import/public", %{
        "import" => %{
          "organization" => "octo-org",
          "destination_action" => "new",
          "destination_slug" => "octo-local"
        }
      })
      |> html_response(429)

    assert html =~ "anonymous API rate limit"
    assert html =~ ~s(value="octo-local")

    Process.put(:organization_discovery_error, :invalid_source)

    html =
      request(c.actor)
      |> post("/organizations/import/public", %{
        "import" => %{
          "organization" => "ghp_should_never_be_echoed",
          "destination_action" => "new",
          "destination_slug" => "ghp_also_secret"
        }
      })
      |> html_response(422)

    refute html =~ "ghp_should_never_be_echoed"
    refute html =~ "ghp_also_secret"
  end

  test "discovery connection failure is sanitized", c do
    Process.put(:organization_discovery_error, :database)

    html =
      request(c.actor)
      |> post("/organizations/import/public", %{
        "import" => %{
          "organization" => "octo-org",
          "destination_action" => "new",
          "destination_slug" => "octo-local"
        }
      })
      |> html_response(503)

    assert html =~ "temporarily unavailable"
    refute html =~ "private database detail"
  end

  test "App onboarding reuses an owned organization and creates no personal credential", c do
    count = Repo.aggregate(ForgeAccounts.GitHubCredential, :count)

    conn =
      request(c.actor)
      |> post("/organizations/import/app", %{
        "import" => %{
          "destination_action" => "existing",
          "destination_organization_id" => Integer.to_string(c.owned.id)
        }
      })

    assert redirected_to(conn, 303) ==
             "/organizations/#{c.owned.username}/settings/github/connection"

    assert Repo.aggregate(ForgeAccounts.GitHubCredential, :count) == count
    refute_received {:public_discovery, _, _, _}
  end

  test "App onboarding can create a local organization before its connection", c do
    slug = "new-app-org-#{c.actor.id}"

    conn =
      request(c.actor)
      |> post("/organizations/import/app", %{
        "import" => %{
          "destination_action" => "new",
          "destination_slug" => slug
        }
      })

    assert redirected_to(conn, 303) == "/organizations/#{slug}/settings/github/connection"

    assert {:ok, organization} =
             ForgeAccounts.fetch_manageable_organization_by_slug(c.actor, slug)

    assert organization.username == slug
  end

  test "new onboarding routes enforce login and CSRF", c do
    for suffix <- ["public", "app"] do
      assert request(nil) |> get("/organizations/import/" <> suffix) |> redirected_to() ==
               "/login"

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        request(c.actor)
        |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})
        |> post("/organizations/import/" <> suffix, %{"_csrf_token" => "bad", "import" => %{}})
      end
    end
  end

  defp request(actor) do
    conn =
      build_conn()
      |> put_req_header("user-agent", "organization-import-test")
      |> Plug.Conn.put_private(:forge_imports, Imports)

    if actor, do: Plug.Test.init_test_session(conn, user_id: actor.id), else: conn
  end

  defp user do
    id = System.unique_integer([:positive])

    Repo.insert!(%User{
      username: "public-web-#{id}",
      email: "public-web-#{id}@example.test",
      password_hash: "unused",
      kind: :user,
      role: :user,
      state: :active
    })
  end
end
