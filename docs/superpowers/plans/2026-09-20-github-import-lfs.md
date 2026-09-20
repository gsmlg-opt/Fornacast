# GitHub Import LFS Implementation Plan

> **For agentic workers:** Use subagent-driven-development for implementation and independent review. Preserve unrelated changes and do not commit or deploy.

**Goal:** One-time GitHub imports publish only when all reachable LFS objects are locally available.

**Architecture:** Reuse GitLFS.PointerScanner and ForgeGitHub.LFS.TransferCoordinator behind an import-owned bounded coordinator. Persist import progress in the existing item checkpoint and fence publication on completion. Preserve the existing mirror bootstrap transfer path and its capability configuration.

**Tech Stack:** Elixir umbrella, PostgreSQL 17, GitCore, GitHub LFS Batch/Basic, local CAS.

## Task 1: Import credential gates

Files: `apps/forge_github/lib/forge_github/lfs/transfer_coordinator.ex` and `apps/forge_github/test/github/lfs_transfer_coordinator_test.exs`.

- [x] Add regression cases accepting `{:saved_credential, id}` and `{:one_time_run, id}` while retaining installation gates and rejecting unrelated/invalid gates.
- [x] Run focused tests and observe the new cases fail on `:invalid_request`.
- [x] Extend only the existing gate validator and documented option type to those import identities.
- [x] Run the focused coordinator tests again.

## Task 2: Durable import LFS staging and publication

Files: `apps/forge_imports/lib/forge_imports/github/lfs_importer.ex` (new), import worker/publisher/recovery and directly necessary import schema validation, `apps/forge_imports/mix.exs`, focused import tests.

- [x] Write a real Git fixture test containing historical, branch-only and tag-only pointers; assert publication cannot precede stored bytes. Observe failure before production edits.
- [x] Implement bounded scanner progress and paged inbound transfer using the current credential provider gate, callbacks for fresh lease/cancellation authorization, and existing verified CAS storage.
- [x] Record baseline/generation-bound completion and yield durable intermediate progress through current worker ownership semantics.
- [x] Require completion before publication for standalone imports, including old staged work. Keep mirror bootstrap's existing gated handoff authoritative without duplicate transfers.
- [x] Cover restart, missing/corrupt bytes, token loss, cancellation/lease loss, empty/non-LFS repositories, and all credential identities with focused tests.
- [x] Preserve existing import test behavior for unrelated metadata, warnings and recovery; update obsolete LFS-only expectations to the new requirement.

## Task 3: Sync regression, documentation and final review

Files: existing scoped mirror LFS/bootstrap tests, README and the import design addendum only.

- [x] Run existing worker/finalizer LFS tests and bootstrap integration coverage. Repair only demonstrated LFS failures.
- [x] Update the stale LFS scope statement and document complete one-time imports, failure/retry behavior and existing sync capability.
- [x] Independently review spec compliance and then correctness/authorization/recovery. Repair and rerun the affected checks.
- [x] Run `devenv shell -- mix format --check-formatted` in the worktree and focused PostgreSQL tests using `PGPORT=55432` and the managed Unix socket.
- [x] Record final evidence, pending live GitHub verification, and a scoped Agent Note after validated work.

## Execution environment

Worktree: `.trees/github-import-lfs`, branch `codex/github-import-lfs`.
Use the parent checkout's devenv shell and `cd` into this worktree to retain the
managed PostgreSQL socket. Set `POSTGRES_TEST_DB=fornacast_lfs_import_test` for
isolated database-backed validation. Only one Mix build/test runs at a time.

No live credentials, GitHub mutations, commits, pushes, or deployment are part of this implementation.


## Verification completed on 2026-09-20

Local implementation is based on `dc72bd2` (v0.3.1), remains uncommitted in
`codex/github-import-lfs`, and has not been deployed.

All commands ran from the parent checkout through `devenv shell -- sh -c`, with
`cd .trees/github-import-lfs`. Database tests used
`PGPORT=55432 POSTGRES_TEST_DB=fornacast_lfs_import_test` and the managed Unix socket.

- `mix format --check-formatted`: passed after final code/test edits.
- `mix test apps/git_lfs/test`: 36 passed.
- `mix test apps/forge_mirrors/test/git_ref_sync_persistence_test.exs`: 29 passed.
- `mix test apps/forge_github/test/github/lfs_transfer_coordinator_test.exs apps/forge_github/test/github/lfs_sync_test.exs apps/forge_github/test/github/lfs_sync_persistence_test.exs apps/forge_github/test/github/lfs_reconciliation_test.exs apps/forge_github/test/github/release_client_test.exs apps/forge_github/test/github/git_ref_worker_test.exs`: 63 passed.
- `mix test apps/forge_imports/test/repository_worker_test.exs apps/forge_imports/test/repository_publication_test.exs apps/forge_imports/test/retry_test.exs apps/forge_imports/test/lfs_importer_test.exs apps/forge_imports/test/github_app_pull_bootstrap_test.exs`: 135 passed, seed 117668.
- After adding the saved-credential revocation regression and finalizing the mirror proof fixture, `mix test apps/forge_imports/test/repository_worker_test.exs:834 apps/forge_imports/test/lfs_importer_test.exs`: 7 passed, 72 excluded, seed 209645. This adds one case to the prior aggregate: **264 distinct focused tests passed**.
- Independent implementation/spec reviews: passed after lease, credential, pagination, and documentation corrections. `git diff --check`: passed.

The initial aggregate run exposed a test fixture that reused previously verified
CAS bytes, bypassing its intended corrupt-download path. Fixtures now use fresh
object content per invocation; the 135-case import rerun passed. Existing unused
fixture warnings and intentional worker shutdown/Sandbox disconnect log messages
remain; no unrelated production changes were made to silence them.

Additional fixes required by the real import path: saved-credential read/page
gates in `ReleaseClient` and `Client`, current-lease credential settlement,
metadata-state cancellation, and lease renewal with refreshed capabilities before
checkout and persistence. These preserve the existing authorization boundaries.

Real local Git fixtures plus real scanner, credential provider, coordinator, and
CAS storage were exercised; GitHub provider responses were simulated. Live GitHub
clone/LFS checkout, remote CI, commit, push, and deployment were not run. Historical
completed imports require re-import to obtain objects skipped by older versions.

Agent Note created and read back with `project: fornacast`:
`9d2aad10-1976-438a-b3d7-d28e2d78e72b`.
