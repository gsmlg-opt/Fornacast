# Project follow-up status, 2026-10-19

Implementation is committed on `codex/project-completion` in
`.trees/codex/project-completion`. These commits are not merged or pushed.
The original main-worktree PAT recovery edits remain preserved.

## Delivery boundaries

| Follow-up | Evidence and remaining boundary |
| --- | --- |
| PAT recovery | `5e82058` excludes failed/cancelled ancestors with successors. Regression tests reproduce the old failure without the patch. The managed local service was reloaded; real browser Sync now POST returned 303 and admitted run 17. This proves admission with the fix, not terminal completion of run 17. |
| Git-data REST | `09e7adf` implements the ten branches/refs/commits/contents routes and real README initialization. Both API versions pass real REST, smart HTTP and SSH clone/fetch/push acceptance against the same repository. Durable CAS/recovery, authorization, audit and mirror outbox integration are covered. See the [Git-data plan reconciliation](2026-07-21-github-api-git-data.md). |
| Two-way mirrors | `f572cac` enables development App configuration and documents the [local acceptance procedure](../../github-app-local-acceptance.md). Real GitHub installation/webhook evidence and independent hydrated Git/LFS checkout from both endpoints remain open. A writable test target and locally configured App credentials are still required. |
| Workbench and HTTP status | `b32896d` replaces `/issues` and `/pulls` placeholders with authorized queries, filters, pagination and detail links. `0d4c5f1` refreshes the published HTTP Fetch audit: #68 is resolved, while [#135](https://github.com/gsmlg-dev/http_fetch/issues/135) blocks preservation of TLS-setup failover. Req/Mint remain in use. |

## Verification

- PostgreSQL 17, isolated `fornacast_completion_test`: 481 tests pass across 34
  focused files in seven umbrella apps. This is a scoped gate, not a full-suite
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

The browser console gate remains open for an existing dependency defect:
`duskmoon_bundler 9.16.11` resolves dynamic-import preload dependencies against
the document URL. `/app-common-ad60895e.js` returns 404 although the actual
`/assets/js/app-common-ad60895e.js` exists. This is covered by
[DuskMoon #200](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/200),
fixed upstream in 9.16.14. The current dependency cohort has not been upgraded
or worked around. A successful asset build does not close this runtime gate.

The [organization acceptance ledger](2026-09-07-github-org-sync-acceptance.md)
retains the real GitHub and two-endpoint gates. Local PAT synchronization and
local REST/Git acceptance do not substitute for those observations.
