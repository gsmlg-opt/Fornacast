# Initialization State, Setup Wizard, and `mix fornacast.run`

**Date:** 2026-07-04
**Status:** Approved

## Problem

A fresh Fornacast install has no users and no explicit record of whether the
app has ever been initialized. Bootstrap currently requires out-of-band steps:
`mix fornacast.admin.create` (dev) or a `Release.migrate()` + `create_first_admin`
eval (Docker). The app should know whether it is initialized, auto-enter an
init flow when it is not, start via a single `mix fornacast.run` command in
development, and boot the existing OTP release in production with no manual
migrate/eval steps.

## Decisions

- First-admin credentials are collected through a **web setup wizard**
  (Gitea-style install page), not terminal prompts or env vars. The same flow
  serves dev and the OTP release.
- Init covers **migrations + directories + admin creation + initialized flag**.
  Boot always runs pending migrations and ensures required directories.
- Initialized state is stored in **`Fornacast.ConfigStore`** (Concord), which
  is the designated home for app-level key/value state.

## Design

### 1. `Fornacast.Setup` (app `fornacast`, plain module — no process)

- ConfigStore key `initialized_at` (UTC timestamp). Absent = not initialized.
- `initialized?/0`:
  - Fast path: `:persistent_term` cache (one-way latch, set only when true).
  - Flag present → true.
  - Flag absent but an admin user exists (pre-feature deployments) →
    **self-heal**: write the flag, return true.
  - Flag present but no admin exists (main DB wiped/restored while config DB
    kept) → treated as **not initialized**; the flag is ignored until setup
    completes again. (`initialized?/0` therefore requires both flag and admin
    to short-circuit true; the persistent_term latch is only set when both
    hold.)
- `mark_initialized!/1` (takes the created admin as actor): writes
  `initialized_at`, records an `app.initialized` audit event, sets the
  persistent_term latch.

### 2. Boot preparation (dev and OTP release, identical path)

In `Fornacast.Application.start/2`, before the supervision tree starts:

1. Run pending migrations with `Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))`
   for each repo in `:ecto_repos` (same mechanism as `Fornacast.Release.migrate/0`).
2. `Fornacast.Storage.ensure_root!/0`.
3. `GitTransport.HostKey.ensure_system_dir!/1` already runs when the SSH
   daemon starts; boot prep does not duplicate it.

Guarded by config `:fornacast, :auto_migrate` — default `true`, set `false`
in `config/test.exs` (the test alias migrates, and the sandbox owns the DB).

`Fornacast.Release.migrate/0` remains as a manual operational escape hatch.
The README's manual "Run migrations" Docker step is removed.

### 3. Setup wizard (app `fornacast_web`)

- **`FornacastWeb.Plugs.RequireSetup`** appended to the `:browser` pipeline:
  when `Fornacast.Setup.initialized?()` is false, redirect to `/setup` and
  halt. Routes outside the browser pipeline (`/health`, Git smart-HTTP) are
  not gated; pre-init they 404/401 naturally because no users or repos exist.
- **Routes:** `GET /setup` and `POST /setup` in a `:setup` pipeline — same
  plugs as `:browser` minus `RequireSetup`.
- **`FornacastWeb.SetupController`:**
  - `new`: renders the admin form — username, email, password (the
    `ForgeAccounts.User.registration_changeset` fields used by
    `admin.create`).
  - `create`: calls `ForgeAccounts.create_first_admin/1` (already
    transactional against concurrent submissions), then
    `Fornacast.Setup.mark_initialized!/1`, then redirects to `/login`.
    Changeset errors re-render the form with a 422.
  - Both actions return 404 when already initialized.
- **Trust model:** first-come-first-served on a fresh instance, like Gitea's
  install page. Documented in the README: do not expose an un-set-up instance
  to untrusted networks.

### 4. `mix fornacast.run` (app `fornacast_web`)

`Mix.Tasks.Fornacast.Run`:

1. Run `ecto.create --quiet` (database creation is not part of boot-time
   migration).
2. Start the app via `Mix.Tasks.Phx.Server.run/1` (boot prep handles
   migrations/dirs).
3. After startup, log one of:
   - not initialized → `Fornacast is not initialized — open
     http://localhost:4000/setup to create the first admin.`
   - initialized → normal startup line.

README switches the dev instructions from `mix phx.server` to
`mix fornacast.run`. `mix fornacast.admin.create` remains for
scripted/headless bootstrap.

### 5. Production / OTP release

The `fornacast` release in `mix.exs` and the Docker `CMD ["/app/bin/fornacast",
"start"]` are already correct and unchanged. With boot prep in
`Fornacast.Application`, a fresh container migrates itself and serves the
setup wizard on first visit. README Docker section drops the manual
`Release.migrate()` and `create_first_admin` eval steps.

## Testing

- `Fornacast.Setup`: flag round-trip; self-heal (admin exists, flag absent);
  flag-without-admin treated as uninitialized; latch behavior.
- Web: uninitialized instance redirects browser routes to `/setup`; GET
  renders form; POST creates admin, sets flag, unlocks routes; `/setup`
  returns 404 once initialized; invalid form re-renders with errors.
- `mix fornacast.run` startup messaging is covered by the Setup unit tests
  (the task itself is thin glue over `phx.server`).
- Existing web tests seed initialized state via their admin fixtures
  (self-heal) or an explicit `Fornacast.Setup` helper in test setup.
- Test isolation: tests that flip init state must clear the persistent_term
  latch in `on_exit`.

## Out of scope

- Site settings (base URL, SSH host/port) in the wizard — config stays in env.
- Gating Git SSH/HTTP transports on init state.
- Multi-step wizard, telemetry opt-in, or any additional setup pages.
