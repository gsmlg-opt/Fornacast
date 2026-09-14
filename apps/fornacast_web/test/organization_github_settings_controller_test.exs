defmodule FornacastWeb.OrganizationGitHubSettingsControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, get_session: 2, put_req_header: 3]

  alias ForgeAccounts.{Organization, User}
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint

  defmodule TestOrganizationSync do
    def reset do
      Process.put({__MODULE__, :results}, %{})
      Process.put({__MODULE__, :calls}, [])
    end

    def result(operation, result) do
      Process.put(
        {__MODULE__, :results},
        Map.put(Process.get({__MODULE__, :results}, %{}), operation, result)
      )
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def get_settings(actor, organization) do
      record(:get_settings, [actor, organization])
      operation_result(:get_settings, {:ok, %{}})
    end

    def get_conflicts(actor, organization, filters) do
      record(:get_conflicts, [actor, organization, filters])
      operation_result(:get_conflicts, {:ok, %{}})
    end

    def begin_installation(actor, organization, state, metadata) do
      record(:begin_installation, [actor, organization, state, metadata])

      operation_result(
        :begin_installation,
        {:ok, %{url: "https://github.com/apps/fornacast/installations/new"}}
      )
    end

    def complete_installation(actor, organization, attrs, metadata) do
      record(:complete_installation, [actor, organization, attrs, metadata])
      operation_result(:complete_installation, {:ok, :connected})
    end

    def update_settings(actor, organization, attrs, metadata) do
      record(:update_settings, [actor, organization, attrs, metadata])
      operation_result(:update_settings, {:ok, :updated})
    end

    def resolve_pull_merge_conflict(actor, organization, attrs, metadata) do
      record(:resolve_pull_merge_conflict, [actor, organization, attrs, metadata])
      operation_result(:resolve_pull_merge_conflict, {:ok, :accepted})
    end

    def bootstrap(actor, organization, attrs, metadata) do
      record(:bootstrap, [actor, organization, attrs, metadata])
      operation_result(:bootstrap, {:ok, :started})
    end

    for operation <- [:reconcile, :pause, :resume, :disconnect] do
      def unquote(operation)(actor, organization, metadata) do
        operation = unquote(operation)
        record(operation, [actor, organization, metadata])
        operation_result(operation, {:ok, :accepted})
      end
    end

    defp operation_result(operation, default) do
      Process.get({__MODULE__, :results}, %{})
      |> Map.get(operation, default)
    end

    defp record(operation, args) do
      Process.put(
        {__MODULE__, :calls},
        [{operation, args} | Process.get({__MODULE__, :calls}, [])]
      )
    end
  end

  setup do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    TestOrganizationSync.reset()

    owner = user_fixture("organization-settings-owner")
    admin = user_fixture("organization-settings-admin", :admin)
    member = user_fixture("organization-settings-member")
    outsider = user_fixture("organization-settings-outsider")

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(owner, %{
               username: unique("organization-settings"),
               display_name: "Acme Engineering"
             })

    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)

    %{
      owner: owner,
      admin: admin,
      member: member,
      outsider: outsider,
      organization: organization
    }
  end

  test "organization settings route precedes dynamic namespace catch-alls" do
    assert %{plug: FornacastWeb.OrganizationSettingsController, plug_opts: :index} =
             Phoenix.Router.route_info(
               FornacastWeb.Router,
               "GET",
               "/organizations/acme/settings",
               "localhost"
             )
  end

  test "all FR-010 organization GitHub routes precede dynamic catch-alls" do
    routes = [
      {"GET", "/organizations/acme/settings/github", :index},
      {"POST", "/organizations/acme/settings/github/install", :install},
      {"GET", "/organizations/acme/settings/github/callback", :callback},
      {"PATCH", "/organizations/acme/settings/github", :update},
      {"POST", "/organizations/acme/settings/github/bootstrap", :bootstrap},
      {"POST", "/organizations/acme/settings/github/reconcile", :reconcile},
      {"POST", "/organizations/acme/settings/github/pause", :pause},
      {"POST", "/organizations/acme/settings/github/resume", :resume},
      {"DELETE", "/organizations/acme/settings/github", :delete},
      {"GET", "/organizations/acme/settings/github/conflicts", :conflicts},
      {"PATCH", "/organizations/acme/settings/github/conflicts/42", :resolve_pull_merge_conflict}
    ]

    for {method, path, action} <- routes do
      assert %{plug: FornacastWeb.OrganizationGitHubSettingsController, plug_opts: ^action} =
               Phoenix.Router.route_info(FornacastWeb.Router, method, path, "localhost")
    end

    assert %{plug: FornacastWeb.OrganizationController, plug_opts: :show} =
             Phoenix.Router.route_info(FornacastWeb.Router, "GET", "/acme", "localhost")
  end

  test "organization owner opens canonical organization settings through one facade call", %{
    owner: owner,
    organization: organization
  } do
    TestOrganizationSync.result(:get_settings, {:ok, settings_view(organization)})

    conn = request_conn(owner) |> get("/organizations/#{organization.username}/settings")
    html = html_response(conn, 200)

    assert html =~ "Organization settings"
    assert html =~ "Acme Engineering"
    assert html =~ ~s(href="/organizations/#{organization.username}/settings/github")
    assert_private_no_store(conn)

    assert [{:get_settings, [%User{id: actor_id}, %Organization{id: organization_id}]}] =
             TestOrganizationSync.calls()

    assert actor_id == owner.id
    assert organization_id == organization.id
  end

  test "owner and site admin open GitHub settings through canonical organization authorization",
       %{
         owner: owner,
         admin: admin,
         organization: organization
       } do
    TestOrganizationSync.result(:get_settings, {:ok, settings_view(organization)})

    for actor <- [owner, admin] do
      TestOrganizationSync.reset()
      TestOrganizationSync.result(:get_settings, {:ok, settings_view(organization)})

      conn = request_conn(actor) |> get(github_settings_path(organization))
      html = html_response(conn, 200)

      assert html =~ "GitHub settings"
      assert html =~ "GitHub is not configured"
      assert_private_no_store(conn)

      assert [{:get_settings, [%User{id: actor_id}, %Organization{id: organization_id}]}] =
               TestOrganizationSync.calls()

      assert actor_id == actor.id
      assert organization_id == organization.id
    end
  end

  test "owner sees a webhook delivery gap from the bounded settings view", %{
    owner: owner,
    organization: organization
  } do
    view =
      organization
      |> settings_view()
      |> Map.put(:mirror, %{state: :active})
      |> Map.put(:webhook_health, %{
        state_counts: %{failed: 1},
        oldest_unprocessed_at: ~U[2026-09-05 00:30:00Z],
        latest_failure: %{failure_class: "invalid_webhook_payload"},
        unreconciled_failed_count: 1,
        gap?: true
      })

    TestOrganizationSync.result(:get_settings, {:ok, view})

    conn = request_conn(owner) |> get(github_settings_path(organization))
    html = html_response(conn, 200)

    assert html =~ "Webhook delivery gap"
    assert html =~ "Latest failure: Invalid webhook payload"
    assert_private_no_store(conn)
  end

  test "member outsider disabled actor and missing or disabled organizations are masked", %{
    owner: owner,
    admin: admin,
    member: member,
    outsider: outsider,
    organization: organization
  } do
    for {actor, path} <- [
          {member, github_settings_path(organization)},
          {outsider, github_settings_path(organization)},
          {owner, "/organizations/#{unique("missing")}/settings/github"}
        ] do
      TestOrganizationSync.reset()
      conn = request_conn(actor) |> get(path)

      assert html_response(conn, 404) =~ "Organization settings not found."
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end

    owner
    |> User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    disabled_actor = request_conn(owner) |> get(github_settings_path(organization))
    assert html_response(disabled_actor, 404) =~ "Organization settings not found."
    assert TestOrganizationSync.calls() == []
    assert_private_no_store(disabled_actor)

    organization
    |> Organization.changeset(%{state: :disabled})
    |> Repo.update!()

    disabled_organization = request_conn(admin) |> get(github_settings_path(organization))

    assert html_response(disabled_organization, 404) =~ "Organization settings not found."
    assert TestOrganizationSync.calls() == []
    assert_private_no_store(disabled_organization)
  end

  test "settings mutations each call one facade action and redirect with 303", %{
    owner: owner,
    organization: organization
  } do
    cases = [
      {:update_settings, :patch, github_settings_path(organization),
       %{"github" => %{"repository_selection" => "all"}}},
      {:bootstrap, :post, github_settings_path(organization) <> "/bootstrap",
       %{"bootstrap" => %{"repository_selection" => "current_policy"}}},
      {:reconcile, :post, github_settings_path(organization) <> "/reconcile", %{}},
      {:pause, :post, github_settings_path(organization) <> "/pause", %{}},
      {:resume, :post, github_settings_path(organization) <> "/resume", %{}},
      {:disconnect, :delete, github_settings_path(organization), %{}}
    ]

    for {operation, method, path, params} <- cases do
      TestOrganizationSync.reset()
      conn = request(method, request_conn(owner), path, params)

      assert redirected_to(conn, 303) == github_settings_path(organization)

      assert [{^operation, [%User{id: actor_id}, %Organization{id: organization_id} | args]}] =
               TestOrganizationSync.calls()

      assert actor_id == owner.id
      assert organization_id == organization.id
      assert length(args) in [1, 2]
      assert_private_no_store(conn)
    end
  end

  test "conflicts use the same bounded view facade and render retained conflicts", %{
    owner: owner,
    organization: organization
  } do
    view =
      organization
      |> settings_view()
      |> Map.put(:conflicts, [
        %{resource: "refs/heads/main", kind: :diverged, state: :open}
      ])

    TestOrganizationSync.result(:get_conflicts, {:ok, view})

    conn = request_conn(owner) |> get(github_settings_path(organization) <> "/conflicts")
    html = html_response(conn, 200)

    assert html =~ "GitHub synchronization conflicts"
    assert html =~ "refs/heads/main"
    assert html =~ "Diverged"
    assert [{:get_conflicts, [_actor, _organization, %{}]}] = TestOrganizationSync.calls()
    assert_private_no_store(conn)
  end

  test "conflicts apply only bounded filters through the conflict facade", %{
    owner: owner,
    organization: organization
  } do
    view = %{
      conflicts: [],
      filters: %{repository: 7, resource: "refs/heads/main", type: "git_ref"},
      repositories: [%{id: 7, full_name: "acme/widgets"}],
      types: ["git_ref"],
      actions: %{}
    }

    TestOrganizationSync.result(:get_conflicts, {:ok, view})

    conn =
      request_conn(owner)
      |> get(
        github_settings_path(organization) <>
          "/conflicts?repository=7&type=git_ref&resource=refs/heads/main"
      )

    assert html_response(conn, 200) =~ "Filter conflicts"

    assert [
             {:get_conflicts, [%User{id: actor_id}, %Organization{id: organization_id}, filters]}
           ] = TestOrganizationSync.calls()

    assert actor_id == owner.id
    assert organization_id == organization.id
    assert filters == %{"repository" => "7", "resource" => "refs/heads/main", "type" => "git_ref"}
  end

  test "owner requests an external recheck for an open pull merge conflict", %{
    owner: owner,
    organization: organization
  } do
    view =
      organization
      |> settings_view()
      |> put_in([:actions, :resolve_pull_merge_conflict], true)
      |> Map.put(:conflicts, [
        %{
          id: 42,
          lock_version: 7,
          resource: "pull request #12",
          resource_kind: "pull_merge",
          kind: :diverged,
          state: :open
        }
      ])

    TestOrganizationSync.result(:get_conflicts, {:ok, view})

    form = request_conn(owner) |> get(github_settings_path(organization) <> "/conflicts")
    action = github_settings_path(organization) <> "/conflicts/42"
    token = extract_form_csrf_token(form.resp_body, action)

    assert form.resp_body =~ "Recheck after external resolution"
    refute form.resp_body =~ "snapshot"

    accepted =
      form
      |> recycle_request()
      |> with_production_csrf()
      |> patch(action, %{
        "_csrf_token" => token,
        "conflict" => %{"lock_version" => "7", "action" => "external_recheck"}
      })

    assert redirected_to(accepted, 303) == github_settings_path(organization) <> "/conflicts"

    assert [
             {:get_conflicts, [%User{}, %Organization{}, %{}]},
             {:resolve_pull_merge_conflict,
              [%User{id: actor_id}, %Organization{id: organization_id}, attrs, metadata]}
           ] = TestOrganizationSync.calls()

    assert actor_id == owner.id
    assert organization_id == organization.id
    assert attrs == %{conflict_id: 42, lock_version: 7, action: "external_recheck"}
    assert metadata.user_agent == "organization-github-settings-controller-test"
    assert_private_no_store(accepted)
  end

  test "only open pull merge conflicts expose the external recheck form", %{
    owner: owner,
    organization: organization
  } do
    view =
      organization
      |> settings_view()
      |> Map.put(:conflicts, [
        %{id: 11, lock_version: 2, resource_kind: "issue", state: :open},
        %{id: 12, lock_version: 3, resource_kind: "pull_merge", state: :resolved},
        %{id: 13, lock_version: 4, resource_kind: "pull_merge", state: :open}
      ])

    TestOrganizationSync.result(:get_conflicts, {:ok, view})

    conn = request_conn(owner) |> get(github_settings_path(organization) <> "/conflicts")

    refute conn.resp_body =~ "conflicts/11"
    refute conn.resp_body =~ "conflicts/12"
    refute conn.resp_body =~ "conflicts/13"
    refute conn.resp_body =~ "Recheck after external resolution"
  end

  test "external recheck rejects malformed input before facade access and masks authorization", %{
    owner: owner,
    outsider: outsider,
    organization: organization
  } do
    action = github_settings_path(organization) <> "/conflicts/42"

    for params <- [
          %{},
          %{"conflict" => "forged"},
          %{"conflict" => %{"lock_version" => "0", "action" => "external_recheck"}},
          %{"conflict" => %{"lock_version" => "7", "action" => "accept_github"}}
        ] do
      TestOrganizationSync.reset()
      conn = request_conn(owner) |> patch(action, params)

      assert html_response(conn, 422) =~ "parameters are invalid"
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end

    TestOrganizationSync.reset()

    conn =
      request_conn(outsider)
      |> patch(action, %{"conflict" => %{"lock_version" => "7", "action" => "external_recheck"}})

    assert html_response(conn, 404) =~ "Organization settings not found."
    assert TestOrganizationSync.calls() == []
    assert_private_no_store(conn)
  end

  test "external recheck stale and leased results are fixed conflicts", %{
    owner: owner,
    organization: organization
  } do
    action = github_settings_path(organization) <> "/conflicts/42"

    for reason <- [:stale, :leased] do
      TestOrganizationSync.reset()
      TestOrganizationSync.result(:resolve_pull_merge_conflict, {:error, reason})

      conn =
        request_conn(owner)
        |> patch(action, %{"conflict" => %{"lock_version" => "7", "action" => "external_recheck"}})

      assert html_response(conn, 409) =~ "changed or is busy"

      assert [{:resolve_pull_merge_conflict, [_actor, _organization, _attrs, _metadata]}] =
               TestOrganizationSync.calls()

      assert_private_no_store(conn)
    end
  end

  test "installation start stores an unguessable actor and organization bound correlation", %{
    owner: owner,
    organization: organization
  } do
    conn = request_conn(owner) |> post(github_settings_path(organization) <> "/install", %{})

    assert redirected_to(conn, 303) ==
             "https://github.com/apps/fornacast/installations/new"

    assert [
             {:begin_installation,
              [%User{id: actor_id}, %Organization{id: organization_id}, state, metadata]}
           ] = TestOrganizationSync.calls()

    assert actor_id == owner.id
    assert organization_id == organization.id
    assert state =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert metadata.user_agent == "organization-github-settings-controller-test"

    assert %{
             "actor_id" => ^actor_id,
             "organization_id" => ^organization_id,
             "state" => ^state
           } = get_session(conn, :github_organization_installation)

    refute conn.resp_body =~ state
    assert_private_no_store(conn)
  end

  test "callback consumes correlation once and passes validated state as durable intent evidence",
       %{
         owner: owner,
         organization: organization
       } do
    started =
      request_conn(owner)
      |> post(github_settings_path(organization) <> "/install", %{})

    [{:begin_installation, [_actor, _organization, state, _metadata]}] =
      TestOrganizationSync.calls()

    callback_path =
      github_settings_path(organization) <>
        "/callback?installation_id=987654&setup_action=install&state=#{state}"

    completed = started |> recycle_request() |> get(callback_path)

    assert redirected_to(completed, 303) == github_settings_path(organization)
    assert get_session(completed, :github_organization_installation) == nil

    assert [
             {:begin_installation, _begin_args},
             {:complete_installation,
              [
                %User{id: actor_id},
                %Organization{id: organization_id},
                %{installation_id: 987_654, setup_action: :install, state: ^state},
                metadata
              ]}
           ] = TestOrganizationSync.calls()

    assert actor_id == owner.id
    assert organization_id == organization.id
    assert metadata.user_agent == "organization-github-settings-controller-test"
    refute completed.resp_body =~ state
    assert_private_no_store(completed)

    replay = completed |> recycle_request() |> get(callback_path)
    assert html_response(replay, 400) =~ "callback is invalid or expired"

    assert length(
             Enum.filter(TestOrganizationSync.calls(), &match?({:complete_installation, _}, &1))
           ) == 1

    assert get_session(replay, :github_organization_installation) == nil
    refute replay.resp_body =~ state
    assert_private_no_store(replay)
  end

  test "callback rejects actor organization and state mismatches before the facade", %{
    owner: owner,
    organization: organization
  } do
    state = callback_state()

    correlations = [
      %{
        "actor_id" => owner.id + 1,
        "organization_id" => organization.id,
        "state" => state
      },
      %{
        "actor_id" => owner.id,
        "organization_id" => organization.id + 1,
        "state" => state
      },
      %{
        "actor_id" => owner.id,
        "organization_id" => organization.id,
        "state" => callback_state()
      }
    ]

    for correlation <- correlations do
      TestOrganizationSync.reset()

      conn =
        request_conn(owner, github_organization_installation: correlation)
        |> get(
          github_settings_path(organization) <>
            "/callback?installation_id=987654&setup_action=install&state=#{state}"
        )

      assert html_response(conn, 400) =~ "callback is invalid or expired"
      assert get_session(conn, :github_organization_installation) == nil
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end
  end

  test "callback strictly parses setup action installation id and state", %{
    owner: owner,
    organization: organization
  } do
    state = callback_state()

    cases = [
      {"0", "install", state},
      {"01", "install", state},
      {"+1", "install", state},
      {"9223372036854775808", "install", state},
      {"not-an-id", "install", state},
      {"987654", "delete", state},
      {"987654", "", state},
      {"987654", "install", "short"}
    ]

    for {installation_id, setup_action, callback_state} <- cases do
      TestOrganizationSync.reset()

      correlation = %{
        "actor_id" => owner.id,
        "organization_id" => organization.id,
        "state" => state
      }

      path =
        github_settings_path(organization) <>
          "/callback?installation_id=#{installation_id}&setup_action=#{setup_action}&state=#{callback_state}"

      conn = request_conn(owner, github_organization_installation: correlation) |> get(path)

      assert html_response(conn, 400) =~ "callback is invalid or expired"
      assert get_session(conn, :github_organization_installation) == nil
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end
  end

  test "installation redirects accept only bounded GitHub HTTPS URLs", %{
    owner: owner,
    organization: organization
  } do
    for url <- [
          "http://github.com/apps/fornacast/installations/new",
          "https://evil.example/apps/fornacast/installations/new",
          "https://github.com.evil.example/apps/fornacast/installations/new",
          "https://attacker@github.com/apps/fornacast/installations/new",
          "https://github.com/apps/fornacast/installations/new#fragment",
          "https://github.com:444/apps/fornacast/installations/new",
          "https://github.com\\@evil.example/apps/fornacast/installations/new",
          :binary.copy("x", 2_049)
        ] do
      TestOrganizationSync.reset()
      TestOrganizationSync.result(:begin_installation, {:ok, %{url: url}})

      conn = request_conn(owner) |> post(github_settings_path(organization) <> "/install", %{})

      assert html_response(conn, 503) =~ "temporarily unavailable"
      assert get_session(conn, :github_organization_installation) == nil
      assert [{:begin_installation, _args}] = TestOrganizationSync.calls()
      refute conn.resp_body =~ url
      assert_private_no_store(conn)
    end
  end

  test "invalid mutation containers fail before facade access", %{
    owner: owner,
    organization: organization
  } do
    for {method, path, params} <- [
          {:patch, github_settings_path(organization), %{"github" => "forged"}},
          {:post, github_settings_path(organization) <> "/bootstrap", %{"bootstrap" => "forged"}}
        ] do
      TestOrganizationSync.reset()
      conn = request(method, request_conn(owner), path, params)

      assert html_response(conn, 422) =~ "parameters are invalid"
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end
  end

  test "domain failures map to fixed non-cacheable responses", %{
    owner: owner,
    organization: organization
  } do
    cases = [
      {:forbidden, 404, "Organization settings not found."},
      {:not_found, 404, "Organization settings not found."},
      {:busy, 409, "changed or is busy"},
      {:stale, 409, "changed or is busy"},
      {:conflict, 409, "changed or is busy"},
      {:missing_permissions, 422, "permissions are insufficient"},
      {:provider_unavailable, 503, "temporarily unavailable"},
      {:unexpected_internal_reason, 503, "temporarily unavailable"}
    ]

    for {reason, status, message} <- cases do
      TestOrganizationSync.reset()
      TestOrganizationSync.result(:get_settings, {:error, reason})

      conn = request_conn(owner) |> get(github_settings_path(organization))
      html = html_response(conn, status)

      assert html =~ message
      refute html =~ inspect(reason)
      assert [{:get_settings, [_actor, _organization]}] = TestOrganizationSync.calls()
      assert_private_no_store(conn)
    end
  end

  test "invalid bounded view data becomes a fixed unavailable response", %{
    owner: owner,
    organization: organization
  } do
    invalid_views = [
      %{repositories: :not_a_list},
      %{operations: Enum.map(1..51, &%{id: &1})},
      %{conflicts: Enum.map(1..51, &%{id: &1})},
      %{missing_permissions: Enum.map(1..51, &"permission-#{&1}")}
    ]

    for view <- invalid_views do
      TestOrganizationSync.reset()
      TestOrganizationSync.result(:get_settings, {:ok, view})

      conn = request_conn(owner) |> get(github_settings_path(organization))

      assert html_response(conn, 503) =~ "temporarily unavailable"
      assert [{:get_settings, [_actor, _organization]}] = TestOrganizationSync.calls()
      assert_private_no_store(conn)
    end
  end

  test "browser pipeline enforces native CSRF tokens on organization mutations", %{
    owner: owner,
    organization: organization
  } do
    view =
      organization
      |> connected_settings_view()
      |> put_in([:actions, :update], true)

    TestOrganizationSync.result(:get_settings, {:ok, view})

    form = request_conn(owner) |> get(github_settings_path(organization))
    token = extract_form_csrf_token(form.resp_body, github_settings_path(organization))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      form
      |> recycle_request()
      |> with_production_csrf()
      |> patch(github_settings_path(organization), %{
        "_csrf_token" => "invalid",
        "github" => %{"repository_selection" => "all"}
      })
    end

    TestOrganizationSync.reset()

    accepted =
      form
      |> recycle_request()
      |> with_production_csrf()
      |> patch(github_settings_path(organization), %{
        "_csrf_token" => token,
        "github" => %{"repository_selection" => "all"}
      })

    assert redirected_to(accepted, 303) == github_settings_path(organization)

    assert [{:update_settings, [_actor, _organization, _attrs, _metadata]}] =
             TestOrganizationSync.calls()

    assert_private_no_store(accepted)
  end

  test "organization settings routes require authentication and remain private on redirects", %{
    organization: organization
  } do
    for path <- [
          "/organizations/#{organization.username}/settings",
          github_settings_path(organization),
          github_settings_path(organization) <> "/conflicts"
        ] do
      TestOrganizationSync.reset()
      conn = request_conn(nil) |> get(path)

      assert redirected_to(conn) == "/login"
      assert TestOrganizationSync.calls() == []
      assert_private_no_store(conn)
    end

    assert %{plug: FornacastWeb.GitHubSettingsController, plug_opts: :index} =
             Phoenix.Router.route_info(
               FornacastWeb.Router,
               "GET",
               "/settings/github",
               "localhost"
             )
  end

  defp request(method, conn, path, params) do
    case method do
      :get -> get(conn, path, params)
      :post -> post(conn, path, params)
      :patch -> patch(conn, path, params)
      :delete -> delete(conn, path, params)
    end
  end

  defp request_conn(user, extra_session \\ []) do
    session = Map.new(extra_session)
    session = if user, do: Map.put(session, :user_id, user.id), else: session

    build_conn()
    |> put_req_header("user-agent", "organization-github-settings-controller-test")
    |> Plug.Conn.put_private(:github_organization_sync, TestOrganizationSync)
    |> Plug.Test.init_test_session(session)
  end

  defp recycle_request(conn) do
    conn
    |> recycle()
    |> put_req_header("user-agent", "organization-github-settings-controller-test")
    |> Plug.Conn.put_private(:github_organization_sync, TestOrganizationSync)
  end

  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp extract_form_csrf_token(html, action) do
    [form] = Regex.run(~r/<form\b[^>]*action="#{Regex.escape(action)}".*?<\/form>/s, html)
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, form)
    token
  end

  defp github_settings_path(organization),
    do: "/organizations/#{organization.username}/settings/github"

  defp callback_state do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp settings_view(organization) do
    %{
      organization: organization,
      mirror: nil,
      installation: nil,
      coverage: :none,
      missing_permissions: [],
      policy: %{},
      capabilities: %{},
      repository_counts: %{},
      repositories: [],
      operations: [],
      conflicts: [],
      actions: %{install: true}
    }
  end

  defp connected_settings_view(organization) do
    organization
    |> settings_view()
    |> Map.merge(%{
      mirror: %{
        state: :active,
        last_webhook_at: ~U[2026-09-05 01:00:00Z],
        last_reconciled_at: ~U[2026-09-05 01:05:00Z]
      },
      installation: %{
        account_login: "acme-inc",
        account_id: 88_001,
        installation_id: 99_001,
        repository_selection: :all,
        permissions: %{contents: :write, issues: :write}
      },
      coverage: :all,
      policy: %{
        repository_selection: :all,
        auto_import_new: true,
        auto_create_remote: false,
        repository_deletion_policy: :retain,
        conflict_notification_policy: :notify
      },
      capabilities: %{
        git: :active,
        issues: :active,
        pulls: :active,
        lfs: :unavailable,
        releases: :unavailable
      },
      actions: %{
        update: true,
        bootstrap: false,
        reconcile: true,
        pause: true,
        resume: false,
        disconnect: true
      }
    })
  end

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
