# User Appearance Implementation Plan

> **For agentic workers:** Use subagent-driven-development to implement the scoped tasks below. Parallel implementation is authorized by project instructions; workers own disjoint files.

**Goal:** Move theme selection to account Appearance settings, with durable user preferences cached through phoenix_session_process.

**Architecture:** PostgreSQL stores users.theme_preference. One Phoenix.SessionProcess user process per account holds shared configuration, and multiple session processes hold only their owning user ID; request identity queries omit preference data. Standard and repository page renderers expose this configuration for JavaScript to resolve auto.

**Tech Stack:** Elixir/Phoenix, Ecto/PostgreSQL 17, phoenix_session_process 1.0.1, Phoenix DuskMoon, JavaScript.

## Task 1: Account appearance storage

- [x] Add apps/fornacast/priv/repo/migrations/20261011000000_add_user_theme_preference.exs with `add :theme_preference, :string, null: false, default: "auto"` and a check permitting auto/sunshine/moonlight.
- [x] Update apps/forge_accounts/lib/forge_accounts/user.ex with the field and appearance_changeset/2 casting only theme_preference, requiring a submitted valid choice.
- [x] Update apps/forge_accounts/lib/forge_accounts.ex with update_user_appearance/2 using active_actor/1, and get_session_user/1 selecting identity fields without theme_preference.
- [x] Add scoped account tests covering defaults, valid choices, invalid/missing choices, isolation, ignored extra attributes, and inactive actors.

## Task 2: Session process integration

- [x] Add `{:phoenix_session_process, "~> 1.0.1"}` to apps/fornacast_web/mix.exs and its supervisor before the Endpoint in application.ex.
- [x] Add apps/fornacast_web/lib/fornacast_web/user_session.ex wrapping separate user and session processes. Load shared appearance on user-cache miss; use per-user locking, session ownership checks, synchronous shared updates, touch, and cleanup.
- [x] Update plugs/current_user.ex to use get_session_user/1, retrieving appearance through UserSession and assigning the hydrated current_user.
- [x] Update controllers/session_controller.ex to rotate/create session processes on login and terminate only the current session on logout, preserving shared user state.
- [x] Add scoped session tests proving multiple sessions share one user process, cross-session configuration query avoidance and saves, account isolation, independent session logout/recovery, shared-user reload, and concurrency/metadata safety.

## Task 3: Appearance UI and loading

- [x] Add authenticated GET/PATCH /settings/appearance to router.ex.
- [x] Extend SettingsController and settings_html/appearance.html.heex with a DuskMoon select, Auto/Sunshine/Moonlight, Save, validation errors, and redirect confirmation. Persist with ForgeAccounts.update_user_appearance/2, then synchronize UserSession.
- [x] Extend html.ex settings navigation; remove appbar theme_menu; emit data-theme-preference on both page renderers from the hydrated current_user, anonymous auto.
- [x] Replace app.js localStorage theme handling with reading the server preference and preserving system scheme observation.
- [x] Update relevant existing appbar assertions and add focused appearance controller and JavaScript behavior tests.

## Task 4: Verification and delivery

- [x] From the worktree, resolve dependencies using the root devenv shell; serialize Mix builds.
- [x] Run focused PostgreSQL tests using the project Unix socket and PGPORT=55432. Run only account appearance/session/UI tests and affected existing shell tests.
- [x] Run `mix format --check-formatted`, `mix assets.build`, and `git diff --check`; review the complete scoped diff.
- [x] Save an Agent Note labeled project=fornacast with behavior, implementation, and verified checks.
- [x] Report the worktree and verification; do not commit or push without user instruction.

## Previous verification before the two-level process correction

- PostgreSQL: 9 account tests, 15 session/Appearance tests, and 6 affected existing shell/settings/repository tests passed.
- JavaScript: 5 behavior tests passed.
- Full format check and asset build passed; generated 43-entry JavaScript manifest has no missing file/import links, and its entry contains server preference loading without the legacy storage key.
- Independent spec and code quality reviews completed; the cleanup/recreation race was repaired with fresh tokens and metadata regression assertions.
- Upstream Bug gsmlg-dev/phoenix_session_process#58 has type Bug and label internal request. Marked temporary public-API cleanup is included.
- Agent Note created: 51849bfc-eda1-46af-aeab-e7fd50f8c894, project=fornacast.
- Worktree remains uncommitted; no main integration, runtime restart, push, or deployment.

## User/session architecture correction

The user clarified that each account has one user process and can have multiple
session processes. Task 2 and its verification now use this contract; the
previous session-only cache verification above does not establish it.

- [x] Verify corrected user/session tests and Appearance controller tests on PostgreSQL.
- [x] Independently review shared state, concurrency, ownership, and recovery.
- [x] Re-run format and compile checks and update the Agent Note.

Corrected implementation verified on 2026-10-12: 9 account tests, 22
user/session and Appearance controller tests, 6 affected shell/repository tests,
and 5 JavaScript behavior tests passed. Full format check, compile with
warnings-as-errors, independent code review, and diff whitespace checks passed.
The earlier asset build remains applicable because this correction changed only
server process state and its tests/documentation. The deterministic cleanup-overlap
test confirms stable user-key reconstruction waits for old cleanup and preserves
new activity/timer metadata. Agent Note updated with the corrected architecture.
Work remains uncommitted and unmerged in `.trees/appearance`.

## Upstream patch update

On 2026-10-12, updated only phoenix_session_process from 1.0.0 to the published
1.0.1 patch with `mix deps.update phoenix_session_process`, after checking
`mix hex.outdated phoenix_session_process`. Issue #58 is closed; removed its
workaround comments, explicit ActivityTracker removal, and redundant test cleanup.
The synchronous Cleanup cancellation before stable-user-key reconstruction is
still required for old callback ordering and stale crashed-process tracking.
Direct package termination now has metadata assertions before cache recreation.
All 22 focused PostgreSQL user/session and Appearance tests passed, including
direct termination metadata checks and overlapping cleanup recovery. Full format
check, warnings-as-errors compilation, and independent source review passed.
No other dependencies were updated.
