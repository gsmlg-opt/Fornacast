# GitHub Device Flow Implementation Plan

> **For agentic workers:** use subagent-driven-development for the independent provider and persistence tasks, then integrate and review the complete flow. Follow the approved Device Flow specification. Do not commit or push without a user request.

**Goal:** connect GitHub App user credentials to existing imports and saved-credential synchronization using client ID `Iv23lizCVE3E24s7fCA0`, Device Flow and automatic refresh.

**Architecture:** `forge_github` owns fixed-origin authorization and refresh calls. `forge_accounts` owns encrypted tokens, authorization and persisted rotation fences. Web session state owns pending authorization; imports and sync use a provider coordinator before existing saved-credential checkouts.

**Tech Stack:** Elixir/Phoenix, PostgreSQL 17/Ecto, existing AES-GCM keyring, Phoenix.SessionProcess, Req/Mint, DuskMoon.

Status: implementation and scoped verification complete (2026-10-22).
Real GitHub consent remains untested. Deployment is outside this implementation.

Workspace: `.trees/codex/github-device-flow`, branch `codex/github-device-flow`.
All Mix commands use the root devenv environment, the original PostgreSQL Unix
socket on port 55432, isolated database `fornacast_device_flow_test`, and
`flock -x /tmp/fornacast-device-flow-mix.lock` to serialize builds and migrations.

## Task 1: GitHub provider client (worker)

Files: new `apps/forge_github/lib/forge_github/device_flow.ex` and a small dedicated
transport if needed; focused `apps/forge_github/test/github/device_flow_test.exs`.
Leave the existing REST host restriction unchanged.

- [x] Write failing provider tests for device authorization, polling and refresh.
- [x] Verify the tests fail because Device Flow is absent.
- [x] Implement `DeviceFlow.start/1`, `poll/2`, `refresh/2` and `client_id/0`.
  Authorization returns redacted device-code data; success returns a redacted
  token value with `client_id`, `access_token`, `refresh_token`, `expires_at` and
  `refresh_expires_at`. Expected failures are atoms, with
  `{:slow_down, interval}` carrying the provider's increased polling interval.
- [x] Verify form parameters, `offline_access`, fixed HTTPS origin, no redirects
  or automatic retries, time/size limits, error sanitization and malformed data.

Example behavior assertions:

```elixir
assert {:error, :authorization_pending} = DeviceFlow.poll(code, opts)
assert {:error, {:slow_down, 10}} = DeviceFlow.poll(code, opts)
refute inspect(token) =~ token.access_token
```

## Task 2: Encrypted persistence and refresh (worker)

Files: credential schema/view/vault and domain API under `apps/forge_accounts`,
new focused account tests, and a migration under
`apps/fornacast/priv/repo/migrations/`.

- [x] Add lifecycle regression tests covering Device Flow credentials.
- [x] Add credential kind/client binding/expiry and encrypted refresh material;
  existing records default to PAT and existing envelopes remain decryptable.
- [x] Add a public account API to save a verified Device Flow account through
  existing ownership, identity, audit and conditional-write mechanisms.
- [x] Add `refresh_github_credential(actor, identity_id, credential_id,
  refresh_callback, opts)` which returns `:ok` for usable credentials and renews
  expiring Device Flow tokens. The callback receives `(refresh_token, client_id)`
  and returns the provider token value. It never returns tokens to its caller.
- [x] Persist a refresh claim before HTTP, atomically store both rotated tokens,
  and use a material generation separate from `verification_version`. Do not
  hold SQL transactions across HTTP. Fence replacement/deletion/stale failures.
- [x] Treat expired/ambiguous refreshes as reconnection requirements. Keep all
  token material within encrypted storage and validated callbacks.
- [x] Verify existing account/vault tests and new lifecycle tests (69 focused
  account tests passed in the combined PostgreSQL run).

Required invariants:

```elixir
assert refreshed.verification_version == original.verification_version
assert refreshed.token_generation > original.token_generation
refute inspect(view) =~ refresh_token
```

## Task 3: Configuration and browser session flow (parent)

Files: config defaults/runtime, `.env.example`, `docker-compose.yml`,
`README.md`, `docs/deployment.md`; web session state, a Device Flow controller,
settings template/router, small polling JavaScript, focused web/config tests.

- [x] Verify the full scoped web suite after the final fixture repair (74 tests,
  zero failures; seed 134719).
- [x] Add `FORNACAST_GITHUB_DEVICE_CLIENT_ID` default and override, independently
  of installation App credentials, with focused configuration tests.
- [x] Add web/session regression tests for start, safe presentation, polling,
  minimum interval, single completion, cancel, expiry and isolation.
- [x] Store pending attempts in the existing Phoenix.SessionProcess session;
  serialize claims before exchange and reject cancelled/superseded completion.
- [x] Add authenticated CSRF-protected start/poll/cancel routes and a DuskMoon
  settings card showing user code, verification link and status. Poll from the
  page without exposing device/access/refresh secrets to the browser.
- [x] On success, verify `/user` and save via Task 2's account API.
- [x] Present generic credential labels where saved App tokens are supported.

Expected browser-safe polling response:

```elixir
%{status: "pending", interval: 5}
%{status: "complete", redirect: "/settings/github"}
```

## Task 4: Import and sync integration (parent, after Tasks 1 and 2)

Files: new saved-credential coordinator in `forge_github`,
`ForgeImports.GitHubAccounts`, `ForgeImports.CredentialProvider`,
`ForgeGitHub.MirrorCredential`, relevant discovery paths, and focused tests.

- [x] Add regression coverage proving expiring credentials are renewed
  before provider work and existing admitted mirror authority survives refresh.
- [x] Implement provider coordination around `refresh_github_credential` and
  existing account checkouts. Preserve existing opaque callback results.
- [x] Route all saved import/discovery/sync token checkouts through it; retain
  one-time PAT and installation-token lifecycle behavior.
- [x] Check authorization and identity after renewal, and report reauthorization
  or missing provider permissions through the existing domain error boundary.
- [x] Verify focused import, account and mirror credential tests in the combined
  PostgreSQL run, plus the separate complete scoped web rerun.

## Task 5: Integrated verification and documentation

- [x] Review each implementation against the approved spec, then review code
  quality and fix actionable findings.
- [x] Run scoped PostgreSQL tests, formatting, warnings-as-errors compilation
  and the asset build. Do not run unrelated test suites.
- [x] Verify completion in the actual built browser settings UI using the isolated
  provider fixture at `http://localhost:4896`; inspect served assets and console.
- [x] Verify browser cancellation, expiry, denial, disabled-flow guidance and
  desktop/mobile layouts without exposing token secrets.
- [x] Report the real GitHub consent boundary: it remains untested and requires
  user consent plus App installation access to the acceptance repository.
- [x] Reconcile this checklist and spec with the implementation and verification.
- [x] Write an implementation Agent Note labeled `project: fornacast` after
  successful verification, preserving proposal/implemented/tested distinctions.

## Verification evidence and acceptance boundary (2026-10-22)

- Combined focused PostgreSQL run: configuration 2, accounts 69, GitHub 34,
  imports 81 and web 18 tests passed. A shared `:269` location filter
  unintentionally excluded 56 web tests, so the web result is incomplete and
  does not replace the dedicated 74-test rerun. These suite totals overlap the
  earlier provider, account-linking facade and coordinator runs; do not sum them.
- Earlier focused provider/REST transport checks and the nine-test Device Flow
  account-linking facade run also passed; provider coverage includes the
  caller-death regression.
- Browser polling JavaScript: `node --test
  apps/fornacast_web/test/assets/github_device.test.mjs` passed seven tests,
  including Back/Forward cache restoration.
- Independent source reviews passed after repairing the refresh-claim race and
  browser cache restoration. Coordinator and saved import/discovery/sync
  consumers preserve admitted authority across renewal and recheck it afterward.
- The dedicated full scoped web rerun passed all 74 tests (seed 134719). The
  logout-during-exchange fixture uses a recycled HTTP `DELETE /logout`; the
  earlier `AlreadySentError` was confined to the fixture, with no production
  code change needed for that repair.
- The isolated browser fixture at `localhost:4896` covered pending code/link,
  polling, successful linking/persistence, cancellation, expiry, denial and
  disabled-flow guidance. Desktop (1440×1000) and mobile (375×812) had no
  horizontal overflow or fixture token secrets in the DOM. The fixture has been
  stopped; the managed application service was untouched. Real GitHub consent
  and acceptance-repository access have not been tested.
- Browser screenshots: `/tmp/fornacast-device-flow-pending.png` and
  `/tmp/fornacast-device-flow-mobile.png`. Served JavaScript was
  `/assets/js/app-280ca446.js`, SHA-256
  `280ca446aea06a2a74e478353c1827bc5ab953e32832ff9f17b8452b6dc2b0ff`.
- Browser console limitation: installed `duskmoon_bundler 9.16.11` generates a
  document-relative preload URL and an extra 404, while the correct module
  imports and Device Flow work. Existing upstream issue
  [phoenix-duskmoon-ui#200](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/200)
  and the `config/config.exs` TODO already track it. No local workaround or
  dependency upgrade is included.
- The asset build passed after the browser cache restoration fix. Final scoped
  formatting, `mix compile --warnings-as-errors` in development and
  `git diff --check` passed after the coordinator edits. Existing import
  test-support warnings were outside the application compilation gate.
- Implementation Agent Note `1ed74dee-0cec-4d26-afa1-896b737e5194`,
  “GitHub App Device Flow connections and one-use token refresh,” was saved
  with `project: fornacast` and read back to verify its content and label.
