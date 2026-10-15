# Admin Styx Jobs Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independent domain
> and web slices. Parent serializes Mix commands and integrates the agreed API.

**Goal:** Add a Gitea-like Admin area containing a safe, read-only Styx Jobs view.

**Architecture:** A persisted-role domain boundary returns bounded, safe job
projections. Web authenticates and authorizes access, then renders a DuskMoon
sidebar, filters and table under the collision-free `/-/admin` namespace.

**Tech Stack:** Elixir, Phoenix HTML, DuskMoon, Ecto/PostgreSQL 17, Styx.

## Task 1: Domain listing and authorization

Files: create `apps/forge_imports/lib/forge_imports/admin_jobs.ex` and
`apps/forge_imports/test/admin_jobs_test.exs`.

- [x] Add failing authorization/projection/filter/pagination/association tests.
  A demoted actor must fail even when its supplied struct still says admin:
  ```elixir
  Repo.update!(Ecto.Changeset.change(admin, role: :user))
  assert {:error, :forbidden} = AdminJobs.list_jobs(admin, %{})
  ```
- [x] Implement `ForgeImports.AdminJobs.list_jobs(actor, params \\ %{})`.
  Use `ForgeAccounts.get_session_user(actor.id)` and require active user/admin.
  Validate state against `Styx.Job.states()` as strings and page as a positive
  integer <= 10000; queue input must be a bounded string. No atom conversion.
- [x] Query newest jobs using `Styx.Job.query/1`, Ecto order/offset and limit 51.
  Return `{:ok, %{jobs: jobs, queues: queues, filters: %{queue: queue, state: state},
  page: page, has_next?: boolean}}`, or `{:error, :forbidden | :invalid_filter}`.
  Empty queue/state filters normalize to nil; page size is fixed at 50.
- [x] Each job exposes id/state/queue/worker/attempt/max_attempts/priority,
  inserted_at/scheduled_at/attempted_at/completed_at/discarded_at/cancelled_at,
  error_count, and task_path (nil or canonical organization task path).
  Select error counts in SQL; do not load raw error bodies. Use only internal
  identifier args for batch association; omit args/meta/errors from output.
- [x] Test current Styx queue/state filters and 51-job pagination. Assert secret
  sentinel strings in args/meta/errors never occur in serialized projections.
- [x] Run `mix test apps/forge_imports/test/admin_jobs_test.exs` on the project
  PostgreSQL socket and isolated `fornacast_styx_test` database.

## Task 2: Admin shell, navigation and requests

Files: modify `apps/fornacast_web/lib/fornacast_web/html.ex` and `router.ex`;
create `plugs/require_admin.ex`, `controllers/admin_jobs_controller.ex`,
`controllers/admin_jobs_html.ex`, `controllers/admin_jobs_html/index.html.heex`,
and `apps/fornacast_web/test/admin_jobs_controller_test.exs`.

- [x] Add failing requests: anonymous -> /login; normal user -> 403; admin ->
  page 200. Assert ordinary organization owners cannot access global jobs.
- [x] Add Admin to shared account menu only for active site administrators.
- [x] Add admin pipeline after browser/authenticated and private_no_store.
  ```elixir
  scope "/-/admin", FornacastWeb do
    pipe_through [:private_no_store, :browser, :authenticated, :admin]
    get "/", AdminJobsController, :index
    get "/jobs", AdminJobsController, :jobs
  end
  ```
- [x] Root redirects to jobs. Controller delegates to AdminJobs; invalid filters
  render an explicit 400, forbidden access 403. Render with shared page helper.
- [x] Add Gitea-like left navigation with Admin heading and active Styx Jobs
  item. Use DuskMoon controls/table and existing responsive settings-grid classes.
  Show filters, a manual refresh link, empty state and filter-preserving paging.
  Link related tasks; explain execution completion and pruned queue history.
- [x] Test no raw job data exposure, account menu visibility, persisted role
  revocation, current sidebar item, filter/paging links and /admin owner route.
- [x] Run `mix test apps/fornacast_web/test/admin_jobs_controller_test.exs`.

## Task 3: Integration verification and durable record

- [x] Review spec compliance and implementation quality.
- [x] Run both focused PostgreSQL test files serially through root devenv shell.
  Set PGHOST=/run/user/1000/devenv-aafe62d/postgres, PGPORT=55432 and
  POSTGRES_TEST_DB=fornacast_styx_test; change directory to this worktree.
- [x] Format changed ex/exs/heex files; check formatting and `git diff --check`.
- [x] Compile with warnings as errors in development and build assets.
- [x] Record the administration boundary in README and project Agent Note,
  distinguishing the uncommitted feature branch from main/deployed versions.

Implementation scope is the read-only Admin Jobs feature. Delivery follows the
user-authorized commit, main-branch merge and release workflow.

## Verification

- PostgreSQL: 9 domain tests and 39 web/navigation tests passed (48 total).
- Changed-file formatting, development compilation with warnings as errors,
  asset build and `git diff --check` passed.
- Independent source/spec/security review found no actionable findings.
- Desktop (1440px) and mobile (390px) previews use the actual Phoenix renderer
  with synthetic jobs rolled back through the SQL sandbox. These previews do
  not verify a live deployment.
- The final state-label whitespace adjustment passed the 10 focused controller
  tests again and was checked in the rebuilt preview.

Implementation was verified on `codex/admin-styx-jobs`, based on
`a937c98e1083678b492505ef76a73453f86c8c45`.
