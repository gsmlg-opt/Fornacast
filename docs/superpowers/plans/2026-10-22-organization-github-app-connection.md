# Organization GitHub App Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect, verify and synchronize GitHub App installations from an organization, without storing or executing under a personal saved GitHub identity.

**Architecture:** Keep encrypted organization credentials in ForgeAccounts, provider installation/inventory transport in ForgeGitHub, connection bindings in ForgeMirrors, and orchestration in ForgeImports. Extend existing import and synchronization source dispatch and domain write admission. Preserve personal credentials, existing jobs, publication fences and the installation-token integration.

**Tech Stack:** Elixir umbrella, Ecto/PostgreSQL 17, Phoenix controllers and SessionProcess, PhoenixDuskmoon, existing Styx queues and Git/LFS workers.

---

The user approved the replacement design and requested parallel execution in AGENTS.md. Work continues in the existing authorized checkout on main, preserving the uncommitted follow-ups. Do not move or reset that work. Do not commit/push/release before the user's existing real-sync acceptance condition is satisfied. Mix compilation/tests are serialized by the parent; implementers must request a test slot. Never modify the running development jobs or credentials to make fixtures pass.

## Contracts and ownership

- Accounts implementer: new organization credential schema/context, organization AAD vault extension, refresh coordinator and tests; migration `20261022000200`.
- Sync implementer: configuration/run/import source fields, all execution and recovery authority boundaries, organization write admission and Git/LFS handoff; migration `20261022000400`.
- Parent: provider installation APIs, ForgeMirrors organization binding, ForgeImports connection facade, organization Device Flow routes/session/UI, documentation and browser acceptance; migration `20261022000300`.
- Each implementer preserves others' edits. Shared interfaces are communicated before dependent edits. No database/ForgeMirrors dependency is added to lower domain contexts.

The worker credential reference is an immutable scope:

```elixir
%{organization_id: organization_id,
  credential_id: credential_id,
  verification_version: verification_version}
```

Connection scope adds `connection_id`, `connection_version`, `installation_id`, immutable `github_organization_id`, and repository inventory. Run snapshots keep these fields. Ordinary token renewal changes material generation only.

### Task 1: Independent encrypted organization credentials

**Files:**
- Create: `apps/forge_accounts/lib/forge_accounts/organization_github_credential.ex`
- Create: `apps/forge_accounts/lib/forge_accounts/organization_github_credentials.ex`
- Modify: `apps/forge_accounts/lib/forge_accounts/github_credential_vault.ex`
- Create: `apps/forge_github/lib/forge_github/organization_credential.ex`
- Create: `apps/fornacast/priv/repo/migrations/20261022000200_create_organization_github_credentials.exs`
- Test: `apps/forge_accounts/test/organization_github_credentials_test.exs`

- [x] Add PostgreSQL regressions for owner-only capture/save, concurrent replacement, independent credential ownership and encrypted token purposes. Core regression:

```elixir
assert {:ok, expected} = OrganizationGitHubCredentials.reference(owner, organization.id)
assert {:ok, saved} = OrganizationGitHubCredentials.save_device_grant_if_current(
  owner, organization.id, profile, token, expected, %{})
assert saved.organization_id == organization.id
assert ForgeAccounts.list_github_accounts(owner) == {:ok, []}
assert {:error, :stale} = OrganizationGitHubCredentials.save_device_grant_if_current(
  owner, organization.id, profile, token, expected, %{})
```

- [x] Implement schema with organization ownership, nullable local authorizer provenance, verified GitHub user/client/App binding, redacted token pair, expiries, credential state, verification version, material generation and durable refresh claim. Local-user removal does not cascade-delete it.
- [x] Implement `reference/2`, `save_device_grant_if_current/6`, `disconnect_if_current/4`, `with_credential/2`, `refresh_credential/3`. Save/disconnect support the outer orchestration transaction and lock live local actor/organization before mutation. Public results never expose envelopes or tokens.
- [x] Give access and refresh separate organization-specific AAD purposes; substitution across organizations, clients, grant users or purposes fails authentication. Reuse the keyring and crypto primitives.
- [x] Coordinate refresh outside a transaction after durable claim admission. Commit token pair atomically under authority/generation/claim predicates. Ambiguous, expired or abandoned one-use refresh requires reconnect. `ForgeGitHub.OrganizationCredential.with_credential/3` renews, then checks authority again before checkout.
- [x] Parent runs `devenv shell --no-tui -- env PGPORT=55432 mix test apps/forge_accounts/test/organization_github_credentials_test.exs` and records results. Review implementation against independent ownership, stale writes, redaction and refresh race requirements.

### Task 2: Exact App-user installation and inventory APIs

**Files:**
- Modify: `apps/forge_github/lib/forge_github/client.ex`
- Create: `apps/forge_github/lib/forge_github/user_installation.ex`
- Test: `apps/forge_github/test/github/user_installation_test.exs`

- [x] Add provider tests with existing bounded test transport for `/user/installations` and `/user/installations/:id/repositories`. Verify another host/path, duplicate repositories, invalid totals and wrong owner IDs fail closed.
- [x] Implement typed `user_installations/2` and `user_installation_repositories/3`, with exact path pagination and the existing request gates. UserInstallation includes App ID/client identity and the existing normalized AppInstallation account/selection/permission/state facts.
- [x] Return normalized repository DTOs without converting public organization discovery into authorization evidence. Cap pages/counts and require complete responses.
- [x] Run the focused provider file. Existing provider mutation/broker contracts remain unchanged.

### Task 3: Organization connection lifecycle and installation binding

**Files:**
- Create: `apps/forge_mirrors/lib/forge_mirrors/organization_github_connection.ex`
- Create: `apps/forge_mirrors/lib/forge_mirrors/organization_github_connections.ex`
- Create: `apps/forge_imports/lib/forge_imports/organization_github_connection.ex`
- Create: `apps/fornacast/priv/repo/migrations/20261022000300_create_organization_github_connections.exs`
- Test: `apps/forge_imports/test/organization_github_connection_test.exs`

- [x] Write regressions for missing, wrong-App, suspended and wrong-account installations, contents permission, immutable-account pinning and stale grant/binding settlement.
- [x] Implement the manager-facing facade contract:

```elixir
reference(actor, organization_id)
connect(actor, organization_id, token, expected, metadata, opts)
installations(actor, organization_id, opts)
bind(actor, organization_id, installation_id, expected_version, metadata, opts)
disconnect(actor, organization_id, expected_version, metadata)
view(actor, organization_id)
```

- [x] Verify `/user` before saving. In one transaction save the organization grant and move connection to `installation_required`, advancing authority and clearing effective coverage while retaining pinned account identity. Never preserve ready status on a newly saved grant.
- [x] Perform provider HTTP outside transactions. Bind only an active configured-App organization installation with sufficient enabled-operation permissions and a complete user-visible repository inventory. Persist immutable IDs and effective coverage, not full-installation claims for user-limited access.
- [x] Recheck current actor management and expected credential/connection versions under lifecycle locks before settlement; audit safe metadata. Source activation remains explicit and rejects active legacy/new work.
- [x] Add context-only worker `scope/1` / `with_credential/3` admission that validates current connection+credential authority; no personal fallback.
- [x] Run focused connection tests and inspect reconnect/disconnect fences.

### Task 4: Existing synchronization with organization authority

**Files:**
- Modify: `apps/forge_mirrors/lib/forge_mirrors/{pat_configuration,pat_settings,pat_git_mirror}.ex`
- Modify: `apps/forge_imports/lib/forge_imports/{organization_pat_settings,pat_sync_run,pat_sync_worker,pat_repository_sync,credential_provider,import_run,discovery_worker,repository_worker,worker,repository_publisher}.ex`
- Modify: existing import admission/orchestration/recovery modules and `ForgeRepos` inbound domain APIs where personal-only checks occur.
- Modify: `apps/forge_github/lib/forge_github/{mirror_credential,git_ref_worker}.ex` and existing scope propagation/claims for explicitly enrolled Git/LFS mirrors.
- Create: `apps/fornacast/priv/repo/migrations/20261022000400_add_organization_device_sync_source.exs`
- Test: focused organization sync/worker/credential/recovery and inbound write admission tests.

- [x] Add `organization_device` source discriminator and nullable independent source fields. Existing records default to the legacy source. Reject incomplete/mixed source snapshots with SQL and domain validation.
- [x] Extend configuration save/view, scheduler, Sync now and durable worker dispatch to snapshot/resolve admitted organization connection scopes. Preserve the existing result pages and retry history. Busy source changes fail; no lease resets or competing writers.
- [x] Discovery uses the bound installation inventory and immutable owner IDs. Every effectful provider checkout revalidates connection/repository scope; publication checks local organization, admitted run/config, repository generations and leases.
- [x] Add narrow organization operation authority at the existing domain boundary for staging/publication/Git writes. The local authorizer stays audit metadata, never a fabricated or automatically replaced User. Regression: after run commit, deactivate/remove that local authorizer; admitted organization work succeeds, while connection disconnect/version change prevents publication.
- [x] Preserve legacy personal authorization, existing running jobs, and mirror handoff. Explicit enrolled Git/LFS source support propagates connection scope and retains force-push/ref-deletion rejection. Broker-only metadata workers cannot claim this source.
- [x] Parent serially runs only touched tests under forge_imports, forge_mirrors, forge_github and forge_repos. Fix in-scope failures, report and stop on unrelated failures as AGENTS requires.

### Task 5: Organization Device Flow and truthful compact UI

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/{user_session,github_device_session,router}.ex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/organization_github_device_controller.ex`
- Create: organization connection HTML module and templates under the same controllers directory.
- Modify: organization PAT/GitHub settings controllers/HTML, personal Device Flow navigation and `assets/js/github_device.js`.
- Test: new organization Device Flow controller tests plus existing scoped organization/personal session, controller and HTML tests and JS polling tests.

- [x] Reuse GitHubDeviceAttempt transitions with per-organization SessionProcess keys. Capture organization+actor+expected connection reference at start. Recheck management at start/poll/bind/save; logout, cancel, supersession, expiry and newer connections reject stale attempts.
- [x] Add authenticated CSRF-protected organization start/poll/cancel, configuration, installation selection/recheck and disconnect routes. JSON polling uses the private/no-store API browser pipeline. Personal legacy navigation opens organization choice; it never transfers stored credentials.
- [x] Keep canonical overview compact: connection/status plus navigation actions, with Device Flow code/instructions on the dedicated organization page. Explain installation-required and missing permissions. Old `/app` bookmarks show the same actual organization state when using this source; private-key mode remains separately available.
- [x] Generalize the existing poller to server-rendered same-origin organization poll/return paths with strict validation, preserving personal-route fixtures where compatibility requires it. Do not accept arbitrary provider/server redirects.
- [x] Run relevant PostgreSQL web and JavaScript tests. Verify cross-organization/session attempts and terminal-state projection.

### Task 6: Local verification and real provider acceptance

**Files:**
- Modify: `docs/github-imports.md`, `docs/github-app-local-acceptance.md` and the plan/spec acceptance status.

- [x] Run focused PostgreSQL regressions, changed-file format then repository format check, warnings-as-errors compilation and asset build. Serialize Mix commands.
- [x] Check current managed job state before any necessary dev migration/restart; keep active legacy job authority intact. Serve the corrected local organization route and verify DOM, navigation, status, polling and console with the authenticated real browser.
- [x] Have the user perform real Device Flow consent/App installation when needed. Verify encrypted organization persistence and actual installation/inventory, without printing secrets or changing GitHub permissions on the user's behalf.
- [ ] Start the approved acceptance synchronization only after existing work settles and the organization source is explicitly activated. Verify successful terminal aggregate run, all repositories succeeded, and required LFS download/access. A public repo GET or mocked test is insufficient.
- [x] Update the canonical Agent Note using the current revision and `project: fornacast`. State implemented, locally verified and live-acceptance boundaries independently.

### Task 7: Conditional commit, push and v0.8.0 delivery

- [ ] Only after real sync acceptance, apply the already requested cmd-git-commit skill; stage the coherent authorized files, conventional commit, push main, and verify HEAD/tracking/remote convergence.
- [ ] Read current release workflow and versions; dispatch next minor `0.8.0` against verified main. Wait for terminal CI/release state, verify tag/source/assets/checksums/image, and run published E2E as required by the workflow.
- [ ] Report release/deployment boundaries. Publication does not restart or deploy the managed instance.

## Verification record

- The final consolidated PostgreSQL runner exited successfully with 530 passing tests: 6 shared-infrastructure, 15 accounts, 37 repositories, 24 mirrors, 133 GitHub provider and worker, 202 imports, and 113 web tests. This includes organization execution, real local LFS transfer, capability-forgery rejection, recovery, publication fences, and legacy-source regressions.
- The minimal AppInstallation decoder fix accepts GitHub's literal `admin` permission value. Its 18 focused provider tests and strict development compilation passed. The managed process was subsequently restarted to load the corrected parser.
- JavaScript Device Flow polling: 9 passed. Repository format check, warnings-as-errors compilation and asset build passed. Migration 004 rollback restored the exact legacy schema and refused existing organization authority before performing DDL.
- The canonical local organization overview at `http://10.100.10.28:4890/organizations/gsmlg-opt/settings/github` showed exactly two connection navigation links and no forms inside its connection section, initially with the accurate `installation_required` state. The dedicated connection page fetched actual provider installations for Gao-OS (174188771) and gsmlg-opt (174185564). Both pages had no console warnings/errors or horizontal overflow on the checked desktop viewport; the installation-required page contained no token-shaped values, activation form or Sync now form.
- Real organization Device Flow consent persisted an encrypted access/refresh grant for gsmlg-opt. At 16:35 UTC, the actual `/user/installations` response returned HTTP 200 and confirmed installation 174185564 for gsmlg-opt with `contents`, `issues` and `pull_requests` write permissions, plus legitimate unrelated admin permissions. Complete `user_installation_repositories` pagination returned 18 actual repositories; the earlier personal run covered 16. This supersedes the earlier missing-permission evidence. The real browser subsequently bound installation 174185564: connection 1 is `ready`, version 2, with 18 persisted repositories. Explicit source activation set configuration 1 to `organization_device`, version 11, with personal owner and identity fields null.
- The production LFS batch/download path succeeded using the organization grant for reachable `gsmlg-opt/repub` object `7ab2525f4b86b65d3e4c70358a17e5a1aaf6f437f99cbcc046dad73d59bb9015`: 917 bytes downloaded with SHA-256 verified. This proves real provider LFS access for that object; it does not establish successful aggregate synchronization.
- Managed development PostgreSQL already has migrations 002-004. The user explicitly approved stopping the old synchronization while preserving data, switching to the organization App and restarting. Disabling the legacy configuration through the real UI let personal run 19 settle naturally as `failed/configuration_changed` at 16:40:41 UTC, without direct SQL mutation. Independent read-only verification confirmed all 12 previous succeeded repository results remain preserved; its four nonterminal result rows were not rewritten.
- The Endpoint lacked the development CodeReloader plug despite reload configuration being enabled. Added the standard plug and Mix listener; strict development compilation, 113 scoped web tests and repository formatting passed afterward. After run 19 settled and with explicit user approval, the managed BEAM restarted as PID 1904256 with keys preserved and health verified. The authenticated real browser then completed installation binding, explicit source activation and Sync now against the corrected runtime.
- Canonical Agent Note `1ed74dee-0cec-4d26-afa1-896b737e5194` was updated at revision 7 with `project: fornacast`, preserving historical release evidence and recording the permission/parser correction plus independent implementation, runtime and real-acceptance boundaries.
- The real browser started acceptance run 20/import 13 at 16:43:13 UTC. Independent read-only verification confirmed configuration, run and import snapshots reference organization connection 1/version 2, credential 1/version 1 and installation 174185564; run/configuration personal owner and identity fields and import personal credential/identity fields are null. Seven repository updates succeeded. Its `unsafe_credential_result` failures exposed an organization callback normalization gap: unlike the personal path, it returned structured provider/Git errors through the credential guard. Applying the existing `safe_result/1` before leaving the trusted callback preserves only the safe error kind, with no guard changes. The regression reproduced the failure, then 31 focused tests, formatting and strict compilation passed.
- A concurrent public-organization-import implementation was subsequently compiled into the shared development VM before its migration existed, producing `undefined_column public_configuration_version` errors and exhausting run 20's delivery attempts. The corrected code was isolated under `.trees/github-org-acceptance`, excluding all concurrent public-import and workspace-navigation changes. In that worktree, 147 scoped PostgreSQL tests passed against a separate `fornacast_org_acceptance_test` database; repository formatting, strict development compilation and assets build passed. The previously added unused test alias was removed.
- The managed Fornacast service was moved to the isolated worktree at the same web/API ports, retaining the existing PostgreSQL socket, credential key settings and absolute paths to the existing repositories, SSH keys, LocalCAS and Concord data. PostgreSQL was not restarted and no domain leases or results were reset. The new VM (PID 1924490) served healthy web/API endpoints and the expected compact organization connection UI without console errors. Existing recovery settled run 20 as `failed/retry_exhausted` at 17:01:18 UTC, retaining its seven completed repository updates.
- Through the real connection page, the browser started run 21/import 14 at 17:02:06 UTC. Read-only verification confirmed the same organization-only connection/credential/installation snapshots and null personal source fields. This run later ended as `failed/storage_unavailable` at 03:20:51 UTC on 2026-10-23 with 17/18 repositories successful; its completed results and scan checkpoints remain preserved. A subsequent real-browser retry started run 25/import 18 at 03:44:48 UTC, with final acceptance still pending.
- Canonical Agent Note revision 8 now describes the organization-owned lifecycle, callback normalization, completed binding/activation, exact isolated runtime, preserved legacy data and pending aggregate acceptance. Historical v0.7.10 evidence was retained and explicitly identified as historical; the `project: fornacast` label and updated content were read back and verified.
- At 18:06:47 UTC the isolated VM received SIGTERM. The same ports were subsequently served by VM 1972961 from the main working tree, with both concurrent public-source migrations present. Run 21 continued and reached nine successful updates; its `claude-code` cancellation remained pending with a normal replacement delivery queued. This live evidence now includes concurrent main-working-tree changes and is distinct from the isolated scoped-source test evidence above.
- The stopped VM left backplane delivery 11951 executing and result 182484 under its original lease until 18:47:02 UTC. After verifying the old VM and Git child processes were gone, a standalone management process used the public `Styx.cancel_all_jobs/2` API with exact delivery/attempt predicates and no queues, plugins or stager. The obsolete delivery became cancelled; independent readback and before/after assertions confirmed the domain row, lease and all 29,822 completed scan items were unchanged. Its temporary notifier did not connect, but the cancellation was durably verified; no notification was needed to stop the already-absent owner. Existing control recovery remains responsible for readmission after lease expiry, avoiding the later two-hour Lifeline window. No domain lease/result reset was performed.
- Existing control recovery queued replacement backplane delivery 12048 at 18:16:32 UTC. Its original domain lease expired normally at 18:47:02; the replacement waits for the existing update queue. At 19:07:26, sigma delivery 11954 reached the existing 3,600,000 ms worker timeout. Its 98,169 completed scan items remain persisted and the same delivery returned to the available queue for retry. Fornacast then started scan 70 across 28 refs. The user explicitly selected continued full acceptance rather than expanding scope to history-scan performance optimization; that scope remains unchanged.
- The retained discovery warning is `unsupported_fork_relationship` for `gsmlg-opt/.github`: GitHub fork-parent relationship metadata is not imported. Its durable synchronization result succeeded with no error. This expected metadata exclusion does not waive the Git/LFS acceptance gate or indicate an App permission failure.
- Sigma's normal second attempt resumed scan 69 and succeeded, bringing run 21 to 11 successful repositories. Fornacast reached the same one-hour worker timeout with 90,618 completed scan work items preserved. Several subsequent repositories remained pending with `cancelled`; domex separately reported `invalid_destination`, although its current local bare repository and path identity checks were valid. The historical underlying domex failure is not recoverable from that coarse classification; wait for normal retry rather than changing destination safety checks.
- Cancellation diagnosis identified an organization authorization compatibility gap: the normal callback performs multiple database authority/lease checks, while Remote.Control reused its 100 ms polling interval as the whole callback budget. An independent Elixir process using the unchanged compiled modules reproduced healthy 150 ms and 300 ms callbacks being killed and classified `cancelled` at about 101 ms. This proves the budget mismatch; available runtime logs do not conclusively associate every observed cancellation with that cause. The isolated fix adds a separate hard-capped 500 ms callback budget, leaving the 100 ms polling interval, owner monitoring, overall deadline, fail-closed results and kill/join behavior intact. Fifteen pure Elixir/ExUnit checks went from eight expected failures to all passing. The PostgreSQL-backed Limits, Remote.Control and Remote integration group passed all 47 tests in isolation. Its hanging-callback elapsed-time check now accounts for two callback evaluations, during execution failure and credential cleanup, retaining the original 550 ms startup/termination margin and all callback-worker, OS-child, credential and permit checks. Full-history scan performance and the one-hour repository-worker timeout are unchanged.
- Loading the two production callback modules through development reload unexpectedly recompiled dependent umbrella apps, briefly making modules unavailable and interrupting six deliveries. The root VM remained running, and completed synchronization/scan work remained persisted. Both production modules are now loaded: an independent probe of the compiled code accepted a healthy 300 ms callback, and HTTP health returned 200. This does not yet prove complete organization-worker recovery. Existing deliveries continue their normal 30-second snoozes without new errors until domain leases expire at 21:50:45 UTC for manifold and 21:51:50 UTC for the other five repositories on 2026-10-22. Read-only source/database review verified atomic expired-lease claims and working maintenance recovery. No domain lease/result reset, data deletion or timeout tuning was performed. Wait for actual new claims, scan progress and successful outcomes to verify runtime adoption. Do not edit/recompile root source during active synchronization; all remaining checks run in the isolated worktree.
- Successful terminal aggregate synchronization, including its LFS work, remains required. Complete provider inventory, real binding, explicit activation, corrected runtime and a separate real LFS download are verified. The terminal-sync acceptance checkbox and conditional commit/push/v0.8.0 release remain incomplete.
- After natural lease expiry, manifold delivery 12162 reclaimed its existing result at 21:51:03 UTC on 2026-10-22 with a different lease owner. Its heartbeat renewed the lease and scan 71 continued from 104,845 to 106,554 completed work items by 21:52:04 UTC, without another callback or missing-module error. This verifies live worker recovery and preserved scan progress for that repository, without resetting domain state. The other five repositories and terminal aggregate synchronization remain pending. A fresh browser reload of the exact LAN run page displayed the same 12 successful and six pending outcomes, with no console warnings/errors on that navigation.
- Subsequent normal recovery completed manifold and agent-note, bringing durable synchronization to 14/18. Backplane and Fornacast retain their full-history scan progress across the existing one-hour worker timeouts. Singularity and claude-code again returned handled `cancelled` outcomes after the 500 ms callback modules were loaded; their deliveries completed with zero Styx error entries and queued replacements. Therefore the callback-budget correction alone does not prove complete live recovery. Postgrex borrower exits 502 ms apart support, but do not establish, callback-budget exhaustion. An independent read-only Repo process measured the real ten-query `OrganizationExecution.authorize` core at roughly 0.7–3.8 ms; the same core passed the current `Control.check` with normal callback exits. That core excludes the complete callback's lease UPDATE and handoff lock. Read-only source inspection found no normal parent transaction retaining those locks, and point-in-time PostgreSQL samples had no blockers; future actual attempts still require observation. No root-source reload, domain lease/result reset, timeout tuning or scan optimization was performed during this investigation.
- At 00:53:05 UTC on 2026-10-23, actual automatic provider refresh advanced organization credential 1's material generation from 1 to 2, preserved verification version 1 and valid status, advanced access expiry to 08:53:05 UTC and cleared its durable refresh claim. This independently verifies real automatic renewal without changing admitted authority; token material was neither inspected nor printed. Canonical Agent Note revision 13 records that proof and the unresolved repeated-cancellation boundary. Successful terminal aggregate synchronization remains required before commit, push or v0.8.0 publication.
- Fornacast completed scan 70, and subsequent normal deliveries for claude-code and Singularity succeeded by 01:15:09 UTC, bringing run 21 to 17/18 successful durable outcomes. A read-only repeatable-read audit verified all seventeen targets' organization ownership, admitted/current generations and ready lifecycle; their latest current-generation scans are prepared with completion/publication timestamps and no unfinished work. All eight required LFS objects, belonging to repub, have ready, verified, size-matched metadata and reachable mappings. Independent streaming reads of the eight LocalCAS files verified all sizes and SHA-256 digests (391,263 bytes total). The successful short-delivery capture contained no PostgreSQL blockers and a maximum sampled SQL age of 7.51 ms; it does not explain the earlier cancellations. Backplane remains the sole incomplete repository, retaining 196,811 completed scan items while its prior lease expires naturally at 01:33:04 UTC.

- The user requested a full-height organization settings panel and GitHub integration submenus during acceptance. The organization-only layout now uses a 100dvh minimum and the existing DuskMoon nested menu for overview, App connection, synchronization configuration, repositories, task history, advanced App settings and conflicts. Each page marks its selected child. All 68 focused web tests passed against the separate PostgreSQL acceptance database; formatting, warnings-as-errors development compilation and asset build passed. The actual LAN runtime subsequently served all seven routes and General with HTTP 200 and no console errors. At 1440x900 its short panel ends at y=884 with a 16px bottom margin; at 390x844 it scrolls naturally without horizontal overflow. These are live served-runtime checks, superseding the earlier static-fixture-only boundary.
- The duskmoon-dev App connection is independently bound to installation 174195783 and GitHub organization 127959075, with 14 effective repositories including the private acceptance repository. Connection 2 is ready and configuration 2 explicitly uses organization credentials with null personal source fields. Its real automatic refresh advanced credential 2 to material generation 2 while preserving verification version 1. The user approved stopping the old anonymous synchronization: import 15/sync 22 settled with its two published repositories retained. The first organization attempt, sync 23/import 16, later failed with a coarse credential error and was canceled through the UI, preserving two skipped existing repositories and twelve retryable items. No additional GitHub configuration change is indicated by the verified binding and credential state.
- The subsequent real-browser retry returned HTTP 422 because two canceled items retained allocated but unproved shadows, not because the organization grant was invalid. The candidate recovery now restarts only canonical terminal empty shadows with fresh staging and records the exact nonadopting successor for delayed cleanup. Proven Git staging still follows normal adoption; corrupt or shared evidence remains rejected. Organization successors enter ordinary conflict admission so fresh attempts are frozen before work starts. The exact old failure was reproduced; 72 scoped PostgreSQL retry/worker/cleanup tests passed, including real local Git staging, publication, both proven-adoption phases, and negative source/path/adopter/cleanup fences. The retry and cleanup changes were adopted in the controlled 04:52 UTC restart on 2026-10-23 after strict compilation, repository formatting and 110 focused PostgreSQL tests passed.
- Background cleanup also exposed a PostgreSQL evidence constraint that rejected the valid repository slug `.github`. Candidate migration `20261023000300` aligns only the slug predicates with the existing canonical repository contract while preserving all other cleanup evidence checks. The real materialization failure was reproduced; all twelve focused migration/recovery tests then passed. The live development database applied this migration during that controlled restart.
- PostgreSQL logs independently identified sibling repository claims upgrading a shared ImportRun lock and deadlocking. The scoped fix acquires the run update lock at claim admission while preserving the authority-before-run-before-item lock order; the regression and focused tests passed. It was loaded in the controlled 03:44 UTC restart. This establishes the claim deadlock cause and fix; the coarse historical credential/cancellation results do not establish that every earlier failure shared that cause.
- The managed root runtime is healthy after that restart, and run 25 is performing existing full-history Git/LFS work with persisted checkpoints. Source compilation and further adoption must wait for a controlled window. Do not reset results, leases or scans, change the worker timeout, or expand this task into scan performance optimization. Successful terminal organization synchronization remains required before commit/push and v0.8.0 publication.

- Normal public admission created duskmoon-dev sync 26/import 19 with twelve fresh items, all fourteen progress entries and the two retained repository updates. It passed preparation and conflict admission, then paused in Git credential checkout before cloning. Its historical `credential_unavailable` result combines several error kinds and does not establish a GitHub configuration defect. An isolated read-only production-client probe subsequently verified both encrypted secrets, unchanged authority, the exact active App installation and permissions, and all fourteen repository IDs. It performed no refresh or provider mutation.
- A deterministic worker regression independently established that an installation preflight returning `request_gate_busy` was incorrectly converted into a credential wait. The candidate preserves that existing safe error atom, allowing ordinary staging backoff without replacing the shadow or attempt. The regression first failed with `awaiting_credential`, then succeeded through the same real local Git staging and publication after retry; all 95 focused organization-provider/repository-worker tests, repository formatting and strict candidate compilation passed. Live adoption and terminal synchronization acceptance remain pending. This does not retrospectively identify sync 26's unrecorded original error.

- At 05:53:01 UTC on 2026-10-23, backplane delivery 13001 reached its existing one-hour timeout with 101,630 scan work items completed. Its retry was durably queued and all Styx executing jobs were empty. With all queues already paused, only managed Fornacast was stopped; PostgreSQL remained ready. The reviewed checkout patch was applied at 05:53:34 UTC after exact checks of all 113 scope files, 38 outside-scope files, HEAD and index. Outside source bytes, HEAD and index were preserved. Combined-root strict development compilation and repository formatting passed; all 95 focused PostgreSQL worker/provider/repository-worker tests passed in the separate `fornacast_org_root_checkout_20261023_test` database without inheriting development credentials or storage settings.
- The reviewed no-start recovery helper then executed successfully at 05:55:42 UTC. Through the actual owning User and existing public APIs it canceled import 19, reconciled only that run, and admitted synchronization 27/import 20 as its exact successor. Independent readback confirmed predecessor 19 canceled; successor 20 awaiting resolution with twelve queued items, zero attempts and no allocated shadows. Its fourteen progress rows retain the exact two completed update rows, and both abandoned shadows carry exact nonadopting successor markers. No management worker or provider request ran. Normal service boot, fresh worker attempts/staging and complete real synchronization acceptance remain to be verified.
