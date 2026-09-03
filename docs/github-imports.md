# GitHub imports

Fornacast provides a **one-time migration** workflow from GitHub.com into local users or
locally owned organizations. Imports are durable, restartable, and web-managed. They are
not mirrors: nothing polls GitHub after the run finishes.

See also the approved design in
[`docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`](../superpowers/specs/2026-08-25-github-repository-organization-import-design.md).

## Credentials

### Saved versus one-time PATs

- **Saved PAT:** Linked under **Settings → GitHub**. The importer checks out the encrypted
  credential only inside an arity-one callback for the selected linked identity. Saved
  credentials survive across imports until replaced or deleted.
- **One-time PAT:** Entered for a single import run. The PAT is encrypted in a run-scoped
  envelope, used only while the run is active, and cleared when the run reaches a terminal
  state. One-time envelopes are never copied to successor retry runs.

Both modes require a GitHub fine-grained or classic PAT with enough access to read the
selected repositories and organization metadata. Linking or import discovery fails with a
safe, non-leaking error when GitHub rejects the token, the token lacks required scopes, or
the GitHub account does not match the expected identity.

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

1. Link a GitHub account or supply a one-time PAT.
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

- Git branches and tags (bare mirror)
- Repository settings needed for publication (visibility, default branch, merge settings)
- Issues, comments, labels, assignees
- Pull requests that map to the current ForgeIssues/ForgePulls model, including same-repo PRs

**Reported but not imported**

- GitHub releases and release assets (no published release domain yet)
- Cross-repository pull requests that cannot be represented locally
- Git LFS objects, wiki repos, submodule recursion, GitHub-only refs
- Organization membership, teams, invitations, and GitHub permission grants

Unsupported categories appear in the final report; they are not silently dropped.

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

- `/settings/github` — link, replace, and delete saved credentials
- `/repos/import` — single-repository plans
- `/organizations/import` — organization plans, conflict review, start controls
- `/imports/:id` — progress, cancel, credential replacement, retry, and final report

Progress polling uses session-scoped JSON at `/imports/:id/status` with a no-JavaScript
manual refresh fallback. Status, report, and telemetry payloads exclude PATs, authorization
headers, storage paths, and private metadata.

## Optional live smoke

For manual verification against a **public** GitHub repository:

1. Start a development instance with PostgreSQL (`mix fornacast.run`).
2. Use a one-time PAT with read access to the public repository only.
3. Walk through discovery, conflict review, progress, and the final report in the web UI.
4. Confirm the imported repository is visible only after publication completes.

Do not persist the smoke PAT as a saved credential unless you intend to keep it. Automated
acceptance uses `Req.Test` stubs and local Git fixtures in
`apps/forge_imports/test/github_import_e2e_test.exs`.

## Automated acceptance

PostgreSQL 17 is the required gate:

```sh
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  mix test apps/forge_imports/test/github_import_e2e_test.exs --max-cases 1
```

Browser verification at multiple viewports is optional for operators; the automated suite
covers domain workflow, recovery controls, and credential redaction.
