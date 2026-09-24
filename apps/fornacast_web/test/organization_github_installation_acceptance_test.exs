defmodule FornacastWeb.OrganizationGitHubInstallationAcceptanceTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Plug.Conn, only: [get_session: 2, put_req_header: 3]

  alias ForgeAccounts.{GitHubIdentity, Organization, User}
  alias ForgeGitHub.AppInstallation
  alias ForgeImports.{ImportRun, OrganizationSync}
  alias ForgeMirrors.{GitHubAppInstallation, OrganizationMirror}
  alias Fornacast.Repo
  alias FornacastWeb.OrganizationGitHubSettingsHTML

  @endpoint FornacastWeb.Endpoint
  @now ~U[2026-09-14 01:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    previous_config = Application.get_env(:forge_github, :app_configuration, :disabled)
    private_key_file = write_private_key!()

    Application.put_env(:forge_github, :app_configuration, %{
      app_id: 123_456,
      app_slug: "fornacast-acceptance",
      private_key_file: private_key_file,
      webhook_secret: fn -> "test-webhook-secret" end,
      webhook_max_bytes: 65_536
    })

    on_exit(fn ->
      Application.put_env(:forge_github, :app_configuration, previous_config)
      File.rm(private_key_file)
    end)

    owner = user_fixture("github-installation-owner")
    outsider = user_fixture("github-installation-outsider")

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(owner, %{
               username: unique("github-installation-org"),
               display_name: "GitHub Installation Acceptance"
             })

    %{owner: owner, outsider: outsider, organization: organization}
  end

  test "only the linked actor and installation webhook make the owner's organization ready to bootstrap",
       context do
    owner_github_id = github_identity_fixture(context.owner, "owner")
    outsider_github_id = github_identity_fixture(context.outsider, "outsider")
    github_account_id = github_organization_id()
    github_account_login = "github-source-#{github_account_id}"

    started =
      request_conn(context.owner)
      |> post(github_settings_path(context.organization) <> "/install", %{})

    redirect_url = redirected_to(started, 303)
    assert redirect_url =~ "https://github.com/apps/fornacast-acceptance/installations/new?state="

    assert %{
             "actor_id" => owner_id,
             "organization_id" => organization_id,
             "state" => state
           } = get_session(started, :github_organization_installation)

    assert owner_id == context.owner.id
    assert organization_id == context.organization.id
    assert state =~ ~r/\A[A-Za-z0-9_-]{43}\z/

    assert redirect_url ==
             "https://github.com/apps/fornacast-acceptance/installations/new?state=#{state}"

    digest = :crypto.hash(:sha256, state)

    assert {:ok, %OrganizationMirror{state: :pending_installation}} =
             ForgeMirrors.get_organization_mirror_for_organization(
               context.organization.id,
               "github"
             )

    installation_id = unique_id()

    observe_installation(
      installation_id,
      github_account_id,
      github_account_login,
      all_permissions()
    )

    assert {:error, :identity_mismatch} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation_id,
               github_account_id: github_organization_id(),
               github_account_login: "wrong-github-organization",
               account_type: :organization,
               repository_selection: :all,
               permissions: all_permissions(),
               state: :active,
               last_verified_at: DateTime.add(@now, 1)
             })

    assert {:ok, %OrganizationMirror{state: :pending_installation}} =
             ForgeMirrors.get_organization_mirror_for_organization(
               context.organization.id,
               "github"
             )

    assert {:error, :forbidden} =
             ForgeMirrors.record_github_installation_callback(
               context.outsider,
               context.organization.id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 1)
             )

    assert {:ok, %{status: :pending_webhook, mirror: pending}} =
             ForgeMirrors.record_github_installation_callback(
               context.owner,
               context.organization.id,
               digest,
               installation_id,
               :install,
               DateTime.add(@now, 2)
             )

    assert {:ok, :unclaimed} =
             ForgeMirrors.confirm_github_installation_webhook(
               installation_id,
               outsider_github_id,
               DateTime.add(@now, 3)
             )

    assert {:ok, %{mirror: %OrganizationMirror{state: :ready_to_bootstrap} = ready}} =
             ForgeMirrors.confirm_github_installation_webhook(
               installation_id,
               owner_github_id,
               DateTime.add(@now, 4)
             )

    assert ready.id == pending.id
    assert ready.organization_id == context.organization.id
    assert ready.github_installation_id == installation_id
    assert ready.github_account_id == github_account_id
    assert ready.github_account_login == github_account_login

    assert {:ok, settings} = OrganizationSync.get_settings(context.owner, context.organization)

    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: context.organization,
        view: settings
      )

    assert html =~ "Review permissions and repository scope"
    assert html =~ "Ready to bootstrap"

    settings_conn =
      started |> recycle_request() |> get(github_settings_path(context.organization) <> "/app")

    settings_html = html_response(settings_conn, 200)

    assert settings_html =~ "Review permissions and repository scope"
    assert settings_html =~ github_account_login
  end

  test "partial access and missing permissions are rendered and bootstrap creates no ImportRun",
       context do
    installation_id = unique_id()
    github_account_id = github_organization_id()
    github_account_login = "partial-access-#{github_account_id}"

    assert {:ok, pending} =
             ForgeMirrors.create_organization_mirror(context.owner, %{
               organization_id: context.organization.id,
               provider: "github",
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: github_account_login,
               capabilities: all_capabilities()
             })

    assert {:ok, %OrganizationMirror{state: :ready_to_bootstrap}} =
             ForgeMirrors.transition_organization_mirror(
               context.owner,
               pending,
               :ready_to_bootstrap
             )

    observe_installation(
      installation_id,
      github_account_id,
      github_account_login,
      %{
        "metadata" => "read",
        "contents" => "write"
      },
      :selected
    )

    assert {:ok, settings} = OrganizationSync.get_settings(context.owner, context.organization)
    assert settings.coverage == :partial
    assert "issues:write" in settings.missing_permissions
    assert "pull_requests:write" in settings.missing_permissions
    refute settings.actions.bootstrap

    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: context.organization,
        view: settings
      )

    assert html =~ "Partial repository coverage"
    assert html =~ "Missing GitHub App permissions"
    assert html =~ "Issues"
    assert html =~ "Pull requests"

    assert {:error, :missing_permissions} =
             OrganizationSync.bootstrap(
               context.owner,
               context.organization,
               %{"repository_selection" => "current_policy"},
               request_metadata(),
               installation_fetch: fn ^installation_id ->
                 {:ok,
                  %AppInstallation{
                    id: installation_id,
                    account_id: github_account_id,
                    account_login: github_account_login,
                    account_type: :organization,
                    repository_selection: :selected,
                    permissions: %{"metadata" => "read", "contents" => "write"},
                    state: :active
                  }}
               end
             )

    assert Repo.aggregate(ImportRun, :count, :id) == 0
  end

  # The callback controller queries the GitHub App API to observe an installation.
  # This test runs the real start/settings routes and the real domain handoff below,
  # avoiding a live GitHub call or a test-only production seam.
  defp observe_installation(
         installation_id,
         github_account_id,
         github_account_login,
         permissions,
         selection \\ :all
       ) do
    assert {:ok, %GitHubAppInstallation{}} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation_id,
               github_account_id: github_account_id,
               github_account_login: github_account_login,
               account_type: :organization,
               repository_selection: selection,
               permissions: permissions,
               state: :active,
               last_verified_at: @now
             })
  end

  defp github_identity_fixture(user, suffix) do
    github_id = unique_id()

    assert {:ok, %GitHubIdentity{} = identity} =
             ForgeAccounts.observe_github_identity(
               %{id: github_id, login: "#{suffix}-#{github_id}"},
               @now
             )

    assert {:ok, %GitHubIdentity{local_user_id: user_id}} =
             ForgeAccounts.link_github_identity(user, identity)

    assert user_id == user.id
    github_id
  end

  defp all_permissions do
    %{
      "metadata" => "read",
      "contents" => "write",
      "issues" => "write",
      "pull_requests" => "write",
      "administration" => "write"
    }
  end

  defp all_capabilities do
    %{
      "git" => "enabled",
      "issues" => "enabled",
      "pulls" => "enabled",
      "lfs" => "enabled",
      "releases" => "enabled"
    }
  end

  defp user_fixture(prefix) do
    value = unique(prefix)

    Repo.insert!(%User{
      username: value,
      email: "#{value}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp request_metadata, do: %{"request_id" => Ecto.UUID.generate()}
  defp unique_id, do: System.unique_integer([:positive, :monotonic])
  defp github_organization_id, do: 8_000_000_000 + unique_id()

  defp request_conn(user) do
    build_conn()
    |> put_req_header("user-agent", "organization-github-installation-acceptance-test")
    |> Plug.Test.init_test_session(%{user_id: user.id})
  end

  defp recycle_request(conn) do
    conn
    |> recycle()
    |> put_req_header("user-agent", "organization-github-installation-acceptance-test")
  end

  defp github_settings_path(organization),
    do: "/organizations/#{organization.username}/settings/github"

  defp write_private_key! do
    path = Path.join(System.tmp_dir!(), "fornacast-acceptance-#{unique_id()}.pem")
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    File.write!(path, pem, [:binary, :exclusive])
    path
  end

  defp unique(prefix) do
    "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
