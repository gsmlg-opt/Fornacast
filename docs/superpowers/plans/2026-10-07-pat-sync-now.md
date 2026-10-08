# Organization PAT Sync now implementation plan

**Goal:** Clicking Sync now immediately starts a recoverable background synchronization of every PAT-visible GitHub organization repository, including existing imported repositories.

**Architecture:** Admit one durable PAT sync run per configuration under a PostgreSQL row lock. A supervised worker resumes discovery, automatically starts the existing import pipeline for new repositories, and fetches existing repository objects through the saved PAT into private tracking refs before LFS completion and public fast-forward CAS. Bind existing repositories by immutable GitHub ID and committed import publication evidence, never by name. Preserve local refs on divergence and remote deletions; report failures without stopping other repositories. The existing import pipeline retains its metadata and release asset coverage for newly imported repositories.

**Scope:** PAT entrypoint, scheduler, supervised durable worker and schema, existing Git/LFS refresh, settings action/status and focused tests. GitHub App sync, outbound writes, force-push and public ref deletion are excluded. Full existing metadata refresh remains subject to the user's pending content clarification.

**Current content boundary:** New repositories run the existing import pipeline for Git history, reachable LFS objects, repository metadata and supported issues, pull requests, releases and release assets. Existing repositories refresh Git refs and their reachable LFS objects; their existing issues, pull requests, release metadata and assets are not refreshed. The settings pages report totals, repository outcomes and discovery/job failures. Saved repository selection does not restrict Sync now, which always includes all PAT-visible organization repositories.

- [x] Reproduce incomplete entrypoint and stale request status overwrite with focused PostgreSQL regressions.
- [x] Add durable run admission and active-run uniqueness; invalid/disabled/paused requests leave completion state unchanged.
- [x] Implement recoverable discovery, all-repository automatic import activation, reliable existing-repository bindings and per-repository progress.
- [x] Implement saved-PAT private fetch, full-history LFS gating, fenced public fast-forward CAS and bookkeeping.
- [x] Connect scheduling and both settings pages to actual job lifecycle.
- [x] Verify all repository enumeration, new and existing contents, repeated clicks, recovery, errors, credentials and local-change preservation through scoped PostgreSQL tests.
- [x] Browser-verify current service and live organization behavior within the authorized request.
- [x] Record validated reusable findings in Agent Note with project=fornacast.

## Validation evidence

Focused PostgreSQL checks passed for PAT admission (7), durable worker (7), existing Git/LFS synchronization (12), settings pages (9), importer credentials/repository worker (88), publication (47), Git write/recovery (25), PAT settings (6), Git object expansion (3), and durable LFS scanner (8). The native annotated-tag traversal unit test also passed. Mix format, Rust format and git diff whitespace checks passed.

The existing GitHub App pull bootstrap test still fails at release baseline handoff (`release_baseline_requires_refetch`); restoring the baseline publisher reproduced the same failure. It was not repaired as part of this PAT change. These checks did not include the full suite or release verification.

Development migrations were applied and the managed Fornacast service was refreshed. Browser verification triggered durable PAT job 1 / import run 2, discovering all 17 `gsmlg-opt` repositories without a review step. Existing `scout` successfully synchronized and local main matched GitHub at `0c39c9c4ab0b4460f5b24d187e24613046c81563`. New `hex_hub` Git contents reached metadata staging and its local main matched GitHub at `95304f39ab17dc64a6d519581cc834e7a7dd5a47`. These initial observations preceded the final recovery audit.

Live capacity contention exposed remote/request-gate busy outcomes; these now stay pending and retry fairly, while imports run, then use bounded retries after import settlement. Scoped worker coverage confirms recovery from persisted busy results. No source ref deletion or force-push is performed.

Final live verification on 2026-10-08 at 21:05 Asia/Shanghai confirmed job 8 succeeded and import run 8 completed: all 17 original repository IDs succeeded, with no failed or pending repositories. The audit checked committed publication evidence across the predecessor lineage, live repository identity, frozen Git refs, all 17 repositories with `git fsck`, completed LFS scans, metadata checkpoints and release asset mappings. All 1,379 release assets (1,096 distinct blobs, 18,818,963,361 bytes) and 8 LFS files passed SHA-256 verification. The settings page showed the same terminal result and all health checks passed.

Historical PR policy excluded 67 records: 55 deleted source branches and 12 changed source commits. This result does not claim exact live GitHub metadata parity. The historical `.github` import has no releases or assets and lacks the newer empty asset checkpoint; its existing terminal evidence was validated.
