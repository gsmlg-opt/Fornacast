# Organization Settings Implementation Plan

> **For agentic workers:** Use the `subagent-driven-development` or `executing-plans` skill to implement this plan task by task after design approval. Steps use checkbox syntax for tracking. Follow repository scope rules and coordinate file ownership before parallel edits.

**Goal:** Add a GitHub-style organization settings experience with General and the existing GitHub integration.

**Architecture:** Extend the current organization settings routes with a shared HEEx layout. Reuse `ForgeAccounts.update_organization/4` for profile editing and preserve the existing authorization and GitHub operational behavior.

**Tech Stack:** Elixir/Phoenix controllers, HEEx, phoenix_duskmoon, Tailwind/DuskMoon tokens, Ecto/PostgreSQL 17, ExUnit.

**Status:** Implemented and verified.
**Design:** `docs/superpowers/specs/2026-09-22-organization-settings-design.md`.
**Baseline:** `3fdd9bb`, inspected 2026-09-22.
**User constraint:** No team, membership, or authorization management.

---

## Scope and file ownership

All paths below are relative to the repository root. They are the implementation
allowlist; modify only files actually needed.

**New files:**

- `apps/fornacast_web/lib/fornacast_web/organization_settings_components.ex`
- `apps/fornacast_web/test/organization_settings_components_test.exs`
- `apps/fornacast_web/test/organization_settings_controller_test.exs`

**Existing source files:**

- `apps/fornacast_web/lib/fornacast_web/router.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_controller.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_html/show.html.heex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_settings_controller.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_settings_html.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_settings_html/index.html.heex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_github_settings_controller.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_github_settings_html.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_github_settings_html/index.html.heex`
- `apps/fornacast_web/lib/fornacast_web/controllers/organization_github_settings_html/conflicts.html.heex`
- `apps/fornacast_web/assets/css/app.css` (only organization-scoped additions if existing classes are insufficient)

**Existing regression tests that may need updates:**

- `apps/fornacast_web/test/organization_controller_test.exs`
- `apps/fornacast_web/test/organization_github_settings_controller_test.exs`
- `apps/fornacast_web/test/organization_github_settings_html_test.exs`

**Documentation:** This plan and its companion design.

Read-only regression coverage:
`apps/forge_accounts/test/organization_management_authorization_test.exs`,
`apps/fornacast_api/test/users_organizations_test.exs`, and
`apps/fornacast_web/test/organization_github_installation_acceptance_test.exs`.

No domain implementation, membership schema, migration, API routes, dependency,
import/mirror behavior, global shell refactor, or generated assets are in scope.

## Task 1: Prepare scoped work and establish the baseline

- [x] Confirm design review before implementation; check current HEAD and
  `git status --short`, preserving unrelated/user-authored work.
- [x] If using a worktree, place it in `.trees/codex/organization-settings` on
  `codex/organization-settings`. Use its own configured devenv environment.
- [x] Read current DuskMoon form/layout component APIs and the existing profile
  validation/error return shape. Do not alter domain rules to simplify the UI.
- [x] Start or reuse managed PostgreSQL and check that PGHOST is a Unix socket
  directory before database verification:

```sh
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120
devenv shell --no-tui -- sh -c 'test -n "$PGHOST" && test -d "$PGHOST"'
```

If the socket check fails, inspect the devenv-provided socket configuration. Do
not silently fall back to localhost or a file database. Use PGPORT=55432.
Serialize all Mix/devenv builds and tests.

- [x] Run the existing files from Task 6's scoped test command before editing,
  omitting the two new files. Record baseline failures separately.

## Task 2: Shared settings layout

**Files:** New component/test and organization-scoped CSS only if needed.

- [x] Create `organization_settings_layout/1` with required `organization`,
  `active` (`:general | :github`), and an `inner_block` slot. Use it as:

```heex
<.organization_settings_layout organization={@organization} active={:general}>
  <h2>General</h2>
</.organization_settings_layout>
```

- [x] Add identity/back link and exactly two navigation links: canonical General
  and existing GitHub settings. Apply `aria-current="page"` to the selected link.
  The component must not fetch account, permission, or provider data.
- [x] Reuse `.settings-layout`/`.settings-sidebar`/`.settings-content` responsive
  geometry. Use existing DuskMoon components, semantic tokens, and project fonts.
- [x] Test navigation URLs, selected state for each section, escaped organization
  name, and organization back link. No People/Teams/Permissions entries.
- [x] Run the component test; expected: all assertions pass with no app/provider calls.

## Task 3: General form and save action

**Files:** General controller/HTML/template, router, new General tests, existing
GitHub controller test's canonical settings case.

- [x] Write failing tests for a valid save, invalid field values, unauthorized
  access, and rendering without a sync facade call.
- [x] Add PATCH next to the current GET inside the same authenticated,
  private/no-store browser scope, before namespace catch-alls:

```elixir
patch "/organizations/:organization_slug/settings", OrganizationSettingsController, :update
```

- [x] Make `index/2` load only the manageable organization and form state. Remove
  its sync facade dependency and remove old status helpers only if now unused.
- [x] Render General in the shared layout with display name/description controls,
  read-only slug/URL, clear field labels, and Save changes. Use the existing
  display-name/description length and normalization rules.
- [x] Name the display-name input `organization[name]` to match the existing
  domain validator, and the description input `organization[description]`.
  Accept only a map under `organization`; select string keys `name` and
  `description`. Treat non-map/absent payloads as 400. Immutable extra keys are
  never forwarded to the domain operation.
- [x] Call the existing audited context operation:

```elixir
ForgeAccounts.update_organization(
  actor,
  organization,
  Map.take(attrs, ["name", "description"]),
  FornacastWeb.RequestMetadata.from_conn(conn)
)
```

- [x] On success, redirect to canonical General with success feedback. On field
  validation errors, render 422 and preserve submitted values; attach domain
  `name` errors to the display-name input. Handle authorization as
  masked 404 and unexpected storage/audit failure with a safe 503 message.
- [x] Explicitly render Phoenix flash in this page's assigns using a DuskMoon
  alert if the current shell does not display flash. Keep this change local.
- [x] Replace the existing test requiring a General sync facade call with zero
  calls. Keep all GitHub-page facade-call expectations intact.
- [x] Test trimming, field limits, NUL rejection, malformed parameters, escaped
  input, attempted immutable-field changes, success audit identity/metadata,
  CSRF rejection, login redirect, and private/no-store headers.
- [x] Prove General loads and saves when the injected sync adapter fails. Run:

```sh
devenv shell --no-tui -- env PGPORT=55432 mix test apps/fornacast_web/test/organization_settings_controller_test.exs apps/fornacast_web/test/organization_github_settings_controller_test.exs apps/fornacast_api/test/users_organizations_test.exs
```

Expected: General is provider-independent; existing REST profile tests still pass.

## Task 4: Organization Settings entry

**Files:** Organization controller/show template and existing controller test.

- [x] Compute a boolean settings-entry assign through
  `ForgeAccounts.fetch_manageable_organization/2` for organization accounts.
  Use false for personal accounts and anonymous actors. Do not duplicate role logic.
- [x] Render Settings beside the organization identity, targeting General.
  Preserve the existing repository list and visibility filtering.
- [x] Test owner/site-admin visibility, member/outsider absence, and unchanged
  personal namespace navigation. This uses current authorization; it creates no
  authorization-management UI or permission model.
- [x] Run `organization_controller_test.exs`; expected: navigation and existing
  repository visibility assertions pass.

## Task 5: Integrate GitHub settings and conflicts

**Files:** Existing GitHub controller/HTML/templates and scoped GitHub web tests.

- [x] Import the shared component and wrap index/conflict content with
  `active={:github}`. Preserve action URLs, CSRF inputs, callbacks, operations,
  test hooks, and conflict navigation.
- [x] Remove redundant top-level settings headings/back links only where the
  shared layout now provides them; retain useful conflict-to-GitHub navigation.
- [x] For provider errors after canonical organization resolution, render the
  safe error inside the shared layout, so General remains accessible. Keep
  masked 404 and invalid-callback responses free of new organization details.
  Limit controller edits to presentation of already-authorized results/errors.
- [x] Test shared navigation/active state on settings, conflicts, and an
  authorized unavailable-provider response. Preserve existing status codes and
  facade call counts.
- [x] Run the existing GitHub controller, HTML, and installation acceptance files.
  Expected: all operational behavior remains unchanged.

## Task 6: Scoped verification and handoff

- [x] Format changed files; run the formatter check. Report unrelated pre-existing
  formatting failures without formatting files outside the allowlist.
- [x] After integration, run these commands serially:

```sh
devenv shell --no-tui -- mix format --check-formatted
devenv shell --no-tui -- env PGPORT=55432 mix test apps/forge_accounts/test/organization_management_authorization_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/organization_settings_components_test.exs apps/fornacast_web/test/organization_settings_controller_test.exs apps/fornacast_web/test/organization_github_settings_controller_test.exs apps/fornacast_web/test/organization_github_settings_html_test.exs apps/fornacast_web/test/organization_github_installation_acceptance_test.exs apps/fornacast_api/test/users_organizations_test.exs
devenv shell --no-tui -- mix assets.build
```

- [x] Verify General/GitHub/conflicts at 1440px and 390px in both themes. Exercise
  tab navigation, keyboard form submission, labels, success/error announcements,
  error focus, and layout overflow. Capture screenshots as review evidence.
  Use local fixtures/fake GitHub responses; no live installation is needed.
- [x] Check `git diff --check` and the file allowlist; exclude secrets, generated
  assets, dependencies, and database files from changes.
- [x] Mark design acceptance items with actual results. Report blocked gates
  explicitly; passing a subset is not full acceptance.
- [x] Record the completed feature in agent-note with `project: fornacast` using
  the repository's note workflow; report if the tool is unavailable.
- [x] Stop after scoped acceptance. Do not run the full umbrella suite, repair
  unrelated failures, commit/push, release, or deploy without authorization.

## Parallel execution map

After baseline verification, the shared component and namespace Settings entry
can be implemented independently with separate file ownership. General and
GitHub integration depend on the component contract and may then proceed in
parallel. Assign a single owner for the shared GitHub controller test file and
router edits. Run verification serially after integration.

## Draft self-review

- [x] Includes only General and existing GitHub integration.
- [x] No team, member, role, or authorization-management implementation remains.
- [x] Uses existing profile validation, audit, and authorization boundaries.
- [x] Defines provider-independent General and preserves integration routes.
- [x] Lists precise file scope, regression gates, and browser acceptance.
- [x] Makes no schema, dependency, REST, or provider-policy changes.

## Execution evidence

- Baseline on `3fdd9bb`: 58 scoped tests passed (6 accounts, 39 web, 13 API).
- New layout and Settings-entry tests failed on missing behavior before implementation.
- New General tests failed on the missing PATCH route/profile form before implementation.
- GitHub navigation tests failed on the missing shared layout before integration.

- Final scoped run: **71 passed** (6 accounts, 52 web, 13 API), seed `290847`.
- `mix format --check-formatted`, `mix assets.build`, and `git diff --check` passed.
- Existing forge_imports test-support warnings remain outside this change; assets
  used the bundler's existing single-bundle fallback for ambiguous split imports.
- Browser: real local sign-in, keyboard save, persisted fields, success feedback,
  invalid-name focus/description preservation. All three pages checked at 1440px
  and 390px in both themes, with no horizontal overflow and correct active links.
- Browser GitHub facade was simulated; no live provider installation or mutation.
- Twelve screenshots plus `browser-checks.json` saved under
  `/home/gao/.codex/visualizations/2026/09/22/01a0c936-90a6-7543-8a0e-5ce42f6b2892/organization-settings/`.
- Implementation detail: the PATCH route uses capture `:organization_slug` so
  Phoenix's merged params do not collide with the nested `organization` form map.
- Read-only spec and code reviews passed after resolving generic error disclosure
  and preserving existing facade-call expectations.
- Agent note saved: `e3226ee5-4cb0-49a1-8528-c9a87f23cbd4`, label `project: fornacast`.
- At implementation acceptance, main was unchanged and delivery had not yet been requested.
