defmodule FornacastWeb.AdminJobsControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias ForgeAccounts.User
  alias Fornacast.Repo
  alias FornacastWeb.{AdminJobsHTML, HTML}

  @endpoint FornacastWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    %{admin: user_fixture(:admin), user: user_fixture(:user)}
  end

  test "administration requires login or an active site administrator", %{
    admin: admin,
    user: user
  } do
    for path <- ["/-/admin", "/-/admin/jobs"] do
      anonymous = request_conn(nil) |> get(path)
      assert redirected_to(anonymous) == "/login"
      assert_private_no_store(anonymous)

      forbidden = request_conn(user) |> get(path)
      assert response(forbidden, 403) =~ "Site administrator access required."
      assert_private_no_store(forbidden)
    end

    root = request_conn(admin) |> get("/-/admin")
    assert redirected_to(root) == "/-/admin/jobs"
    assert_private_no_store(root)
  end

  test "organization ownership does not grant global jobs access", %{user: user} do
    assert {:ok, _organization} =
             ForgeAccounts.create_organization(user, %{
               username: unique("owned-org"),
               display_name: "Owned organization"
             })

    conn = request_conn(user) |> get("/-/admin/jobs")
    assert response(conn, 403) =~ "Site administrator access required."
    assert_private_no_store(conn)
  end

  test "jobs page renders the active Admin sidebar and explicit empty history", %{admin: admin} do
    queue = unique("empty")
    job_fixture(queue, state: "completed")

    conn =
      request_conn(admin) |> get("/-/admin/jobs", %{"queue" => queue, "state" => "retryable"})

    html = html_response(conn, 200)
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "nav[aria-label='Administration']") |> LazyHTML.text() =~
             "Admin"

    assert LazyHTML.attribute(LazyHTML.query(document, "a[aria-current='page']"), "href") == [
             "/-/admin/jobs"
           ]

    assert html =~ "No jobs found"

    assert LazyHTML.query(document, ".page-heading .eyebrow") |> LazyHTML.text() ==
             "Administration"

    assert html =~ "not successful domain synchronization"
    assert html =~ "Queue history is pruned"
    assert html =~ ~s(method="get")
    assert_private_no_store(conn)
  end

  test "raw arguments, metadata and error bodies never reach the jobs response", %{admin: admin} do
    queue = unique("safe")
    secret = "job-secret-#{unique("sentinel")}"

    job =
      job_fixture(queue,
        args: %{"token" => secret},
        meta: %{"private" => secret},
        errors: [%{"attempt" => 1, "error" => "stacktrace: #{secret}"}],
        attempt: 1,
        max_attempts: 7,
        priority: 3
      )

    conn = request_conn(admin) |> get("/-/admin/jobs", %{"queue" => queue})
    html = html_response(conn, 200)
    document = LazyHTML.from_document(html)

    assert html =~ job.worker
    assert html =~ "1/7"
    assert LazyHTML.query(document, "td[data-label='Error count']") |> LazyHTML.text() == "1"
    assert LazyHTML.query(document, "td[data-label='Priority']") |> LazyHTML.text() == "3"
    assert html =~ "Lifecycle timestamps (UTC)"
    refute html =~ secret
    refute html =~ "stacktrace:"

    refute Enum.any?(
             LazyHTML.query(document, "[data-admin-page] a, [data-admin-page] button"),
             fn action ->
               action
               |> LazyHTML.text()
               |> String.trim()
               |> String.match?(~r/\A(?:retry|cancel|delete)(?: job)?\z/i)
             end
           )

    assert_private_no_store(conn)
  end

  test "filters select matching jobs and pagination and refresh retain filters", %{admin: admin} do
    queue = unique("paged")
    for _index <- 1..51, do: job_fixture(queue, state: "completed")
    job_fixture(queue, state: "retryable", worker: "HiddenStateWorker")
    job_fixture(unique("other"), state: "completed", worker: "HiddenQueueWorker")

    params = %{"queue" => queue, "state" => "completed"}
    first = request_conn(admin) |> get("/-/admin/jobs", params)
    first_html = html_response(first, 200)
    first_document = LazyHTML.from_document(first_html)

    assert Enum.count(LazyHTML.query(first_document, "#admin-jobs-table tbody tr")) == 50
    refute first_html =~ "HiddenStateWorker"
    refute first_html =~ "HiddenQueueWorker"
    assert_link_filters(first_document, "a[rel='next']", queue, "completed", "2")
    assert_link_filters(first_document, "a", queue, "completed", "1", "Refresh")

    second = request_conn(admin) |> get("/-/admin/jobs", Map.put(params, "page", "2"))
    second_document = html_response(second, 200) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query(second_document, "#admin-jobs-table tbody tr")) == 1
    assert_link_filters(second_document, "a[rel='prev']", queue, "completed", "1")
    assert Enum.count(LazyHTML.query(second_document, "a[rel='next']")) == 0
    assert_private_no_store(first)
    assert_private_no_store(second)
  end

  test "invalid filter values render a visible 400 and no raw input", %{admin: admin} do
    for params <- [
          %{"state" => "<script>bad-state</script>"},
          %{"queue" => %{"nested" => "secret"}},
          %{"page" => "0"},
          %{"page" => "10001"},
          %{"unexpected" => "secret"}
        ] do
      conn = request_conn(admin) |> get("/-/admin/jobs", params)
      html = html_response(conn, 400)
      assert html =~ "Invalid jobs filter."
      assert html =~ ~s(role="alert")
      refute html =~ "<script>bad-state</script>"
      refute html =~ "secret"
      assert_private_no_store(conn)
    end
  end

  test "persisted demotion and disablement revoke an existing browser session", %{admin: admin} do
    conn = request_conn(admin) |> get("/-/admin/jobs")
    assert html_response(conn, 200) =~ ~s(href="/-/admin")

    admin |> Ecto.Changeset.change(role: :user) |> Repo.update!()
    demoted = conn |> recycle() |> get("/-/admin/jobs")
    assert response(demoted, 403) =~ "Site administrator access required."
    assert_private_no_store(demoted)

    admin |> Ecto.Changeset.change(state: :disabled) |> Repo.update!()
    disabled = conn |> recycle() |> get("/-/admin/jobs")
    assert redirected_to(disabled) == "/login"
    assert_private_no_store(disabled)
  end

  test "both shared shells expose Admin only for active user administrators", %{
    admin: admin,
    user: user
  } do
    for actor <- [admin, user, %{admin | state: :disabled}] do
      for shell <- [:page, :repository_page] do
        conn = build_conn() |> Plug.Conn.assign(:current_user, actor)

        rendered =
          case shell do
            :page -> HTML.page(conn, "Example", "content")
            :repository_page -> HTML.repository_page(conn, "Example", {:safe, "content"})
          end

        if actor == admin,
          do: assert(rendered.resp_body =~ ~s(href="/-/admin">Admin</a>)),
          else: refute(rendered.resp_body =~ ~s(href="/-/admin">Admin</a>))
      end
    end
  end

  test "the valid account name admin keeps its profile route", %{user: viewer} do
    named_admin = user_fixture(:user, "admin")
    conn = request_conn(viewer) |> get("/admin")
    assert html_response(conn, 200) =~ named_admin.username

    assert Phoenix.Router.route_info(FornacastWeb.Router, "GET", "/admin", "localhost").plug ==
             FornacastWeb.OrganizationController
  end

  test "safe related task paths render links and unrelated jobs have none" do
    path = "/organizations/example/settings/github/runs/42"
    job = safe_job(%{id: 1, task_path: path})

    listing = %{
      jobs: [job, safe_job(%{id: 2})],
      queues: ["github_control"],
      filters: %{queue: nil, state: nil},
      page: 1,
      has_next?: false
    }

    document =
      AdminJobsHTML.index(%{listing: listing, error: nil, __changed__: nil})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(document, "td[data-label='Related task'] a"), "href") ==
             [path]
  end

  defp assert_link_filters(document, selector, queue, state, page, text \\ nil) do
    links = LazyHTML.query(document, selector)

    links =
      if text,
        do: Enum.filter(links, &(LazyHTML.text(&1) |> String.trim() == text)),
        else: Enum.to_list(links)

    assert [link] = links
    [href] = LazyHTML.attribute(link, "href")

    assert URI.decode_query(URI.parse(href).query) == %{
             "queue" => queue,
             "state" => state,
             "page" => page
           }
  end

  defp request_conn(user) do
    session = if user, do: [user_id: user.id], else: []
    build_conn() |> Plug.Test.init_test_session(session)
  end

  defp user_fixture(role, username \\ nil) do
    value = username || unique("jobs-#{role}")

    Repo.insert!(%User{
      username: value,
      email: "#{value}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: role,
      state: :active
    })
  end

  defp job_fixture(queue, opts) do
    {args, opts} = Keyword.pop(opts, :args, %{})
    opts = Keyword.merge([queue: queue, worker: "AdminJobsWebTestWorker", priority: 0], opts)
    args |> Styx.Job.new(opts) |> Repo.insert!()
  end

  defp safe_job(attrs) do
    Map.merge(
      %{
        id: 1,
        state: "completed",
        queue: "github_control",
        worker: "ExampleWorker",
        attempt: 1,
        max_attempts: 3,
        priority: 0,
        error_count: 0,
        inserted_at: ~U[2026-10-15 00:00:00Z],
        scheduled_at: ~U[2026-10-15 00:00:00Z],
        attempted_at: nil,
        completed_at: nil,
        discarded_at: nil,
        cancelled_at: nil,
        task_path: nil
      },
      attrs
    )
  end

  defp unique(prefix),
    do: "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)}"

  defp assert_private_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end
end
