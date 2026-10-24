# Organization public/API and App onboarding implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track the scoped steps below. Preserve all pre-existing uncommitted work; do not commit, publish, restart the managed service or start a live synchronization.

**Goal:** Replace organization import credential selection with anonymous public synchronization and the existing organization-owned App connection.

**Architecture:** Add an explicit public credential/source through the existing GitHub, Git, import and organization synchronization boundaries. Reuse organization Device Flow for the App entry and reuse durable import/sync workers, authorization, leases and reports for public work. Keep source admission explicit and forbid fallback to saved credentials.

**Tech Stack:** Elixir/Phoenix umbrella, PostgreSQL 17, existing GitCore Git transport, Phoenix DuskMoon and scoped ExUnit tests.

## Shared contracts and ownership

- Transport worker owns `apps/forge_github/`, `apps/git_core/`, and the narrow `ForgeAccounts.GitHubProfileSafety` public-source extension and tests.
- Domain worker owns `apps/forge_imports/`, `apps/forge_mirrors/`, and the additive public-source migration/tests under `apps/fornacast/`.
- Parent owns web routes/controllers/templates/tests, operator docs, plan integration and final verification.
- GitHub callback credentials use explicit `:public` for anonymous work, distinct from a nonempty binary token. Transport code must omit Authorization for it.
- GitCore public callers use an explicit anonymous mode; authenticated calls retain existing required login/token validation. Transport worker reports the exact map contract before domain integration.
- Public organization discovery retains the existing context API:

```elixir
ForgeImports.create_organization_discovery(actor, %{
  organization: "octo-org",
  credential_source: "public",
  destination_organization: %{action: "existing", id: organization_id}
}, metadata)
```

- Existing destinations require current organization ownership. New destinations use the existing authorized organization-creation/publication path.
- App onboarding selects/creates a local organization and redirects to `/organizations/:slug/settings/github/connection`; it never selects a personal identity or starts synchronization as a side effect of GET.
- Public synchronization configuration belongs in ForgeMirrors and executes through existing import/sync workers. Domain worker reports its narrow public configure/trigger/projection APIs for web integration.
- All Mix/devenv builds and tests serialize with `flock /tmp/fornacast-public-app-mix.lock`. PostgreSQL commands use the devenv Unix socket and `PGPORT=55432`.

## Task 1: Anonymous REST, assets, LFS and Git transport

- [x] Add failing focused tests passing `:public` through organization/repository discovery and required metadata, release and LFS requests; assert no Authorization or token-derived gate bucket.
- [x] Run the new tests under the shared Mix lock and record the expected missing-source failure.
- [x] Implement explicit anonymous dispatch while preserving fixed hosts, pagination, response validation, request limits and typed failures.
- [x] Add failing GitCore tests for anonymous fetch with no ambient credential helpers and rejection of malformed/mixed anonymous credentials.
- [x] Implement the narrow anonymous remote contract and prove real local Git bytes and refs arrive, including a second fast-forward.
- [x] Run only affected GitHub/GitCore tests; report exact commands and results.

Example verification command (use the actual affected test filenames):

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- env PGPORT=55432 mix test apps/forge_github/test/github/client_test.exs
```

## Task 2: Public import and organization sync source

- [x] Add PostgreSQL tests for `credential_source: "public"`, null personal credential fields, destination ownership and private-repository rejection.
- [x] Add additive public-source schema constraints and extend explicit source dispatch, trusted credential checkout and result-safety validation for `:public`.
- [x] Validate immutable GitHub identity, complete public inventory and repository visibility before consequential work and publication.
- [x] Add public configuration/trigger/projection APIs using existing organization sync configuration, snapshots, queues and execution fences. Preserve old source records and reject busy cutover.
- [x] Cover first import, cancellation/recovery, rate-limit waiting, user/organization authorization, repeat synchronization and required LFS failures.
- [x] Run only affected import/mirror/migration tests; coordinate the transport contract with Task 1.

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- env PGPORT=55432 mix test apps/forge_imports/test/discovery_test.exs apps/forge_imports/test/credential_provider_test.exs
```

## Task 3: Replace the organization import form

- [x] Add controller/HTML tests: chooser has exactly Public/App entries and no personal credential inputs; unauthenticated and foreign organization access remain rejected.
- [x] Render separate server-driven public and App entry pages. New/existing destination choices submit only their relevant fields and remain usable without JavaScript.
- [x] Public POST calls the existing discovery API with the public source and preserves safe input on validation errors.
- [x] App POST validates/creates the destination through ForgeAccounts and redirects to that organization's existing App connection. Existing ready connections remain usable.
- [x] Integrate the public sync APIs with the relevant organization controls and source labels; keep progress/review/cancel/retry on existing routes.
- [x] Run focused web tests including legacy repository-import compatibility.

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- env PGPORT=55432 mix test apps/fornacast_web/test/import_controller_test.exs apps/fornacast_web/test/import_html_test.exs
```

## Task 4: Integrate and verify

- [x] Review scoped diffs against the saved baseline, including source constraints, secrets, visibility changes and old-source compatibility.
- [x] Obtain independent spec and code review; resolve findings within scope.
- [x] Run the affected PostgreSQL suites after integration; check formatting, compile with warnings-as-errors and build assets.
- [x] Verify served UI in a real browser: exact requested LAN route when current code is loaded, otherwise explicitly separate managed runtime from an isolated local fixture.
- [x] Prove anonymous Git publication and subsequent sync with real local Git data. Do not claim full live GitHub import or App sync from mocked evidence.
- [x] Update `docs/github-imports.md` and a project-scoped Agent Note with implemented behavior, evidence and remaining live acceptance limits.
- [x] Mark completed steps and report delivered code, tests and runtime verification separately.

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- mix format --check-formatted
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- mix compile --warnings-as-errors
```

Unrelated failures remain outside this work. Report them and stop their repair; do not broaden the change.

## Implementation and verification record — 2026-10-23

Implemented in the uncommitted working tree above `3815ae1a9c243d8c260728534f5de0d34c570443`. The pre-existing Device Flow and navigation work was preserved. No commit, push, release, managed restart or live user synchronization was performed.

The public GitCore contract is `authentication: :anonymous`, `credential_login: nil`, with `:public` as the credential argument. Domain APIs are `ForgeImports.OrganizationPublicSync.view/configure/sync/refresh`; first absent configuration version `0` is accepted under the existing mutation lock. Completed standalone public imports adopt only unconfigured targets into manual synchronization.

Review corrections cover public-source queue admission under its lock, resumable pauses during discovery/checkout, canceled provisional discovery constraints, token-looking input sanitization, public retry controls and rate-wait deadlines. Required public resource authentication failures now terminate with `public_authorization_required` and GitHub App guidance. Visibility is rechecked after LFS and before applying refs; deterministic tests preserve refs and `write_version` when the source becomes private.

### Scoped automated evidence

| Scope | Final result |
| --- | --- |
| GitCore, GitHub and profile safety | 223 passed, seed 580792 |
| Public/domain and existing PAT/Device Flow regressions | 155 passed |
| Web controllers, HTML and organization App regressions | 87 passed, seed 215262 |
| Scoped formatting and `git diff --check` | Passed |
| Development `mix compile --force --warnings-as-errors` | Passed |
| `mix assets.build` | Passed |

The transport agent recorded the initial expected anonymous-source failures with seed 119562: missing GitCore authentication field, rejected public profile, invalid anonymous request and gate key. Final tests include real local Git bytes and a second fast-forward; provider REST/LFS responses use test clients.

Final transport command:

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- env PGPORT=55432 mix test \
  apps/forge_github/test/github/public_access_test.exs \
  apps/forge_github/test/github/client_test.exs \
  apps/forge_github/test/github/client_graphql_deadline_test.exs \
  apps/forge_github/test/github/repository_client_test.exs \
  apps/forge_github/test/github/identity_client_test.exs \
  apps/forge_github/test/github/inventory_client_test.exs \
  apps/forge_github/test/github/label_client_test.exs \
  apps/forge_github/test/github/issue_client_test.exs \
  apps/forge_github/test/github/pull_client_test.exs \
  apps/forge_github/test/github/relationship_client_test.exs \
  apps/forge_github/test/github/release_client_test.exs \
  apps/forge_github/test/github/release_asset_client_test.exs \
  apps/forge_github/test/github/lfs_test.exs \
  apps/forge_github/test/github/lfs_transfer_coordinator_test.exs \
  apps/git_core/test/remote_test.exs \
  apps/git_core/test/remote_sync_test.exs \
  apps/git_core/test/public_remote_test.exs \
  apps/forge_accounts/test/github_profile_safety_test.exs
```

Final domain command:

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- env PGPORT=55432 mix test \
  apps/forge_imports/test/public_organization_sync_test.exs \
  apps/forge_imports/test/public_organization_worker_test.exs \
  apps/forge_imports/test/organization_device_worker_test.exs \
  apps/forge_imports/test/organization_execution_test.exs \
  apps/forge_imports/test/organization_device_credential_provider_test.exs \
  apps/forge_imports/test/organization_pat_settings_test.exs \
  apps/forge_imports/test/pat_sync_worker_test.exs \
  apps/forge_imports/test/pat_repository_sync_test.exs \
  apps/forge_imports/test/credential_provider_test.exs \
  apps/forge_imports/test/retry_test.exs \
  apps/forge_imports/test/discovery_test.exs \
  apps/forge_imports/test/discovery_recovery_test.exs \
  apps/forge_mirrors/test/pat_settings_test.exs \
  apps/fornacast/test/public_organization_migration_test.exs
```

Final web command:

```sh
flock /tmp/fornacast-public-app-mix.lock devenv shell --no-tui -- env PGPORT=55432 mix test \
  apps/fornacast_web/test/import_controller_test.exs \
  apps/fornacast_web/test/import_html_test.exs \
  apps/fornacast_web/test/organization_import_controller_test.exs \
  apps/fornacast_web/test/organization_public_sync_controller_test.exs \
  apps/fornacast_web/test/organization_pat_settings_test.exs \
  apps/fornacast_web/test/organization_github_connection_html_test.exs \
  apps/fornacast_web/test/organization_github_device_controller_test.exs
```

Incremental development compilation initially replayed stale Inspect-consolidation diagnostics. The generated stale protocol cache was removed and a full forced compile passed without changing product source for that cache issue. Existing unused-alias/default warnings in the import Git fixture were preserved.

### Real-browser evidence and deployment limits

Chrome exercised the actual Endpoint and PostgreSQL test sandbox at an isolated `localhost:4906` fixture, with mocked GitHub discovery and disabled task dispatch. At desktop 1440px and mobile 390px, the chooser and forms had no horizontal overflow. With JavaScript disabled, native form submission discovered `source-org/project`, entered the existing review flow, and displayed public access without personal credential inputs. New/existing destination branches contained only their corresponding fields, including the destination editor on the import run.

The App form submitted the owned local destination and reached its organization connection page. No GitHub consent or installation was attempted. Public pause and resume returned to public settings, changed status and disabled/enabled explicit synchronization; repository-management and history navigation worked. The fixture was stopped and its sandbox transaction rolled back after inspection.

Served fixture assets were `app-cb5bd1b0.css` and `app-df201a0e.js`. With scripts enabled, the existing relative modulepreload request `/organizations/app-common-ad60895e.js` returned 404 while the real `/assets/js/app-common-ad60895e.js` loaded successfully and custom elements initialized. This known upstream issue is tracked by `duskmoon-dev/phoenix-duskmoon-ui#200`; no duplicate issue or new workaround was added. The no-JavaScript checks had no console errors.

Screenshots were retained at `/tmp/fornacast-public-app-browser-20261023/chooser-desktop.png` and `/tmp/fornacast-public-app-browser-20261023/public-mobile-nojs.png`.

The requested LAN route still served the old personal-account/PAT form when checked. The managed instance was not restarted. Local tests and mocked browser discovery do not prove live GitHub full import, App consent/installation or complete App synchronization.

The coherent engineering review was saved and read back as Agent Note `0812f701-015b-45d4-bad9-4730d789ae72`, revision 1, with the exact label `project=fornacast`.
