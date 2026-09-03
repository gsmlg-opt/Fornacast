defmodule FornacastWeb.RepositoryImportControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias ForgeAccounts.User
  alias ForgeImports.RunView
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint
  @secret "github_pat_repository_import_controller_secret"

  defmodule TestImports do
    def reset do
      Process.put({__MODULE__, :run_result}, {:error, :not_found})
      Process.put({__MODULE__, :resolve_result}, {:error, :not_found})
      Process.delete({__MODULE__, :start_result})
      Process.put({__MODULE__, :calls}, [])
    end

    def run_result(result), do: Process.put({__MODULE__, :run_result}, result)
    def resolve_result(result), do: Process.put({__MODULE__, :resolve_result}, result)
    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def get_run_view(actor, run_id) do
      record(:get_run_view, [actor, run_id])
      Process.get({__MODULE__, :run_result})
    end

    def resolve_repository_conflicts(actor, run_id, decisions, request_metadata) do
      record(:resolve_repository_conflicts, [actor, run_id, decisions, request_metadata])
      Process.get({__MODULE__, :resolve_result})
    end

    def start_import(actor, run_id, request_metadata, opts \\ []) do
      record(:start_import, [actor, run_id, request_metadata, opts])
      Process.get({__MODULE__, :start_result}, {:error, :not_found})
    end

    def start_result(result), do: Process.put({__MODULE__, :start_result}, result)

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
    TestImports.reset()

    %{actor: user_fixture("repository-import")}
  end

  test "conflict review posts canonical skip rename and typed replace decisions", %{actor: actor} do
    view = run_view(actor)
    TestImports.run_result({:ok, view})
    TestImports.resolve_result({:ok, resolved_view(view)})

    shown = request_conn(actor) |> get("/imports/91/conflicts")
    html = html_response(shown, 200)

    assert html =~ "Resolve repository conflicts"
    assert html =~ ~s(action="/imports/91/conflicts" method="post")
    assert html =~ ~s(name="decisions[301][action]")
    assert html =~ ~s(name="decisions[302][slug]")
    assert html =~ ~s(name="decisions[303][confirmation]")
    assert html =~ "#{actor.username}/replace-target"
    refute secret_surfaces(shown) =~ @secret
    assert_private_no_store(shown)

    TestImports.reset()
    TestImports.run_result({:ok, view})
    TestImports.resolve_result({:ok, resolved_view(view)})

    resolved =
      request_conn(actor)
      |> patch("/imports/91/conflicts", %{
        "decisions" => %{
          "301" => %{
            "action" => "skip",
            "slug" => "",
            "confirmation" => "",
            "apply_to_similar" => "true"
          },
          "302" => %{
            "action" => "rename",
            "slug" => "renamed-repository",
            "confirmation" => ""
          },
          "303" => %{
            "action" => "replace",
            "slug" => "",
            "confirmation" => "#{actor.username}/replace-target"
          }
        }
      })

    assert redirected_to(resolved, 303) == "/imports/91/review"
    assert_private_no_store(resolved)

    assert [
             {:get_run_view, [%User{id: actor_id}, 91]},
             {:resolve_repository_conflicts,
              [
                %User{id: resolved_actor_id},
                91,
                %{
                  301 => %{action: :skip, apply_to_similar: true},
                  302 => %{action: :rename, slug: "renamed-repository"},
                  303 => %{
                    action: :replace,
                    confirmation: confirmation
                  }
                },
                request_metadata
              ]}
           ] = TestImports.calls()

    assert actor_id == actor.id
    assert resolved_actor_id == actor.id
    assert confirmation == "#{actor.username}/replace-target"
    assert request_metadata.user_agent == "repository-import-controller-test"
    assert request_metadata.ip_address == "127.0.0.1"
    refute inspect(TestImports.calls()) =~ @secret
  end

  test "review shows start for a resolved awaiting plan and running hides it", %{actor: actor} do
    view = actor |> run_view() |> resolved_view()
    TestImports.run_result({:ok, view})

    conn = request_conn(actor) |> get("/imports/91/review")
    html = html_response(conn, 200)

    assert html =~ ~s(action="/imports/91/start")
    assert html =~ "Start import"
    refute html =~ "Import start is unavailable until metadata import support is installed."

    TestImports.run_result({:ok, %{view | state: :running}})
    running = request_conn(actor) |> get("/imports/91/review")
    running_html = html_response(running, 200)

    refute running_html =~ ~s(action="/imports/91/start")
  end

  test "start posts to the import service and redirects to progress", %{actor: actor} do
    view = actor |> run_view() |> resolved_view()
    TestImports.run_result({:ok, view})
    TestImports.start_result({:ok, %{view | state: :running}})

    conn = request_conn(actor) |> post("/imports/91/start", %{})

    assert redirected_to(conn, 303) == "/imports/91"

    assert Enum.any?(TestImports.calls(), fn
             {:start_import, [^actor, 91, request_metadata, []]} ->
               request_metadata.user_agent == "repository-import-controller-test"

             _ ->
               false
           end)
  end

  test "review is read-only, summarizes decisions and never assigns a PAT", %{actor: actor} do
    view = actor |> run_view() |> resolved_view()
    TestImports.run_result({:ok, %{view | state: :running}})

    conn = request_conn(actor) |> get("/imports/91/review")
    html = html_response(conn, 200)

    assert html =~ "Review import plan"
    assert html =~ "Running"
    assert html =~ "Skip"
    assert html =~ "Rename"
    assert html =~ "Replace"
    assert html =~ "renamed-repository"
    refute html =~ ~s(action="/imports/91/start")

    refute secret_surfaces(conn) =~ @secret
    assert_private_no_store(conn)
  end

  test "blank browser rows are omitted so skip can apply to similar conflicts", %{actor: actor} do
    view = run_view(actor)
    TestImports.run_result({:ok, view})
    TestImports.resolve_result({:ok, resolved_view(view)})

    conn =
      request_conn(actor)
      |> patch("/imports/91/conflicts", %{
        "decisions" => %{
          "301" => %{
            "action" => "skip",
            "apply_to_similar" => "true",
            "slug" => "",
            "confirmation" => ""
          },
          "302" => %{"slug" => "", "confirmation" => ""},
          "303" => %{"slug" => "", "confirmation" => ""}
        }
      })

    assert redirected_to(conn, 303) == "/imports/91/review"

    assert Enum.any?(TestImports.calls(), fn
             {:resolve_repository_conflicts,
              [_actor, 91, %{301 => %{action: :skip, apply_to_similar: true}}, _metadata]} ->
               true

             _call ->
               false
           end)
  end

  test "direct review and conflict routes redirect to the unresolved safe step", %{actor: actor} do
    unresolved = run_view(actor)
    TestImports.run_result({:ok, unresolved})

    review = request_conn(actor) |> get("/imports/91/review")
    assert redirected_to(review, 303) == "/imports/91/conflicts"

    TestImports.reset()
    resolved = resolved_view(unresolved)
    TestImports.run_result({:ok, resolved})

    conflicts = request_conn(actor) |> get("/imports/91/conflicts")
    assert redirected_to(conflicts, 303) == "/imports/91/review"

    TestImports.reset()

    dirty_destination = %{
      resolved
      | destination: %{
          resolved.destination
          | organization_status: :conflict,
            organization_classification: "namespace_conflict"
        }
    }

    TestImports.run_result({:ok, dirty_destination})

    dirty_review = request_conn(actor) |> get("/imports/91/review")
    assert redirected_to(dirty_review, 303) == "/imports/91"

    for {state, resume_state} <- [
          {:discovering, nil},
          {:ready, nil},
          {:awaiting_credential, :awaiting_resolution}
        ],
        path <- ["/imports/91/conflicts", "/imports/91/review"] do
      TestImports.reset()
      TestImports.run_result({:ok, %{unresolved | state: state, resume_state: resume_state}})

      redirected = request_conn(actor) |> get(path)
      assert redirected_to(redirected, 303) == "/imports/91"
    end
  end

  test "foreign and malformed conflict or review requests are masked before mutation", %{
    actor: actor
  } do
    foreign_view = %{run_view(actor) | actor_user_id: actor.id + 10_000}

    for path <- ["/imports/91/conflicts", "/imports/91/review"] do
      TestImports.reset()
      TestImports.run_result({:ok, foreign_view})
      conn = request_conn(actor) |> get(path)
      assert html_response(conn, 404) =~ "Import not found."
      refute conn.resp_body =~ "octo/skip-target"
      refute Enum.any?(TestImports.calls(), &match?({:resolve_repository_conflicts, _}, &1))
      assert_private_no_store(conn)
    end

    TestImports.reset()
    TestImports.run_result({:error, :not_found})

    foreign_patch =
      request_conn(actor)
      |> patch("/imports/91/conflicts", %{"decisions" => %{}})

    assert html_response(foreign_patch, 404) =~ "Import not found."
    refute Enum.any?(TestImports.calls(), &match?({:resolve_repository_conflicts, _}, &1))

    TestImports.reset()
    TestImports.run_result({:ok, run_view(actor)})

    malformed =
      request_conn(actor)
      |> patch("/imports/91/conflicts", %{
        "decisions" => %{
          "303" => %{
            "action" => "replace",
            "slug" => "must-be-empty",
            "confirmation" => "#{actor.username}/replace-target"
          }
        }
      })

    assert html_response(malformed, 422) =~ "Check each repository conflict choice"
    refute Enum.any?(TestImports.calls(), &match?({:resolve_repository_conflicts, _}, &1))
    refute secret_surfaces(malformed) =~ @secret

    TestImports.reset()
    TestImports.run_result({:ok, run_view(actor)})

    pat_shaped =
      request_conn(actor)
      |> patch("/imports/91/conflicts", %{
        "decisions" => %{
          "303" => %{
            "action" => "replace",
            "slug" => "",
            "confirmation" => "#{actor.username}/replace-target",
            "pat" => @secret
          }
        }
      })

    assert html_response(pat_shaped, 422) =~ "Check each repository conflict choice"
    refute Enum.any?(TestImports.calls(), &match?({:resolve_repository_conflicts, _}, &1))
    refute secret_surfaces(pat_shaped) =~ @secret
  end

  test "new conflict and review routes reject anonymous and disabled users before service", %{
    actor: actor
  } do
    requests = [
      {:get, "/imports/91/conflicts", %{}},
      {:patch, "/imports/91/conflicts", %{"decisions" => %{}}},
      {:get, "/imports/91/review", %{}}
    ]

    for {method, path, params} <- requests do
      TestImports.reset()
      conn = request(method, request_conn(nil), path, params)
      assert redirected_to(conn) == "/login"
      assert TestImports.calls() == []
      assert_private_no_store(conn)
    end

    actor
    |> User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    for {method, path, params} <- requests do
      TestImports.reset()
      conn = request(method, request_conn(actor), path, params)
      assert redirected_to(conn) == "/login"
      assert TestImports.calls() == []
      assert_private_no_store(conn)
    end
  end

  test "the conflict PATCH route enforces the rendered CSRF token", %{actor: actor} do
    view = run_view(actor)
    TestImports.run_result({:ok, view})
    form = request_conn(actor) |> get("/imports/91/conflicts")
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, form.resp_body)

    params = %{
      "_csrf_token" => token,
      "decisions" => %{
        "301" => %{
          "action" => "skip",
          "apply_to_similar" => "true",
          "slug" => "",
          "confirmation" => ""
        },
        "302" => %{"slug" => "", "confirmation" => ""},
        "303" => %{"slug" => "", "confirmation" => ""}
      }
    }

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> patch("/imports/91/conflicts", %{params | "_csrf_token" => "invalid"})
    end

    TestImports.resolve_result({:ok, resolved_view(view)})

    accepted =
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> patch("/imports/91/conflicts", params)

    assert redirected_to(accepted, 303) == "/imports/91/review"
  end

  defp request(:get, conn, path, _params), do: get(conn, path)
  defp request(:patch, conn, path, params), do: patch(conn, path, params)

  defp request_conn(actor) do
    conn =
      build_conn()
      |> put_req_header("user-agent", "repository-import-controller-test")
      |> Plug.Conn.put_private(:forge_imports, TestImports)

    if actor, do: Plug.Test.init_test_session(conn, user_id: actor.id), else: conn
  end

  defp recycle_request(conn, actor) do
    conn
    |> recycle()
    |> put_req_header("user-agent", "repository-import-controller-test")
    |> Plug.Conn.put_private(:forge_imports, TestImports)
    |> Plug.Test.init_test_session(user_id: actor.id)
  end

  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp secret_surfaces(conn) do
    [conn.resp_body, inspect(conn.assigns), inspect(conn.resp_headers)]
    |> Enum.join("\n")
  end

  defp assert_private_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp run_view(actor) do
    %RunView{
      id: 91,
      actor_user_id: actor.id,
      source: %{
        kind: :repository,
        owner_github_id: 8_001,
        owner_login: "octo",
        repository_github_id: 9_001,
        repository_full_name: "octo/alpha",
        provenance: %{"credential" => @secret}
      },
      destination: %{
        organization_action: :existing,
        organization_slug: actor.username,
        organization_id: nil,
        organization_status: :clean,
        organization_classification: nil
      },
      state: :awaiting_resolution,
      resume_state: nil,
      wait_reason: nil,
      next_attempt_at: nil,
      terminal_at: nil,
      report_finalized_at: nil,
      counts: %{selected: 3, published: 0, skipped: 0, warnings: 1, failures: 0},
      repositories: [
        repository(301, 9_001, "skip-target"),
        repository(302, 9_002, "rename-target"),
        repository(303, 9_003, "replace-target")
      ],
      reports: [
        %{
          repository_item_id: 303,
          scope: :repository,
          outcome: :warning,
          classification: "repository_conflict",
          summary: "Choose how to handle the existing repository",
          metadata: %{"credential" => @secret},
          source_count: 1
        }
      ],
      inserted_at: ~U[2026-08-28 01:00:00Z],
      updated_at: ~U[2026-08-28 01:01:00Z]
    }
  end

  defp repository(id, github_id, slug) do
    %{
      id: id,
      github_repository_id: github_id,
      source_full_name: "octo/#{slug}",
      source_name: slug,
      selected: true,
      destination_owner_id: 1,
      destination_slug: slug,
      destination_visibility: :private,
      conflict_action: nil,
      state: :awaiting_resolution,
      resume_state: nil,
      wait_reason: "repository_conflict",
      next_attempt_at: nil,
      attempt_count: 0,
      counts: %{imported: 0, skipped: 0, warnings: 0, failures: 0}
    }
  end

  defp resolved_view(view) do
    [skipped, renamed, replaced] = view.repositories

    %{
      view
      | repositories: [
          %{skipped | state: :queued, wait_reason: nil, conflict_action: :skip},
          %{
            renamed
            | state: :queued,
              wait_reason: nil,
              conflict_action: :rename,
              destination_slug: "renamed-repository"
          },
          %{replaced | state: :queued, wait_reason: nil, conflict_action: :replace}
        ]
    }
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
