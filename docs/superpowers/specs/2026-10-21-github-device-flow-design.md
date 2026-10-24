# GitHub App Device Flow for imports and synchronization

Status: implemented and scoped verification complete, 2026-10-22.
Real GitHub consent and local credential persistence verified on 2026-10-22;
access to a selected acceptance repository remains untested.
User approval: 2026-10-22.

## User decisions

- GitHub App client ID: `Iv23lizCVE3E24s7fCA0`.
- Authenticate using Device Flow.
- Connect GitHub accounts for imports and synchronization.

## Baseline behavior

Before this change, `/settings/github` verified a supplied PAT against `/user`
and linked the account through `ForgeAccounts`' encrypted credential boundary. Imports
and saved-credential synchronization obtain tokens through callbacks. They do
not require PAT-specific token prefixes or classic OAuth scope headers.

The optional GitHub App installation path uses a numeric App ID, a private key,
an App slug and a webhook secret. Its installation tokens have a separate
lifecycle. The baseline had no Device Flow configuration, provider client, web
route, refresh-token storage or user-token refresh implementation.

Saved synchronization authority includes `verification_version`. Existing
credential replacement increments that version, so invoking PAT replacement
on every automatic refresh would invalidate synchronization authority.

## Implemented behavior

The GitHub account settings overview shows current connections and two compact
navigation buttons: **Connect with GitHub** opens `/settings/github/device`, and
**Link GitHub account** opens `/settings/github/link`. Their configuration forms
are on those separate pages, as requested in the local UI follow-up. The Device
Flow page starts authorization and displays GitHub's user code, verification link
and expiration time. The page polls through Fornacast until authorization succeeds,
is denied, expires or is cancelled. The provider's minimum polling interval is
enforced on the server, including the extra delay required by `slow_down`.

After authorization, verify the GitHub identity with `/user`, then persist the
credential using the existing account ownership, encryption and audit boundary.
The linked account is selectable for existing repository and organization
imports and saved-credential synchronization. Display its credential type and
reconnection status accurately. Existing PAT linking remains available.

Device authorization gives the user token the intersection of the user's
permissions and the App's permissions and installed repositories. Installation
and permission changes remain GitHub-side prerequisites; authorization alone
does not make every organization repository accessible.

The operator must enable **Device Flow** in the GitHub App settings. Report
`device_flow_disabled` with this corrective action instead of a generic
credential failure.

## Configuration and provider ownership

- Add a separate public client ID setting,
  `FORNACAST_GITHUB_DEVICE_CLIENT_ID`, with the supplied client ID as the
  Fornacast default and an environment override for self-hosters.
- Read it consistently in development and release runtime configuration.
  Document it in `.env.example`, Compose, README and deployment guidance.
- `forge_github` owns bounded, fixed-origin requests to
  `https://github.com/login/device/code` and
  `https://github.com/login/oauth/access_token`. Keep the existing REST client's
  `api.github.com` host restriction intact. Disable redirects and incidental
  automatic retries; apply request deadlines, response limits and sanitized
  errors to the new token endpoint requests.
- Use form POST bodies and request JSON responses. Request `offline_access`
  when starting authorization to obtain expiring, refreshable credentials.
  GitHub App permissions do not use classic `repo` or `read:org` OAuth scopes.
- Poll with the client ID, device code and
  `urn:ietf:params:oauth:grant-type:device_code` grant type.
- Refresh with the client ID, refresh token and `refresh_token` grant type.
  GitHub's current contract exempts Device Flow tokens from the client-secret
  requirement, including renewal.

## Temporary authorization state

Bind each pending attempt to the authenticated local user and browser session.
Keep the device code on the server; the browser receives only an opaque attempt
reference, user code, verification link and safe status. Validate provider
responses, including the expected GitHub verification origin.

Only the owning active user and session may poll or cancel. All mutations are
CSRF protected. Starting another attempt supersedes the previous attempt for
that session. Enforce expiry, prevent concurrent token exchanges for the same
attempt and consume successful authorization once. Expired, cancelled or
superseded attempts cannot save credentials. Restarting Fornacast may discard
pending attempts and require starting authorization again.

The save reservation rechecks expiry immediately before persistence. A save
admitted before expiry may finish afterward; the existing per-user session lock
serializes that reservation with cancellation and logout. Returning to a cached
authorization page reloads its current server state before resuming polling.

## Credential storage and refresh

Extend the saved credential model with a credential kind, client binding,
access-token expiry and encrypted refresh-token material and expiry. Existing
rows remain PAT credentials. Keep access tokens, refresh tokens and device
codes out of logs, audit payloads, browser state and callback results. Reuse the
configured credential encryption keyring and fail closed if unavailable.

`forge_accounts` owns persistence, authorization and compare-and-set updates;
`forge_github` owns provider calls and refresh coordination. Keep the existing
umbrella dependency direction. Imports and synchronization request a usable
saved credential through that coordination boundary before provider work.

Refresh shortly before access-token expiry. Serialize refresh per credential,
atomically persist both rotated tokens, and distinguish token generation from
the authorization version pinned by synchronization. Same-account renewal
must preserve admitted synchronization authority. Reauthorization, manual
replacement, unlinking and revocation retain existing authorization fencing.
Stale operations cannot overwrite a newer credential or mark its generation
invalid using an older provider failure.

Do not hold a database transaction open during provider HTTP calls. Coordinate
refresh attempts using a persisted claim/generation fence. After an ambiguous
refresh outcome, require reconnection when the one-use refresh token cannot be
recovered; do not claim that retrying the old refresh token is always safe.
Expired or rejected refresh credentials require Device Flow reconnection.
Transient failures outside token renewal retain the existing bounded retry
behavior. Once a refresh request is dispatched, this implementation conservatively
requires reconnection for any failed or uncertain response; it never retries the
old one-use refresh token. Other callers may wait briefly for an active claim.

Retain legacy internal saved-PAT configuration compatibility while using the
stored credential kind to select lifecycle behavior and accurate product
labels. This work does not require migrating installed mirror authority to the
separate GitHub App installation-token path.

## Scope and alternatives

The selected approach is a managed connection in the existing account settings,
with encrypted rotating credentials reused by current import and sync APIs.
It supports unattended synchronization without a client secret.

An access-token-only connection would require frequent reauthorization when
tokens expire and would not meet the background synchronization requirement.
An installation-token replacement would need additional App credentials and a
different authorization lifecycle; it is outside this Device Flow change.

This change excludes GitHub sign-in to Fornacast, new synchronization resource
types, broad transport migrations, automatic installation changes, release
publication and deployment.

## Verification

- Configuration tests: supplied default and environment override in development
  and releases; Device Flow remains usable with installation App configuration
  disabled.
- Provider tests: exact request parameters and origins; response bounds;
  pending, slow-down, denied, disabled and expired authorization; malformed
  responses and refresh failures.
- PostgreSQL account tests: encrypted access/refresh persistence, existing PAT
  compatibility, ownership, stale writes, rotation, revocation and unlinking.
- Refresh tests: concurrent callers, expired tokens, rotated-token persistence,
  authorization-version stability and ambiguous outcomes requiring reconnect.
- Web tests: authenticated start/poll/cancel, session isolation, CSRF, expiry,
  single consumption and absence of secrets from rendered responses.
- Focused import and saved-credential sync tests proving renewed tokens remain
  usable under the admitted authority and missing permissions fail clearly.
- Format check and compilation, followed by browser checks of the served UI.
  Real GitHub authorization requires the user's Device Flow consent and an App
  installation with access to the selected acceptance repository.

## Verification status (2026-10-22)

Implementation and independent source review cover provider transport, encrypted
persistence, refresh coordination, saved-credential consumers and the web/session
flow. Review fixes preserve active refresh claims during account verification
and reload authorization pages restored from the browser Back/Forward cache.

The combined focused PostgreSQL run passed configuration, account, GitHub and
import checks; its web subset was incomplete because of a location filter.
Seven JavaScript polling tests and the asset build also passed. Exact suite
counts and final formatting/compilation results are recorded in the
implementation plan without aggregating overlapping runs. The dedicated full
scoped web rerun passed all 74 tests after correcting the logout request
connection in its test fixture. Final scoped formatting, warnings-as-errors
development compilation and diff checks passed.

The built settings page completed authorization and persistence against an
isolated provider fixture at `http://localhost:4896`. Browser checks also covered
pending polling, cancellation, expiry, denial, disabled-flow guidance and
desktop/mobile layouts without token secrets in the DOM. That fixture/listener
has been stopped; the managed application service was untouched. This was not
real GitHub consent.
The subsequent local test at `http://10.100.10.28:4890` completed real GitHub
consent on 2026-10-22. Read-only database metadata and fresh authenticated settings
responses confirmed the saved `github_app_user` credential was valid, with its
latest verification at 10:08:03 UTC. Access to a selected acceptance repository
and synchronization using that connection remain untested. The compact navigation
and account-status visibility changes are local, uncommitted follow-ups.
The served browser also showed the existing dependency preload URL issue tracked
by [phoenix-duskmoon-ui#200](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/200)
with installed `duskmoon_bundler 9.16.11`; normal module imports and Device Flow
completed despite the extra preload 404. No dependency workaround is part of
this feature.

## Sources checked

Repository baseline: `main` at `ada4c54` (v0.7.9).

- `apps/fornacast_web/lib/fornacast_web/controllers/github_settings_controller.ex`
- `apps/forge_imports/lib/forge_imports/github_accounts.ex`
- `apps/forge_accounts/lib/forge_accounts/github_credential.ex`
- `apps/forge_accounts/lib/forge_accounts/github_credential_vault.ex`
- `apps/forge_github/lib/forge_github/mirror_credential.ex`
- `apps/forge_mirrors/lib/forge_mirrors/pat_git_mirror.ex`
- [GitHub: generating user access tokens, Device Flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow-to-generate-a-user-access-token)
- [GitHub: refreshing user access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)
