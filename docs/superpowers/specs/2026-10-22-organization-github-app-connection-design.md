# Organization-owned GitHub App connections with Device Flow

Status: approved by the user (LGTM), 2026-10-22. Implementation and acceptance
are tracked in `../plans/2026-10-22-organization-github-app-connection.md`.

This corrects the organization-connection boundary in
`2026-10-21-github-device-flow-design.md`. That document remains the historical
description of the released personal connection. The user requested that GitHub
App connection be configured and owned within a Fornacast organization.

## Problem and required outcome

The current Device Flow writes a personal `GitHubCredential`. Organization
synchronization chooses that personal owner/identity through `PatConfiguration`,
while the organization App page reads a separate installation/mirror record.
Consequently, successful authorization does not connect the organization shown
in the Connection card. Relocating the existing form would retain this defect.

An authorized organization manager must connect GitHub from the organization's
settings, bind an actual GitHub organization installation, and manage that
organization's encrypted connection. Imports and synchronization must consume
that connection. The organization page must report the connection and the work
actually using it, without requiring a personal saved-account selector.

## Confirmed inputs and protocol boundary

- Device Flow remains the required authorization method.
- Client ID: `Iv23lizCVE3E24s7fCA0`.
- App slug: `fornacast`; public URL: `https://github.com/apps/fornacast`.
- Installation URL: `https://github.com/apps/fornacast/installations/new`.
- Public GitHub App lookup on 2026-10-22 confirmed numeric App ID `5412311`
  and a matching client ID. Its returned permissions/events were empty; a real
  installation and its effective permissions still require verification.

Device Flow generates a GitHub App **user access token**, even when Fornacast
stores the connection for an organization. It cannot install the App or mint
an installation access token. GitHub access remains bounded by the authorizing
GitHub user, the App and its installation. The UI must explain missing access
and support another manager reconnecting when the GitHub grant becomes invalid.

The existing private-key installation-token integration remains a separate
authentication mechanism. No client secret or App private key is required for
the organization Device Flow path. Webhook verification remains separately
configured and is never implied by Device Flow authorization.

## Approaches and decision

1. **Organization-owned Device Flow connection — recommended.** Add explicit
   organization credential ownership and installation binding, and adapt the
   existing organization import/Sync now pipeline. This meets the requested
   Device Flow contract and fixes persistence, authorization and status together.
2. **Installation-token connection.** Use the existing permanent App mirror
   integration and supply App ID, slug, private key and webhook configuration.
   This supports App installation authority independent of a GitHub user grant,
   but changes the credential requirements. It is retained as an existing mode,
   rather than silently replacing the requested Device Flow mechanism.

The recommended implementation preserves the existing synchronization resource
scope. New organization connections default to the existing inbound import/
Git-LFS update path. Connecting does not enroll repositories in bidirectional
mirrors, enable metadata writes or start synchronization automatically.

## Organization workflow and routes

`/organizations/:organization/settings/github` is the canonical entry point.
Its compact connection actions open organization configuration pages. The old
`/app` bookmark resolves to the same organization connection/status surface;
it must not show a second, contradictory disconnected card for this mode.

1. A current manager selects **Connect with GitHub** within the organization.
   Show the local organization and intended GitHub organization explicitly.
2. Start Device Flow, display the code/link and poll inside this organization.
3. Verify `/user` and save the resulting grant to encrypted organization
   credential storage. Do not create or replace a personal linked account.
4. Enumerate `/user/installations` with the saved App user token. Present only
   active installations of the configured App targeting GitHub organizations.
5. The manager chooses the intended GitHub organization. Validate immutable
   account and installation IDs, App identity and effective repository coverage.
   Existing bindings pin the account ID; a matching or renamed login alone
   cannot replace it with another GitHub organization.
6. If no suitable installation is visible, show **Authorization completed;
   organization installation required**, the App installation link and
   **Check installation again**. Retain the encrypted grant for that organization;
   do not claim Connected, enable sync, or redirect to personal settings.
7. After successful binding and permission checks, show the GitHub organization,
   installation, available repositories, connection health and sync actions.
8. The manager explicitly starts synchronization using the existing task page,
   run history and status endpoint. Initial import and later Git/LFS updates keep
   their current content semantics and publication safeguards.

Organization start/poll/cancel, installation selection/recheck, reconnect and
disconnect use authenticated, CSRF-protected organization routes. Read-only pages
and projections remain private/no-store. Return paths are fixed local routes.
Install selection is a verified local bind; installing or changing permissions
on GitHub still requires the user's action in GitHub.

Personal PAT/account compatibility remains available for existing imports and
legacy configurations. Personal Device Flow UI is no longer the entry point for
organization App connection. Preserve stored personal credentials and direct
old navigation toward organization selection without starting authorization or
transferring credentials automatically.

## Persistence and ownership

`forge_accounts` owns an additive `OrganizationGitHubCredential` schema, separate
from personal `GitHubCredential`/`GitHubIdentity`. It contains:

- local organization ID; authenticated GitHub user ID/login as grant provenance;
- authorizing local user ID for audit, without ownership or cascade-delete
  semantics; client ID and verified App identity;
- encrypted access/refresh envelopes, expiries and credential state;
- verification/authority version, token generation and durable refresh claim.

`forge_mirrors` owns an organization connection record containing organization
ID, credential reference/version, verified GitHub organization ID/login,
installation ID and observation, connection state/version and effective scope.
Pending authorization/installation and disconnected states are explicit. There
is at most one current connection per local organization. Existing uniqueness
and identity-conflict rules for active organization/mirror bindings remain.

Keep provider binding and synchronization policy out of the account vault.
The orchestration facade coordinates those public contexts. Database migrations
belong under `apps/fornacast/priv/repo/migrations`.

Organization access and refresh envelopes use different AAD purposes, each
distinct from personal credential purposes. Each includes its version,
credential ID, organization ID, client binding and GitHub grant-user identity.
Replacing an access envelope with a refresh envelope, or substituting another
organization's envelope, must fail authentication. Reuse the existing keyring
and encryption implementation. Personal envelopes retain their existing AAD.
Never relabel or duplicate a personal access/refresh ciphertext into an
organization credential; require fresh authorization for the new connection.

Deleting/unlinking a personal connection or removing its user from a local
organization must not delete an independent organization credential. A removed
manager cannot manage the organization or finish an uncommitted authorization.
All current authorized managers can reconnect or disconnect the organization.
The provider may still invalidate access when the GitHub grant user's rights
change; local organization ownership does not override that provider boundary.

On reconnect, the old connection may remain usable while Device Flow is pending.
Saving the newly authorized grant atomically replaces the token pair, advances
credential and connection authority, and marks the connection unverified/
installation-required. Clear effective-scope verification; retain the pinned
GitHub organization ID and historical installation observation. This fences work
admitted under the old organization connection. The new grant must verify the
installation and effective repository coverage before the connection can return
to ready. Never combine a new grant with an old binding's ready status. Coordinate
this settlement through public context APIs in one database transaction, with
provider HTTP outside it. Rechecking an installation without a new grant also
uses expected authority versions before saving a verified binding.

## Attempt isolation, concurrency and renewal

Reuse Device Flow transport, token normalization, session infrastructure,
polling intervals, one-use claims, expiry and logout/cancellation behavior.
Each attempt additionally captures immutable organization ID, initiating local
user/session and expected organization connection version. Session attempt keys
include the organization; another organization's attempt cannot supersede,
poll, cancel or complete it accidentally.

Recheck the active actor and organization management permission at start, poll,
installation binding and immediately before committing either grant or binding.
Network calls remain outside SQL transactions. Use existing organization/user
locking patterns at settlement so removal of ownership or a newer connection
fences late results. A successful provider exchange is not sufficient authority
to overwrite another manager's connection.

Reuse the established refresh invariants: commit a durable claim before HTTP;
settle access and refresh material atomically under generation/authority checks;
ordinary refresh advances token generation without changing admitted authority;
ambiguous one-use refresh failure requires reconnect. Reconnect, disconnect and
invalidation fence stale refresh/save results. Access/refresh tokens and the
provider's secret `device_code` never enter browser state, job arguments, audit
metadata, logs or public results. Only the user-facing `user_code` and verified
verification link are displayed on the authenticated organization device page.

## Installation-bound discovery and access

Add bounded, typed App-user-token APIs for installation listing and
`/user/installations/:installation_id/repositories`. Reuse fixed-host transport,
DTO validation, request gates, error classification and repository normalization.
Validate pagination against the exact bound installation path; incomplete or
invalid pagination cannot establish complete coverage.

Inventory must come from the chosen installation, rather than generic public
organization discovery. Every repository must match the immutable GitHub
organization ID and belong to the effective installation inventory. Recheck
installation/repository membership before consequential effects; a successful
`GET /repos/:owner/:repo` alone is insufficient evidence of installation access.

Installation repository selection and the grant user's effective repository
access are separate facts. Do not describe a limited user-visible list as full
installation coverage. Bind policy and source IDs explicitly and retain the
existing local selection semantics within that provider-authorized boundary.

Permissions are checked against enabled work. Display missing permissions and
the available installation action before admitting work that needs them.
Repository metadata/Git visibility does not establish LFS availability. The
earlier `repub` LFS 403 was resolved after the App permissions and organization
installation were corrected. The organization credential completed the real
LFS batch/download path for a reachable 917-byte object with size and SHA-256
verification. This object-level access proof does not replace successful
terminal synchronization of the complete organization inventory.

## Synchronization integration and execution authority

Reuse the existing organization Sync now, `PatSyncRun`, `ImportRun`, Styx queues,
repository result leases, checkpoints, retry/recovery and inbound Git/LFS engine.
Internal legacy PAT names may remain; product labels describe the actual source.
There is no additional synchronization engine.

Add an explicit organization credential-source discriminator and connection
references to configuration, run snapshots, import credential dispatch,
validation, constraints, scheduler/recovery and status projections. Personal
owner/identity fields remain mandatory only for the legacy personal source.
New runs snapshot organization, connection/credential authority versions,
installation, GitHub organization and repository-scope authority. They never
silently fall back to a personal saved credential or installation-token broker.

Worker authority must change alongside checkout. A committed organization run
executes under its live organization connection, configuration and leased run/
repository scope. The connecting/requesting user is audit provenance, not the
credential owner workers impersonate. Check organization state, connection
versions, pause/disconnect, destination, repository generation and lease before
provider work and publication.

Extend source-specific discovery, staging, destination authorization,
publication, recovery and inbound write-admission boundaries where they currently
require the original personal actor. Use narrow organization-operation domain
APIs and existing authorization/write fences; do not fabricate an active User,
choose another owner automatically or weaken personal import authorization.
Domain applications must not acquire a reverse dependency on `ForgeMirrors`.

Preserve the legacy-writer handoff guard for repositories already enrolled in
Git/LFS mirrors. Supporting this source in that existing, explicitly selected
Git/LFS mode requires connection scope propagation, `MirrorCredential` dispatch
and source-specific claims/authorization. Apply the existing force-push and
ref-deletion restrictions to the new source explicitly. Broker-only permanent
metadata workers must not claim this source or acquire additional capabilities.

The full private-key App metadata-mirror pipeline is not converted as part of
this connection correction. Its existing behavior remains available for its
existing configured authentication source. Do not treat the new source as
`:github_app`, which currently means installation-token authority.

## Unified status and migration

The connection card derives from organization credential health and verified
binding. Sync health derives from the actual selected mode's runs/operations.
Authorization completed, installation required, permissions missing, ready,
running, failed and reconnect required are distinct user-visible states.
Webhook status says unavailable/not configured when appropriate. A connected
badge never claims successful synchronization or webhook delivery.

Migrations are additive. Preserve personal credentials, existing configurations,
run history, repository IDs, mirror bindings, generations and publication proof.
An existing legacy run, including run #19, retains its recorded source and
authority. Preparing a new organization connection does not rebind that work.

Activation against an existing configuration is an explicit source switch after
its active work has settled, or after a separately requested pause/cancellation
has fenced it at existing authorization boundaries. Reject a busy switch; never
SQL-reset leases, relabel active runs or allow competing legacy/new writers.
Reconcile an existing mirror's ownership/identity conflicts before adopting it;
do not insert a parallel active mirror or discard its repository evidence.

## Acceptance and implementation boundary

The implementation must demonstrate:

1. Real organization-scoped start/poll/cancel, installation-required and connected
   UI states; no personal credential is created by organization authorization.
2. Authorization isolation for members/non-owners, cross-organization attempts,
   ownership removal during provider HTTP, concurrent owners and stale completion.
3. Encrypted organization storage, no shared refresh envelope, safe renewal and
   refresh racing disconnect/reconnect; personal lifecycle compatibility.
4. Wrong App/account, absent/suspended installation, insufficient permissions,
   selected-repository restrictions and incomplete pagination fail closed.
5. Existing import/sync execution and recovery use only the admitted organization
   source, with publication/local-write checks and no actor impersonation.
   After connection and run commitment, removing or deactivating the connecting
   local user does not stop work solely because that audit user is inactive;
   another current manager retains management access. Independently revoked
   GitHub-side access still fails under the provider's permission checks.
6. Legacy run/source preservation, busy cutover rejection, handoff safety and
   explicit Git/LFS write-policy restrictions.
7. PostgreSQL-scoped regressions, formatting, compilation, and real-browser proof
   at the served local organization route, including no secrets or overflow.
8. Real App consent/installation binding and a successful terminal sync including
   LFS before the earlier conditional commit/push/v0.8.0 release is fulfilled.

This design stage does not mutate GitHub installations, permissions, existing
credentials or active sync work. Implementation, local verification, live provider
acceptance, publication and deployment must be reported as separate boundaries.
The design remains uncommitted while the user's conditional delivery gate is
unmet. Implementation begins after review of this replacement design.

## Sources

- `apps/forge_accounts/lib/forge_accounts/{github_accounts,github_credential,github_credential_vault}.ex`
- `apps/fornacast_web/lib/fornacast_web/{github_device_attempt,github_device_session}.ex`
- Organization GitHub/PAT settings controllers and templates; `router.ex`.
- `apps/forge_imports/lib/forge_imports/{organization_sync,organization_pat_settings,pat_sync_worker,pat_repository_sync,credential_provider}.ex`
- Import discovery, repository worker, publisher, recovery and organization orchestration.
- `apps/forge_mirrors/lib/forge_mirrors/{pat_configuration,organization_mirror,pat_git_mirror}.ex`
- `apps/forge_github/lib/forge_github/{mirror_credential,git_ref_worker,inventory_worker}.ex`
- [GitHub user access tokens and Device Flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)
- [GitHub App installation APIs](https://docs.github.com/en/rest/apps/installations)
- [Installation access-token authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
