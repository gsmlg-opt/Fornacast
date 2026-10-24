# GitHub imports

Fornacast provides a **one-time migration** workflow from GitHub.com into local users or
locally owned organizations. Imports are durable, restartable, and web-managed.
Organization synchronization configuration is separate from each one-time import and
supports subsequent explicit synchronization.

See also the approved design in
[`docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`](../superpowers/specs/2026-08-25-github-repository-organization-import-design.md).

## Credentials

### Organization import options

Open **Import organization** (`/organizations/import`) and choose one of two paths:

- **Synchronize public repositories:** enter the GitHub organization and create or
  select a local organization you own. No GitHub account or token is required.
- **Install and connect GitHub App:** create or select the local organization, then
  authorize and verify its organization-owned App connection as described below.

New and existing destinations use separate server-rendered forms. Switching the
destination does not submit stale fields from the other choice; these forms work
with JavaScript disabled. Discovery opens the existing repository selection,
conflict review and explicit start workflow.

### Public repository access

Public access uses anonymous GitHub REST, Git and LFS reads. It never falls back to
a saved account. GitHub's anonymous REST limit is normally 60 requests per hour per
originating IP; the actual response controls waiting and the next attempt time.
Large imports may need several limit windows. Required resources that need
authorization prevent publication; connect the App to use authenticated access.

Only complete public inventories are admitted. The organization and repository
numeric IDs and repository visibility are checked again during execution and before
publication. Private or inaccessible repositories are not silently skipped as a
successful public import. Public retries retain anonymous access and require no
saved identity.

After a public organization import completes, an unconfigured destination receives
a manual public synchronization configuration. Existing configured sources and
active jobs remain unchanged. Use **Organization settings → GitHub → Synchronize
public repositories** to configure or switch a source explicitly, synchronize again,
pause or resume, manage repository selection, and open task history. Switching
sources requires active work to finish. Public synchronization is inbound only;
bidirectional Git/LFS enrollment requires an authenticated source.

### Organization GitHub App connections

Choose **Organization settings → GitHub → Connect with GitHub**. Authorize using
Device Flow, then select the Fornacast App installation in the intended GitHub
organization. Authorization alone leaves the connection at **installation
required**. The installation must provide read access to contents, issues and
pull requests, and its effective repository list must be verified before the
connection becomes ready. Install the App at
[GitHub](https://github.com/apps/fornacast/installations/new), then refresh and
recheck the installation if it is missing or its permissions changed.

Access and refresh tokens are encrypted and owned by the local organization.
The authorizing user is recorded for audit; removing that user from the local
organization does not invalidate committed organization work. GitHub may still
revoke access when the authorizing GitHub user's access changes. A current local
organization manager can reconnect or disconnect the connection.

The App must have Device Flow enabled. Its public client ID is
`Iv23lizCVE3E24s7fCA0`; no client secret or App private key is required for this
connection. It creates a GitHub App user token, whose effective access is bounded
by the user, App permissions and installation repository selection. The displayed
repository list describes that effective access, not all installed repositories.

Activate **Use organization connection for synchronization** separately, then
choose **Sync now**. Existing active work prevents switching sources. New work
records the organization's connection and credential versions, and checks them
again before provider work and publication. Reconnect clears verified installation
scope and fences older work; recheck and reactivate the connection afterward.
Existing personal credentials and previously admitted jobs retain their original
authority. No personal token is copied into an organization connection.

### Legacy saved connections and one-time PATs

- **Saved PAT:** Choose **Settings → GitHub → Link GitHub account** to open the
  PAT form. The importer checks out the encrypted
  credential only inside an arity-one callback for the selected linked identity. Saved
  credentials survive across imports until replaced or deleted.
- **One-time PAT:** Entered for a single import run. The PAT is encrypted in a run-scoped
  envelope, used only while the run is active, and cleared when the run reaches a terminal
  state. One-time envelopes are never copied to successor retry runs.

PAT modes require a GitHub fine-grained or classic PAT with enough access to read the
selected repositories and organization metadata. App connections can access only
repositories available to both the user and the App installation, within the App's
granted permissions. Linking or import discovery fails with a
safe, non-leaking error when GitHub rejects the token, the token lacks required scopes, or
the GitHub account does not match the expected identity.

Use **Connect with GitHub** again if the organization displays **Reconnect required**.
Expired or rejected refresh tokens and abandoned or uncertain refresh requests
require reconnection because GitHub refresh tokens can be used only once.
Automatic renewal keeps the synchronization authorization version unchanged;
manual reconnection or credential replacement advances authorization and requires
installation verification and source activation again for an organization connection.

### Encryption keyring

Production releases require a dedicated AES-256-GCM keyring that is **not** derived from
`SECRET_KEY_BASE`:

| Variable | Purpose |
| -------- | ------- |
| `FORNACAST_GITHUB_CREDENTIAL_KEYS` | JSON object mapping key IDs to base64-encoded 32-byte keys |
| `FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID` | Key ID used for new writes |

Example shape (generate a key with `openssl rand -base64 32`):

```sh
FORNACAST_GITHUB_CREDENTIAL_KEYS='{"2026-08":"<base64-32-byte-key>"}'
FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID=2026-08
```

### Key rotation

Rotate in this order:

1. Add **both** the old and new keys to `FORNACAST_GITHUB_CREDENTIAL_KEYS`.
2. Switch `FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID` to the new key ID so new writes use it.
3. Re-encrypt saved credentials through the normal replace/reverify flows (or restart
   imports that were paused awaiting credential replacement).
4. Remove the old key from the JSON map only after every ciphertext has been rewritten.

Never remove the active key or the only key that can decrypt existing saved credentials.

## Import lifecycle

### Discovery and planning

1. For organizations, choose public access or connect the organization App. Legacy
   repository imports can still select a linked account or a one-time PAT.
2. Discover a repository or organization namespace.
3. Select repositories. Organization discovery initially selects every accessible repository.
4. Resolve conflicts: skip, rename, or confirmed replace for repositories; organizations are
   never replaced—choose a new local organization or an existing one you own.
5. Start the import. Organization plans activate the destination organization before any
   repository worker claims work.

### Execution and recovery

Each selected repository is an independent durable item processed by bounded workers:

| Phase | Meaning |
| ----- | ------- |
| Git staging | Bare mirror into a private importing shadow |
| Metadata staging | Issues, comments, labels, assignees, representable pull requests |
| LFS staging | Download and verify objects reachable from all imported branches and tags |
| Publication | Atomic swap from hidden shadow to visible repository |

Workers persist checkpoints and resume from durable evidence after restarts. The reconciler
re-schedules claimable work; worker return values never advance SQL state directly.

**Rate limits:** GitHub `403` rate-limit responses move the run/item into a persisted wait
with `next_attempt_at`. Nothing busy-loops before that instant.

**Awaiting credential:** Deleted, revoked, expired, or mismatched saved credentials move
unfinished runs/items to `awaiting_credential` while preserving the exact resume phase.
Provide a replacement credential for the same GitHub numeric account to resume.

**Cancellation:** Cancel requests persist intent first, stop queued work, and cooperatively
terminate Git/REST work between pages. Publication already in flight is never interrupted;
if publication commits first, the repository remains imported.

**Retry:** Terminal runs with partial or total unpublished failure can create an immutable
successor run. Only retryable unpublished items are copied; predecessor rows and reports
stay unchanged.

### Final report

When every selected item is terminal, Fornacast finalizes a durable report with bounded
entries (`imported`, `skipped`, `warning`, `failed`, `canceled`, `not_selected`) and clears
one-time credential material in the same transaction.

## Limits and cleanup

| Setting | Default | Role |
| ------- | ------- | ---- |
| `FORNACAST_IMPORT_REPOSITORY_CLEANUP_GRACE_SECONDS` | `86400` | Delay before reclaiming unpublished staging or grace-expired tombstones |
| `git_core` remote limits (`config :git_core, :limits`) | see `config/config.exs` | Mirror wall time, output cap, repository bytes, ref count |
| `forge_imports` recovery concurrency | `recovery_max_concurrency: 2` | Global import worker cap |

Cleanup requires the repository tree and Git process to share the same effective UID. Keep
the storage parent private and mount the volume exclusively to one node at a time.

## Supported and unsupported data

**Imported when representable today**

- Git branches and tags (bare mirror), including their reachable Git LFS objects
- Repository settings needed for publication (visibility, default branch, merge settings)
- Issues, comments, labels, assignees
- Pull requests that map to the current ForgeIssues/ForgePulls model, including same-repo PRs
- Release metadata and release asset binaries in one-time imports

**Reported but not imported**

- Cross-repository pull requests that cannot be represented locally
- Wiki repos, submodule recursion, GitHub-only refs
- Organization membership, teams, invitations, and GitHub permission grants

Unsupported categories appear in the final report; they are not silently dropped.

## Release assets

One-time imports preserve release timestamps, immutable state, historical body
projections and validated reaction/mention aggregates. Provider IDs remain source
mappings; public release and asset IDs and download URLs belong to Fornacast.
Historical reaction URLs remain GitHub references; importing aggregates does not
create local reactions.

Asset binaries stream into shared LocalCAS. PostgreSQL owns asset metadata and
upload operations. A separately versioned asset checkpoint prevents repository
publication until required assets are complete. Failures keep that phase incomplete
and appear in the report. Retry resumes journaled bytes and mappings.

Previously completed imports require explicit backfill with the current actor and
a saved credential:

```elixir
ForgeImports.backfill_release_assets(actor, item_id, github_identity_id, request_metadata)
```

Backfill preserves the completed run and repository lifecycle and checks current
generation and authorization. Boot and migrations never trigger historical GitHub
downloads. Organization mirrors retain the release-binary exclusion.

Upload local assets with a raw body and its Content-Type to
`/api/v3/repos/:owner/:repo/releases/:id/assets?name=...`. Metadata, PATCH/DELETE and
range downloads use `/releases/assets/:asset_id`; `Accept: application/octet-stream`
selects bytes. The release page provides authorized asset and source archive links.
Private/draft visibility is inherited from the release. Published immutable
releases reject metadata and asset changes.

Deletion hides metadata immediately. Maintenance reclaims unreferenced bytes after
the configured grace, checking other assets, unfinished operations and LFS inventory.
The supported deployment remains one BEAM with exclusive storage and
stop-before-start upgrades. Back up PostgreSQL and the complete filesystem volume
together in a quiesced window.

## Git LFS

One-time imports download LFS objects referenced anywhere in the history reachable
from imported branches and tags, including annotated tags. Objects are streamed
into local storage and checked against their SHA-256 identifier and declared size
before the repository can be published. Empty repositories and repositories
without LFS pointers require no LFS downloads.

LFS uses the import's admitted public, organization, saved or one-time source. That
source must also be able to read the repository's LFS objects. GitHub App-backed organization mirrors
retain their existing bootstrap handoff: an LFS-enabled repository stays in the
synchronizing lifecycle until the mirror workers make its objects available and
confirm its refs. Existing mirror capability settings remain in effect.

Scans and transfers keep durable progress across worker restarts. Missing objects,
size/hash mismatches, and authentication failures prevent successful publication;
they are not downgraded to an unsupported-feature warning. Use the existing
credential replacement and retry controls after resolving the reported failure.
Completed historical imports are not automatically repaired; re-import them to
fetch LFS objects that an older version skipped.

For LFS-enabled ongoing synchronization, inbound objects are downloaded and
verified before confirming local refs; outbound objects are uploaded and verified
before pushing refs to GitHub. LFS locking is not supported.

## Conflict and replacement semantics

- **Skip:** The repository is not imported; intentional skips are excluded from retry.
- **Rename:** Publish under a new slug in the destination namespace.
- **Replace:** Create a new local repository row and storage generation; tombstone the
  previous live repository without mutating its storage in place. The public URL slug stays
  the same, but the repository ID and generation change.

Organization namespaces are never replaced. Importers may create a new organization or select
an existing organization they locally own.

## Web UI and observability

Authenticated owners manage imports under:

- `/organizations/:organization/settings/github` — compact organization connection summary
- `/organizations/:organization/settings/github/connection` — authorize with Device Flow, select/recheck the installation, activate or disconnect the organization source
- `/organizations/:organization/settings/github/public` — configure anonymous public access and start subsequent synchronization
- `/organizations/:organization/settings/github/runs` — synchronization tasks and results
- `/organizations/:organization/settings/github/legacy` — existing personal credential synchronization configuration
- `/organizations/:organization/settings/github/app/advanced` — separate private-key installation-token integration
- `/settings/github` — manage legacy personal credentials and choose an organization to connect
- `/settings/github/device` — choose the organization that owns the GitHub App connection
- `/settings/github/link` — link an account with a saved PAT
- `/repos/import` — single-repository plans
- `/organizations/import` — choose public access or the organization GitHub App
- `/organizations/import/public` and `/organizations/import/app` — choose a new or owned local destination without personal credential fields
- `/imports/:id` — progress, cancel, credential replacement, retry, and final report

Progress polling uses session-scoped JSON at `/imports/:id/status` with a no-JavaScript
manual refresh fallback. Status, report, and telemetry payloads exclude PATs, authorization
headers, storage paths, and private metadata.

## Optional live smoke

For manual verification against a **public** GitHub organization:

1. Start a development instance with PostgreSQL (`mix fornacast.run`).
2. Open **Import organization → Synchronize public repositories** and choose a local destination.
3. Walk through discovery, conflict review, progress, and the final report in the web UI.
4. Confirm the imported repository is visible only after publication completes.

Automated acceptance uses stubbed GitHub responses and real local Git fixtures in
`apps/forge_imports/test/public_organization_sync_test.exs` and the existing
`apps/forge_imports/test/github_import_e2e_test.exs`. These tests do not prove live
App consent or a complete live GitHub organization synchronization.

## Automated acceptance

PostgreSQL 17 is the required gate:

```sh
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  mix test apps/forge_imports/test/github_import_e2e_test.exs --max-cases 1
```

Browser verification at multiple viewports is optional for operators; the automated suite
covers domain workflow, recovery controls, and credential redaction.
