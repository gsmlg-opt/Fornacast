# Styx GitHub Synchronization Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the independent runtime and web slices. Parent coordinates shared configuration, serial PostgreSQL checks, integration review and documentation.

**Goal:** Execute the full GitHub organization synchronization chain through Styx and expose durable, truthful task results.

**Architecture:** Styx handles scheduling and delivery; domain leases and publication evidence govern writes and completion. Separate long repository work from quick control work, and read status from organization-authorized business projections.

**Tech Stack:** Elixir/OTP, Styx 0.1.0, Ecto, PostgreSQL 17, Phoenix, DuskMoon.

---

## Task 1: Queue foundation (parent)

Files: `apps/forge_imports/mix.exs`, `mix.lock`, `config/config.exs`,
`config/test.exs`, `apps/fornacast/priv/repo/migrations/20261015000000_add_styx_jobs.exs`.

- [x] Add `{:styx, "~> 0.1.0"}` without updating unrelated dependencies.
- [x] Create migration using `Styx.Migration.up/0` and `down/0`.
- [x] Configure `Fornacast.Repo`, Basic engine, independent queue concurrency,
      maintenance cron, orphan recovery and completed delivery pruning.
- [x] Use manual testing with queues and periodic services disabled.
- [x] Fetch dependencies and validate compilation serially through root devenv.

## Task 2: Runtime migration (runtime worker)

Files: `apps/forge_imports/lib/forge_imports/application.ex`,
`recovery_supervisor.ex`, `pat_sync_worker.ex`, `organization_pat_settings.ex`,
transactional enqueue callsites in discovery/orchestration/retry/wait/cancel,
new `sync_jobs.ex` and worker modules, independent PAT repository result schema
and migration. Tests under `apps/forge_imports/test/`.

- [x] Add small enqueue interface: `enqueue_pat_sync(run_id)`,
      `enqueue_discovery(import_run_id)`, `enqueue_repository(item_id)` and
      `recover/0`, returning checked results from Styx insertions.
- [x] Add independent PAT repository result/lease records before permitting
      parallel updates. Control aggregates results instead of competing JSON writes.
- [x] Replace supervised PAT/import dispatch loops with Styx control,
      discovery, repository and update workers. Preserve cleanup and App inventory.
- [x] Insert initial jobs and continuations transactionally, keeping Git/API
      work outside transactions and only identifiers in serialized arguments.
- [x] Propagate actual failures to finite Styx retries; persist domain failure
      on exhaustion. Keep true waiting separate from errors.
- [x] Bootstrap claimable legacy work respecting unexpired leases and retain
      a bounded periodic repair/aggregation producer.
- [x] Test admission rollback, duplicate delivery, lease ownership, safe
      continuation, recovery and exhausted child aggregation.

## Task 3: Task projection and web management (web worker)

Files: new `apps/forge_imports/lib/forge_imports/pat_sync_queries.ex`,
`apps/fornacast_web/lib/fornacast_web/router.ex`, organization PAT controller,
HTML module/templates, `assets/js/pat_sync_status.js`, focused web tests.

- [x] Add `list_runs(actor, organization_id)` and
      `get_run(actor, organization_id, run_id)` with domain organization
      authorization and explicit safe fields.
- [x] Add canonical GET history/detail and JSON status routes under
      `/organizations/:organization/settings/github/runs`.
- [x] Redirect accepted sync to its returned run; preserve check feedback
      through POST/redirect/GET onto a canonical settings page.
- [x] Always render and poll queued/running tasks through explicit URLs.
      Update status, counts and actions together; show failed connections.
- [x] Display per-repository phases, waits, failures, attempts/timing,
      warnings and actual supported synchronization scope.
- [x] Test initial empty progress, check redirect, duplicate attachment,
      terminal state and another organization owner's access.

## Task 4: Integration and operator documentation (parent)

Files: `README.md`, `docs/deployment.md`, design/plan above, focused integration
tests if implementation seams need additional coverage.

- [x] Review spec compliance, then review concurrency/error/security quality.
- [x] Compile and run scoped import and PAT web tests on the PostgreSQL Unix
      socket with `PGPORT=55432`; serialize Mix/devenv commands.
- [x] Validate polling behavior and asset build; run format check.
- [x] Document stop-before-start cutover, no lease reset, queued recovery and
      job-versus-business-state distinction. Preserve paired backup policy.
- [x] Record a verified project-scoped Agent Note for the new execution seam.

No production replay, restart, release, deployment or Git publication is part
of this implementation request.

## Validation results

Validated on the isolated uncommitted `codex/styx-github-sync` branch with
PostgreSQL 17, `PGPORT=55432`, and the separate `fornacast_styx_test` database.

- Affected import/runtime regressions: 293 passed, including actual Styx queue
  drains through discovery, Git/LFS, metadata, publication and final aggregation.
- PAT web requests and authorized projections: 17 passed.
- JavaScript polling lifecycle: 10 passed.
- `mix assets.build`: Tailwind and JavaScript bundles built successfully.
- Independent specification and code-quality reviews found no remaining gaps.
- Changed-file formatting and development compilation with warnings as errors
  passed. Existing warnings in unchanged test support and legacy regression
  fixtures remain outside this change.

The retained manual Reconciler tests explicitly invoke the recovery seam now
that asynchronous admission schedules Styx rather than waking the legacy loop.

Agent Note `7cafc60a-be1f-4c48-a12a-c353f8bd75b0` was saved with
`project=fornacast` and verified by direct read. It explicitly distinguishes
uncommitted branch behavior from main and the deployed environment.
