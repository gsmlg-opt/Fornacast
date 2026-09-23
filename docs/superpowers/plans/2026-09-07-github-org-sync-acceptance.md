# GitHub organization sync acceptance ledger

Source: `docs/fornacast-github-org-sync-prd.md`, section 13 (all 22 criteria).

This is a working evidence ledger, not a completion declaration. A test entrypoint
below identifies relevant coverage; its existence alone does not prove acceptance.
The full goal remains open. PR11 through PR16 have local implementation and
focused integration proof. The remaining gate is the external, two-endpoint
acceptance matrix, including a synchronized clone/checkout from GitHub.

## Requirement-by-requirement gates

### Security and lifecycle follow-up (2026-09-23)

- Historical `installation.created` deliveries no longer complete a setup
  callback. They remain buffered provenance only; completion still requires the
  live webhook path and reloaded local authorization.
- Installation completion now reloads the actor and checks current
  organization-management authority while the intent and mirror are locked.
  Permission loss therefore leaves the intent unclaimed and performs no
  bootstrap scheduling.
- Local disconnect now invalidates installation-token cache state without
  terminally adding the installation to the broker's provider-revoked set.
  Provider deletion continues to use durable revocation and terminal broker
  fencing. Focused acceptance and broker suites passed locally; live GitHub
  installation and reconnect acceptance remain unverified.

### PR16 reconciliation and operator foundations (2026-09-14)

- Commit `ed6b551` makes `last_reconciled_at` a proof of the complete durable
  organization sweep rather than an inventory-listing timestamp. The final
  inventory page atomically tags every admitted Git/LFS, repository-metadata,
  issue/comment, pull-head, and release branch with one immutable sweep marker
  and queues an organization-scoped finalizer. Dynamically created Git-ref,
  resource, release-tag, continuation, and superseding Git operations retain the
  same marker, so the finalizer cannot borrow an unrelated later reconciliation.
- The finalizer uses bounded first-failure and incomplete-existence probes. It
  advances the watermark only after every marker-bearing operation completes;
  pending/effect-pending work yields its lease, a terminal child fails the sweep,
  and pause or revocation retains the pending finalizer without moving the
  watermark. Organization FIFO serializes sweep generations, while expired-lease
  recovery rejects the stale owner and reclaims the same operation. A webhook
  health regression proves a failed-delivery gap remains visible until this full
  finalizer succeeds.
- Repository-metadata pause fencing now covers both sides of effect preparation.
  A pause immediately after claim returns unmarked processing work to `pending`
  without fetching a token. A pause after durable preparation retains the exact
  `effect_pending` marker and stops before Administration-write token checkout or
  PATCH; resume re-enters canonical GET-first recovery. Both paths retain clean
  failure diagnostics and use the existing binding-then-organization lock order.
- A PostgreSQL integration path now intentionally omits the repository webhook:
  the owner schedules a real organization reconciliation, the leased inventory
  worker observes the unchanged repository identity, and the leased metadata
  worker discovers and applies a later GitHub description without an outbound
  Administration token or PATCH. No inbox row exists before or after repair, and
  the real organization finalizer keeps `last_reconciled_at` behind the Git and
  metadata children before advancing it to the inventory observation time.
- The same owner-scheduled inventory boundary now has real-worker omitted-event
  proof for collaboration metadata. The issue/comment integration runs the
  checkpointed remote and mapped sweeps plus every generated `sync.issue` and
  `sync.issue_comment` child, imports a previously unknown GitHub label, applies
  a GitHub-only title update, tombstones a comment deleted without a webhook,
  and advances the marker finalizer only after the bounded worker drain. The
  pull integration runs both remote/mapped pull-head phases and their two
  canonical children, applies a GitHub-only title update, and likewise proves
  zero inbox deliveries and a held-then-completed organization watermark.
- The final focused gate passed **12 ForgeMirrors lifecycle tests** and **100
  ForgeGitHub worker tests**, with exact changed-file formatting, diff checks,
  and production warnings-as-errors compilation. A broader nine-file
  ForgeMirrors matrix passed **122 of 123** tests; the sole failure was the
  already-documented operation-scheduler aggregate assertion observing committed
  stale rows in the shared test database. Two final reviews reported no remaining
  P0/P1/P2 finding.
- Commits `940e8af`, `fae7690`, and `008fb7e` extend that same owner-scheduled
  inventory boundary through the remaining Git/LFS and release workers. A release
  deleted on GitHub without a webhook is discovered by the remote and mapped
  release sweeps, canonically re-read as absent, soft-deleted locally, confirmed
  in its durable mapping, and allowed to advance the organization watermark only
  after all marker-bearing work completes. Persisted JSON release timestamps are
  normalized back to UTC-second `DateTime` values before three-way comparison, so
  an equivalent local release does not become a false concurrent edit.
- The Git/LFS path creates a branch and LFS pointer only in a separate controlled
  bare remote, proves the commit is initially absent from the local object store,
  fetches it into the private tracking namespace, and then runs the real
  `LFSSync` pointer scanner and `TransferCoordinator`. Only the GitHub Batch and
  object-download transport responses are controlled. The public ref remains
  absent across a durable `effect_pending` scan checkpoint, LFS bytes are staged,
  verified, and attached before ref confirmation, and the real LFS reachability
  finalizer persists another bounded checkpoint while the organization finalizer
  remains waiting. The ref, LFS reachability, sweep operations, and watermark all
  converge with zero webhook inbox rows.
- The combined gate passed **30 ForgeGitHub tests**. The complete **28-test** Git
  persistence file encountered only the already-documented shared numeric fixture
  collisions; both affected selectors passed together in isolation. Exact changed-
  file formatting, diff checks, warnings-as-errors compilation, and two independent
  P0/P1/P2 reviews passed. Commit `33d8c95` completes the local omitted-event
  resource matrix by adding an unknown GitHub assignee to the real inventory
  issue path and proving the observed immutable identity, provider-owned join,
  and confirmed assignee-ID baseline. Its focused integration test and independent
  P0/P1/P2 review pass. Criterion 20 is locally accepted for repository metadata,
  Git/LFS, issues, labels, assignees, comments, pull requests, and releases.
  Criterion 11 still requires real clone/checkout proof from both endpoints.
- Commits `0a1d78b`, `f33d5d3`, and `da72c12` complete the local pause and
  revocation matrix across inventory, repository creation/metadata, Git/LFS,
  issues/comments, pull synchronization/creation/merge, releases, and the
  organization finalizer. Inventory and Git reconciliation roots now return
  typed lifecycle failures before token or provider access; paused work releases
  its lease without losing its cursor/marker, while revocation and missing
  capability stop terminally. Real PostgreSQL scope tests cover organization
  pause/revocation, installation suspension, disabled Git, finalizer watermark
  retention, and later resume.
- Pull-merge LFS publication now persists the exact merge marker before requesting
  a write token or transferring an object. Recovery reclaims the marker and saved
  LFS cursor, every transfer step receives exact-marker authorization, and a fresh
  fence runs after LFS before provider re-observation and again around the Git CAS
  credential. Installation revocation at either token boundary or as LFS returns
  stops further reads, transfer, and push while retaining the durable marker.
  Installation deletion is also exercised through the real webhook processor:
  authorization is revoked before token invalidation, queued effects cannot be
  claimed, and the local bare repository, public ref, LFS object, and repository
  row remain intact.
- The final lifecycle gate passed **99 ForgeGitHub inventory/Git/issue/release/
  webhook tests**, **84 of 86 pull-merge tests**, and **47 of 49 ForgeMirrors
  inventory/Git persistence tests**. Each pair of failures was the documented
  shared numeric-fixture collision and every affected selector passed directly
  with the new lifecycle/LFS selectors. Warnings-as-errors compilation, exact
  changed-file formatting, diff checks, and two final P0/P1/P2 cross-reviews
  passed. Criteria 21 and 22 are locally accepted; live GitHub disconnect proof
  remains part of final external acceptance.
- Commit `68fbacd` completes the local duplicate/out-of-order matrix. Distinct
  issue, comment, pull-request, and release delivery GUIDs retain only immutable
  routing identities, and every resource worker re-reads the same canonical
  provider state. The first operation applies one domain version/event; the
  older operation confirms the same mapping without another mutation or
  provider-origin outbox event. The release path uses the real metadata client,
  durable tag-proof split, Git-ref confirmation, and release continuation for
  both deliveries rather than stopping at webhook scheduling.
- Commit `b2156f9` closes the remaining restart evidence for release deletion. A
  real persisted `sync.release` operation moves to `effect_pending`, releases
  its lease while retaining the exact delete marker, and is reclaimed by a new
  owner with the same marker and mark time. The restarted worker then confirms
  immutable-ID absence and completes without a second DELETE. Together with the
  existing inventory, Git/LFS, repository create/metadata, issue/comment,
  pull-create/sync/merge, release create/update, checkpoint, lease-expiry, and
  marker-replacement cases, this completes the local operation-boundary restart
  matrix.
- The final event/restart gate passed **21 ForgeMirrors tests** and **113 of 115
  ForgeGitHub tests**. The two failures were the documented shared numeric
  fixture collisions; all **8 changed acceptance selectors** passed together.
  Exact formatting, diff checks, warnings-as-errors compilation, and two
  independent P0/P1/P2 reviews passed. Criteria 18 and 19 are locally accepted;
  live two-endpoint acceptance remains external.

- Organization owners and active site administrators now have three bounded,
  durable repository-metadata conflict actions: accept the exact canonical
  GitHub snapshot, keep the exact Fornacast snapshot and push it, or recheck
  after an external resolution. Accept GitHub is not offered for archived or
  `internal` observations that Fornacast cannot represent. An explicit keep
  action may intentionally PATCH such a GitHub repository back to an
  unarchived public/private state; automatic reconciliation still never coerces
  or PATCHes an unrepresentable observation.
- Every request is tied to the open conflict version and exact baseline/local/
  remote fingerprints. The conflict remains open while work is queued or an
  outbound effect is ambiguous and closes only after canonical confirmation.
  Git-ref conflicts remain read-only in this UI and still require an explicit
  Git action. Duplicate exact submissions replay one operation, while competing
  or stale capabilities fail closed.
- Authorization is reloaded at request time, before local application or effect
  preparation, and again at the prepared-to-attempted boundary immediately
  before the worker obtains Administration-write credentials or PATCHes GitHub.
  Revocation at that boundary creates a visible permission conflict and performs
  no write-token checkout or PATCH. Once an attempt begins, the durable marker
  permits GET-first ambiguous-effect recovery without issuing a second intent;
  pre-marker-format effects are conservatively treated as already attempted.
- Resolution requests and workers share the repository-binding, organization,
  conflict lock order. A PostgreSQL barrier regression holds the binding, waits
  until the request backend is blocked, and proves the conflict remains
  `FOR UPDATE NOWAIT`-acquirable before releasing the worker. Requested,
  completed, and terminally failed audit events are distinct and transactionally
  aligned with their durable outcomes.
- The final action matrix passed **28 ForgeMirrors**, **18 ForgeGitHub**, **5
  ForgeImports**, and **35 FornacastWeb** tests. It includes the three actions,
  exact evidence drift, replay/competition, authorization revocation before
  recording and after effect preparation, provider failure, timeout-after-
  committed-PATCH restart recovery, worker enablement, strict parameter/CSRF
  handling, authorization masking, action visibility, Git read-only behavior,
  deterministic lock ordering, and legacy effect-marker recovery. Two focused
  final reviews reported no remaining P0/P1/P2 finding.

- The first-release repository-metadata representation policy is now explicit.
  Fornacast repositories have no local archived state or `internal` visibility,
  so identity-validated GitHub observations of those values create distinct,
  terminal `repository_*_unrepresentable` conflicts rather than coercing
  visibility, tombstoning local data, or issuing a metadata PATCH. The canonical
  provider path and `github_archived` observation still advance atomically so a
  simultaneous rename cannot strand later reconciliation.
- When GitHub returns to a representable public/private, unarchived state, a
  successful full metadata confirmation transactionally closes only the matching
  representation-policy conflict with a system-attributed resolution. A real
  leased worker integration proves rename-plus-archive observation, no
  Administration token or PATCH, recovery through the persisted renamed path,
  safe inbound convergence, and conflict closure. Focused verification passed
  **5 ForgeRepos**, **29 ForgeMirrors**, and **24 ForgeGitHub** tests. This is an
  explicit safe representation boundary, not a claim that Fornacast now exposes
  a local archived or internal repository mode.

- Policy-enabled local organization repository creation now materializes one
  durable `sync.repository.create` operation behind a shared typed auto-create
  and Git-capability gate. The worker requires installation-scoped Metadata read
  and Administration write access, performs an exact-name GET before POST, and
  marks expected absence plus the complete local target before the external
  effect. It reauthorizes the owned marker, organization lifecycle, policy,
  capability, installation, permission, immutable account, and local repository
  immediately before every POST.
- The GitHub client permits only `POST /orgs/:organization/repos`, the exact
  name/optional description/public-or-private visibility payload, and HTTP 201.
  Canonical owner ID/login, repository ID/node, name, and full name must agree
  before binding. Timeouts keep the effect marker for GET-first recovery; a 422
  performs one canonical GET and confirms a delayed self-create before treating
  a mismatching repository as a visible namespace conflict. Conflicts are scoped
  per local repository binding and cannot overwrite another contender's
  evidence.
- Pause releases the lease while retaining queued work and any ambiguous marker.
  Revocation, missing permission, and policy/capability downgrade stop before
  POST and checkpoint ambiguous recovery evidence without deleting the local
  repository. Confirmation atomically binds immutable GitHub identity and the
  repository metadata baseline, then orders Git reconciliation, Git finalization,
  and the exact post-Git metadata sweep. The binding stays `discovered` until
  that keyed metadata operation confirms, including when GitHub initially uses
  `main` while the local default branch is different.
- Final focused verification passed **70 ForgeMirrors** and **32 ForgeGitHub**
  tests. This includes materialization races, policy/capability rejection,
  pause/revocation races before POST, 403 classification, 422 self-create and
  collision recovery, timeout/restart recovery, immutable binding/baseline
  confirmation, per-binding conflicts, newer-local ordering, and default-branch
  Git-then-metadata activation. Exact scoped formatting, diff checks, and
  production warnings-as-errors compilation passed. Two independent final
  reviews reported no remaining P0/P1/P2 finding.
- Acceptance criterion 6 is locally accepted. Live GitHub proof remains part of
  final acceptance. The archived/internal representation policy and safe
  metadata operator actions are now covered; PR16 still needs the remaining
  full reconciliation, lifecycle, recovery, and two-endpoint acceptance
  matrices.

- The repository-metadata foundation now performs per-field baseline/local/GitHub
  decisions for representable fields. Remote-only changes use a trusted
  ForgeRepos exact-preimage/owner/generation/write-version boundary; compatible
  changes to different fields merge; local-only changes persist an immutable
  outbound marker before an installation-gated PATCH. Canonical responses
  confirm the baseline, and ambiguous timeouts retain the marker for a read
  before any retry. Rename recovery probes the marked target and prior path but
  accepts only the bound immutable GitHub ID/node. Namespace collisions and
  incompatible edits remain explicit conflicts. GitHub-origin repository
  updates emit an atomic provider-neutral outbox event that the mirror ignores,
  preventing echo.
- Focused verification for this convergence slice passed **5 ForgeRepos**, **23
  ForgeMirrors**, and **17 ForgeGitHub** tests, plus the new direct transactional
  DomainOutbox regression. The tests include remote/local/compatible concurrent
  edits, rename collision, timeout after remote commit, timeout after rename,
  uncommitted rename fallback, and a newer local edit ordered behind an older
  durable effect. The full DomainOutbox test file also encountered a pre-existing
  committed stale test event in the shared test database; its changed regression
  passed in isolation and the unrelated fixture-state failure was not modified.
- This convergence slice still does not represent local archived state or GitHub
  `internal` visibility, so those inputs remain unsupported rather than being
  overwritten. Safe operator conflict actions also remain open, and PR16 remains
  incomplete.

- Commit `acd3a6e` changes pull reconciliation from an unsupported-head-only
  mapped scan into a checkpointed canonical GitHub pull inventory followed by a
  pinned mapped-resource pass. Remote pulls omitted from webhooks now enqueue
  ordinary `sync.pull` work, while confirmed, provider-bound pending, and
  unsupported mappings are revisited. Mapped-only pages acquire no installation
  token; duplicate provider IDs/numbers are rejected before durable fan-out.
- The same commit adds a supervised, leased repository-metadata observation
  worker. Completed installation inventory schedules idempotent
  `reconcile.repository.metadata` work; exact immutable repository identity and
  bounded canonical fields are fetched with an installation token. Matching
  observations establish a shared canonical fingerprint/baseline. Differences
  retain or refresh one open `repository_metadata_diverged` conflict without
  overwriting local state or leaving the operation in a reclaim loop.
- Organization owners can now filter open conflicts by repository, resource,
  and resource type and compare database-truncated baseline/Fornacast/GitHub
  snapshots. Git ref conflicts explicitly require an operator Git action and
  reconciliation; no automatic Git resolution was introduced. Filter IDs are
  organization-scoped and PostgreSQL-bigint bounded.
- Settings expose bounded webhook inbox counts, oldest unprocessed receipt, and
  unreconciled failed-delivery count. A reconciliation later than the failed
  receipt clears the visible gap without deleting historical delivery evidence.
- Combined focused verification passed **51 ForgeMirrors**, **25 ForgeGitHub**,
  **5 ForgeImports**, and **32 FornacastWeb** tests. The changed webhook-health
  regression passed in isolation, exact scoped formatting and diff checks
  passed, and production compilation passed with warnings as errors. Running the
  entire webhook inbox file in the combined mirror matrix still reproduces the
  previously documented unrelated installation-identity fixture collision; it
  was not modified or suppressed.
- This is a foundation checkpoint, not PR16 or PRD completion. Repository
  metadata still needs a trusted exact-preimage ForgeRepos apply boundary,
  outbound marker/PATCH/recovery, local repository creation on GitHub, rename
  collision handling, and explicit archived/internal-visibility policy. Safe
  metadata conflict actions, the full deterministic fault matrix, integrated
  omitted-webhook convergence, pause/resume, disconnect/revocation, and live
  GitHub evidence also remain open.

### PR15 release synchronization foundations (2026-09-14)

- Commit `c3996de` adds monotonic release sync versions, atomic local and
  provider-origin outbox events, exact projection/apply boundaries, GitHub
  authorship, soft-delete tombstones and minimum-version lost-effect recovery.
  Local/import/provider paths share the 65,536-codepoint and 262,144-byte body
  profile. Provider create/update requests require an exact coordinator-supplied
  two-sided tag proof; provider-owned publication timestamps must be canonical
  UTC seconds. The final focused domain gate passed **23 tests**.
- Commit `74d5b6c` adds the installation-gated GitHub release client and canonical
  projection. Exact routes/statuses, confined pagination, repository/object/tag
  identity, unique-tag recovery lookup, provider publication semantics and
  credential-echo rejection are covered. Assets and content URLs are stripped;
  only a bounded asset count survives for warning/reporting. The final focused
  client/projection gate passed **18 tests**.
- A combined **41-test** PostgreSQL gate and production warnings-as-errors
  compilation passed. Independent reviews initially found body-profile drift,
  absent tag/recovery contracts, noncanonical timestamps, reserved tag drift,
  wrong-tag create confirmation and credential-echo retention; all were repaired
  and both final re-reviews passed.
- Commit `5fb30ff` establishes the trusted importing lifecycle boundary used by
  GitHub App bootstrap without permitting long-lived one-time credentials or
  emitting synchronization work before publication.
- Commit `f9e04df` adds durable release mappings, local outbox materialization,
  checkpointed remote and mapped reconciliation, fresh two-sided tag-proof
  scheduling, atomic domain/mapping confirmation, provider-effect markers,
  pause/revocation fences and activation of eligible historical release
  deliveries. Effect recovery records the provider-applied baseline while
  preserving a newer local projection.
- Commit `328e912` adds the bounded release synchronization worker, immutable-ID
  canonical reads, unique-tag-only create recovery, provider CRUD effects,
  marker replacement before superseding writes, webhook routing and terminal
  failure classification. Valid 255-codepoint release tags are accepted at
  ingress while remaining bounded to 1,020 bytes.
- Commit `17bbdfb` imports releases after pulls and before number-sequence
  settlement, with page checkpoints, lease/cancellation fences, author mapping,
  tag-presence enforcement, bounded asset/unsupported-field reports, capability
  gating and atomic handoff of buffered release deliveries. Installation-backed
  settings default Releases on only when the required permission contract is
  available; persisted string states render correctly.
- Final PR15 gates passed **105 ForgeImports**, **43 ForgeMirrors**, **63
  ForgeGitHub**, and **7 FornacastWeb** tests, plus production
  warnings-as-errors compilation and exact scoped formatting. Two independent
  final re-reviews reported no remaining finding after repairs for lease renewal,
  immutable node preconditions, marker supersession, Unicode tags, failure
  classification and legacy delivery activation.
- Broad app runs also exposed only unrelated pre-existing gates outside PR15:
  three ForgeMirrors rollback tests reject reversing the prepared/authoritative
  LFS scan distinction, one ForgeGitHub deadline test returned
  `request_gate_busy` instead of timeout, and one webhook-inbox fixture collided
  with an existing installation identity. Per the PRD scope rule these were not
  modified or suppressed.
- PR15 and criterion 16 are locally accepted. Live GitHub proof and the PR16
  omitted-webhook/full-reconciliation acceptance matrix remain final gates.

### PR13 webhook activation and bootstrap replay repair (2026-09-14)

- Supported pull-request webhook actions now enter the processable inbox path;
  release actions remain explicitly deferred until PR15 is complete.
- Bootstrap handoff and terminal activation match deliveries by the authoritative
  installation and GitHub repository identities, accept only an unbound or
  already-matching organization association, and atomically bind the local
  organization while promoting durable work.
- An idempotent claim-time migration activates historical supported pull
  deliveries only for live, included, bound repositories whose pull capability
  is enabled. Paused and revoked mirrors and release deliveries remain fenced.
- Paused mirrors retain pending resource operations, while operation claiming
  and all effects remain disabled until resume. Focused regression verification
  passed **96 tests**: ForgeMirrors **19**, ForgeGitHub **18**, ForgeImports
  **49**, and FornacastAPI **10**. An independent re-review reported no remaining
  finding after it caught and the implementation repaired a paused
  issue/comment retention regression.
- This restores the real ingress-to-worker path for PR13 local acceptance.
  Live GitHub delivery proof and the complete 22-item acceptance matrix remain
  final gates.

### PR14 release metadata domain and local surfaces (2026-09-14)

- `forge_releases` now owns repository-scoped release metadata with all FR-091
  fields, exact local tag validation under the repository write fence,
  transactional authorization revalidation, atomic audit records, coherent
  draft/publication state, exclusive local/GitHub authorship, soft deletion and
  active repository/tag uniqueness. The focused domain suite passed **12**
  tests and an independent domain review reported no finding.
- The repository web UI provides discoverable DuskMoon-only release list,
  detail, create, edit and delete flows plus the canonical encoded tag route.
  Private masking, CSRF, private/no-store responses, retained validation values,
  sanitized Markdown, PATCH updates and absence of asset UI are covered. The
  focused web/navigation suite passed **52** tests and final review reported no
  finding.
- Both supported REST versions expose GitHub-compatible release metadata
  list/show/by-tag/latest/create/update/delete operations. Repository write
  authority and update target existence are established before request-body
  parsing; pagination and encoded-slash tags are covered. Pinned OpenAPI slice 5
  contains exactly those seven operations, no asset path, and declares release
  assets unsupported. The final API/OpenAPI suite passed **29** tests after an
  independent review caught and repaired the stale slice-4 pull contract.
- PR14 and FR-090 through FR-093 are locally accepted as the local foundation.
  This does not satisfy acceptance criterion 16: PR15 must still prove two-way
  release convergence against a fresh confirmed tag, retarget conflicts,
  ignored assets and durable provider-effect recovery.

### PR13 connected merge acceptance and admission recovery (2026-09-14)

- One API integration now drives a represented pull whose base and head are
  distinct active mirrors with disjoint local object databases. It enters
  through the real authenticated `PUT /merge`, starts the production-named
  merge worker, materializes the exact head closure, and performs an exact
  `B -> M` CAS through `GitCore.Remote` into a filesystem-backed provider base
  repository while the provider head remains `H`.
- The provider applies that CAS but the transport reports a timeout. The test
  waits for the durable effect-pending operation, stops the worker, starts a new
  worker owner, and proves recovery observes the provider through the real
  GitHub ref/pull/issue clients, does not push again, and atomically confirms
  the local base, pull, issue, paired mappings, ref baseline, domain intent and
  scheduler operation at the same `M`. Both local and provider pull endpoints
  are read after completion; the merge commit has exactly parents `B,H`, both
  head refs remain `H`, and strict Git fsck passes.
- This connected path exposed an admission/recovery mismatch: atomic admission
  persists a canonical request fingerprint in its preparation checkpoint, but
  marked recovery previously reconstructed a fingerprint-free proof and failed
  after the external effect. Recovery now retains the fingerprint in its
  write-once marker, validates the current checkpoint against that evidence,
  and rejects a different same-length fingerprint.
- Fresh focused verification passed **127 tests**: mirror merge boundary **42**,
  merge worker **81**, and API merge integration **4**. Scoped formatting and
  diff checks passed. An independent architecture review reported no remaining
  PR13 finding after the fingerprint binding repair.
- PR13 and FR-080 through FR-083 are locally accepted. Live GitHub App write
  validation remains unproven external delivery evidence and is still required
  before full production/PRD acceptance. PR14-PR16 and the full 22-item PRD
  acceptance boundary remain open.

### PR13 represented cross-repository merge materialization (2026-09-14)

- A coordinated merge whose active head mirror is a distinct repository now
  holds the base writer fence and head cleanup/read fence under one absolute
  deadline. Every materialization, tree and commit transaction rechecks the
  coordinator capability, immutable pull observation, repository generations,
  owner relationship and locked intent before object work.
- `GitCore.materialize_merge_head/4` copies only missing content-addressed
  objects without consulting refs or repository merge configuration. It
  checksum-validates the exact source head and every visited destination or
  source body, validates repeated edges against their required object kind,
  repairs partial destination closures, and collects the complete bounded write
  set before publishing children first and the requested head commit last.
- Header kind and size are checked before body decoding. A hard 64 MiB
  per-allocation ceiling and gitoxide allocation override protect loose and
  packed objects; missing bodies additionally share the existing aggregate
  64 MiB transfer budget and 8 MiB blob ceiling. Commit/tree traversal and the
  one-slot native write pool bound CPU, retained memory and concurrent
  publication. A timed-out native worker is joined before repository leases are
  released.
- Crash/replay integration proves that a failure after head materialization may
  leave only unreachable content-addressed objects: no ref, config, tree
  checkpoint, public merge result or pull state changes. The same durable intent
  then replays to the exact `B,H` merge. Missing `H` and head-generation
  replacement fail closed.
- Represented cross-repository admission now uses the same active mirror,
  provider identity and exact-ref eligibility proof as metadata synchronization;
  unrepresented heads remain read-only as required by FR-082. SHA-1 and SHA-256
  materialization, disjoint object stores, partial closures, corrupt destination
  bodies, conflicting repeated edges and oversized source/destination headers
  have focused regression coverage.
- Fresh verification passed **179 scoped Elixir tests**: GitCore **43**,
  coordinated ForgePulls **43**, and GitHub admission/worker **93**. The native
  crate passed all **85 Rust tests**; the materializer-specific suite passed
  **12**. Production warnings-as-errors compilation, Rust/Elixir formatting and
  diff checks passed. Two independent security/cross-repository reviews reported
  no remaining blocker after the allocation, closure and concurrency repairs.
- This closes bounded cross-repository object materialization and writer
  admission, not all of FR-083 or PR13. The merge worker still needs one genuine
  two-repository, two-endpoint effect/confirmation integration proving the exact
  merge commit and PR state converge on both sides. PR14-PR16 and the full
  22-item PRD acceptance boundary remain open. No push, deployment or live
  GitHub write validation occurred.

### PR13 coordinated merge runtime and requester admission (2026-09-14)

- A configured GitHub App now starts a dedicated `merge.pull` claim loop and a
  separate bounded operation pool. The worker uses the exact merge-only
  allowlist, a 1,860-second lease with a strictly shorter processor timeout,
  defaults to two concurrent operations and enforces the validated maximum of
  eight. Claim-loop and operation-task crashes restart or durably release/defer
  their leases without rewriting an existing effect marker.
- API and web merge entry points now route every mirror-owned repository through
  one coordinator admission path. Unmirrored repositories retain the ordinary
  local merge path; a paused, unavailable or unsupported mirror never falls
  back to an independent local merge. Admission atomically commits the pending
  scheduler operation, prepared domain intent and exact preparation checkpoint
  before the worker can perform a Git or provider effect.
- Request replay is bound to a write-once canonical fingerprint of normalized
  merge method, expected head SHA, title/message and request identity. The same
  request is byte-stable, while changed evidence is rejected in pending,
  processing, effect-pending, completed and failed states. Preparation reloads
  the repository merge policy inside its transaction; nonpending replay reloads
  the active requester and current repository-write authorization.
- The synchronous compatibility wait is capped at 25 seconds and returns success
  only when the scheduler operation, domain intent and local pull all confirm the
  same merge OID. Queued work remains recoverable after timeout; terminal worker
  failures return immediately, while durable conflict failures remain conflicts.
- True late head binding now has integration coverage: a missing represented head
  stays read-only through wrong-identity/missing-ref observations and promotes
  only from exact active-mirror/ref evidence. Opaque same-base heads promote
  atomically when a distinct represented head ref becomes available.
- Fresh scoped PostgreSQL verification passed **239 tests**: mirror admission
  boundary **41**, coordinated domain preparation **10**, GitHub admission,
  runtime, worker and pull-sync behavior **164**, web merge routing **21**, and
  API merge routing **3**. Production warnings-as-errors compilation, scoped
  formatting and diff checks passed. Deliberate crash tests emit expected error
  logs; existing ForgeImports fixture warnings remain unrelated.
- This slice does **not** complete FR-083. Admission still rejects a represented
  cross-repository pull because the deterministic writer cannot yet materialize
  a head commit that exists only in the head repository object database. A
  disjoint-object-store regression, bounded content-addressed transfer under
  ordered repository fences, removal of that temporary restriction, and exact
  two-endpoint result confirmation remain required. PR14–16 and the full 22-item
  PRD acceptance boundary also remain open.

### PR13 pull-sync activation and merge-conflict external recheck (2026-09-13)

- Ordinary pull synchronization is now registered in the production supervision
  tree behind explicit GitHub App activation. It owns a dedicated two-slot task
  supervisor, retains the exact `sync.pull`/pull-head-reevaluation allowlist and
  restarts its scheduled claim loop after a processor task exits or crashes.
  This removes the inactive-worker FIFO prerequisite before merge activation;
  merge work itself is not yet admitted or supervised.
- A specialized owner/admin boundary now supports only the canonical
  `external_recheck` action for an open `pull_merge` conflict. It locks and
  correlates the persisted organization, active repository binding, coordinated
  merge intent, retained `merge.pull` operation, cursor and external-effect
  marker; rejects stale, forged, leased or unrelated capabilities; then resolves
  with optimistic CAS, audits the action and makes the same operation due in one
  transaction. The merge reservation, intent, marker, checkpoint and cursor are
  retained byte-for-byte. The browser action itself performs no provider or Git
  effect.
- The bounded organization settings projection now lists open conflicts only
  and exposes the resource kind and lock version needed for that action. The
  authenticated native-CSRF form is implemented for open pull-merge conflicts,
  strictly parses the conflict/version/action capability, masks unauthorized
  organizations, and redirects back to the conflict list after the durable
  transaction. Production rendering and facade execution remain explicitly
  disabled until the dedicated merge worker is active, so an accepted recheck
  cannot be stranded in the queue. Full snapshot comparison, filters, `accept
  GitHub`, and `keep Fornacast` remain PR16 work.
- Fresh PostgreSQL scoped verification passed **58 tests**: mirror effect and
  resolution **23**, GitHub supervision/lifecycle **9**, organization facade
  **5**, and web authorization/CSRF/controller behavior **21**. The deliberate
  task-crash lifecycle test emits its expected error log. Existing unrelated
  importer fixture warnings remain unchanged. Production compilation with
  warnings as errors, scoped formatting and diff checks also passed.
- A source/coverage audit corrected the prior broad remainder description:
  represented cross-repository metadata sync and core nil-to-represented
  promotion are implemented. Remaining PR13 cross-repository work is a genuine
  disjoint-object-database merge test and bounded head-object materialization,
  plus late-binding and nil-to-same-base integration cases. Request admission,
  prepared-intent writing, unmarked failure lease release, the dedicated
  long-lease merge worker, controller completion semantics and final two-endpoint
  proof also remain open. PR14-PR16 and full PRD acceptance remain unfinished.

### PR13 merge-owned outbound relationship effects (2026-09-14)

- The dedicated merge metadata intent now admits exact three-way label and
  known-assignee set deltas in addition to title/body changes. Set-only and
  mixed scalar/set effects retain the same compact `metadata_issue_pending`
  marker, immutable full preimage/target, closed-state and merge-result fences;
  the ordinary `sync.pull` effect boundary remains unchanged.
- Missing assignee node IDs are authenticated one user per claim. Missing label
  nodes are authenticated one bounded repository-inventory page per claim with
  an intent-bound cursor. Both proof boundaries reload and lock the durable
  yielded operation before committing node evidence, reject fabricated callback
  success, preserve both immutable intents and the merge reservation, and never
  rewrite a confirmed resource baseline. Exhausted label inventory records a
  visible `relationship_unavailable` conflict and does not restart.
- Exact merged issue observations now materialize provider relationships that
  were not in the local catalogs. The read-only preflight validates the complete
  pull/issue envelope, every bounded label profile and every assignee numeric-ID/
  node-ID pair before returning the lowest missing label. A merge-specific
  boundary imports or exactly adopts one label per claim, then releases only the
  lease while preserving the merge marker, checkpoint, coordinator intent,
  metadata intent, reservation and paired baselines byte-for-byte. The next
  claim observes all assignee profiles atomically from the already-authenticated
  issue response without an extra user request; unmanaged local assignees remain
  attached until the final domain transaction applies the provider memberships.
- Label import holds both repository writer fences through the domain and
  mapping transaction. The base ref may be the prepared `B` or already-applied
  merge `M`; the head must remain exactly `H`, and both repository generations
  remain pinned. Tests reject malformed later labels, identity collisions,
  dangling/wrong-repository mappings, fabricated callbacks, unsafe metadata
  preimage/target timestamps, lease/capability/intent/ref drift and catalog
  writes preceding invalid label evidence.
- Before PATCH, the worker loads exact confirmed numeric-ID/node-ID rows and
  resolves fresh label names and assignee logins through the bounded GraphQL
  relationship client. It sends total `labels` or `assignees` sets only when
  that set changed, explicitly sends empty sets for removals, and still omits
  state, reason, draft, refs, SHAs and merge facts. It reobserves the merged base,
  pull and canonical issue after name resolution and rechecks the exact intent
  and capability immediately before mutation.
- Relationship effects use the same exact-target, exact-preimage/timestamp and
  third-state recovery rules as scalar effects. Tests prove a lost PATCH response
  is confirmed without a second PATCH, a third relationship set becomes durable
  `ambiguous_external_effect` without PATCH or Git retry, and mixed scalar/set
  changes complete atomically. Permanent provider numeric IDs remain the intent
  identity; node IDs may legitimately advance from missing to authenticated and
  are immutable through supported mapping writes.
- Fresh connected PostgreSQL verification completed cleanly with **295 passing
  assertions**: merge mirror boundaries and proofs **119**, coordinated merge
  domain/recovery **73**, and provider observation/decision/recovery **103**.
  The generalized exact-ref path
  retained another **12** ordinary pull-worker tests. Production
  warnings-as-errors compilation, scoped formatting and diff checks passed.
  Independent cross-review approved the prerequisite boundaries and worker
  integration after repairing repository-scoped dangling-label admission; exact
  preexisting label adoption was retained as the established inbound contract.
- The previous post-assertion `DBConnection.OwnershipError` was traced to the
  application-wide `MergeReconciler` continuing its periodic task after a
  shared ExUnit SQL sandbox owner exited. Test configuration now disables only
  that global scheduler; isolated scheduler tests explicitly enable their own
  supervised instances. The lifecycle regression, all 33 reconciler/recovery
  tests and the complete 295-assertion matrix passed without an orphaned task or
  ownership error. Production remains enabled by default and passed
  warnings-as-errors compilation.
- Merge-owned local labels without provider mappings now materialize one lowest-ID
  prerequisite per claim. An exact provider namespace is adopted without POST;
  an absent namespace is marked before creation with a composite
  `metadata_label_pending` marker that retains the exact merge-CAS or metadata
  parent. Confirmation inserts the mapping and restores that parent without
  clearing the merge reservation, checkpoint or paired baselines.
- Recovery of an uncertain create is GET-only. Exact recorded output confirms;
  an absent or different result, local evidence drift, and provider identity
  collisions become durable visible conflicts without another POST, metadata
  PATCH or Git push. Removed membership and newly assigned lower-ID labels cannot
  strand an already-issued create. Open conflicts fence every recovery/commit
  path until explicitly resolved.
- Local ref/generation fences cover the effect. Installation write authority and
  repository identity are rechecked around token acquisition and every provider
  boundary. Provider drift is reobserved before conflict recording. When a newer
  unmapped label appears under `metadata_issue_pending`, the prior metadata
  target must first be proven applied; its exact preimage is retried before label
  creation, while a third state conflicts before label access.
- Fresh PostgreSQL verification passed **183 tests**: merge boundary, metadata,
  confirmation and local-label effects **104**, plus provider merge-worker
  integration **79**. Production warnings-as-errors compilation, scoped format
  checks and diff checks passed. Independent spec and quality reviews approved
  after repairing post-response authority checks, marked-label drift recovery,
  deterministic conflict routing and the unresolved-conflict fence.
- This closes mapped merge-owned effects, node proofs, unknown provider label/
  assignee materialization and local unmapped outbound label creation/adoption,
  not all of PR13. Durable conflict-resolution UX, runtime admission and
  activation, remaining cross-repository/head transitions, PR14–16 and full PRD
  acceptance remain unfinished. No push, deployment or live GitHub write
  validation occurred.

### PR13 merge-owned scalar outbound metadata effects (2026-09-14)

- A coordinated merge can now advance from its exact Git CAS marker to a
  dedicated `metadata_issue_pending` phase after an authenticated observation
  proves base `M` and the merged pull. The phase change preserves every merge
  proof field, reservation and `merge_written` intent while atomically storing
  the full title/body preimage and target in an immutable `PullMetadataIntent`.
  No migration was required.
- The provider worker obtains a separate base-repository-only
  `metadata:read`/`pull_requests:write` token and patches only changed title/body
  fields. It never writes merged state, reason, draft, refs, SHAs or merge facts,
  and it never trusts the PATCH response. Fresh base, pull and canonical issue
  observations must match the durable target and nonregressed marker-relative
  timestamps before final confirmation can clear the marker.
- Recovery distinguishes an unchanged exact preimage, an exact applied target,
  and a third or ABA state. Only the exact preimage with both retained timestamps
  can retry. Third states and marker-relative timestamp regressions record a
  durable `ambiguous_external_effect` conflict. Lease and installation authority
  are rechecked after each token acquisition and after PATCH before any further
  provider read.
- Mixed independent scalar changes retain provider-only fields for atomic local
  application. A genuinely newer local scalar edit advances to a contiguous
  immutable intent sequence only after the prior target is observed; an exact
  replay remains idempotent. Same-call sequencing is bounded and metadata
  recovery cannot retry the Git push.
- Fresh connected PostgreSQL verification passed **201 tests**: mirror merge
  boundaries **81**, coordinated merge domain **40**, and provider
  observation/decision/recovery **80**. Production warnings-as-errors compile,
  scoped formatting and diff checks passed. Independent spec and quality reviews
  approved after mixed-field, timestamp and post-PATCH authority repairs.
- This is the scalar title/body outbound slice only. Merge-owned outbound
  label/assignee effects and their node proofs, unknown relationship
  materialization, conflict resolution, worker admission/activation, PR14–16 and
  full PRD acceptance remain unfinished. No push, deployment or live GitHub
  writes occurred.

### PR13 atomic inbound metadata convergence during merge (2026-09-08)

- Compatible provider-only title/body and already-mapped label/assignee changes
  now apply inside the existing merge finalization transaction. The exact local
  version, fields, merge state and relationship preimage fence the update; state,
  refs and draft cannot be rewritten through the metadata request. Metadata and
  closure each advance the canonical version, and paired confirmation uses the
  resulting actual version. Failed confirmation rolls back both updates/events;
  an already advanced Git M remains recoverable without another merge commit.
- The read-only provider observation accepts differing known memberships while
  retaining immutable node checks. Final authorization revalidates the original
  raw pair under ordered nonblocking identity locks held through confirmation.
  Savepoints preserve transaction usability on contention and are used only in
  active transactions. Unknown identities remain prerequisites, not implicit
  catalog writes. Existing unmanaged local assignees remain preserved.
- Connected PostgreSQL verification: **79 passed** (domain finalization and
  metadata sync 34; provider worker and observation 45). Tests cover inbound
  additions/removals, node drift, actual cross-connection contention, same-M
  recovery, exact preimage rejection, rollback and completed replay.
- Broader scoped run: **226 assertions passed** (Git 4, mirrors 63, pull domain
  99, provider 57, API 3), with a verification caveat: the unchanged standalone
  `MergeReconciler` 30-second background task logged a sandbox ownership error
  after the test owner exited. No assertions failed; this is not an entirely
  clean runtime run. The final focused 79-test rerun passed without that error.
  Existing importer fixture warnings remain unchanged. The separate background
  runtime/test ownership issue was not suppressed or modified in this slice.
- Production warnings-as-errors compilation and scoped formatting/diff checks
  passed. Spec and code-quality reviews approved the inbound implementation.
- Outbound merge-owned metadata effects/recovery, unknown relationship
  materialization, conflict resolution, admission/activation, PR14–16 and full
  PRD acceptance remain unfinished. No push, deployment or live GitHub writes.

### PR13 merge-owned metadata decisions and durable conflicts (2026-09-08)

- A separate pure merge-time decision uses authentic paired baselines for
  title/body and relationship set deltas. It returns metadata targets only, not
  invented closed/ref baselines. Ordinary pull metadata decisions remain intact.
  Proposed relationship sets retain the 512-entry limit after delta composition.
- The merge worker routes competing scalar edits and incompatible draft/state
  changes to independently validated durable conflicts. Confirmation authority,
  paired mappings, current domain projection, and provider evidence are rechecked;
  Issue then Pull row locks prevent stale conflict classification. Conflict
  insertion and lease yielding preserve the effect marker and original baselines.
- Authorization inside finalization rejects incompatible newer local closure
  states before domain mutation, so a not-planned/reopened edit cannot silently
  become completed. Existing open conflicts continue to block confirmation.
- Connected scoped PostgreSQL matrix: **87 passed** (confirmation 25, finalizer
  14, provider worker/observation/decision 48). Tests cover real worker routing,
  invalid evidence, current authority, row-lock order, and preserved snapshots.
- Final broader scoped matrix: **197 passed** (Git 4, mirrors 63, pull domain
  79, provider 48, API 3). Production warnings-as-errors compilation, scoped
  formatting and diff checks passed; spec and quality reviews approved. Existing
  unrelated importer fixture warnings remain unchanged.
- Nonconflicting differences still await merge-owned durable metadata effects;
  unknown/different provider relationships still need observation/materialization
  integration. Conflict resolution, admission, activation, PR14–16, and the full
  PRD acceptance matrix remain unfinished. No push, deployment, or GitHub writes.

### PR13 exact merged-result confirmation integration (2026-09-08)

- The unregistered merge worker now connects authenticated paired provider
  observations to the trusted domain finalizer and transactional mirror
  confirmation. Actual resulting metadata and resolved relationships must match
  before both mappings advance at the actual local version and the base ref,
  operation, and domain intent complete atomically.
- Provider evidence retains the raw PR base OID and issue state reason. A raw
  historical base B or M and null/completed reason are normalized only alongside
  separately observed branch M and exact merged-commit proof. Third bases,
  incompatible reasons, substituted identities, and unknown relationships reject.
- Connected scoped PostgreSQL tests: **64 passed** (confirmation 17, domain
  finalization 14, provider worker and observation 33). These include newer local
  metadata preservation, local-M recovery, and revocation after observation.
  Provider HTTP is stubbed; database transactions and Git objects are real.
- Broader scoped regression matrix: **174 passed** (Git transport 4, mirrors
  55, pull domain/recovery 79, provider 33, API merge 3). Production compilation
  with warnings-as-errors, scoped formatting, and diff checks passed. Spec and
  code-quality reviews found no actionable issues in this bounded integration.
- Different metadata retains the effect marker, reservation, and original paired
  baselines. Merge-owned metadata reconciliation and conflict resolution remain
  unfinished, as do requester admission and worker activation. This is not full
  FR-083, PR13, or PRD acceptance. No push, deployment, or live GitHub writes.

### PR13 local merge finalization boundary (2026-09-08)

- A dedicated trusted domain finalizer can apply an already written merge commit
  after coordinator authorization. Both authorization and caller confirmation
  callbacks are mandatory and run inside the database transaction; numeric IDs
  alone are not authorization. This API is not yet connected to the merge worker.
- Sorted distinct base/head repository fences protect exact local ref checks.
  The private result/tree pins and actual merge object's tree and ordered parents
  must match the durable intent. Only the original base can advance to that merge
  commit; an already advanced ref is recoverable, and a third OID is rejected.
  No new merge commit is constructed during finalization.
- Closure and merge facts preserve newer title/body/draft/relationship edits.
  The canonical issue version, domain outbox, audit, repository write version,
  caller confirmation SQL, and intent completion commit atomically. Callback
  rejection or final SQL failure rolls them back while leaving the local Git
  result recoverable. Completed replay does not repeat domain mutations/events.
- Combined scoped PostgreSQL regression matrix: **147 passed** (Git transport 4,
  mirror merge boundary 38, pull domain/recovery/snapshot/outbox 79, prepared
  provider merge worker 23, API merge 3). Fourteen finalization tests use real
  database transactions and Git objects, including caller SQL rollback after a
  successful callback followed by failed intent completion. They prove trusted
  transaction composition, not real GitHub final confirmation.
  Production compilation with warnings-as-errors and scoped formatting checks
  passed; existing unrelated importer test fixture warnings remain unchanged.
- The coordinator still needs dedicated final authorization and authenticated
  paired provider evidence, safe paired mapping/ref baseline confirmation, and
  worker integration. It must not label newer local metadata remotely confirmed
  without evidence. Existing ref-only readiness and generic completion guards
  remain unchanged; this is not full FR-083 or PR13 acceptance.

### PR13 prepared merge execution and ambiguous-effect recovery (2026-09-08)

- A bounded, deliberately unregistered merge worker executes an already written
  deterministic merge commit through an exact expected-base Git compare-and-swap.
  Fresh local/provider base and head evidence, paired pull/issue identity, current
  coordinator authority, and LFS prerequisites are required before the immutable
  pre-push marker. Provider observations use read-only credentials; LFS and Git
  mutations use a base-repository-only write token.
- Recovery observes the authenticated remote base before retrying. The original
  base permits a freshly authorized retry of the same commit; the prepared merge
  commit records confirmation readiness; a third commit records a durable conflict.
  Yielding never clears the effect marker, merge reservation, or existing conflict.
  Provider numeric/node identities and the original installation remain pinned.
- Bounded LFS progress checkpoints yield without inventing a network failure.
  Runtime authority checks fence scan/transfer preparation and new batch, upload,
  and verification requests. These checks do not claim to cancel an external
  request already in flight. Denial after opening an upload source closes it.
  Batch authorization is rechecked after acquiring the installation request gate.
- Final scoped PostgreSQL regression matrix: **157 passed** (Git transport 4,
  mirrors 52, pull domain 22, provider 76, API merge 3). Tests include deterministic
  merge writing, stale/ref divergence, ambiguous push recovery, revocation during
  LFS preparation and gate waits, and upload source cleanup. Provider HTTP is
  stubbed; domain transactions and Git fixtures are real. Existing unrelated
  importer fixture warnings remain unchanged.
- Push success is not merge completion. This worker does not update local public
  refs, close the pull, or complete the mirror operation, and is not admitted by
  the worker pool. Dedicated two-endpoint confirmation, atomic local/domain and
  mapping confirmation, requester admission, and activation remain to implement.
  PR14–16 and the full PRD acceptance matrix remain open. No push, deployment,
  or live GitHub write validation occurred.

### PR13 read-only head reevaluation and discovery (2026-09-08)

- Unsupported pulls now have a leased coordinator and worker path. An explicitly
  unknown provider head may be revealed once from authenticated paired evidence;
  that claim yields without changing domain state or confirmed baselines. A
  separate claim may bind the immutable head to an active local mirror only
  under fresh Git ref/OID fences and exact paired local/provider metadata proof.
- Representation advances the canonical domain version and both mapping versions
  atomically while retaining snapshots, provider identities, and remote timestamps.
  Changed local or remote metadata, including still-opaque head observations, is
  not silently acknowledged or rebased: the worker records a terminal validation
  failure with an explicit read-only metadata mismatch detail.
- Sorted, bounded, nonblocking merge-reservation guards cover base and head;
  busy guards, revoked access, stale leases, substituted identities, unavailable
  refs, and malformed unsupported mappings cannot promote the pull.
- Completed organization inventory schedules idempotent pull-head discovery.
  Its database-only pages enumerate at most 100 unsupported mappings with a
  scoped high-water cursor, yielding ordinary pull reconciliation children.
  This does not add a bootstrap activation requirement. A real local integration
  test covers discovery through representation without a webhook.
- Final combined scoped PostgreSQL verification: **401 passed** (issues 11,
  mirrors 178, pull domain 9, provider 201, API 1, HTML 1). This includes existing
  paired metadata, creation, relationship/label recovery, and read-only rendering
  regressions. Provider HTTP is stubbed; Git repositories and database boundaries
  are real. Existing unrelated importer fixture warnings remain unchanged.
- Follow-up error-routing regression: a corrupt unsupported local identity now
  fails as explicit local validation before requesting credentials, rather than
  being retried as a network fault. The four-file scoped matrix passed 86 tests
  (mirror boundary 14 and provider 72) after reproducing the incorrect retry.
- This closes the locally verified reevaluation gap described below, not PR13
  merge orchestration, overall activation, PR14–16, or full PRD acceptance.
  No push, deployment, or live GitHub write validation occurred.

### PR13 explicit unknown-head import (2026-09-08)

- Pull transport and projection accept explicit `head.repo: null` while rejecting
  omitted/malformed head repository objects and null base repositories. Head refs
  and SHAs are retained without inventing a repository identity from a name.
- The authenticated paired preflight still checks canonical issue coherence and
  exact base identity before attribution. Resolution and creation require the
  base Git proof before and after the domain callback; no head proof is invented.
  The pull mapping is unsupported/read-only with explicit nil provider head,
  while the canonical issue mapping is retained. Known but unready heads remain
  retryable and cannot be downgraded through this creation-only path.
- Final combined scoped PostgreSQL verification passed 333 tests (issues 11,
  mirrors 134, provider 186, one API and one HTML read-only regression). The API
  retains null head repository/user without borrowing the base identity; the UI
  identifies read-only external pulls and omits merge/comment controls. Ten-file
  formatting, diff checks and focused review passed.
- At this checkpoint reevaluation remained open (now addressed by the section
  above): the existing `ForgePulls.HeadRepresentation` domain
  transition has no mirror coordinator/worker path. That path must validate the
  unsupported pull and canonical issue pair, prove fresh immutable head identity
  and active refs, and bind head identity atomically without silently confirming
  newer local or remote edits. A known head identity must never be replaced;
  explicit unknown-to-known admission needs its own proof boundary.
- This is nullable inbound creation proof only, not complete FR-080–082, merge
  orchestration, activation, PR14–16 or full PRD acceptance. No push, deployment
  or live GitHub write validation occurred.

### PR13 mapped outbound label prerequisites (2026-09-08)

- A new local label assigned to a mapped pull is adopted only on an exact remote
  snapshot match, or created after an immutable label effect is persisted.
  Admission binds actual membership, label version/snapshot, paired mapping
  tokens, local pull fingerprint, original installation and provider/ref proof.
- Repository identity is checked around name lookup and immediately before and
  after POST. Git fences span the write and immediate mapping confirmation.
  Both canonical pull/issue baselines remain unchanged until the later metadata
  claim; real integration proves that claim PATCHes membership and confirms both.
- Lost-response recovery queries the original saved name and never repeats POST.
  Exact matches confirm the original label version while preserving newer local
  metadata. Missing/third-state remote results, deleted labels and unversioned
  local drift become visible conflicts retaining effect evidence. Stale caller
  markers are rejected before recovery evidence is exposed.
- Label GET/POST responses reject credential echoes, archived/malformed archive
  state and unsafe node identities before retaining canonical evidence fields.
  Historical label observation returns the actual locked row without mutations.
- Final combined scoped PostgreSQL verification passed 299 tests (issues 11,
  mirrors 107, provider 181), including existing issue-sync regressions. Nine-file
  formatting, diff checks and focused review passed. Existing importer fixture
  warnings remain outside these edits.
- Existing pull-request write permission is sufficient for label creation;
  token scope was not expanded ([GitHub permission reference](https://docs.github.com/en/rest/issues/labels#create-a-label)).
- This closes the mapped new-local-label prerequisite path, not ongoing label
  metadata convergence after later renames. Remaining head/merge/activation work,
  pending-metadata-effect third-state resolution, PR14–16 and full PRD acceptance
  remain open. No push, deployment or live GitHub write validation occurred.

### PR13 mapped inbound label materialization (2026-09-08)

- Processing mapped pulls can import one unknown remote label and yield the same
  parent operation before applying membership on the next claim. Both canonical
  baselines remain unchanged during prerequisite creation.
- Admission and finalization bind the exact paired mappings, current local
  version/fingerprint, installation and ref eligibility. Live Git write fences
  span label import. Lease loss rolls back the import; pending effects cannot
  use this marker-clearing prerequisite path.
- Worker integration proves two-claim convergence, live ref-loss rejection,
  visible namespace collision and retained effect evidence without another PATCH
  when an unknown remote label appears during recovery.
- Combined scoped PostgreSQL verification passed 197 tests (mirrors 93, provider
  104); four-file formatting and diff checks passed. Existing importer fixture
  warnings remain unrelated to this scope.
- New local unmapped-label export remains open, as do pending-effect third-state
  resolution, remaining PR13 head/merge/activation gates, PR14–16 and full PRD
  acceptance. No push, deployment or live GitHub write validation occurred.
- Follow-up review hardening rejects organization-wide label node collisions
  before and after the domain callback; a collision introduced during the callback
  rolls back the transaction. Namespace and immutable-node conflicts retain nested
  pull and remote-label identity/field evidence, plus diagnostic local-label data
  where available. Cross-repository collisions retain the remote candidate but do
  not include the other repository's local label in this diagnostic view.
- Final hardened combined verification passed 201 tests (mirrors 96, provider
  105), with four-file formatting and diff checks passing. Targeted re-review
  found no remaining blocker in these two fixes.

### PR13 mapped relationship node proofs (2026-09-08)

- Mapped metadata effects seed missing immutable user nodes one per claim and
  label nodes one bounded inventory page per claim, preserving the exact intent
  and effect marker. Repository, installation, lease, identity collision and
  paired-state checks reject stale or substituted proofs atomically.
- Label cursors are intent-bound; exhausted inventory becomes a visible conflict
  instead of restarting. Draft-only effects do not perform relationship discovery.
- Real HTTP-stub integration covers multi-claim discovery, lost PATCH responses,
  draft continuation, exhaustion, wrong users and revocation during proof reads.
- Combined scoped PostgreSQL verification passed 180 tests (mirrors 80, provider
  100); all eight changed Elixir files passed formatting and diff checks.
- This closes this missing-node slice only. Unknown relationship materialization,
  remaining head/merge transport, activation and PR14–16/full acceptance remain
  open. No push, deployment or live GitHub write validation occurred.

### PR13 remote-version replay guard (2026-09-08)

- Paired markers retain independent canonical issue and pull observation times.
  Admission/reload reject missing, malformed or older-than-baseline versions.
  Replay requires both the full preimage and its versions to match; restored
  values with changed timestamps become ambiguous instead of causing another
  PATCH/draft conversion. An exact target still confirms with a newer timestamp.
- Genuine HTTP-stub integration regressions reproduced duplicate issue writes,
  duplicate draft conversions and a write after restored values during GraphQL
  lookup; all three now reject replay. Paired confirmation additionally prevents
  either stored remote observation time from moving backward.
- Root final combined verification passed 141 tests (mirrors 47, provider 94),
  plus five-file formatting. Timestamp precision remains that of the provider:
  indistinguishable same-second changes are not claimed to be detectable.
- This does not close missing-node seeding, activation, the other PR13 gates,
  PR14–16 or full PRD acceptance. Nothing was pushed or deployed.

### PR13 paired effect admission and historical confirmation (2026-09-08)

- `9bce29e` atomically persists immutable full metadata evidence and its compact
  operation marker. Admission rederives scalar/set targets from the locked paired
  baseline, exact current local preimage, and observed remote preimage; checks
  unchanged refs and action-specific draft semantics; and binds identity, hash,
  paired mapping tokens and original installation/ref eligibility evidence.
- Reload preserves the intent while permitting newer local metadata. Paired
  confirmation can retain a proven historical baseline without overwriting newer
  local changes, including a new label that has no provider mapping yet.
- Forty scoped PostgreSQL tests passed, including stale proof/lease rejection,
  replacement intents, draft-only issue immutability, ref continuity, original
  installation substitution, maximum Unicode bodies and unmapped-label recovery.
- `96c6ba1` wires paired local and outbound metadata decisions, separate issue and
  draft effects, exact pre/post recovery, historical confirmation, and fresh name
  resolution into the worker. Nonempty labels/assignees merge independent additions
  and removals; lost PATCH responses recover with one write. A fresh paired read
  after GraphQL detects remote drift before PATCH and recognizes an already-applied
  target without replay. Newer unmapped local labels survive recovery end to end.
- Final combined verification passed 134 tests (mirrors 43, provider 91), including
  creation/client/projection/recovery regressions and the real local Git + database
  + HTTP-stub worker cases. Seven-file formatting passed. Earlier 12/14 and 64-test
  snapshots below are historical, not current failures.
- Missing immutable node proofs for mapped relationship effects still retry rather
  than being seeded by this path. Worker activation, unsupported-head handling,
  merge orchestration, other remaining PR13 gates and PR14–16/full PRD acceptance
  remain open. No live GitHub, push, deployment, or full acceptance claim is made.

### PR13 full relationship evidence and worker integration (2026-09-08)

- `a4d0779` adds actual local paired relationship projections and independent
  remote issue snapshots/timestamps. The scalar-only projection remains available
  for existing bootstrap callers, not as evidence of synchronized relationships.
- `03fbff8` stores immutable, hashed metadata evidence in a separate bounded 2 MB
  intent table with per-operation sequence uniqueness. Pure recovery classification
  compares complete saved remote preimage/target snapshots and preserves current
  local sets; a third remote state is ambiguous. The operation marker's 64 KiB
  limit is unchanged. Leased admission and compact marker reference wiring remain
  to be implemented; a schema alone does not establish durable effect recovery.
- Focused combined verification passed 52 tests (mirrors 30, provider 22), including
  storage persistence/duplicate protection, seven recovery cases and four paired
  worker cases. Projection/decision verification separately passed 13 tests.
- Worker integration is still uncommitted work in progress. An initial broader
  integration/lifecycle run passed 9/14: five failures exposed missing paired
  fixture baselines and unfinished outbound/recovery integration. Existing outbound
  assertions are retained, not skipped or weakened. Do not infer full worker
  acceptance from the focused results.
- After correcting the paired fixtures, the real inbound label and two Git-ref
  safety cases passed. The broader matrix now passes 12/14; the remaining failures
  are outbound issue/draft completion and pending disjoint-effect recovery, both
  explicitly deferred by the incomplete paired-effect path. Eleven-file formatting
  passed. Worker changes remain uncommitted until those effects are integrated.

### PR13 paired confirmation and identity-link fencing (2026-09-08)

- `894f57e` fences current/target local assignee users and known GitHub identities
  with PostgreSQL NOWAIT/savepoint locks. Four independent-connection tests cover
  linking existing identities, inserting linked identities, inverse lock contention,
  and rollback of scalar/version/outbox changes. Contention returns
  `:relationship_lock_busy`; mapped worker integration must retry it.
- Processing-only `confirm_mapped_pull_pair/5` validates both baseline tokens,
  reads the actual resulting domain relationship projection, and confirms both
  mappings in the same transaction as the local mutation and operation completion.
  Regressing companion observation times and incorrect resulting sets roll back.
  Its callback is trusted internal domain composition, not a sandbox for arbitrary
  writes. Effect-pending recovery and worker integration are still outstanding.
- Root combined verification: 58 scoped tests passed (issues 12, mirrors 26,
  pulls 20), including four independent PostgreSQL tests; six-file format check
  passed. Existing importer test-support warnings remain unrelated.
- These are local prerequisites, not PR13 completion, activation, live GitHub
  validation, or full PRD acceptance. Nothing was pushed or deployed.

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

### Final connection and unsupported-resource acceptance (2026-09-14)

- `fe1a8fd` adds a real web/domain acceptance boundary for criteria 1 and 2.
  An organization owner starts an installation through the production route,
  correlates the one-time state, binds a distinct immutable GitHub organization,
  and sees the bound installation through the settings route. A linked outsider
  and an immutable installation-identity mismatch are rejected. Partial repository
  selection and missing required permissions are rendered before bootstrap, and
  bootstrap is refused without creating an import run. Two focused PostgreSQL web
  acceptance tests pass; the existing callback-controller tests retain their
  parsing, expiry, one-time-consumption, and mismatch coverage.
- `757bf18` completes the local negative boundary for criterion 17. Repository
  reconciliation now admits only `refs/heads/*` and `refs/tags/*` from both local
  and provider observations, so `refs/wiki/*` cannot fan out into Git work. The
  owner-driven reconciliation acceptance also carries asset-bearing release data
  through the real reconciliation parent and proves that neither wiki nor release
  assets create operations or mappings. The combined unsupported-resource matrix
  passes 66 focused tests across GitHub, mirrors, imports, and release persistence.
- The App-backed bootstrap acceptance now imports real issue, comment,
  same-repository pull, and release fixtures through `RepositoryWorker`, publishes
  their permanent mappings/baselines, and proves six supported delivery families
  remain buffered through staging and become eligible only after handoff. A valid
  pull delivery is run through the production webhook worker before and after the
  baseline: it defers before handoff, then completes and creates the exact bound
  `sync.pull` operation after the run finishes. The focused file passes two tests.
  Dedicated Git/LFS publication, scan, transport, and finalizer tests remain the
  evidence for the Git/LFS portion rather than treating an empty LFS fixture as
  a transfer proof.
- Newly visible GitHub repositories now have a production consumer for the
  inventory-created `bootstrap.repository_import` operation. It creates one
  installation-token-backed repository import in the connected organization,
  reuses its durable run/item across worker restarts, and hands publication into
  the existing permanent binding/baseline/reconciliation pipeline. The parent
  completes only after the exact child reconciliation is durable, releasing
  repository FIFO before that child activates the binding. Retryable discovery
  failures retain historical runs and create one provenance-linked successor;
  revoked, canceled, permission, and validation failures stop instead of minting
  another token. The combined PostgreSQL gate passes 64 scoped import worker,
  reconciler, credential-provider, and publication tests, and production
  compilation passes with warnings as errors. Independent Critical/Important
  review reports no remaining finding.
- The final local Git/LFS acceptance audit found no missing production path for
  criteria 7-10 or 12. Fresh scoped verification passes 28 GitHub Git/LFS worker
  and reconciliation tests, 38 mirror decision/persistence tests, four real bare-
  remote transport tests, and the official smart-HTTP `git-lfs` clone/checkout
  test. Together these prove bidirectional create/fast-forward decisions and
  effects, exact-baseline branch/tag deletion, durable visible divergence without
  mutation, ref publication only after LFS transfer, and missing/corrupt-object
  degradation. They remain local controlled-endpoint evidence; criterion 11 still
  requires a synchronized clone/checkout from a real GitHub endpoint.
- These are local acceptance results. Live GitHub App installation and provider
  endpoint validation remain required before the complete 22-item PRD can be
  declared finished.

| # | Required outcome | Current evidence / next gate |
|---|---|---|
| 1 | Owner connects the App to the correct organization | Locally accepted in `fe1a8fd` through the production install/settings routes, correlated callback domain handoff, distinct immutable GitHub organization identity, owner success, linked-outsider rejection, and installation mismatch rejection. Retain live GitHub App proof. |
| 2 | Permission and partial-access problems visible before bootstrap | Locally accepted in `fe1a8fd`: settings render partial selection and missing permissions, while the production bootstrap route refuses the request and creates no import run. Retain live provider-permission proof. |
| 3 | All enabled supported resources bootstrap to active bindings | Locally accepted by composition: the App-backed acceptance imports and publishes real issue/comment/pull/release mappings and baselines; publication tests cover Git refs and LFS hold; Git/LFS persistence tests prove the finalizer activates the repository and organization only after required confirmations. Retain live GitHub bootstrap proof. |
| 4 | Bootstrap-time webhooks replay after baseline | Locally accepted: six supported delivery families remain buffered during real App staging and become eligible only after publication handoff; a valid pull delivery is deferred by the real worker before baseline and completes into the exact bound `sync.pull` operation after the run finishes. Dedicated Git/LFS and resource webhook tests cover the other processors. Retain live delivery proof. |
| 5 | GitHub-created repository imports according to policy | Locally accepted: the production inventory consumer follows policy-created work through one App-backed run/item, retryable discovery successor recovery, publication handoff, parent FIFO release, and exact child reconciliation claim while preserving the active organization binding. Retain live GitHub creation/import proof. |
| 6 | Local organization repository is created on GitHub according to policy | Locally accepted in PR16: typed policy/capability admission, strict installation-gated create, absence marker, immediate pre-POST lifecycle fence, timeout and 422 recovery, per-binding collision evidence, immutable binding/baseline, and ordered Git-then-metadata activation are covered. Retain live GitHub proof in final acceptance. |
| 7 | Local branch create/fast-forward reaches GitHub | Locally accepted by composition: the worker persists/authorizes the outbound effect and the real fixed-host transport fixture advances the exact remote branch/tag without force. Retain live GitHub proof. |
| 8 | GitHub branch create/fast-forward reaches Fornacast | Locally accepted: owner reconciliation fetches a commit from a separate bare remote into the private namespace, holds the public ref across LFS checkpoints, and applies the exact local CAS only after object verification. Retain live GitHub proof. |
| 9 | Safe ref deletion only from unchanged baseline | Locally accepted: decision, persistence, worker, local CAS, and real remote transport tests cover branch/tag deletion only at the exact confirmed OID and preserve stale refs. Retain live two-endpoint proof. |
| 10 | Divergence is visible and neither side overwritten | Locally accepted: the worker records the exact baseline/local/remote conflict and conflicted ref state without calling either mutation boundary; the production owner conflict route renders bounded comparisons and keeps Git conflicts read-only. Retain live conflict proof. |
| 11 | LFS clone and checkout succeed from either endpoint after sync | Actual Fornacast smart-HTTP clone with official git-lfs 3.7.1 checks out 128 KiB with matching SHA-256. Existing official SSH LFS transfer coverage is also present. Remote endpoint plus full synchronization-to-clone chain remain unproven. |
| 12 | Missing/corrupt LFS blocks confirmation and degrades sync | Locally accepted: worker, storage, durable 101-pointer replay, authoritative scan, and finalizer tests prove the public ref and baseline remain unchanged while the operation/repository is degraded; verified bytes are required before later confirmation. Retain live GitHub failure/recovery proof. |
| 13 | Issue/comment changes converge both ways | PR12 local worker, mapping, effect recovery, label materialization, signed ingress and bootstrap activation are implemented through `f45097e`; combined activation matrix: 150 passed. Real domain/lease/HTTP-stub tests cover both directions and omitted comment deletion. Retain live two-endpoint acceptance. |
| 14 | Same-repository PR metadata converges both ways | Locally accepted in PR13, including represented cross-repository synchronization, unrepresented read-only behavior and trusted late head representation. Retain live GitHub validation in final acceptance. |
| 15 | Coordinated PR merge produces one confirmed Git result | Locally accepted through real API admission, disjoint repositories, exact provider Git CAS, lost-response worker restart, provider re-observation, one merge result and matching local/provider pull state. Retain live GitHub validation in final acceptance. |
| 16 | Release metadata converges and stays bound to a confirmed tag | PR14 local domain/API/web and PR15 bootstrap/incremental synchronization are locally accepted. Fresh two-sided tag proof, retarget conflicts, immutable provider identity, marker replacement and newer-local recovery are covered. Retain live GitHub proof in final acceptance. |
| 17 | Release assets and wiki never synchronize | Locally accepted in `757bf18`: bootstrap/import/persistence paths strip release assets, owner-driven reconciliation creates no asset work or mappings, and remote `refs/wiki/*` observations are excluded before Git fanout. Retain live negative proof. |
| 18 | Duplicate/out-of-order webhooks neither duplicate nor regress | Locally accepted in PR16. Distinct issue, comment, pull, and release deliveries retain immutable hints, re-read canonical provider state, converge one domain version/mapping baseline, and emit no duplicate provider-origin event. |
| 19 | Every operation boundary recovers after restart | Locally accepted across inventory/finalization, Git/LFS, repository create/metadata, issues/comments, pull create/sync/merge, and release create/update/delete. Durable leases, cursors, checkpoints, exact effect markers, ambiguous-result reads, and no-replay recovery are covered. |
| 20 | Full reconciliation repairs omitted deliveries | Locally accepted in PR16. One immutable owner-scheduled sweep now repairs intentionally omitted repository metadata, Git/LFS, issue/comment/label/assignee, pull, and release deliveries through real workers with zero inbox rows; `last_reconciled_at` advances only after every marker-bearing branch and finalizer completes. Retain two-endpoint/live GitHub proof in final acceptance. |
| 21 | Pause prevents new effects but retains work | Locally accepted in PR16 across inventory/finalizers, repository creation/metadata, Git/LFS, issues/comments, pulls/create/merge, and releases. Pre-effect and post-marker fences stop credentials/provider effects while preserving queued work, lease recovery, markers, and LFS cursors for resume. |
| 22 | Disconnect/revocation stops token use and retains local repos | Locally accepted in PR16 across all worker families and in-flight marked recovery. Real deletion processing revokes authorization before token invalidation, prevents later claims/provider use, and retains the local repository, refs, LFS data, and durable marker. Retain the live GitHub disconnect flow in final external acceptance. |

## Current local verification

- `25e69c2` adds atomic pull scalar/draft and relationship application with one
  Issue version/event. The optional relationship group requires exact preimages;
  managed assignee identity rows are representation-independent and share-locked,
  while existing unmapped local assignees remain intact through shared Issue
  replacement rules. Projection and observation return labels, refs, and canonical
  managed preimages. Fresh regression verification passed 109 tests (12 issue,
  22 mirror, 32 pull, 43 provider), with three files format-checked. This is not
  mapped-worker integration. New account links into formerly unmanaged users are
  still a required concurrency gate; known-row locks alone do not fence phantoms.
- `6207654` adds a leased read-only paired-mapping gate and a pure paired-view
  metadata decision helper. The gate checks both canonical identities, repository
  identity shape, snapshots, equal scalar/version baselines, and stored hashes;
  legacy nil hashes are explicitly read-derived and are never persisted as a
  repair. The decision merges relationship deltas against the issue baseline and
  returns separate pull/issue targets plus exact observed issue preconditions.
  Fifty-eight scoped tests passed (30 mirror, 28 provider); six files passed
  formatting. Neither helper is wired into mapped confirmation yet. Atomic domain
  relationship application, dual-mapping confirmation, full-set durable effects,
  and concurrent new account-link fencing remain required.
- `7efefd4` moves mapped-pull Git eligibility and immutable/scalar preflight ahead
  of author and assignee attribution writes. A regression reproduced attribution
  on a substituted repository before rejection; paired issue identity, changed
  refs, and incoherent scalar observations are also rejected before attribution.
  Unavailable local refs now prevent provider reads. Forty-six scoped mapped,
  creation, and lifecycle tests passed; three files passed formatting. Mapped
  label/assignee set reconciliation remains the next integration gate.
- `3a2ef63` label-node preparation consumes one authenticated inventory page per claim,
  saves intent-bound progress, and seeds only existing confirmed local mappings
  without modifying their metadata baseline. Existing and newly seeded node
  collisions are rejected. Completed inventories with missing desired labels
  produce `relationship_unavailable` conflicts from persisted evidence, retaining
  the original creation marker and intent reservation. Real DB/local-Git/HTTP-stub
  integration proves two-page resume, a subsequent fresh label rename, one POST
  and one cleanup PATCH; empty inventory proves one scan, no PATCH, and a visible
  conflict. Fresh verification passed 79 tests (58 mirror, 21 provider), and all
  seven changed files passed formatting. This completes this outbound prerequisite
  path locally, not mapped-PR synchronization, merge coordination, activation, or
  the complete PRD acceptance gates.
- `00f46fc` seeds one intended assignee node per leased recovery claim without
  changing the creation marker or checkpoint. Database tests reject wrong IDs,
  node collisions, expired leases, replacement installations, and removed users.
  `767f705` resolves retained relationship nodes through one fresh GraphQL query,
  replacing per-name HTTP lookups. Real database/local-Git/stubbed-HTTP integration
  seeds two users across claims, then uses newly renamed logins for one cleanup
  PATCH and confirms the original intent after exactly one creation POST. The
  GraphQL deadline is bounded by the lease; it is not an end-to-end cleanup
  deadline. Combined verification passed 69 tests (43 mirror, 26 provider),
  including the pending label-proof boundary. Label worker preparation, exhausted
  inventory conflicts, mapped-PR reconciliation, and activation remain open.
- `f336fae` adds a single-page authenticated label inventory client. Pagination
  is fixed to the exact repository, advancing page, and 100-item page size;
  responses retain only bounded canonical fields and reject credential echoes,
  duplicate identities, and malformed node IDs. Seventy scoped label/client/pull
  client tests passed and three files passed formatting. Durable label-node
  seeding and worker integration are still required; this is not an activation
  or end-to-end acceptance result.
- `cf3aaed` adds immutable nullable user node identities, authenticated numeric-ID
  lookup, and fresh node-based relationship resolution. Exact node sets, label
  repository ownership, credential-echo rejection, and absolute GraphQL request
  deadlines are checked. Existing node associations cannot be replaced; absent
  nodes can be seeded without regressing newer profile observations. Fresh scoped
  verification passed 27 new tests and 97 existing identity/profile/client
  regressions (124 total); all 13 changed files passed formatting. These are
  provider/domain prerequisites, not worker integration or activation. Durable
  missing-node preparation and worker wiring remain open. Two 512-node GraphQL
  arrays have local fixture coverage only, not live GitHub limit acceptance.
- `5b390d1` records intent-bound outbound creation conflicts instead of deferring
  zero/multiple UUID matches and identity/metadata divergence as network errors.
  The exact marker and scan survive in the failed operation checkpoint; the
  immutable intent still reserves the local pull, and no candidate mapping is
  invented. Zero-match claims require a persisted completed empty scan; multiple
  matches require two distinct compact identities. Real integration proves one
  POST followed by an open conflict and no cleanup/mapping for an empty scan.
  Fresh combined verification passed 102 tests (46 mirror, 56 provider), with
  eight changed files format-checked. A fixture timing race was corrected by
  capturing claim time after operation materialization. Conflict resolution and
  relationship prerequisite recovery remain open; this does not enable workers.
- `0a25679` adds durable paged recovery and fresh eligibility without another
  creator grant. A regression proved replacement-installation acceptance; the
  fixed boundary pins both original organization and installation identities.
- `a16155f` connects outbound creation to the pull worker. Fresh combined
  verification passed 90 scoped PostgreSQL/provider tests (37 mirror, 53 GitHub),
  and 13 changed files passed formatting. Real database/local Git integration
  with stubbed HTTP proves original-intent cleanup after a newer local edit,
  missing local refs blocking admission, and lost POST response recovery across
  separate claims with exactly one POST. Provider tests prove identity-checked
  ref reads, a post-wait lease check before PATCH, and 512-item relationship
  payload/response bounds (listing pages remain 100). These are local proofs.
  Visible intent-bound conflicts, missing/renamed relationship prerequisites,
  checkpointed large relationship-name verification, and production activation
  remain open; the current error path retains evidence but defers conflicts.
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
