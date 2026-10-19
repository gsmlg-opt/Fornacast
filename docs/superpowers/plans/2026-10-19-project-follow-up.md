# Project follow-up status, 2026-10-19

Delivery work is on `codex/project-completion` in
`.trees/codex/project-completion`. Delivery includes six commits through `3e01499`
and the saved-PAT Git/LFS integration with final endpoint evidence. These changes
remain unmerged and unpushed.
The original main-worktree PAT recovery edits remain preserved.

## Delivery boundaries

| Follow-up | Evidence and remaining boundary |
| --- | --- |
| PAT recovery | `5e82058` excludes failed/cancelled ancestors with successors. Regression tests reproduce the old failure without the patch. The managed local service was reloaded; real browser Sync now POST returned 303 and admitted run 17. This proves admission with the fix, not terminal completion of run 17. |
| Git-data REST | `09e7adf` implements the ten branches/refs/commits/contents routes and real README initialization. Both API versions pass real REST, smart HTTP and SSH clone/fetch/push acceptance against the same repository. Durable CAS/recovery, authorization, audit and mirror outbox integration are covered. See the [Git-data plan reconciliation](2026-07-21-github-api-git-data.md). |
| Two-way mirrors | Permanent saved-PAT Git/LFS passes real GitHub inbound and Fornacast outbound worker execution. Independent endpoint clones/checkouts match refs, commits, trees and hydrated LFS bytes. Inbound and repaired outbound use explicitly separate local fixtures. Full PAT metadata/inventory parity remains open. `f572cac` supplies optional App configuration only. |
| Workbench and HTTP status | `b32896d` replaces `/issues` and `/pulls` placeholders with authorized queries, filters, pagination and detail links. The HTTP audit records #68 resolved and [#135](https://github.com/gsmlg-dev/http_fetch/issues/135) fixed in published Hex/GitHub 0.21.14. Source/packages were inspected and the release workflow completed successfully, checked at 11:24 UTC. Dependency adoption and scoped transport acceptance remain required; Fornacast still locks 0.18.1 and uses Req/Mint. |

## Verification

- PostgreSQL 17, isolated `fornacast_delivery_test`: 653 tests pass across 44
  focused files in nine umbrella apps. This is a scoped gate, not a full-suite
  or remote CI claim.
- All 93 native tests pass. Native formatting, repository-wide Elixir
  formatting, development compilation with warnings as errors, and asset build
  pass. The full 100 MiB contents HTTP roundtrip was not run; lowered ceilings
  cover payload-limit behavior.
- An isolated browser fixture at port 14990 verifies login, issue open/closed/all
  filters, pagination, private-repository exclusion, pull open/closed filters,
  and issue/pull detail navigation. The pull fixture uses real Git branches and
  commits. It is separate from the managed instance at port 4890 and rolls back
  its database rows on shutdown.
- The permanent PAT enrollment page renders its DuskMoon checkbox group with
  the expected repository-ID array and checked enrolled repository. Recovery
  regressions prove that a failed observation retains an outstanding effect's
  marker and LFS checkpoint, releases its lease, preserves provider retry times,
  and settles once. Real endpoint execution also exercises delayed reclaim
  without resetting leases or claiming that the effect was reconciled.
- The real outbound attempt exposed raw blob descriptors crossing process
  ownership. The coordinator now keeps open/read/close in one private source
  process and gives the transport an opaque handle. Regression coverage uses
  the real transport worker and raw file-backed source, including retry, timeout,
  caller death and revocation during opening. Fresh outbound worker execution
  and independent endpoint checks pass after the repair; the previous failed
  attempt remains recorded in the evidence.

The browser console gate remains open for an existing dependency defect:
`duskmoon_bundler 9.16.11` resolves dynamic-import preload dependencies against
the document URL. `/app-common-ad60895e.js` returns 404 although the actual
`/assets/js/app-common-ad60895e.js` exists. This is covered by
[DuskMoon #200](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/200),
fixed upstream in 9.16.14. The current dependency cohort has not been upgraded
or worked around. A successful asset build does not close this runtime gate.

The [organization acceptance ledger](2026-09-07-github-org-sync-acceptance.md)
distinguishes the verified inbound two-endpoint chain, permanent PAT Git/LFS
implementation/acceptance, and remaining full metadata acceptance.

## Local credential preflight

The user designated `duskmoon-dev` for external acceptance. Read-only GitHub
requests using `GITHUB_TOKEN` from the managed process returned 200 for `/user`,
`/orgs/duskmoon-dev`, and `/user/memberships/orgs/duskmoon-dev`: account `gsmlg`
has active admin membership in organization ID `127959075`. No credential values
were logged. The private test repository
`duskmoon-dev/fornacast-sync-acceptance-20261019` (ID `1425392764`) was created
for this acceptance; no pre-existing GitHub repository was modified.

The user has no GitHub App. PRD product decision 4 chooses PAT now and App as a
future replacement. Existing PAT configuration supports inbound import and Git/LFS
refresh. This branch also adds explicit permanent Git/LFS enrollment with saved
PAT authority; it no longer requires an installation for that bounded capability.

The real saved-PAT browser flow completed import 11 and published item 116 at
`/admin/fornacast-sync-acceptance-20261019`, with zero warnings, failures or skips.
Independent GitHub and Fornacast HTTP clones pass Git and LFS integrity checks,
match refs and commit/tree IDs, and hydrate matching 131072-byte LFS content.
See the [safe manifest](../../evidence/2026-10-19-pat-endpoint-checkouts.json).
The temporary local API key was revoked and its credential file removed.
This proves the original inbound import chain and both endpoint checkouts.

Permanent-worker acceptance is recorded in the
[bidirectional Git/LFS manifest](../../evidence/2026-10-19-pat-bidirectional-git-lfs.json).
The V2 fixture completes inbound reconciliation 179 and independently checks both
endpoints at GitHub commit `413d6df73602ef32fd50f512c16b829aa3acf95c`. Its first
outbound attempt fails at operation 189 because of raw-source ownership; that
failure is retained, and no failed row is rewritten as success. After graceful
V2 rollback, V3 imports/enrolls the same remote state into a fresh local binding.
Initial reconciliation 197 and outbound reconciliation 205 complete normally;
finalizer 214 confirms bootstrap item 52 at 11:34:56 UTC. Actual Fornacast HTTP
Git/LFS push produces `4ec67d38fc186ddea1321a7e6d02aa13ea5c00e0`, then the
production worker updates real GitHub branches/tags without force or deletion.

Fresh clones from both endpoints pass `git fsck --full`, `git lfs fsck`, four
branch checkouts, ref/tree comparisons and hydrated 128/160/192 KiB byte hashes.
Both fixtures revoke their temporary local API keys, remove credential files,
roll back database rows and stop their listeners on graceful shutdown. The
private GitHub test repository remains as evidence. The managed instance and its
independent active Sync now run are preserved. This accepts the bounded PAT
Git/LFS path; full PAT metadata/inventory and the remaining external PRD matrix
remain open.
