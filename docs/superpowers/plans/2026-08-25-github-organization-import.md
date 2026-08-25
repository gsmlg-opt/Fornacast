# GitHub Organization Import and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Coordinate selected GitHub organization repositories through independent durable workers, complete crash/rate/credential/cancellation recovery, expose safe progress and successor retry controls, and prove the full supported-content migration end to end.

**Architecture:** The database is authoritative for every run/item phase and terminal report. A small reconciler GenServer schedules bounded `Task.Supervisor.async_nolink` workers that claim item leases; organization imports aggregate per-repository outcomes without making the whole organization atomic.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, Task.Supervisor, Fornacast.OperationLease, Req 0.7/Req.Test, git/erlexec, Turso/PostgreSQL, Phoenix 1.8, PhoenixDuskmoon 9.12, telemetry 1.4

---

**Prerequisite:** Complete `2026-08-25-github-metadata-import.md` first.

**Design:** `docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`

**Command convention:** Prefix Mix commands with:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix <task-and-arguments>
```

Use serial focused database suites. Do not repair failures outside the GitHub import/touched-domain scope.

## File and module map

- Existing `ForgeImports.RecoverySupervisor`: one-for-all Task.Supervisor + reconciler boundary.
- Existing `ForgeImports.Reconciler`: bounded scheduler; runtime state limits concurrency only.
- `ForgeImports.Scheduler`: pure query for claimable runs/items.
- `ForgeImports.Worker` and `Recovery`: lease-owned phase dispatch and durable-fact classification.
- `ForgeImports.OrganizationOrchestrator`: freezes destination and creates/selects one local organization.
- `ForgeImports.Waits`: rate-limit and credential wait/resume behavior.
- `ForgeImports.Cancellation`: cooperative cancellation; publication remains non-interruptible.
- `ForgeImports.Retry`: immutable successor-run creation and validated staging adoption.
- `ForgeImports.Report` and `RunAggregator`: idempotent entries and exact terminal aggregation.
- `FornacastWeb.ImportStatusController` plus `assets/js/import_status.js`: safe progressive polling with no-JS fallback.

### Task 1: Activate a new or existing local organization safely

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/organization_orchestrator.ex`
- Create: `apps/forge_imports/test/organization_orchestration_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`

- [ ] **Step 1: Write destination activation tests**

Cover new and existing organizations, importer as sole new owner, source name fallback, supported description, reserved/ownership drift, no GitHub member/team import, existing profile/membership preservation, at least one selected repository, mixed not-selected items, and organization survival when every repository later fails.

```elixir
assert {:ok, activated} =
         ForgeImports.start_import(actor, run.id, request_metadata,
           dispatch: :manual
         )

assert activated.destination_organization.username == "acme"
assert ForgeAccounts.organization_role(actor, activated.destination_organization) == :owner
assert ForgeAccounts.list_user_organizations(other_github_member) == []
```

- [ ] **Step 2: Run the organization orchestration test before implementation**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/organization_orchestration_test.exs --max-cases 1
```

Expected: FAIL because organization plan activation is absent.

- [ ] **Step 3: Implement the actor-aware transaction**

Public/internal contracts:

```elixir
ForgeImports.start_import(actor, run_id, request_metadata, opts \\ [])
OrganizationOrchestrator.freeze_and_activate(actor, run, request_metadata)
OrganizationOrchestrator.create_destination_organization(repo, actor, run)
OrganizationOrchestrator.activate_existing_organization(repo, actor, run)
ForgeAccounts.create_import_organization(actor, attrs, request_metadata)
```

For a new destination, create the organization and importer owner membership transactionally using supported source name/description, then freeze selected items. For an existing destination, lock/recheck local `:owner` membership and preserve profile/memberships. Do not allow a site-admin override. Commit `ready -> running`, audit, and destination ID together before dispatch.

Each repository remains an independent item. A later item failure never deletes the organization or rolls back a published sibling.

- [ ] **Step 4: Run organization and account tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/organization_orchestration_test.exs apps/forge_accounts/test/forge_accounts_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit organization activation**

```bash
git add apps/forge_imports apps/forge_accounts
git commit -m "feat(import): activate GitHub organization plans"
```

### Task 2: Generalize recovery scheduling across every durable phase

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/scheduler.ex`
- Create: `apps/forge_imports/lib/forge_imports/worker.ex`
- Create: `apps/forge_imports/lib/forge_imports/recovery.ex`
- Create: `apps/forge_imports/test/recovery_supervisor_test.exs`
- Create: `apps/forge_imports/test/reconciler_test.exs`
- Create: `apps/forge_imports/test/worker_recovery_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Modify: `apps/forge_imports/lib/forge_imports/recovery_supervisor.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_worker.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Write startup/crash/lease/concurrency tests**

Test startup reconciliation, expired and live leases, bounded global concurrency, task crash, reconciler/supervisor restart, lease renewal/loss during Git and REST pages, phase replay from durable evidence, and proof that a worker return value or PID never advances SQL state.

```elixir
assert item.state == :staging_metadata
send(reconciler, :tick)
assert eventually(fn -> claimed_by_worker?(item.id) end)
Process.exit(active_worker(item.id), :kill)
assert eventually(fn -> recovered_from_checkpoint?(item.id) end)
```

- [ ] **Step 2: Run recovery tests and expose current one-scan limitations**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/recovery_supervisor_test.exs apps/forge_imports/test/reconciler_test.exs apps/forge_imports/test/worker_recovery_test.exs --max-cases 1
```

Expected: FAIL for unhandled phases and missing bounded worker tracking.

- [ ] **Step 3: Implement durable scheduling and recovery classification**

Pure/query contracts:

```elixir
Scheduler.claimable_discovery_ids(now, limit)
Scheduler.claimable_item_ids(now, limit)
Worker.run(item_id, lease_owner, opts \\ [])
Recovery.classify(item, durable_facts)
Recovery.reconcile(item, opts \\ [])
```

The reconciler tracks `%Task{}` references only to enforce configured concurrency. On startup and interval ticks, it queries claimable IDs, starts `async_nolink` tasks, and handles result/DOWN/timeout without treating them as completion. Workers claim `RepositoryItem` through `OperationLease`, renew between pages/batches, pass a heartbeat callback into long Git work, and stop on lease loss.

Recovery classifies from staged bare validation, committed mappings/checkpoints, shadow lifecycle, publication marker, terminal report, and credential cleanup. It never infers success from directory existence alone.

- [ ] **Step 4: Run recovery and operation-lease suites**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/recovery_supervisor_test.exs apps/forge_imports/test/reconciler_test.exs apps/forge_imports/test/worker_recovery_test.exs apps/fornacast/test/operation_lease_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit generic recovery**

```bash
git add apps/forge_imports config/config.exs config/test.exs
git commit -m "feat(import): recover durable import workers"
```

### Task 3: Persist rate-limit and credential waits

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/waits.ex`
- Create: `apps/forge_imports/test/waits_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Modify: `apps/forge_imports/lib/forge_imports/github_accounts.ex`

- [ ] **Step 1: Write wait/resume tests**

Cover primary/secondary GitHub rate limits, exact retry boundary, no busy retry, restart during wait, deleted/revoked/expired/insufficient saved credential, one-time replacement, GitHub identity mismatch, exact pre-wait phase restoration, and foreign-run masking.

```elixir
assert {:ok, waiting} = Waits.rate_limited(item, ~U[2026-08-25 11:00:00Z], :secondary)
assert waiting.wait_reason == :rate_limit
refute Scheduler.claimable?(waiting, ~U[2026-08-25 10:59:59Z])
assert Scheduler.claimable?(waiting, ~U[2026-08-25 11:00:00Z])
```

- [ ] **Step 2: Run and verify wait transitions are incomplete**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/waits_test.exs --max-cases 1
```

Expected: FAIL because `Waits` is missing.

- [ ] **Step 3: Implement waits without losing the work phase**

```elixir
Waits.rate_limited(item, retry_at, classification)
Waits.awaiting_credential(run, item, resume_state)
Waits.resume_with_credential(actor, run, credential_source, request_metadata, opts \\ [])
ForgeImports.replace_run_credential(actor, run_id, credential_source, request_metadata, opts \\ [])
```

Store `wait_reason`, `resume_state`, and `next_attempt_at`. Exclude future retry times from scheduler queries. All GitHub settings deletion/replacement routes already pass through `ForgeImports`; credential deletion transactionally moves affected unfinished runs/items to `awaiting_credential`. Recovery detects out-of-band missing credentials and performs the same transition.

Replacement credentials must verify the same GitHub numeric account before resuming. Restore each item to its exact persisted phase.

- [ ] **Step 4: Run waits, accounts, and scheduler tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/waits_test.exs apps/forge_imports/test/github_accounts_test.exs apps/forge_imports/test/reconciler_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit durable waits**

```bash
git add apps/forge_imports
git commit -m "feat(import): pause for GitHub limits and credentials"
```

### Task 4: Implement cooperative cancellation and cleanup reconciliation

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/cancellation.ex`
- Create: `apps/forge_imports/lib/forge_imports/cleanup_reconciler.ex`
- Create: `apps/forge_imports/test/cancellation_test.exs`
- Create: `apps/forge_imports/test/cleanup_reconciler_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/worker.ex`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`

- [ ] **Step 1: Write phase-by-phase cancellation tests**

Cover discovery, queued, Git, metadata page, ready-to-publish, publishing race, already-published siblings, restart after intent, whole Git process-group termination, one-time envelope deletion, failed-shadow cleanup, tombstone grace, and live-lease refusal.

- [ ] **Step 2: Run cancellation tests before public control exists**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/cancellation_test.exs apps/forge_imports/test/cleanup_reconciler_test.exs --max-cases 1
```

Expected: FAIL for missing cancellation/cleanup orchestration.

- [ ] **Step 3: Persist intent first and make cleanup replay-safe**

```elixir
Cancellation.request(actor, run, request_metadata)
Cancellation.check(item)
CleanupReconciler.reconcile(now, limit)
ForgeImports.request_cancel(actor, run_id, request_metadata)
```

Request cancellation commits run intent, item intents, and a sanitized `github_import.cancel_requested` audit before signaling workers. Scheduler stops queued work. The Milestone 2 Git runner's `:cancel?` callback observes durable intent and terminates its managed group; REST checks between pages and object batches. Never interrupt `publishing`; if publication commits first, mark that item successful.

Cleanup processes only unpublished staging or grace-expired tombstones after proving no import/Git-write/merge lease. Terminal run transition and one-time envelope clearing commit together.

- [ ] **Step 4: Run cancellation, remote, publication, and cleanup tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/cancellation_test.exs apps/forge_imports/test/cleanup_reconciler_test.exs apps/git_core/test/remote_test.exs apps/forge_imports/test/repository_publication_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit cancellation**

```bash
git add apps/forge_imports
git commit -m "feat(import): cancel and clean import runs"
```

### Task 5: Create immutable successor retries

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/retry.ex`
- Create: `apps/forge_imports/test/retry_test.exs`
- Create: `apps/fornacast/priv/repo/migrations/20260825000600_add_import_recovery_constraints.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`

- [ ] **Step 1: Write successor eligibility/adoption tests**

Test partial organization success, failed/canceled eligibility, intentional skip exclusion, published exclusion, predecessor links, checkpoint/shadow adoption, corrupt evidence rejection, one-time credential non-copy, required replacement credential, concurrent retry calls, and predecessor immutability.

```elixir
assert {:ok, successor} =
         ForgeImports.retry_import(actor, predecessor.id, {:saved, identity.id}, request_metadata)

assert successor.predecessor_run_id == predecessor.id
assert Enum.all?(successor.repositories, &(&1.predecessor_item_id != nil))
assert Repo.reload!(predecessor).state == :completed_with_warnings
```

- [ ] **Step 2: Run and verify terminal rows currently cannot retry**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/retry_test.exs --max-cases 1
```

Expected: FAIL with no successor API.

- [ ] **Step 3: Implement successor creation in one ownership transaction**

```elixir
Retry.create_successor(actor, predecessor, credential_source, request_metadata)
Retry.adopt_staging(repo, predecessor_item, successor_item)
```

Copy only retryable unpublished items. Validate every adopted shadow, staging directory, Git evidence, object mapping, and checkpoint before attaching it to the successor. Never copy a one-time envelope or modify predecessor items/report. The migration adds partial unique indexes on non-null run/item predecessor IDs plus scheduler indexes on state, next-attempt time, and lease expiry. Those constraints prevent concurrent duplicate successors while allowing a failed successor to be retried as the next link in the chain. Record a `github_import.retry_created` audit with both run IDs.

- [ ] **Step 4: Run retry and persistence tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/retry_test.exs apps/forge_imports/test/import_persistence_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit successor retry**

```bash
git add apps/forge_imports apps/fornacast/priv/repo/migrations/20260825000600_add_import_recovery_constraints.exs
git commit -m "feat(import): retry with immutable successor runs"
```

### Task 6: Finalize reports and exact terminal aggregation

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/report.ex`
- Create: `apps/forge_imports/lib/forge_imports/run_aggregator.ex`
- Create: `apps/forge_imports/lib/forge_imports/report_view.ex`
- Create: `apps/forge_imports/test/report_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/run_view.ex`
- Modify: `apps/forge_imports/lib/forge_imports/report_entry.ex`
- Modify: `apps/forge_imports/lib/forge_imports/worker.ex`

- [ ] **Step 1: Write every aggregation/report outcome test**

Cover all success, mixed success/failure, warning, all-intentional-skip, nothing-published failure, cancellation with published siblings, not-selected exclusion, idempotent entry keys, bounded metadata, unsupported-category names without unsupported-only fetches, audit parity, terminal immutability, and atomic one-time cleanup.

- [ ] **Step 2: Run and verify current count fields are insufficient**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/report_test.exs --max-cases 1
```

Expected: FAIL for missing report finalization/aggregation.

- [ ] **Step 3: Implement idempotent reports and run completion**

```elixir
Report.record(repo, attrs)
Report.finalize(run_id)
RunAggregator.finish_if_terminal(run_id)
ReportView.load(actor, run_id)
```

Use unique `(import_run_id, idempotency_key)` entries. Outcomes are `imported | skipped | warning | failed | canceled | not_selected`. Commit the final report summary, exact terminal state, completion audit, and one-time credential clearing in one transaction.

Aggregation:

```elixir
def terminal_state(%{all_published?: true, warnings?: false}), do: :completed
def terminal_state(%{cancel_requested?: true, unpublished: count}) when count > 0, do: :canceled
def terminal_state(%{published: 0, runnable_failed?: true}), do: :failed
def terminal_state(%{all_terminal?: true}), do: :completed_with_warnings
```

Order the real implementation so a committed publication remains successful when cancellation races.

- [ ] **Step 4: Run reports, cancellation, and metadata accounting tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/report_test.exs apps/forge_imports/test/cancellation_test.exs apps/forge_imports/test/github/metadata_importer_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit reporting**

```bash
git add apps/forge_imports
git commit -m "feat(import): finalize durable import reports"
```

### Task 7: Add safe progress polling and final web controls

**Files:**

- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_status_controller.ex`
- Create: `apps/fornacast_web/assets/js/import_status.js`
- Create: `apps/fornacast_web/test/import_status_controller_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/show.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/organization.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/assets/js/app.js`
- Modify: `apps/fornacast_web/test/import_controller_test.exs`
- Modify: `apps/fornacast_web/test/import_html_test.exs`

- [ ] **Step 1: Write session isolation, safe JSON, and no-JS tests**

Cover authenticated owner status, foreign-run 404, safe bounded JSON, rate-limit resume time, awaiting-credential form, cancel, successor retry, report view, mixed organization rows, polling failure fallback, CSRF, and no `/api/v3` or OpenAPI route changes.

```elixir
body = json_response(get(authenticated_conn(actor), "/imports/#{run.id}/status"), 200)
assert body["state"] == "running"
refute inspect(body) =~ "credential_ciphertext"
refute inspect(body) =~ "github_pat_"
```

- [ ] **Step 2: Run web tests before routes/controls exist**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/import_status_controller_test.exs apps/fornacast_web/test/import_controller_test.exs apps/fornacast_web/test/import_html_test.exs --max-cases 1
```

Expected: FAIL for missing status/cancel/retry/credential routes.

- [ ] **Step 3: Add web-session-only routes and progressive polling**

```elixir
get "/imports/:id/status", ImportStatusController, :show
post "/imports/:id/cancel", ImportController, :cancel
post "/imports/:id/retry", ImportController, :retry
post "/imports/:id/credential", ImportController, :credential
get "/imports/:id/report", ImportController, :report
```

`ImportStatusController` returns only `%RunView{}` phase/count/retry-time/published-link data with `private, no-store`. `import_status.js` polls only elements with an owner-scoped data URL, updates accessible text/progress, backs off on failure, and never replaces ordinary forms/manual refresh. New HEEx remains PhoenixDuskmoon-only; invoke the `phoenix-duskmoon-design` guidance before implementation.

Delegate `get_status(actor, run_id)` and `get_report(actor, run_id)` from `ForgeImports`; both mask foreign runs as `:not_found` and return safe view structs only.

- [ ] **Step 4: Run web, router-contract, and asset tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/import_status_controller_test.exs apps/fornacast_web/test/import_controller_test.exs apps/fornacast_web/test/import_html_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix assets.build
```

Expected: all tests pass, assets build, and API operation manifests remain unchanged.

- [ ] **Step 5: Commit final controls**

```bash
git add apps/fornacast_web apps/fornacast_api/test/openapi_contract_test.exs
git commit -m "feat(web): manage GitHub import progress"
```

### Task 8: Emit bounded telemetry and prove privacy boundaries

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/telemetry.ex`
- Create: `apps/forge_imports/test/telemetry_test.exs`
- Create: `apps/forge_imports/test/import_security_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/github/client.ex`
- Modify: `apps/forge_imports/lib/forge_imports/worker.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_publisher.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_cleanup.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/organization_controller.ex`
- Modify: `apps/fornacast_web/test/organization_controller_test.exs`

- [ ] **Step 1: Write telemetry/redaction/namespace privacy tests**

Assert bounded events for phase duration, GitHub outcome, rate pause, staged bytes, publication, retry, cancellation, cleanup, and completion. Reject names, usernames, URLs, paths, PATs, authorization headers, raw Git/HTTP bodies, and exception strings. Reprove arbitrary authenticated users cannot see imported private repository metadata on namespace pages.

- [ ] **Step 2: Run and inspect current missing/unbounded events**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/telemetry_test.exs apps/forge_imports/test/import_security_test.exs apps/fornacast_web/test/organization_controller_test.exs --max-cases 1
```

Expected: FAIL for missing telemetry and any remaining unsafe metadata.

- [ ] **Step 3: Add a single telemetry wrapper and sanitize every call site**

```elixir
def execute(event, measurements, metadata)
    when is_list(event) and is_map(measurements) and is_map(metadata) do
  :telemetry.execute([:fornacast, :github_import | event], measurements, bounded(metadata))
end
```

Allow only numeric IDs/counts, bounded phase/error atoms, booleans, and durations. Keep namespace pages on the actor-aware repository-view API introduced in Milestone 2.

- [ ] **Step 4: Run telemetry/security tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/telemetry_test.exs apps/forge_imports/test/import_security_test.exs apps/fornacast_web/test/organization_controller_test.exs --max-cases 1
```

Expected: all tests pass with no secret-bearing captured term.

- [ ] **Step 5: Commit observability/privacy hardening**

```bash
git add apps/forge_imports apps/fornacast_web
git commit -m "feat(import): observe imports without leaking metadata"
```

### Task 9: Prove the full organization workflow and document operations

**Files:**

- Create: `apps/forge_imports/test/support/fake_github.ex`
- Create: `apps/forge_imports/test/support/git_remote_fixture.ex`
- Create: `apps/forge_imports/test/github_import_e2e_test.exs`
- Create: `docs/github-imports.md`
- Modify: `apps/forge_imports/test/test_helper.exs`
- Modify: `README.md`
- Modify: `.env.example`
- Modify FK-safe reset helpers in touched test suites only.

- [ ] **Step 1: Write the end-to-end matrix using Req.Test and local Git fixtures**

Prove saved/one-time repository import, organization selection with success/skip/rename/replace/failure, exact metadata, rate wait, credential replacement, restart during Git and pagination, cancellation, successor retry, atomic visibility/replacement, complete report, and no PAT in logs/audits/argv/config/report/files.

- [ ] **Step 2: Run the isolated E2E test and close only in-scope failures**

```bash
devenv shell -- env FORNACAST_TEST_DATABASE_PATH=/tmp/fornacast-github-import-e2e.db nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/github_import_e2e_test.exs --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 3: Document configuration, rotation, lifecycle, and limits**

`docs/github-imports.md` must document:

- saved versus one-time PAT behavior and GitHub permission/approval failures;
- `FORNACAST_GITHUB_CREDENTIAL_KEYS` JSON keyring and active-key ID;
- key rotation order: add old+new, switch active, re-encrypt, then remove old;
- repository size/time/concurrency and cleanup grace settings;
- supported/unsupported data, including releases and fork PRs;
- conflict/replacement semantics and new local repository ID;
- rate-limit, awaiting-credential, cancel, retry, and report behavior; and
- optional public-source live smoke without credential persistence.

Update README and `.env.example` with links and non-secret example shapes only.

- [ ] **Step 4: Run the complete scoped Turso/PostgreSQL and browser acceptance matrix**

Turso:

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=turso FORNACAST_TEST_DATABASE_PATH=/tmp/fornacast-github-import-final.db nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast/test apps/forge_accounts/test apps/forge_repos/test apps/forge_issues/test apps/forge_pulls/test apps/git_core/test apps/git_transport/test apps/forge_imports/test apps/fornacast_web/test apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

PostgreSQL:

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast/test apps/forge_accounts/test apps/forge_repos/test apps/forge_issues/test apps/forge_pulls/test apps/git_core/test apps/git_transport/test apps/forge_imports/test apps/fornacast_web/test apps/fornacast_api/test/issue_contract_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
```

Then run:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix format --check-formatted
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix assets.build
```

Start the dev service and use Chrome DevTools to verify `/settings/github`, `/repos/import`, `/organizations/import`, conflict review, progress, awaiting-credential, and final report at 1440×900, 768×1024, and 390×844. Verify keyboard focus, labels, status announcements, polling fallback, no overflow, and no secret in DOM/network/logs.

- [ ] **Step 5: Commit final acceptance/docs corrections**

```bash
git status --short
git diff --check
git add apps config docs README.md .env.example mix.exs mix.lock
git commit -m "test(import): verify GitHub organization migration"
```

Do not create an empty commit. If an out-of-scope test fails, record it and stop instead of modifying unrelated code.
