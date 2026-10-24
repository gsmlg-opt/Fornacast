defmodule FornacastWeb.OrganizationGitHubConnectionHTMLTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias FornacastWeb.OrganizationGitHubConnectionHTML, as: HTML
  alias ForgeMirrors.{OrganizationGitHubConnection, PatConfiguration}

  test "authorization without installation is not projected as connected or sync-ready" do
    html = render(:connection, :installation_required)
    assert html =~ "installation required"
    assert html =~ "Install or configure Fornacast on GitHub"
    refute html =~ "Organization GitHub App connected"
    refute html =~ "Use organization connection for synchronization"
    refute html =~ ">Sync now<"
    refute html =~ "github_identity_id"
  end

  test "missing installation permissions remain explicit and activation is unavailable" do
    html = render(:connection, :permissions_missing)
    assert html =~ "Installation permissions missing"
    assert html =~ "contents, issues and pull requests"
    refute html =~ "connection/activate"
    refute html =~ ">Sync now<"
  end

  test "ready installation requires separate activation before explicit synchronization" do
    html = render(:connection, :ready)
    assert html =~ "Organization GitHub App connected"
    assert html =~ "Installation #99"
    assert html =~ "1 effective repositories"
    assert html =~ "Use organization connection for synchronization"
    assert html =~ ~s(name="connection[connection_version]" value="2")
    refute html =~ ">Sync now<"
    html = render(:connection, :ready, true)
    assert html =~ "Sync now"
    refute html =~ "connection/activate"
    assert html =~ "LFS access is checked during synchronization"
  end

  test "compact overview never includes authorization code or configuration forms" do
    html = render(:index, :ready)
    document = LazyHTML.from_fragment(html)

    assert Enum.count(
             LazyHTML.query(
               document,
               "nav[aria-label='Organization GitHub connection options'] a"
             )
           ) == 2

    assert Enum.count(LazyHTML.query(document, "form")) == 0
    assert html =~ "Connect with GitHub"
    assert html =~ "Link GitHub account"
    refute html =~ "data-github-device-poll"
    refute html =~ "Credential owner"
  end

  test "compact disconnected overview reports the selected legacy source and its actual synchronization status" do
    for status <- ["running", "failed"] do
      config = %PatConfiguration{
        id: 9,
        credential_source: :personal,
        enabled: true,
        last_sync_status: status
      }

      html = render(:index, :disconnected, config) |> String.replace(~r/\s+/, " ")

      assert html =~ "Not connected"
      assert html =~ "Synchronization source: legacy personal connection. Status: #{status}."
      refute html =~ "Organization GitHub App connected"
      refute html =~ "Organization connection selected for synchronization"

      document = LazyHTML.from_fragment(html)

      assert Enum.count(
               LazyHTML.query(
                 document,
                 "nav[aria-label='Organization GitHub connection options'] a"
               )
             ) == 2

      assert Enum.count(LazyHTML.query(document, "form")) == 0
    end
  end

  test "public synchronization status links to anonymous settings without a personal credential" do
    config = %PatConfiguration{
      id: 9,
      credential_source: :public,
      enabled: true,
      last_sync_status: "succeeded"
    }

    html = render(:index, :disconnected, config) |> String.replace(~r/\s+/, " ")
    assert html =~ ~s(data-synchronization-source="public")
    assert html =~ "Synchronization source: public GitHub API. Status: succeeded."
    assert html =~ ~s(href="/organizations/acme/settings/github/public")
    refute html =~ "Synchronization source: legacy personal connection"
  end

  defp render(template, state, config_or_active \\ false) do
    organization = %ForgeAccounts.Organization{
      id: 1,
      username: "acme",
      display_name: "Acme",
      state: :active
    }

    connection = %OrganizationGitHubConnection{
      id: 2,
      organization_id: 1,
      credential_id: 3,
      credential_version: 1,
      github_organization: "source-org",
      installation_id: 99,
      lock_version: 2,
      state: state,
      inventory: %{"repositories" => [%{"id" => 80}]}
    }

    view = %{
      state: state,
      connection: if(state == :disconnected, do: nil, else: connection),
      connection_version: 2,
      credential: %{status: :valid, github_user_login: "authorizer"}
    }

    config =
      case config_or_active do
        %PatConfiguration{} = config ->
          config

        true ->
          %PatConfiguration{
            credential_source: :organization_device,
            organization_connection_id: 2,
            organization_connection_version: 2,
            enabled: true
          }

        false ->
          %PatConfiguration{}
      end

    render_component(&apply(HTML, template, [&1]),
      organization: organization,
      view: view,
      config: config,
      installations: [],
      error: nil,
      flash: nil,
      device_flow: nil
    )
  end
end
