# Project Components Implementation Plan

> **For agentic workers:** Use subagent-driven-development to execute this approved plan with independent file ownership and serialized Mix builds.

**Goal:** Own the Git presentation components in Fornacast and deliver a scoped upstream removal PR.

**Architecture:** A pure `fornacast_component` umbrella library receives presentation maps and slots. Web owns typed projection, routes, authorization, and Git resource lifetime. DuskMoon supplies foundation controls.

**Tech Stack:** Elixir, Phoenix HEEx, DuskMoon, npm workspaces, delegated JavaScript clipboard behavior.

### 1. Independent component app

Files: `apps/fornacast_component/{mix.exs,package.json,README.md,THIRD_PARTY_NOTICES.md}`, `lib/{fornacast_component.ex,fornacast_component/git_repository.ex}`, `assets/js/clipboard.js`, `test/{git_repository_test.exs,test_helper.exs,js/clipboard.test.js}`.

- [x] Copy the approved upstream six-component implementation and behavior tests; rename `dm_git_` to `fc_git_` and module to `FornacastComponent.GitRepository`.
- [x] Add `attr :name_href, :string, default: nil`; render the name through a native anchor when present and retain plain text otherwise. Assert owner and name have distinct hrefs and the slash is outside both links.
- [x] Copy clipboard behavior/tests, replacing `data-copy-` with `data-fc-copy-` and using an app-owned installation symbol. Export `installClipboardBehavior` in a private workspace.
- [x] Preserve complete MIT licensing/provenance and declare only presentation dependencies; no application callback.
- [x] Verify: `mix test --no-start` from the app and `node --test apps/fornacast_component/test/js/clipboard.test.js`.

### 2. Web adapter and shared layout

Files: `apps/fornacast_component/lib/fornacast_component/repository_layout.ex`, `apps/fornacast_web/lib/fornacast_web/{repository_paths.ex,repository_view.ex}`, existing repository/release/issue/PR HTML modules and templates, `apps/fornacast_web/test/repository_html_test.exs`.

- [x] Extract existing URL constructors/ref normalization into `RepositoryPaths` without changing route encoding.
- [x] Project result chrome into plain header/navigation/toolbar/clone maps in `RepositoryView.frame(result, active)`; keep formatting and domain structs in Web.
- [x] Extract frame/ref controls/clone popover/panel/breadcrumb/pagination renderers into the library. Frame accepts `view` and an inner slot; breadcrumbs receive prepared tuples; pagination receives a prepared page URL.
- [x] Replace every shared frame consumer with `<.fc_repository_frame view={RepositoryView.frame(@result, :code)}>` (use each existing active tab). Replace all six Git calls with `fc_git_*`; remove obsolete shared Web renderers.
- [x] Update URL consumers to `RepositoryPaths`, and tests to the projected component API. Assert canonical owner/name links on nested pages while Code remains ref-aware.
- [x] Verify focused PostgreSQL tests for repository HTML/controller, release, issue and PR pages at `PGPORT=55432`; preserve existing masking/authorization assertions.

### 3. Integration and runtime

Files: Web `mix.exs`, root `mix.exs`, `config/config.exs`, `.formatter.exs`, Web assets entry/package, `package-lock.json`, `AGENTS.md`.

- [x] Add `{:fornacast_component, in_umbrella: true}` and explicit release entry, source/watch paths, formatter inputs, and private npm workspace dependency/import.
- [x] Update lockfile workspace entries and align DuskMoon Elements/Art Elements to the published 1.9.0 graph used by Phoenix DuskMoon 9.16.7. Document presentation ownership in AGENTS.
- [x] Verify scoped format, warnings-as-errors compile, assets, explicit release application entry and no remaining Web `dm_git_*` calls.
- [x] Transfer only this task diff back to the main working directory, preserving its prior edits; restart the authorized managed dev app.
- [x] Browser-check title navigation from nested pages, tree/blob/diff rendering, clipboard, themes, mobile/desktop containment and keyboard anchors.

### 4. Upstream removal PR

Files: upstream Git component source/tests/import/docs registration, Git clipboard implementation/tests, six Storybook stories/templates and associated router/controller/menu/catalogue/gallery tests, README/home/hooks/changelog.

- [x] Prepare scoped removal in the existing isolated upstream checkout; preserve generic dialogs/popovers and historical changelog.
- [x] Verify remaining JS tests and library compile/format; recheck upstream main. Scoped Storybook route tests remain pending because the native OXC build stalled during cargo metadata Git fetching.
- [x] After local verification, commit/push `codex/remove-git-business-components`, create the explicitly requested Draft PR with a breaking-change migration note, and attach it to this task. Do not merge or publish.
- [x] Record the validated architecture boundary in scoped Agent Notes and update the final plan/design status, with the remaining Storybook validation explicitly pending.

## Validation boundary (2026-10-10)

Implementation is present in the root working directory, with dependency maintenance and component migration in separate commit scopes. App-only tests: 26 passed; focused Web PostgreSQL tests: 155 passed; clipboard Node tests: 9 passed. Formatting, warnings-as-errors compilation and diff checks passed. Release includes `fornacast_component: :permanent`; workspace resolution and release-distributed MIT notices are verified. Aligning the two DuskMoon aggregate packages to published 1.9.0 resolved consumer JavaScript loading; the final production artifact also loaded successfully in Chrome. Issue #180 remains a general nested-package resolver defect, not a local acceptance blocker. Existing #175 single-bundle fallback remains unchanged.

The authorized managed dev service was stopped/started to load the final clone invoker adaptation: BEAM 1884234 -> 1903463; app/database/storage health checks all ok. Browser acceptance covers canonical title links with actual clicks and keyboard Enter, nested blob/diff/tree rendering, 390px/1440px containment, theme-menu switching, native clone popover opening, Escape dismissal/focus return, and secure/legacy copying with one handler invocation and exact values. The DuskMoon trigger slot attributes are forwarded to the native Code button. Empty/setup states are covered by focused render tests.

Upstream Draft PR: https://github.com/duskmoon-dev/phoenix-duskmoon-ui/pull/182, head `af52a75c42e214ef2b931fcb198edf6522ab6bf3`. Retained library tests: 59 passed; retained JS tests: 3 passed; scoped formatting and standalone library compilation passed. Current main `6f5444c` only adds the 9.16.8 version bump and applies cleanly against the removal. Storybook validation remains pending; no merge or publication was performed.
