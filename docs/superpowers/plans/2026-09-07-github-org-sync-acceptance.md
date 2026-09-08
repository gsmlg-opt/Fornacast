# GitHub organization sync acceptance ledger

Source: `docs/fornacast-github-org-sync-prd.md`, section 13 (all 22 criteria).

This is a working evidence ledger, not a completion declaration. A test entrypoint
below identifies relevant coverage; its existence alone does not prove acceptance.
The full goal remains open. PR11 and PR12 have local implementation and focused
integration proof; PR13 is in progress. PR14–16 and the complete acceptance matrix
remain open.

## Requirement-by-requirement gates

PR13 integration audit additionally identified these concrete remaining gates:

- Bootstrap draft and cross-repository mapping exclusions were removed in
  `667af80`, with supported/read-only eligibility paths. Runtime discovery and
  two-way creation still require their separate worker and activation gates.
- New bootstrap imports now preserve the issue-list's authoritative issue ID for
  the PR's canonical issue mapping (14 mapper/importer tests passed). Legacy rows
  previously recorded the PR ID as the issue ID; those are rejected with an
  actionable revalidation error. Authenticated legacy recovery and already-bound
  mirror repair remain required; never infer issue identity from a PR ID or number.
- Read-side `SnapshotRefresh` now advances the canonical issue version and emits
  its event atomically for changed refs, with unchanged-read churn prevented.
  Confirmation retains exact expected fields and merge-state checks as well as
  the version; remaining worker and merge-coordinator paths must honor them.
- A provider pull with `head.repo: null` is still rejected by the canonical
  projection. Known but unrepresented immutable head identities are a different
  case. Add an explicit opaque read-only identity path and authenticated later
  representation; never invent provider IDs or bind by branch/repository names.

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
| 13 | Issue/comment changes converge both ways | PR12 local worker, mapping, effect recovery, label materialization, signed ingress and bootstrap activation are implemented through `f45097e`; combined activation matrix: 150 passed. Real domain/lease/HTTP-stub tests cover both directions and omitted comment deletion. Complete end-to-end acceptance and restart matrix remain open. |
| 14 | Same-repository PR metadata converges both ways | PR13 remains open. Bootstrap import is not two-way synchronization. FR-080 additionally requires cross-repository PR synchronization when both head and base repositories have active mirrors; FR-082 permits read-only metadata only when the head repository is not represented locally. Include a trusted nil-to-represented head binding transition when its mirror later becomes available; current immutable import identity alone cannot perform that transition. |
| 15 | Coordinated PR merge produces one confirmed Git result | PR13 remains open; verify effect-boundary recovery, exact expected SHAs, and both resulting endpoints. |
| 16 | Release metadata converges and stays bound to a confirmed tag | PR14–15 remain open. Existing scaffold is not proof of implementation. |
| 17 | Release assets and wiki never synchronize | Verify explicit negative fixtures across import, inbound events, outbound events, and reconciliation when release sync is implemented. |
| 18 | Duplicate/out-of-order webhooks neither duplicate nor regress | Inbox foundation tests exist. Extend resource-specific fixtures for issues/comments, PRs, and releases. |
| 19 | Every operation boundary recovers after restart | Git/LFS checkpoint, lease, marker-replacement and rate-limit recovery tests pass. Metadata create/update/delete/merge boundaries and full restart matrix remain open. |
| 20 | Full reconciliation repairs omitted deliveries | Inventory and Git/LFS reconciliation exist. Complete metadata sweeps and intentionally omitted-event acceptance in PR16. |
| 21 | Pause prevents new effects but retains work | Foundation lifecycle/scheduler tests exist. Recheck each new worker at the external-effect boundary, including a pause during long LFS work. |
| 22 | Disconnect/revocation stops token use and retains local repos | App credential/lifecycle foundation exists. Verify every new worker and in-flight recovery path in final acceptance. |

## Current local verification

- `5a78ec6` persists immutable outbound pull-create intents and implements paired
  identification/confirmation. A committed first marker alone grants creation;
  recovery and different operations cannot obtain a second grant. PostgreSQL
  constraints preserve bounded full bodies and unresolved intent reservations.
  Confirmation stores the original intent version in both mappings while newer
  local metadata survives. Review regressions reject generic evidence clearing
  and callback relationship mutations. Fresh verification passed 47 scoped tests
  (29 admission/finalization, 18 recovery/client), with all seven changed files
  format-checked. Provider POST/scan/cleanup orchestration and live ref fencing
  remain caller obligations and are not yet integrated into outbound creation.
- `7534f74` adds bounded, observation-only outbound pull-create recovery. The
  scanner retains candidate identities across pages, requires a complete scan,
  and treats zero or multiple UUID matches as ambiguous; it never grants another
  POST. Eighteen focused recovery/client tests and scoped formatting passed.
  This helper is not yet integrated into outbound worker orchestration and does
  not establish paired identity confirmation, cleanup, or creation completion.
- `3339b3a` commits the inbound pull worker path. Review caught attribution writes
  preceding immutable head/canonical issue validation; the real regression failed
  before the fix and the paired no-write preflight now runs first. Eighteen pull
  worker/integration tests passed after that correction.
- `70df2ec` imports/adopts one missing remote label per inbound-creation claim,
  retaining the same pending parent/cursor/checkpoint rather than enqueueing a
  blocked child. A real two-label test refetches paired observations on three
  claims, then commits the pull and both label memberships. Fresh combined
  PostgreSQL verification passed 111 tests (mirrors 42, provider 69), with four
  changed files format-checked. This covers new inbound creation; mapped-pull
  relationship reconciliation, label-conflict UX and outbound creation still
  require their own gates. No production worker activation or push occurred.
- `7a6c1fb` adds leased missing-pull routing, immutable head resolution and atomic
  inbound canonical issue/pull mappings. Review regressions now reject a callback
  that creates two aggregates and accept equal numeric IDs in separate provider
  namespaces. Completion uses the normal finality hook, but current eligibility
  requires active bindings; no new bootstrap activation claim follows.
- Fresh combined verification passed 180 scoped PostgreSQL tests (mirrors 88,
  pulls 25, provider 67). Worker integration covers paired inbound creation,
  deleted author attribution, substituted base identity, missing live Git refs,
  and known unrepresented read-only heads. Repository writer fences remain held
  from final live-ref checks through the mapping transaction. Nine changed files
  passed formatting. Worker changes are under final review; unknown-label
  prerequisites, outbound creation/recovery and activation remain open.
- `e4bfb7a` adds an explicit trusted nil-to-represented head transition. It checks
  the full local preimage and both repository generations, preserves content and
  merge facts, and emits one canonical version/event/audit transaction. The outer
  mirror operation must still prove provider identity and active ref eligibility;
  this domain API does not itself enable automatic head discovery.
- Fresh combined verification passed 196 scoped PostgreSQL tests (mirrors 52,
  pulls 81, provider workers/integration 63). It includes the new atomic inbound
  paired-mapping boundary, real elapsed lease expiry, callback binding replacement,
  independent local/provider numbering, and valid comment-create scan recovery
  (`e1f655f`). Eight changed source/test paths passed formatting checks.
- `bbc3e71` removes automatic repeated issue/comment POSTs after a complete
  zero-match correlation scan, including the newer-label recovery branch.
  A missing marker cannot prove a prior create failed. The operation instead
  becomes a visible ambiguous-effect conflict; positive matches still use the
  existing authenticated adoption path. Root verification passed 72 scoped
  PostgreSQL tests (worker 34, integration 16, persistence 22), including retained
  conflict scan evidence. Explicit owner resolution remains a PR16 gate.
- `792fd97` adds trusted inbound pull aggregate creation with independent shared
  local numbering, explicit head identity, relationships, and atomic event/audit
  rollback. `60c207f` adds leased merge reservations, opposing base/head overlap
  fencing, current requester authorization and post-wait database-clock checks.
  A fresh combined PostgreSQL matrix passed 164 tests (mirrors 57, pulls 94,
  provider worker/integration 13); all nine changed files passed formatting.
  These are domain/pre-push boundaries, not remote merge or discovery completion.
- Comment synchronization now verifies canonical issue/pull provider mappings
  without requiring local issue numbers to equal GitHub numbers. The regression
  failed before the fix; the fresh focused matrix passed 55 tests (mirrors 39,
  provider integration 16). Remote routes still use the mapped GitHub number.

- PR13 provider client and authorized head rendering are checkpointed locally
  in `47f1801` and `c29f656`. A fresh combined run passed provider 10 and API 25
  tests before those commits. Nothing was pushed. Transactional PR apply/observe,
  canonical projection and active-mirror/ref eligibility are the next integration
  prerequisites; the worker and coordinated merge remain open.
- Existing-PR transactional domain foundation passed 68 scoped PostgreSQL tests
  (seven new sync cases plus 61 existing pull cases). Exact issue version, all
  nine metadata fields and merge state protect apply/observe. Full Unicode body
  limits and rollback are covered. Persisted mirror/ref eligibility passed eight
  cases. These helpers do not yet prove worker integration, fresh Git availability,
  PR creation or coordinated merges.
- Local REST draft creation is now accepted as a boolean in both API versions;
  REST draft updates remain rejected. The focused creation and pinned contract
  run passed 18 tests. Local domain create/update outbox and SnapshotRefresh
  version/event producers are under regression verification; no worker enablement
  is implied by this API result.
- Local producers and snapshot refresh passed a combined 78-test PostgreSQL
  run. A separate fresh API/client/projection run passed 40 tests; projection
  (`7472732`) and draft creation API (`938b173`) are checkpointed locally.
  The projection retains distinct PR and canonical issue identities and rejects
  inconsistent paired observations. Worker integration is still pending.
- PR13 persistence RED now covers missing pull context/confirmation and rejected
  stale or revoked head eligibility at effect boundaries (five expected failures
  before implementation). Authenticated legacy identity recovery has a separate
  RED covering successful/idempotent repair and mismatched/denied evidence.
  These are unfinished implementation gates, not passing acceptance evidence.
- Initial persistence verification passed 27 PostgreSQL tests (eight pull cases
  plus 19 existing resource cases), and authenticated bootstrap recovery passed
  15 mapper/importer cases. Review follow-ups remain open: exact local marker
  preimage/version checks, correlated nil-identity initialization, and cancellation,
  expired-lease and App revocation fencing for recovery. No worker enablement or
  completed acceptance claim follows from these initial results.
- Follow-up scoped runs passed 29 persistence/resource tests and 16 bootstrap
  mapper/importer/recovery authorization tests. Persistence now checks marker
  preimages and permits correlated initial provider identity; recovery rechecks
  cancellation, leases, owner access and App binding state under locks. Review
  continues on confirmation fingerprint continuity and repository/destination
  ownership consistency. Automatic legacy recovery scheduling, already-bound
  repair and the real PR worker integration remain open.
- Publication review found that legacy `ready_to_publish` dispatch calls the
  publisher directly and its durable proof currently trusts terminal metadata
  checkpoints. The identity guard in the importer alone is therefore insufficient:
  publication must validate identities without HTTP, and the worker must route
  invalid legacy evidence through bounded authenticated metadata recovery.
  Worker unit-contract RED: all five tests fail because `PullSyncWorker` is absent;
  these injected callbacks are not PostgreSQL integration evidence.
- Persistence follow-up passed 42 scoped PostgreSQL tests (15 pull persistence,
  19 generic resource, eight eligibility). Regressions proved rejection of a
  substituted marker preimage and incorrect canonical issue projection; database
  object constraints and version monotonicity also passed. Contradictory mixed
  local/remote operation cursors remain under review before checkpointing.
- Fresh combined verification passed 103 scoped PostgreSQL tests: persistence
  45 and importer/mapper/publication 58. Persistence is checkpointed locally in
  `47540f7`, including contradictory-cursor rejection and observed mapping-version
  fencing before effects. Publication now rechecks identity in its final locked
  transaction, including recovery of already-admitted legacy publication. Automatic
  metadata recovery routing and worker integration are still being implemented;
  this checkpoint does not enable PR synchronization or complete PR13.
- The initial worker implementation is present but unverified. Review identified
  two recovery requirements now under regression testing: failed reads must retain
  unresolved effect markers, and an applied disjoint-field merge must recover even
  after a newer local edit. Bootstrap automatic identity recovery is also under
  test; the existing recovery state machine can demote invalid legacy publication
  evidence without introducing a second publication dispatch path.
- Root worker/provider verification passed 19 tests (seven worker contracts and
  12 issue-client cases). The worker retains pending markers on observation
  failure and reconstructs disjoint-merge preimages without storing large bodies
  in effect markers. One test assertion was corrected to the domain's actual
  two-field merge-state contract. Real leased PostgreSQL worker integration,
  ingress enablement and full PR synchronization acceptance remain unproven.
- Trusted head import API is checkpointed in `515c00c` (14 import + six model
  tests freshly passed); canonical PR issue transport is in `dd9ef24` (12 client
  cases in the prior 19-test root run, formatting checked). Bootstrap identity
  recovery is checkpointed in `a6ee26d`, with 58 importer/mapper/publication tests
  freshly passed. Recovery handles one identity per lease and retains durable
  progress; already-admitted publication reopening and already-bound mapping
  repair are still open. Bootstrap draft/external-head mapper wiring is next.
- FR-083 audit found mirrored same-repository PRs can still enter the ordinary
  local merge path through `ForgePulls.merge/5`. A no-local-fallback guard is a
  prerequisite only; the actual single coordinator and identical two-endpoint
  result confirmation must still be implemented and verified.
- Worker checkpoint `b5f95a5` passed a fresh ten-test run: seven contracts and
  three real leased PostgreSQL/domain/persistence integrations with stubbed
  provider HTTP. Required Git refs are still represented by fixture baselines;
  live Git availability is an explicit pending gate before worker enablement.
  Merge guard `7da8f81` passed both mirrored/no-local-fallback and ordinary local
  merge tests. It prevents independent merges but does not implement FR-083.
  Scoped formatting passed for both checkpoints. Bootstrap mapper RED reproduced
  the remaining draft/external import exclusions (13/15 passed before changes).
- Fresh-Git behavioral RED passed the three existing scenarios with real bare
  repositories, but reproduced two unsafe paths: a deleted external head ref
  still allowed confirmation, and a changed base ref still allowed an outbound
  effect. Availability checks are being implemented before enablement. Bootstrap
  represented-head RED separately reproduced external-head binding to the base
  repository and missing represented-head proof handling (six of eight passed).
- Merge design retains a single deterministic local commit and exact expected-base
  push, followed by fresh provider and local confirmation of the same result.
  GitHub's [REST merge API](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
  documents a head-SHA condition, not an expected-base condition. Direct pushes
  can produce [indirect merges](https://docs.github.com/en/pull-requests/reference/pull-request-merges#indirect-merges),
  but push success is not proof of exact PR merge state. Durable intent preparation
  must precede object writing and exclude coordinator-owned operations from the
  ordinary local merge reconciler. Implementation and two-endpoint proof are open.
- Live availability checkpoint `3c2a069` passed 13 scoped tests (eight worker
  contracts and five integrations with real bare Git refs/objects). Checks use
  proof-selected repository generations, bounded exact refs and commit existence,
  including post-effect rechecks. Retry diagnostics retain a Git-specific reason
  without discarding unresolved markers. Worker activation is still disabled.
- Root handoff audit found another activation gate: `organization_sync/handoff.ex`
  still seeds the legacy pull snapshot and does not initialize the worker's
  canonical issue version, PR node identity or separate merge state. Actual
  bootstrap-to-worker compatibility must be implemented and tested; manually
  seeded integration mappings are not proof that this production path works.
- Bootstrap checkpoint `667af80` passed fresh root verification: 16 mapper/importer
  tests alongside 13 worker tests (29 total), with scoped formatting clean. Draft
  flags, external read-only heads, represented-head live/ref proof and atomic
  warning resolution are implemented. Handoff compatibility is still open.
- The handoff fix will retain bounded authenticated numeric/node identities,
  original canonical snapshot fingerprint/version and merge state on the import
  mapping, without duplicating large bodies or expanding report metadata limits.
  Handoff must match this evidence to both mappings and the local projection;
  missing legacy evidence requires authenticated recovery, never rebaselining.
- Durable merge-intent tests reproduced the missing API, then exposed an SQL
  NULL constraint gap. The implementation is under scoped regression verification;
  an additive constraint correction preserves the retained database. This remains
  intent preparation only, not Git object writing or two-endpoint merge completion.
- Durable intent checkpoint `7d20c62` passed a fresh root run of 91 scoped
  PostgreSQL tests and formatting. Fixed message/signatures and resource preimage
  are replay-validated; ordinary recovery cannot process coordinator-owned rows,
  and unfinished intents still block cleanup. Deterministic object writing and
  all provider/public-ref/merged-state effects remain to be implemented.
- FR-081 audit found the existing comment domain accepts PR parents but mirror
  routing rejects them or confuses the canonical issue and pull mappings. Pulls-only
  comment sweeps and bootstrap completion gates are also missing. The implementation
  must use canonical issue identity, verify its PR companion, and derive actual
  parent kind under locks before checking the appropriate capability.
- FR-082 UI checkpoint `422161a` adds the external-head read-only notice using
  the existing DuskMoon alert and avoids claiming merge conflicts when analysis
  cannot resolve a non-local head. All 33 scoped pull HTML/controller tests and
  scoped formatting passed. This does not establish the remaining head-binding
  transition, provider integration, or full browser acceptance gates.
- Merge writer RED reproduced missing APIs in nine domain tests and two native
  tests (28 existing native tests passed). Native tree-only and fixed-tree commit
  primitives now compile, but writer verification remains open. Review requires
  recursive merge-base coverage and recovery between tree publication, pinning,
  and the durable tree checkpoint; fixed signatures alone do not ensure replay
  uses the same merge tree after repository configuration changes.
  The expanded RED matrix reproduced one virtual commit published by a
  crisscross merge during the tree-only phase (30/31 native tests passed), plus
  two missing tree crash checkpoints (10/12 writer tests passed). The correction
  filters tree-phase publication to trees/blobs and commits the tree ID before
  pinning. The subsequent focused matrix passed all 43 tests (31 native, 12
  writer), including cleanup blocking at the durable tree checkpoint. Fresh
  root regression then passed 134 tests (103 pull domain/recovery, 31 native);
  scoped Elixir and Rust formatting passed. This writer checkpoint is committed
  locally in `ff98558`. A separate scoped Rust merge unit run passed 13 tests,
  including hard limits, deadline cancellation and exact worker-capacity release.
  Remote coordinator execution remains open.
- Pull bootstrap evidence mapper tests pass (nine); integration reached the new
  paired identity and handoff assertions but its final comment claim was blocked
  by repository FIFO ordering. The pipeline is not yet verified. Handoff retains
  both canonical issue and pull mirror identities; ordinary issue synchronization
  must exclude the PR companion while comments verify both identities.
- The comment-routing matrix passed 86 scoped tests (41 mirror, 45 GitHub),
  including capability-specific token permissions, mixed issue/PR comment pages,
  canonical companion exclusion, and pending-parent FIFO progression. Review
  then identified an early-context failure path that could discard an existing
  effect marker. Two unit regressions reproduced marker loss on context/token
  failures, and two database regressions reproduced the missing recovery-only
  deferral API. Recovery GET permission failures also cannot prove an old write
  was rejected. The preservation fix subsequently passed 92 scoped tests
  (43 mirror, 49 GitHub), including real worker-to-database evidence retention;
  root independently reran all 92 successfully and checked scoped formatting.
  The checkpoint is committed locally in `5a7ec30`; actual bootstrap handoff
  integration remains a separate, still-open proof.
- Bootstrap review also found authenticated PR companion labels/assignees were
  not imported/proved before confirming their issue snapshot. The pending fix
  must import those authenticated relationships and verify a compact canonical
  issue fingerprint; current local relationship values alone are not evidence.
- Paired App bootstrap PR/issue GETs now retain the existing bounded body
  allowance while keeping PAT and unrelated JSON-field limits unchanged.
  `f41f6d0` passed all 48 Client tests, including 65,536 four-byte codepoints
  and rejection above 262,144 body bytes. Importer domain validation and the
  complete authenticated baseline pipeline remain separate gates.
- The evidence slice passed 11 focused tests, including real PAT import,
  evidence replay, contradictory-node recovery, handoff and leased comment
  context. Root's broader four-file run passed 57/62: five existing metadata
  importer cases now receive provider 404 before their identity/head assertions.
  Their authenticated companion fixtures and behavior need verification before
  committing the slice. Genuine App-bootstrap long-body proof is still open;
  a PAT fixture cannot establish that gate or bypass the intentional PAT limit.
  These five fixtures were corrected without weakening their identity/head
  assertions. A separate real App credential-provider/broker test now verifies
  the full multibyte body through metadata staging and publication. Root reran
  all 63 scoped import/publication tests successfully and checked formatting;
  the evidence/handoff checkpoint is committed in `935ded0`. This does not prove
  live GitHub inventory/bootstrap or background pull synchronization.
- Runtime activation audit confirms PullSyncWorker is not supervised and its
  current init ignores `enabled: false`. Local outbox already enqueues sync.pull;
  unmapped pulls are rejected and can block repository FIFO. Signed pull webhook
  admission, pull reconciliation sweeps, discovery/create, changing ref/SHA
  handling and merge routing are still missing. Lifecycle gating alone must not
  be called runtime synchronization completion or silently drop unmapped work.
  Lifecycle gating is now committed as `a6324f6`: root reran 16 lifecycle,
  mapped-worker and integration tests and checked formatting. Production worker
  registration remains intentionally absent until creation/recovery is handled.

- On 2026-09-08 the user approved leaving the dormant Turso migration test
  unchanged and resuming PostgreSQL-only verification. The scoped domain run
  passed 148 tests after fixture isolation and query-budget repairs. The first
  combined API/provider run passed 33 of 34 tests: head redaction, nullable
  contracts and provider cases passed, while the issue-composition route still
  made two pull queries against its budget of one. The follow-up repaired that
  regression without increasing the budget, preserved repository-level issue
  creation, and rejected foreign-head commit/diff ref resolution in the base
  repository. Final combined PostgreSQL run: **184 passed** (issues 88,
  pulls 61, API/contracts 25, provider 10). The existing background
  MergeReconciler SQL sandbox ownership error was still logged without a failed
  test and is not claimed fixed. This is not PR13 completion.

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
Label domain/versioning (`02fb593`) and atomic leased identity mapping (`b56b616`)
are committed. Exact domain tests: nine passed; mirror mapping/resolver tests:
34 passed. Worker label materialization and authenticated comment-deletion proof
are committed in `5ff311b`: 23 worker tests and nine real integration tests pass,
with production warnings-as-errors and scoped formatting checks passing.
The real tests cover outbound label creation before issue assignment, inbound
unknown-label materialization before issue creation, and denied/mismatched
repository access preserving comments when GitHub returns 404.

`b8256b9` verifies effect recovery before concurrent new-label materialization.
`d08c70c` provides bounded mapped-resource inventory. `d1dce73` schedules partial
bootstrap reconciliation and replays bound metadata; `f45097e` enables signed
issue/comment ingress, schedules metadata sweeps from handoff/inventory, and gates
activation on current successful Git and metadata completion without conflicts.
Sweeps traverse remote listings then mapped identities, including omitted comment
deletions. A real integration test proves empty remote listing -> mapped scan ->
access-checked GET/404 -> local tombstone without a webhook.

The combined activation matrix passed 150 tests (mirrors 61, worker/integration
39, publication 41, API ingress nine), plus production warnings-as-errors.
Pause/revoke finalizer races, superseded finalizer proof, and organization health
restoration are covered. Full PRD acceptance, live GitHub validation, and the
remaining PR13–16 work are not established by this local matrix.
- Compilation with warnings-as-errors and staged formatting checks passed for
  committed PR11. Existing importer test-support warnings
  are distinct from production compilation.
- `a5e21bc` declares git-lfs in devenv and CI test dependencies. No push occurred.

Do not infer public deployment, live GitHub validation, release publication, or
completion of the PRD from these local results.
