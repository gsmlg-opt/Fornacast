# GitHub organization sync acceptance ledger

Source: `docs/fornacast-github-org-sync-prd.md`, section 13 (all 22 criteria).

This is a working evidence ledger, not a completion declaration. A test entrypoint
below identifies relevant coverage; its existence alone does not prove acceptance.
The full goal remains open. PR11 is locally implemented in `acedead`, PR12 is in progress, and
PR13–16 remain to be implemented and verified.

## Requirement-by-requirement gates

| # | Required outcome | Current evidence / next gate |
|---|---|---|
| 1 | Owner connects the App to the correct organization | Foundation installation/authorization tests exist in `apps/forge_mirrors/test/`. Re-run the complete connection flow with owner and mismatched-account cases in final acceptance. |
| 2 | Permission and partial-access problems visible before bootstrap | Installation intent and settings checks exist. Final acceptance must verify rendered diagnostics and prevent bootstrap with missing required permissions. |
| 3 | All enabled supported resources bootstrap to active bindings | `apps/forge_imports/test/repository_publication_test.exs` covers atomic handoff and hidden LFS bootstrap. Release metadata and complete collaboration convergence remain open. |
| 4 | Bootstrap-time webhooks replay after baseline | Handoff and durable inbox tests exist. Re-run a complete buffered replay with Git, LFS, and metadata resources after PR12–16. |
| 5 | GitHub-created repository imports according to policy | Inventory worker and persistence tests exist. Final gate must follow inventory through completed bootstrap, not stop at enqueue. |
| 6 | Local organization repository is created on GitHub according to policy | Outbox/inventory foundation exists. Complete provider-side creation and ambiguous-create recovery must be proven, including policy-disabled behavior. |
| 7 | Local branch create/fast-forward reaches GitHub | Git ref worker and exact remote primitives have focused tests. Run the complete outbound Git+LFS workflow against the remote fixture. |
| 8 | GitHub branch create/fast-forward reaches Fornacast | Inbound ref worker coverage exists. Verify the public ref changes only after required LFS availability. |
| 9 | Safe ref deletion only from unchanged baseline | `git_ref_decision_test.exs` and worker/persistence tests cover policy and CAS. Include branch/tag deletion in final two-endpoint acceptance. |
| 10 | Divergence is visible and neither side overwritten | Conflict persistence/worker tests exist. Finish and verify conflict UX in PR16. |
| 11 | LFS clone and checkout succeed from either endpoint after sync | Actual Fornacast smart-HTTP clone with official git-lfs 3.7.1 checks out 128 KiB with matching SHA-256. Existing official SSH LFS transfer coverage is also present. Remote endpoint plus full synchronization-to-clone chain remain unproven. |
| 12 | Missing/corrupt LFS blocks confirmation and degrades sync | Focused worker, storage, durable 101-pointer replay, and authoritative-scan tests pass. Finalizer queue/catch-up review fixes are committed in `acedead`; retain the full integrated gate in final acceptance. |
| 13 | Issue/comment changes converge both ways | PR12 in progress: scalar/set comparison, persisted snapshots, correlation-marker codec, transactional version/outbox producers (`b8c9ea7`), bounded provider APIs (`ae19146`), and consumer/webhook trigger retention (`7128612`) pass focused tests. Worker effects, mappings, correlation recovery, and integrated convergence remain open. |
| 14 | Same-repository PR metadata converges both ways | PR13 remains open. Bootstrap import is not two-way synchronization. |
| 15 | Coordinated PR merge produces one confirmed Git result | PR13 remains open; verify effect-boundary recovery, exact expected SHAs, and both resulting endpoints. |
| 16 | Release metadata converges and stays bound to a confirmed tag | PR14–15 remain open. Existing scaffold is not proof of implementation. |
| 17 | Release assets and wiki never synchronize | Verify explicit negative fixtures across import, inbound events, outbound events, and reconciliation when release sync is implemented. |
| 18 | Duplicate/out-of-order webhooks neither duplicate nor regress | Inbox foundation tests exist. Extend resource-specific fixtures for issues/comments, PRs, and releases. |
| 19 | Every operation boundary recovers after restart | Git/LFS checkpoint, lease, marker-replacement and rate-limit recovery tests pass. Metadata create/update/delete/merge boundaries and full restart matrix remain open. |
| 20 | Full reconciliation repairs omitted deliveries | Inventory and Git/LFS reconciliation exist. Complete metadata sweeps and intentionally omitted-event acceptance in PR16. |
| 21 | Pause prevents new effects but retains work | Foundation lifecycle/scheduler tests exist. Recheck each new worker at the external-effect boundary, including a pause during long LFS work. |
| 22 | Disconnect/revocation stops token use and retains local repos | App credential/lifecycle foundation exists. Verify every new worker and in-flight recovery path in final acceptance. |

## Current local verification

- Latest combined scoped matrix: **152 passed** (GitCore 2, GitLFS 24,
  ForgeMirrors 25 including the five PR12 comparison tests, ForgeGitHub 54,
  ForgeImports 41, FornacastWeb 6 including official HTTP/SSH LFS clients).
  The final generic terminal-child fix then passed ForgeMirrors 18 and GitHub
  worker/reconciliation 24 tests, plus compilation with warnings-as-errors.
- PR11 focused PostgreSQL matrix: 111 tests passed before the finalizer follow-up
  tests were added (GitLFS 24, ForgeMirrors 14, ForgeGitHub 32, ForgeImports 41).
- Additional finalizer checkpoint/integrity matrix: 19 passed.
- Additional provider/native matrix: GitCore 2, installation intent 3, GitHub LFS 18 passed.
- Official HTTP clone/smudge test: passed; a fresh clone fails when its required
  test-owned object bytes are removed. This is **local endpoint** evidence.
- PR12 comparison policy: five standalone ExUnit tests passed, including all 512
  combinations of three-element baseline/local/remote sets.
- PR12 baseline/marker/policy matrix: 15 passed. Snapshot tests include direct
  PostgreSQL constraint rejection of oversized objects and arrays. Marker tests
  preserve unrelated content and count the suffix and combining codepoints in
  the bounded body budget. These helpers do not yet prove worker integration.
- PR12 provider API/Client/inventory regression matrix: 56 passed, with
  warnings-as-errors production compilation. API body limits count Unicode
  codepoints, and only root/list-resource body fields gain the larger JSON
  string budget; unrelated strings retain the generic bound.
- Webhook body/decoder/processor matrix: 34 passed (`c3a9add`). Long supported
  issue/comment bodies survive ingress without expanding other field budgets.
  Metadata notifications still remain `pending_unsupported` until the resource
  worker is ready; direct processor wiring alone is not an enabled sync path.
- Final consumer/webhook routing matrix: 71 passed (mirror retention/materializer
  33, provider webhook processor/body 38). Tests cover forged routes, immutable
  IDs, pull-vs-issue identity separation, bootstrap buffering, capabilities,
  paused/conflicted retention, tombstones, and transactional enqueue before ack.
- Conflict/baseline snapshot matrix: eight passed (`a876382`). Supported long
  bodies now persist in all three conflict snapshots, with independent bounded
  PostgreSQL enforcement. Resolution metadata retains its smaller limit.

## Active PR12 integration work

One resource worker, lease-checked atomic mirror confirmation, and trusted domain
apply/observe APIs are being implemented together. Domain APIs are committed in
`90843ae` (25 focused tests); `b696e4b` preserves repository writers' existing
permissions on imported issues/comments (93 focused tests). Relationship identity
resolution is committed in `ac2ce32` (six tests), including repository-scoped label
IDs, verified assignee links, deduplication, and ambiguous-account rejection.

The bootstrap handoff now locally seeds the shared canonical snapshot, including
labels and known-identity assignees, and the actual local `sync_version`.
The handoff and shared worker/persistence implementation are committed in
`dace021`. A combined 93-test run passed: publication (41), mirror persistence
and outbox (30), worker (17), and real integration (5). The integration tests use
real domain transactions, leases, mappings, and confirmation with stubbed HTTP;
they prove mapped inbound/outbound edits, newer-local-edit preservation, and
remote issue/comment creation. Production warnings-as-errors compilation passed.
App bootstrap now also retains bounded long issue/comment bodies across pages;
all 44 Client tests pass, including unchanged PAT and unrelated-field limits.
Live label materialization, ingress activation, and broader recovery acceptance
remain open; these results do not prove full issue convergence or PR12 completion.
- Compilation with warnings-as-errors and staged formatting checks passed for
  committed PR11. Existing importer test-support warnings
  are distinct from production compilation.
- `a5e21bc` declares git-lfs in devenv and CI test dependencies. No push occurred.

Do not infer public deployment, live GitHub validation, release publication, or
completion of the PRD from these local results.
