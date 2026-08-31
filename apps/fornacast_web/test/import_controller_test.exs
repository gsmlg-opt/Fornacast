defmodule FornacastWeb.ImportControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  import Plug.Conn,
    only: [get_resp_header: 2, get_session: 1, get_session: 2, put_req_header: 3]

  alias ForgeAccounts.{GitHubAccountView, User}
  alias ForgeImports.RunView
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint
  @pat "github_pat_controller_secret"

  defmodule TestImports do
    def reset do
      Process.put({__MODULE__, :accounts}, {:ok, []})
      Process.put({__MODULE__, :results}, %{})
      Process.put({__MODULE__, :calls}, [])
    end

    def accounts(result), do: Process.put({__MODULE__, :accounts}, result)

    def result(operation, result) do
      Process.put(
        {__MODULE__, :results},
        Map.put(Process.get({__MODULE__, :results}, %{}), operation, result)
      )
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def list_github_accounts(actor) do
      record(:list_accounts, [actor])
      Process.get({__MODULE__, :accounts}, {:ok, []}) |> resolve_result()
    end

    def create_repository_discovery(actor, attrs, metadata) do
      record(:repository_discover, [actor, attrs, metadata])
      operation_result(:repository_discover)
    end

    def create_organization_discovery(actor, attrs, metadata) do
      record(:organization_discover, [actor, attrs, metadata])
      operation_result(:organization_discover)
    end

    def get_run_view(actor, id) do
      record(:show, [actor, id])
      operation_result(:show)
    end

    def update_repository_selection(actor, id, repository_ids) do
      record(:selection, [actor, id, repository_ids])
      operation_result(:selection)
    end

    def update_organization_destination(actor, id, destination) do
      record(:destination, [actor, id, destination])
      operation_result(:destination)
    end

    defp operation_result(operation) do
      Process.get({__MODULE__, :results}, %{})
      |> Map.get(operation, {:error, :not_found})
      |> resolve_result()
    end

    defp resolve_result({:raise, exception, message}), do: raise(exception, message: message)

    defp resolve_result({:raise_turso, code, message}),
      do: raise(Turso.Error, code: code, message: message)

    defp resolve_result(result), do: result

    defp record(operation, args) do
      Process.put(
        {__MODULE__, :calls},
        [{operation, args} | Process.get({__MODULE__, :calls}, [])]
      )
    end
  end

  defmodule TestAccounts do
    def reset do
      Process.put({__MODULE__, :result}, :delegate)
      Process.put({__MODULE__, :calls}, [])
    end

    def result(result), do: Process.put({__MODULE__, :result}, result)
    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def list_repository_owners(actor) do
      Process.put({__MODULE__, :calls}, [actor | Process.get({__MODULE__, :calls}, [])])

      case Process.get({__MODULE__, :result}, :delegate) do
        :delegate -> ForgeAccounts.list_repository_owners(actor)
        {:raise, exception, message} -> raise exception, message: message
        {:raise_turso, code, message} -> raise Turso.Error, code: code, message: message
        result -> result
      end
    end
  end

  setup do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    TestImports.reset()
    TestAccounts.reset()

    actor = user_fixture("import-actor")

    %{actor: actor}
  end

  test "repository and organization entrypoints render owner-scoped no-JavaScript forms", %{
    actor: actor
  } do
    TestImports.accounts(
      {:ok,
       [
         account(41, "octocat", :valid),
         account(42, "hubot", :invalid),
         account(43, "ghost", nil)
       ]}
    )

    owned = owned_organization_fixture(actor, "owned")
    member = member_organization_fixture(actor, "member")

    repository = request_conn(actor) |> get("/repos/import")
    repository_html = html_response(repository, 200)

    assert repository_html =~ "Import repository from GitHub"
    assert repository_html =~ ~s(action="/repos/import/discover" method="post")
    assert repository_html =~ ~s(name="import[source]")
    assert repository_html =~ ~s(name="import[credential_source]")
    assert repository_html =~ ~s(value="saved")
    assert repository_html =~ ~s(value="one_time")
    assert repository_html =~ ~s(name="import[github_identity_id]")
    assert repository_html =~ "Github:octocat"
    refute repository_html =~ "Github:hubot"
    refute repository_html =~ "Github:ghost"
    assert_blank_pat(repository_html)
    assert_real_csrf(repository_html)
    assert_private_no_store(repository)

    organization = request_conn(actor) |> get("/organizations/import")
    organization_html = html_response(organization, 200)

    assert organization_html =~ "Import organization from GitHub"
    assert organization_html =~ ~s(action="/organizations/import/discover" method="post")
    assert organization_html =~ ~s(name="import[organization]")
    assert organization_html =~ ~s(name="import[destination_action]")
    assert organization_html =~ ~s(name="import[destination_slug]")
    assert organization_html =~ ~s(name="import[destination_organization_id]")
    assert organization_html =~ owned.username
    refute organization_html =~ member.username
    assert_blank_pat(organization_html)
    assert_real_csrf(organization_html)
    assert_private_no_store(organization)
  end

  test "repository discovery canonicalizes saved and one-time credentials before service calls",
       %{
         actor: actor
       } do
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
    TestImports.result(:repository_discover, {:ok, run_view(actor, 71)})

    saved =
      request_conn(actor)
      |> post("/repos/import/discover", %{
        "import" => %{
          "source" => "octo/repo",
          "credential_source" => "saved",
          "github_identity_id" => "41",
          "pat" => ""
        }
      })

    assert redirected_to(saved, 303) == "/imports/71"
    assert_private_no_store(saved)

    assert [
             {:repository_discover,
              [
                %User{id: actor_id},
                %{
                  source: "octo/repo",
                  credential_source: "saved",
                  github_identity_id: 41
                },
                metadata
              ]}
           ] = mutation_calls()

    assert actor_id == actor.id
    assert metadata.user_agent == "import-controller-test"
    assert metadata.ip_address == "127.0.0.1"

    TestImports.reset()
    TestImports.result(:repository_discover, {:ok, run_view(actor, 72)})
    parent = self()

    log =
      capture_log(fn ->
        conn =
          request_conn(actor)
          |> post("/repos/import/discover", %{
            "import" => %{
              "source" => "https://github.com/octo/repo",
              "credential_source" => "one_time",
              "github_identity_id" => "",
              "pat" => @pat
            }
          })

        send(parent, {:one_time_conn, conn})
      end)

    assert_receive {:one_time_conn, one_time}
    assert redirected_to(one_time, 303) == "/imports/72"

    assert [
             {:repository_discover,
              [
                %User{id: actor_id},
                %{
                  source: "https://github.com/octo/repo",
                  credential_source: "one_time",
                  pat: @pat
                },
                _metadata
              ]}
           ] = mutation_calls()

    assert actor_id == actor.id
    refute secret_surfaces(one_time) =~ @pat
    refute log =~ @pat
    assert_private_no_store(one_time)
  end

  test "organization discovery accepts only new or actor-owned existing destinations", %{
    actor: actor
  } do
    owned = owned_organization_fixture(actor, "destination")
    foreign = owned_organization_fixture(user_fixture("foreign-owner"), "foreign")
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
    TestImports.result(:organization_discover, {:ok, run_view(actor, 81, :organization)})

    created =
      request_conn(actor)
      |> post("/organizations/import/discover", %{
        "import" => %{
          "organization" => "octo-org",
          "credential_source" => "saved",
          "github_identity_id" => "41",
          "pat" => "",
          "destination_action" => "new",
          "destination_slug" => "octo-local",
          "destination_organization_id" => ""
        }
      })

    assert redirected_to(created, 303) == "/imports/81"

    assert [
             {:organization_discover,
              [
                %User{},
                %{
                  organization: "octo-org",
                  credential_source: "saved",
                  github_identity_id: 41,
                  destination_organization: %{action: "new", slug: "octo-local"}
                },
                _metadata
              ]}
           ] = mutation_calls()

    TestImports.reset()
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
    TestImports.result(:organization_discover, {:ok, run_view(actor, 82, :organization)})

    existing =
      request_conn(actor)
      |> post("/organizations/import/discover", %{
        "import" => %{
          "organization" => "octo-org",
          "credential_source" => "saved",
          "github_identity_id" => "41",
          "pat" => "",
          "destination_action" => "existing",
          "destination_slug" => "",
          "destination_organization_id" => Integer.to_string(owned.id)
        }
      })

    assert redirected_to(existing, 303) == "/imports/82"

    assert Enum.any?(mutation_calls(), fn
             {:organization_discover,
              [_actor, %{destination_organization: %{action: "existing", id: id}}, _metadata]} ->
               id == owned.id

             _other ->
               false
           end)

    TestImports.reset()
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})

    rejected =
      request_conn(actor)
      |> post("/organizations/import/discover", %{
        "import" => %{
          "organization" => "octo-org",
          "credential_source" => "saved",
          "github_identity_id" => "41",
          "pat" => "",
          "destination_action" => "existing",
          "destination_slug" => "",
          "destination_organization_id" => Integer.to_string(foreign.id)
        }
      })

    assert html_response(rejected, 404) =~ "Import not found."
    assert mutation_calls() == []
  end

  test "organization discovery rejects non-empty inactive destination fields before service", %{
    actor: actor
  } do
    owned = owned_organization_fixture(actor, "mixed-destination")
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})

    for params <- [
          %{
            "organization" => "octo-org",
            "credential_source" => "saved",
            "github_identity_id" => "41",
            "pat" => "",
            "destination_action" => "new",
            "destination_slug" => "octo-local",
            "destination_organization_id" => Integer.to_string(owned.id)
          },
          %{
            "organization" => "octo-org",
            "credential_source" => "saved",
            "github_identity_id" => "41",
            "pat" => "",
            "destination_action" => "existing",
            "destination_slug" => "octo-local",
            "destination_organization_id" => Integer.to_string(owned.id)
          },
          %{
            "organization" => "octo-org",
            "credential_source" => "saved",
            "github_identity_id" => "41",
            "pat" => "",
            "destination_action" => "new",
            "destination_slug" => "octo-local"
          }
        ] do
      TestImports.reset()
      TestImports.accounts({:ok, [account(41, "octocat", :valid)]})

      conn =
        request_conn(actor)
        |> post("/organizations/import/discover", %{"import" => params})

      assert html_response(conn, 422) =~ invalid_message()
      assert mutation_calls() == []
    end
  end

  test "mixed credentials and malformed canonical values are rejected before service calls", %{
    actor: actor
  } do
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})

    cases = [
      %{
        "source" => "octo/repo",
        "credential_source" => "saved",
        "github_identity_id" => "41",
        "pat" => @pat
      },
      %{
        "source" => "octo/repo",
        "credential_source" => "saved",
        "github_identity_id" => "01",
        "pat" => ""
      },
      %{
        "source" => String.duplicate("a", 513),
        "credential_source" => "one_time",
        "github_identity_id" => "",
        "pat" => @pat
      },
      %{
        "source" => "octo/repo",
        "credential_source" => "one_time",
        "github_identity_id" => "",
        "pat" => "line one\nline two"
      },
      %{
        "source" => "octo/repo",
        "credential_source" => "other",
        "github_identity_id" => "",
        "pat" => ""
      }
    ]

    for params <- cases do
      TestImports.reset()
      TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
      conn = request_conn(actor) |> post("/repos/import/discover", %{"import" => params})
      html = html_response(conn, 422)

      assert html =~ "Check the GitHub source, credential, and destination."
      refute secret_surfaces(conn) =~ @pat
      assert mutation_calls() == []
      assert_private_no_store(conn)
    end
  end

  test "show and no-JavaScript patch forms use canonical ids and actor-scoped service APIs", %{
    actor: actor
  } do
    owned = owned_organization_fixture(actor, "patch")
    view = run_view(actor, 91, :organization)

    TestImports.result(:show, {:ok, view})
    shown = request_conn(actor) |> get("/imports/91")
    html = html_response(shown, 200)

    assert html =~ "octo/alpha"
    assert html =~ ~s(action="/imports/91/selection" method="post")
    assert html =~ ~s(action="/imports/91/destination" method="post")
    assert_private_no_store(shown)

    TestImports.reset()
    TestImports.result(:selection, {:ok, view})

    selection =
      request_conn(actor)
      |> patch("/imports/91/selection", %{
        "selection" => %{
          "present" => "true",
          "repository_ids" => ["9001", "9002"]
        }
      })

    assert redirected_to(selection, 303) == "/imports/91"

    assert [{:selection, [%User{id: actor_id}, 91, [9001, 9002]]}] = mutation_calls()
    assert actor_id == actor.id

    TestImports.reset()
    TestImports.result(:destination, {:ok, view})

    destination =
      request_conn(actor)
      |> patch("/imports/91/destination", %{
        "destination" => %{
          "action" => "existing",
          "slug" => "",
          "organization_id" => Integer.to_string(owned.id)
        }
      })

    assert redirected_to(destination, 303) == "/imports/91"
    assert [{:destination, [%User{}, 91, %{action: "existing", id: owned_id}]}] = mutation_calls()
    assert owned_id == owned.id
  end

  test "scalar, duplicate, noncanonical, and foreign mutation inputs are masked or rejected", %{
    actor: actor
  } do
    for {path, params} <- [
          {"/imports/91/selection", %{"selection" => %{"repository_ids" => "9001"}}},
          {"/imports/91/selection", %{"selection" => %{"repository_ids" => ["9001", "9001"]}}},
          {"/imports/91/selection", %{"selection" => %{"repository_ids" => ["09001"]}}}
        ] do
      TestImports.reset()
      conn = request_conn(actor) |> patch(path, params)
      assert html_response(conn, 422) =~ "Check the import choices and try again."
      assert mutation_calls() == []
    end

    for path <- ["/imports/01", "/imports/9223372036854775808"] do
      TestImports.reset()
      conn = request_conn(actor) |> get(path)
      assert html_response(conn, 404) =~ "Import not found."
      assert mutation_calls() == []
    end

    TestImports.reset()
    TestImports.result(:show, {:error, :not_found})
    foreign = request_conn(actor) |> get("/imports/91")
    html = html_response(foreign, 404)
    assert html =~ "Import not found."
    refute html =~ ":not_found"
  end

  test "an omitted repository checkbox list means select none", %{actor: actor} do
    TestImports.result(:selection, {:ok, run_view(actor, 91, :organization)})

    conn =
      request_conn(actor)
      |> patch("/imports/91/selection", %{"selection" => %{"present" => "true"}})

    assert redirected_to(conn, 303) == "/imports/91"
    assert [{:selection, [%User{id: actor_id}, 91, []]}] = mutation_calls()
    assert actor_id == actor.id
  end

  test "secret-looking source, organization, and destination text is never echoed on errors", %{
    actor: actor
  } do
    cases = [
      {:repository_discover, "/repos/import/discover",
       %{
         "source" => @pat,
         "credential_source" => "one_time",
         "github_identity_id" => "",
         "pat" => "plain-one-time-token"
       }},
      {:organization_discover, "/organizations/import/discover",
       %{
         "organization" => @pat,
         "credential_source" => "one_time",
         "github_identity_id" => "",
         "pat" => "plain-one-time-token",
         "destination_action" => "new",
         "destination_slug" => "safe-destination",
         "destination_organization_id" => ""
       }},
      {:organization_discover, "/organizations/import/discover",
       %{
         "organization" => "octo-org",
         "credential_source" => "saved",
         "github_identity_id" => "41",
         "pat" => "",
         "destination_action" => "new",
         "destination_slug" => @pat,
         "destination_organization_id" => ""
       }}
    ]

    for {operation, path, import_params} <- cases do
      TestImports.reset()
      TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
      TestImports.result(operation, {:error, :invalid_source})
      parent = self()

      log =
        capture_log(fn ->
          send(
            parent,
            {:secret_text_conn, operation,
             request_conn(actor) |> post(path, %{"import" => import_params})}
          )
        end)

      assert_receive {:secret_text_conn, ^operation, conn}
      assert html_response(conn, 422) =~ invalid_message()
      refute secret_surfaces(conn) =~ @pat
      refute log =~ @pat
      assert get_resp_header(conn, "location") == []
    end
  end

  test "show rejects RunView values outside the persisted state vocabulary", %{actor: actor} do
    TestImports.result(:show, {:ok, %{run_view(actor, 91) | state: :invented_state}})

    conn = request_conn(actor) |> get("/imports/91")

    assert html_response(conn, 503) =~ "GitHub discovery is temporarily unavailable."
    refute conn.resp_body =~ "Invented"
  end

  test "show masks ownership errors and classifies unavailable or malformed service results", %{
    actor: actor
  } do
    for {result, status, message} <- [
          {{:error, :not_found}, 404, "Import not found."},
          {{:error, :forbidden}, 404, "Import not found."},
          {{:error, :upstream_unavailable}, 503, "GitHub discovery is temporarily unavailable."},
          {{:ok, %{id: 91, state: :discovering}}, 503,
           "GitHub discovery is temporarily unavailable."}
        ] do
      TestImports.reset()
      TestImports.result(:show, result)
      conn = request_conn(actor) |> get("/imports/91")
      assert html_response(conn, status) =~ message
      refute conn.resp_body =~ inspect(elem(result, 1))
    end
  end

  test "show renders a safe persisted destination conflict without repository rows", %{
    actor: actor
  } do
    run = run_view(actor, 91, :organization)

    run = %{
      run
      | repositories: [],
        reports: [],
        counts: %{selected: 0, published: 0, skipped: 0, warnings: 0, failures: 0},
        destination: %{
          organization_action: :new,
          organization_slug: "imports",
          organization_id: nil,
          organization_status: :invalid,
          organization_classification: "reserved_namespace"
        }
    }

    TestImports.result(:show, {:ok, run})
    conn = request_conn(actor) |> get("/imports/91")
    html = html_response(conn, 200)

    assert html =~ ~s(data-destination-warning="invalid")
    assert html =~ "Reserved namespace"
    refute html =~ @pat
    refute html =~ "credential_envelope"
    refute html =~ ~r/>\s*(?:Start|Cancel|Retry)(?: import)?\s*</i
  end

  test "known service failures are fixed, masked, non-cacheable, and secret-free", %{actor: actor} do
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})

    TestImports.result(
      :repository_discover,
      {:raise, ForgeImports.Discovery.CredentialBootstrapError, "callback failed #{@pat}"}
    )

    parent = self()

    log =
      capture_log(fn ->
        conn =
          request_conn(actor)
          |> post("/repos/import/discover", %{
            "import" => %{
              "source" => "octo/repo",
              "credential_source" => "one_time",
              "github_identity_id" => "",
              "pat" => @pat
            }
          })

        send(parent, {:failed_conn, conn})
      end)

    assert_receive {:failed_conn, conn}
    html = html_response(conn, 503)
    assert html =~ "GitHub discovery is temporarily unavailable."
    refute secret_surfaces(conn) =~ @pat
    refute log =~ @pat
    assert get_resp_header(conn, "location") == []
    assert_private_no_store(conn)
  end

  test "owned-organization lookup availability failures are sanitized across every callsite", %{
    actor: actor
  } do
    failures = [
      {:raise, DBConnection.ConnectionError, "database failure #{@pat}"},
      {:raise_turso, :busy, "busy #{@pat}"},
      {:raise_turso, :io, "io #{@pat}"},
      {:raise_turso, :corrupt, "corrupt #{@pat}"}
    ]

    requests = [
      {:repository_new, fn -> request_conn(actor) |> get("/repos/import") end},
      {:organization_new, fn -> request_conn(actor) |> get("/organizations/import") end},
      {:show,
       fn ->
         TestImports.result(:show, {:ok, run_view(actor, 91, :organization)})
         request_conn(actor) |> get("/imports/91")
       end},
      {:destination,
       fn ->
         request_conn(actor)
         |> patch("/imports/91/destination", %{
           "destination" => %{
             "action" => "existing",
             "slug" => "",
             "organization_id" => "41"
           }
         })
       end}
    ]

    for failure <- failures, {operation, request} <- requests do
      TestImports.reset()
      TestAccounts.reset()
      TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
      TestAccounts.result(failure)
      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:owned_lookup_conn, operation, request.()})
        end)

      assert_receive {:owned_lookup_conn, ^operation, conn}
      assert html_response(conn, 503) =~ "GitHub discovery is temporarily unavailable."
      refute secret_surfaces(conn) =~ @pat
      refute log =~ @pat
      assert get_resp_header(conn, "location") == []
      assert_private_no_store(conn)
      refute Enum.any?(mutation_calls(), &match?({:destination, _args}, &1))
    end
  end

  test "programming failures in owned-organization lookups still propagate", %{actor: actor} do
    TestAccounts.result({:raise, RuntimeError, "programming failure"})

    assert_raise RuntimeError, "programming failure", fn ->
      request_conn(actor) |> get("/organizations/import")
    end
  end

  test "non-recoverable Turso owned-organization failures still propagate", %{actor: actor} do
    for code <- [:error, :constraint, :misuse, :invalid_param, nil] do
      TestAccounts.result({:raise_turso, code, "non-recoverable lookup failure"})

      error =
        assert_raise Turso.Error, "non-recoverable lookup failure", fn ->
          request_conn(actor) |> get("/organizations/import")
        end

      assert error.code == code
    end
  end

  test "the browser pipeline enforces real CSRF tokens for import mutations", %{actor: actor} do
    TestImports.accounts({:ok, [account(41, "octocat", :valid)]})
    form = request_conn(actor) |> get("/repos/import")
    token = extract_csrf_token(form.resp_body)
    params = repository_saved_params(token)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> post("/repos/import/discover", put_in(params["_csrf_token"], "invalid"))
    end

    TestImports.result(:repository_discover, {:ok, run_view(actor, 101)})

    accepted =
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> post("/repos/import/discover", params)

    assert redirected_to(accepted, 303) == "/imports/101"
    assert_private_no_store(accepted)
  end

  test "the browser pipeline enforces real CSRF tokens for PATCH forms", %{actor: actor} do
    view = run_view(actor, 91, :organization)
    TestImports.result(:show, {:ok, view})
    form = request_conn(actor) |> get("/imports/91")
    token = extract_form_csrf_token(form.resp_body, "/imports/91/selection")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> patch("/imports/91/selection", %{
        "_csrf_token" => "invalid",
        "selection" => %{"present" => "true"}
      })
    end

    TestImports.result(:selection, {:ok, view})

    accepted =
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> patch("/imports/91/selection", %{
        "_csrf_token" => token,
        "selection" => %{"present" => "true"}
      })

    assert redirected_to(accepted, 303) == "/imports/91"
  end

  test "setup redirects are non-cacheable and import routes precede dynamic catch-alls", %{
    actor: actor
  } do
    assert %{plug: FornacastWeb.ImportController, plug_opts: :show} =
             Phoenix.Router.route_info(FornacastWeb.Router, "GET", "/imports/91", "localhost")

    assert %{plug: FornacastWeb.ImportController, plug_opts: :organization_new} =
             Phoenix.Router.route_info(
               FornacastWeb.Router,
               "GET",
               "/organizations/import",
               "localhost"
             )

    Fornacast.Setup.reset!()
    conn = request_conn(actor) |> get("/imports/91")

    assert redirected_to(conn) == "/setup"
    assert TestImports.calls() == []
    assert_private_no_store(conn)
  end

  test "all seven routes reject anonymous and disabled users before service calls", %{
    actor: actor
  } do
    anonymous_paths = [
      {:get, "/repos/import", %{}},
      {:post, "/repos/import/discover", %{}},
      {:get, "/organizations/import", %{}},
      {:post, "/organizations/import/discover", %{}},
      {:get, "/imports/91", %{}},
      {:patch, "/imports/91/destination", %{}},
      {:patch, "/imports/91/selection", %{}}
    ]

    for {method, path, params} <- anonymous_paths do
      TestImports.reset()
      conn = request(method, request_conn(nil), path, params)
      assert redirected_to(conn) == "/login"
      assert_private_no_store(conn)
      assert TestImports.calls() == []
    end

    actor
    |> User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    for {method, path, params} <- anonymous_paths do
      TestImports.reset()
      disabled = request(method, request_conn(actor), path, params)
      assert redirected_to(disabled) == "/login"
      assert get_session(disabled, :user_id) == nil
      assert TestImports.calls() == []
      assert_private_no_store(disabled)
    end
  end

  defp request(:get, conn, path, _params), do: get(conn, path)
  defp request(:post, conn, path, params), do: post(conn, path, params)
  defp request(:patch, conn, path, params), do: patch(conn, path, params)

  defp request_conn(user) do
    conn =
      build_conn()
      |> put_req_header("user-agent", "import-controller-test")
      |> Plug.Conn.put_private(:forge_imports, TestImports)
      |> Plug.Conn.put_private(:forge_accounts, TestAccounts)

    if user, do: Plug.Test.init_test_session(conn, user_id: user.id), else: conn
  end

  defp recycle_request(conn, actor) do
    conn
    |> recycle()
    |> put_req_header("user-agent", "import-controller-test")
    |> Plug.Conn.put_private(:forge_imports, TestImports)
    |> Plug.Conn.put_private(:forge_accounts, TestAccounts)
    |> Plug.Test.init_test_session(user_id: actor.id)
  end

  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp extract_csrf_token(html) do
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html)
    token
  end

  defp extract_form_csrf_token(html, action) do
    [form] = Regex.run(~r/<form action="#{Regex.escape(action)}".*?<\/form>/s, html)
    extract_csrf_token(form)
  end

  defp repository_saved_params(token) do
    %{
      "_csrf_token" => token,
      "import" => %{
        "source" => "octo/repo",
        "credential_source" => "saved",
        "github_identity_id" => "41",
        "pat" => ""
      }
    }
  end

  defp mutation_calls do
    Enum.reject(TestImports.calls(), &match?({:list_accounts, _args}, &1))
  end

  defp assert_blank_pat(html) do
    [input] = Regex.run(~r/<input\b[^>]*name="import\[pat\]"[^>]*>/, html)
    assert input =~ ~s(type="password")
    assert input =~ ~s(autocomplete="new-password")
    assert input =~ ~s(maxlength="4096")
    refute input =~ ~r/\bvalue=/
  end

  defp assert_real_csrf(html) do
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html)
    assert byte_size(token) > 20
    refute token in ["token", "csrf", "placeholder"]
  end

  defp secret_surfaces(conn) do
    [
      conn.resp_body,
      inspect(get_session(conn)),
      inspect(conn.assigns),
      inspect(conn.resp_headers),
      inspect(Map.get(conn.assigns, :flash, %{}))
    ]
    |> Enum.join("\n")
  end

  defp assert_private_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp invalid_message, do: "Check the GitHub source, credential, and destination."

  defp run_view(actor, id, kind \\ :repository) do
    %RunView{
      id: id,
      actor_user_id: actor.id,
      source: %{
        kind: kind,
        owner_github_id: 8_001,
        owner_login: "octo",
        repository_github_id: if(kind == :repository, do: 9_001),
        repository_full_name: if(kind == :repository, do: "octo/alpha"),
        provenance: %{}
      },
      destination: %{
        organization_action: if(kind == :organization, do: :new, else: :existing),
        organization_slug: if(kind == :organization, do: "octo-local", else: actor.username),
        organization_id: nil,
        organization_status: :clean,
        organization_classification: nil
      },
      state: :awaiting_resolution,
      counts: %{selected: 2, published: 0, skipped: 0, warnings: 1, failures: 0},
      repositories: [
        %{
          id: 301,
          github_repository_id: 9_001,
          source_full_name: "octo/alpha",
          source_name: "alpha",
          selected: true,
          destination_owner_id: actor.id,
          destination_slug: "alpha",
          destination_visibility: :private,
          conflict_action: nil,
          state: :queued,
          wait_reason: nil,
          next_attempt_at: nil,
          attempt_count: 0,
          counts: %{imported: 0, skipped: 0, warnings: 1, failures: 0}
        },
        %{
          id: 302,
          github_repository_id: 9_002,
          source_full_name: "octo/beta",
          source_name: "beta",
          selected: true,
          destination_owner_id: actor.id,
          destination_slug: "beta",
          destination_visibility: :public,
          conflict_action: nil,
          state: :awaiting_resolution,
          wait_reason: "repository_conflict",
          next_attempt_at: nil,
          attempt_count: 0,
          counts: %{imported: 0, skipped: 0, warnings: 0, failures: 0}
        }
      ],
      reports: [
        %{
          repository_item_id: 301,
          scope: :repository,
          outcome: :warning,
          classification: "unsupported_releases",
          summary: "GitHub releases are not imported",
          metadata: %{},
          source_count: 0
        }
      ],
      inserted_at: ~U[2026-08-26 07:00:00Z],
      updated_at: ~U[2026-08-26 07:01:00Z]
    }
  end

  defp account(identity_id, login, credential_status) do
    credential_present = credential_status in [:valid, :invalid]

    %GitHubAccountView{
      identity_id: identity_id,
      github_user_id: 90_000 + identity_id,
      login: login,
      display_name: "Github:#{login}",
      avatar_url: "https://avatars.githubusercontent.com/u/#{90_000 + identity_id}",
      profile_url: "https://github.com/#{login}",
      credential_present: credential_present,
      credential_status: credential_status,
      identity_last_verified_at: ~U[2026-08-26 08:00:00Z],
      credential_last_verified_at: if(credential_present, do: ~U[2026-08-26 08:01:00Z])
    }
  end

  defp owned_organization_fixture(actor, prefix) do
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

    {:ok, organization} =
      ForgeAccounts.create_organization(actor, %{
        username: "#{prefix}-#{suffix}",
        display_name: "#{prefix} #{suffix}"
      })

    organization
  end

  defp member_organization_fixture(actor, prefix) do
    owner = user_fixture("#{prefix}-owner")
    organization = owned_organization_fixture(owner, prefix)
    {:ok, _membership} = ForgeAccounts.add_organization_member(organization, actor, :member)
    organization
  end

  defp user_fixture(prefix) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Repo.insert!(%User{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
