# Implementation Plan: GitHub Organization Two-Way Synchronization

- **Project:** Fornacast
- **Status:** Proposed
- **Input PRD:** `fornacast-github-org-sync-prd.md`
- **Reviewed baseline:** `main` at `e7680a2edd5d2e061db3a30f598db10ffe6f263f`
- **Database:** PostgreSQL 17
- **Delivery model:** Small, independently reviewable pull requests

## 1. Current repository assessment

The current codebase has a strong bootstrap importer but no permanent synchronization subsystem.

Reusable foundations:

- explicit import-run and repository-item state machines;
- lease-based restart recovery and bounded `Task.Supervisor` execution;
- staged Git import and atomic publication;
- import checkpoints, object mappings, cancellation, retry, and reporting;
- repository read/write fences;
- durable Git write operations and crash reconciliation;
- exact expected-ref checks;
- organization owner/admin authorization;
- hardened fixed-host GitHub REST transport;
- PostgreSQL-first testing and release gates.

Missing foundations:

- GitHub App installation authentication;
- organization-scoped sync settings;
- permanent organization/repository bindings;
- webhook ingress/inbox;
- local domain outbox;
- mirror operation scheduler;
- confirmed ref/resource baselines;
- outbound Git transport;
- safe inbound tracking-ref fetch;
- ref-deletion and ancestry primitives;
- Git LFS server/client/storage;
- release metadata domain;
- two-way metadata mutations and conflict resolution.

The implementation must preserve the importer as a bootstrap subsystem. Do not turn import tables into permanent sync tables.

## 2. Target umbrella boundaries

```text
fornacast
  Repo, migrations, Audit, OperationLease, DomainOutbox, shared config/storage

forge_github
  GitHub App JWT/authentication
  installation token broker
  reusable REST transport/client
  webhook verification and event normalization
  GitHub LFS remote client policy

forge_imports
  one-time bootstrap only
  imports via PAT or installation-token credential provider

forge_mirrors
  organization/repository bindings
  inbox/outbox dispatch
  operation leases/scheduler
  baselines, reconciliation, conflicts
  provider-neutral synchronization policy

forge_repos / forge_issues / forge_pulls / forge_releases
  local domain ownership and mutations
  emit provider-neutral domain outbox events

git_core / git_transport
  local Git data, ref CAS, protocol
  remote fetch/push primitives remain in git_core

git_lfs
  local LFS Batch/Basic protocol
  LFS object metadata and reachability
  GitHub transfer orchestration

forge_blobs
  neutral content-addressed blob storage used by LFS
  and later by release assets
```

### Dependency rule

Domain apps emit events through `Fornacast.DomainOutbox`; they never call `ForgeMirrors` directly. This prevents cycles and keeps local domain operations usable without GitHub.

## 3. Delivery principles

1. Every pull request must be independently deployable.
2. Provider extraction must preserve existing import behavior.
3. Every new durable state machine must define legal transitions in the schema/context.
4. Every external effect must have a durable operation record before execution.
5. Every retryable effect must be idempotent or recoverable after an ambiguous result.
6. Every local Git mutation must remain under the existing repository write fence.
7. Webhook HTTP handling ends after signature verification and durable enqueue.
8. No phase may weaken current private-repository masking or secret handling.
9. Do not implement Git, LFS, issues, PRs, and releases in one pull request.
10. PostgreSQL concurrency/recovery tests are release gates.

## 4. Workstream dependency graph

```text
A. forge_github extraction ─────────────┐
                                       ├─> D. GitHub App + webhook
B. generic domain outbox ───────┐       │
                                ├─> C. forge_mirrors persistence/scheduler
                                │       │
                                │       ├─> E. settings + inventory + bootstrap
                                │       ├─> F. Git two-way sync
                                │       ├─> H. issues/PR sync
                                │       └─> I. release sync
G. blob/LFS foundation ─────────────────────> F/H independent, needed for Git+LFS release
J. release metadata foundation ─────────────> I
```

Workstreams A, B, G, and J can begin in parallel after the design documents are accepted.

## 5. Pull-request sequence

## PR 1 — Freeze architecture and add app scaffolds

### Objective

Establish module boundaries without changing runtime behavior.

### Changes

- Add:
  - `apps/forge_github/`;
  - `apps/forge_mirrors/`;
  - placeholder application supervisors;
  - app entries in umbrella release configuration.
- Add the accepted design spec and implementation plan under:
  - `docs/superpowers/specs/2026-09-04-github-organization-sync-design.md`;
  - `docs/superpowers/plans/2026-09-04-github-organization-sync.md`.
- Update `AGENTS.md` and root README scope/roadmap:
  - importer is bootstrap-only;
  - mirror feature is post-v0.2.2;
  - wiki/release assets remain excluded.
- Add compile-only context interfaces and types, but no tables or workers.

### Definition of done

- Existing tests unchanged and passing.
- OTP release boots with both new applications.
- No runtime process does synchronization work.
- Dependency graph has no cycles.

## PR 2 — Extract reusable GitHub provider client

### Objective

Move provider-level code out of `forge_imports` while preserving all import behavior.

### Move/refactor

From `ForgeImports.GitHub.*` into `ForgeGitHub.*`:

- `Client`;
- `Transport`;
- `HostPolicy`;
- `Pagination`;
- `RequestGate`;
- `Error`;
- organization/repository/user decoders;
- repository reference validation where provider-specific.

Keep import-specific code in `forge_imports`:

- metadata importer;
- metadata mapper;
- discovery orchestration;
- import reports/checkpoints;
- PAT selection and import credential lifecycle.

### API

Provide a transport-neutral request function supporting bounded:

- `GET`;
- `POST`;
- `PATCH`;
- `PUT`;
- `DELETE`.

The existing importer initially uses only `GET`, but outbound sync needs mutations.

### Security constraints

- fixed API origin for ordinary GitHub API calls;
- redirect disabled unless an endpoint contract explicitly requires it;
- bounded request/response size and JSON complexity;
- DNS/private-address protections;
- classified rate-limit errors;
- no token in errors, inspect output, telemetry, or logs.

### Tests

- Move provider tests with zero semantic weakening.
- Preserve all existing import integration tests.
- Add mutation-method request tests using the existing test transport pattern.
- Add regression tests for rate limits, malformed pagination, DNS rebinding, redirects, and oversized bodies.

### Definition of done

`forge_imports` depends on `forge_github`; `forge_github` does not depend on `forge_imports`.

## PR 3 — Add provider-neutral domain outbox

### Objective

Create the transactional seam for all future outbound synchronization.

### Migration

Add `domain_outbox_events` with:

```text
id
event_id
aggregate_type
aggregate_id
event_type
origin
causation_id
correlation_id
payload
state
attempt_count
available_at
lease_owner
lease_expires_at
inserted_at / updated_at
```

Required constraints:

- unique `event_id`;
- bounded strings/payload;
- legal state/lease combinations;
- indexes for claimable events and aggregate ordering.

### Context

Add `Fornacast.DomainOutbox`:

- `record_multi/…`;
- `claim_batch/…`;
- `ack/…`;
- `release/…`;
- `fail/…`;
- stale-lease recovery.

Use the existing `OperationLease` patterns where possible.

### Initial producers

Integrate only:

- repository create/update;
- successful Git receive-pack bookkeeping;
- repository tombstone/archive once available.

Each mutation and outbox insert must commit in the same database transaction.

### Tests

- atomic rollback;
- duplicate event ID;
- stale lease recovery;
- concurrent claim;
- event ordering for one aggregate;
- origin and causation propagation;
- no event when the domain mutation fails.

### Definition of done

There is still no GitHub side effect. The outbox is durable and observable.

## PR 4 — Create permanent mirror persistence and scheduler

### Objective

Implement the durable mirror state machine before connecting to GitHub.

### Migrations

Add:

- `organization_mirrors`;
- `repository_mirrors`;
- `mirror_ref_states`;
- `mirror_resource_states`;
- `mirror_operations`;
- `mirror_webhook_deliveries`;
- `mirror_conflicts`.

Split migrations if necessary, but retain foreign keys, uniqueness, check constraints, and claim indexes.

### Context APIs

`ForgeMirrors`:

- create/get/update organization mirror;
- bind repository;
- transition states;
- enqueue idempotent operation;
- claim/retry/complete operation;
- record/resolve conflict;
- list organization status;
- pause/resume;
- schedule reconciliation.

### Supervision

`ForgeMirrors.Application`:

```text
ForgeMirrors.TaskSupervisor
ForgeMirrors.OperationReconciler
ForgeMirrors.OutboxDispatcher
ForgeMirrors.PeriodicReconciler
```

Use bounded tasks, durable leases, and no process per repository.

### Concurrency

- one active state-changing operation per repository mirror;
- multiple repositories can progress concurrently;
- organization inventory operations serialize per organization mirror;
- expired leases are claimable after restart.

### Tests

- all state transitions;
- invalid transition constraints;
- duplicate dedupe keys;
- concurrent claims;
- pause/resume;
- crash after claim;
- crash after external-effect marker but before completion;
- per-repository serialization.

## PR 5 — GitHub App authentication and installation lifecycle

### Objective

Replace PAT assumptions for permanent organization connections.

### Configuration

Add validated runtime configuration:

```text
FORNACAST_GITHUB_APP_ID
FORNACAST_GITHUB_APP_SLUG
FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE
FORNACAST_GITHUB_WEBHOOK_SECRET
FORNACAST_GITHUB_WEBHOOK_MAX_BYTES
```

Prefer a mounted key file over multiline environment data.

### Provider APIs

`ForgeGitHub.AppAuthentication`:

- create short-lived App JWT;
- list/read installation;
- create installation token;
- normalize token metadata;
- redact inspect output.

`ForgeGitHub.InstallationTokenBroker`:

- cache by installation and effective permission/repository subset;
- refresh before expiry;
- single-flight concurrent refresh;
- invalidate on 401, revocation, or installation events;
- never persist tokens.

### Persistence

Add `github_app_installations`, or fold provider installation data into the organization mirror only if ownership remains clean.

### Tests

- JWT claims and clock skew;
- token refresh/single-flight;
- revoked installation;
- changed repository selection;
- token values of arbitrary valid length;
- secret redaction.

## PR 6 — Webhook ingress and durable inbox

### Objective

Accept GitHub App events safely and quickly.

### API route

Add a dedicated route outside ordinary API-key authentication:

```text
POST /api/webhooks/github
```

Use a raw-body plug before JSON decoding.

### Processing

1. enforce body bound;
2. verify `X-Hub-Signature-256`;
3. validate `X-GitHub-Delivery`, event, hook ID, and content type;
4. persist raw payload and routing metadata;
5. return `202 Accepted`;
6. let `ForgeMirrors` normalize/process asynchronously.

### Events

Implement installation/inventory events first:

- `installation`;
- `installation_repositories`;
- `repository`.

Other supported events may be durably stored as `pending_unsupported` until their processor lands, allowing bootstrap-time buffering.

### Tests

- official signature vector;
- modified payload rejection;
- constant-time comparison wrapper;
- duplicate GUID;
- redelivery with same GUID;
- body limit;
- invalid JSON after valid signature;
- DB failure returns non-2xx;
- request path performs no GitHub API call.

## PR 7 — Organization settings, inventory, and bootstrap handoff

### Objective

Deliver the first visible vertical slice: connect an organization, discover repositories, bootstrap them, and retain permanent bindings.

### Web UI

Add:

```text
/organizations/:organization/settings
/organizations/:organization/settings/github
```

Screens:

- not configured;
- installation pending;
- permission/repository-scope review;
- bootstrap configuration;
- bootstrap progress;
- active/partial/degraded status;
- repository table;
- recent operations/conflicts.

Use existing DuskMoon components and context-level authorization.

### Inventory

- list repositories accessible to installation;
- upsert by immutable GitHub repository ID;
- classify added, removed, renamed, archived, or access-revoked;
- paginate/checkpoint large organizations;
- schedule imports according to policy.

### Import credential abstraction

Introduce `ForgeImports.CredentialProvider` with implementations:

- saved PAT;
- one-time PAT;
- GitHub App installation token.

Rename internal variables from `pat` to `credential` where practical, but avoid unrelated public API churn.

### Handoff

After an import repository item is published:

- bind the local repository ID;
- copy import object mappings into permanent mirror-resource state;
- seed standard branch/tag baselines;
- mark buffered webhook deliveries eligible;
- run repository reconciliation;
- activate the repository mirror.

### Important limitation

Do not mark Git LFS or Releases capabilities active until their bootstrap paths are implemented. Capability state is independent, for example:

```text
git: active
issues: active
pulls: active
lfs: unavailable
releases: unavailable
```

### Release target

This PR completes the v0.3.0 foundation/preview milestone.

## PR 8 — Git synchronization primitives

### Objective

Add safe local and remote primitives without yet wiring every event source.

### `git_core`

Add bounded APIs/NIFs:

- `is_ancestor(path, ancestor_oid, descendant_oid, opts)`;
- `compare_and_delete_ref(path, full_ref, expected_oid, opts)`;
- validated internal tracking-ref operations;
- optional atomic multi-ref CAS if required by tests.

All APIs must respect existing ref limits, deadlines, and write-fence requirements.

### `GitCore.Remote`

Keep `mirror/refresh` for bootstrap. Add mirror-specific operations:

- fetch validated heads/tags into a caller-owned internal namespace;
- list observed remote refs;
- push one or more exact expected-state refs;
- delete remote ref with exact expected OID;
- no repository-config credential persistence;
- no unbounded redirect or protocol fallback.

Never use the existing force/prune refresh directly against public local refs for permanent two-way sync.

### Tests

Use local bare repositories as deterministic remotes:

- create;
- fast-forward;
- tag create;
- exact delete;
- stale remote expected OID;
- divergence;
- timeout/cancellation;
- credential cleanup;
- internal refs never advertised by ordinary clone/fetch.

## PR 9 — Bidirectional Git ref engine

### Objective

Wire inbox/outbox/reconciliation to the three-state ref algorithm.

### Inbound

- `push/create/delete` webhook enqueues a ref observation;
- fetch remote standard refs into tracking namespace;
- calculate `B/L/R`;
- ensure compatible result;
- apply under repository write fence with expected OID;
- update baseline atomically.

### Outbound

- consume local Git outbox events;
- coalesce refs per repository;
- re-read current local and remote refs;
- calculate `B/L/R`;
- push with expected remote OID;
- confirm baseline.

### Conflicts

Record:

- non-fast-forward divergence;
- tag retarget;
- delete-versus-update;
- missing baseline;
- local ref changed during operation.

Do not provide automated force resolution in this PR.

### Recovery tests

Inject crashes:

- after remote fetch;
- after local CAS;
- after remote push response but before DB completion;
- during baseline update;
- during outbox acknowledgement.

The reconciler must converge or create one explicit conflict.

## PR 10 — Neutral blob store and local Git LFS protocol

### Objective

Build the local LFS service independently of GitHub mirroring.

### Storage extraction

Move/generalize the existing release asset CAS implementation into `forge_blobs` while preserving behavior and tests. `forge_releases` and `git_lfs` depend on `forge_blobs`; `git_lfs` must not depend on `forge_releases`.

### `git_lfs`

Add:

- LFS object schema and repository reachability mapping;
- staging/commit/verify APIs;
- Batch endpoint;
- Basic download/upload actions;
- range reads where supported;
- scoped expiring transfer authorization;
- SSH `git-lfs-authenticate` support.

### Routes

Add LFS routes before generic Git repository routes:

```text
POST /:owner/:repo.git/info/lfs/objects/batch
GET  /:owner/:repo.git/info/lfs/objects/:oid
PUT  /:owner/:repo.git/info/lfs/objects/:oid
POST /:owner/:repo.git/info/lfs/objects/:oid/verify
```

### Tests

- standard LFS pointer parsing;
- upload/download with official Git LFS client;
- SHA-256 mismatch;
- size mismatch;
- interrupted upload recovery;
- authorization isolation;
- dedupe across repositories;
- SSH discovery/auth;
- repository deletion does not prematurely delete shared objects.

## PR 11 — GitHub LFS synchronization

### Objective

Make Git and LFS publication atomic at the synchronization-policy level.

### Provider client

Implement GitHub LFS Batch/Basic interactions with:

- trusted Batch endpoint;
- validated action URLs;
- HTTPS only;
- no unsafe redirects;
- public-address DNS policy;
- bounded streaming;
- expiry handling;
- rate-limit/error classification.

### Pointer scanner

Add a bounded, checkpointed scanner for LFS pointers reachable from:

- all synchronized branch heads;
- all synchronized tags.

Persist scan cursors and discovered repository-object relationships.

### Ordering

Inbound worker:

```text
fetch -> scan -> download/verify missing LFS -> local ref CAS -> confirm
```

Outbound worker:

```text
scan -> verify local objects -> upload/verify missing remote LFS -> remote push -> confirm
```

### Tests

- bootstrap with multiple branches and shared objects;
- incremental commit adds/removes pointers;
- retry after expired action URL;
- remote object absent;
- object corrupt;
- Git ref never confirms before object availability.

This completes v0.4.0.

## PR 12 — Issue synchronization

### Objective

Provide durable two-way issues, comments, labels, and assignees.

### Schema/domain work

- permanent resource mappings;
- canonical fingerprints;
- remote updated timestamps;
- local version tracking;
- origin/causation metadata;
- label mappings;
- comment mappings and tombstones.

### Producers

Add outbox recording to the same transactions as:

- issue create/update/state change;
- comment create/update/delete;
- label relationship changes;
- assignee relationship changes.

### Provider mutations

Add GitHub create/get/update endpoints and list-by-update-time reconciliation.

### Idempotent creates

GitHub create APIs do not supply a general client idempotency key. Implement a deterministic recovery strategy. Recommended:

- append a hidden, namespaced correlation marker for outbound-created issue/comment bodies;
- strip the marker from local rendered content;
- on ambiguous timeout, search/refetch and recover the mapping before retrying;
- if multiple candidates match, create a conflict rather than duplicate.

Document this product-visible source-format behavior.

### Conflict rules

- scalar text/state: three-way comparison;
- labels/assignees: baseline set delta;
- comments: provider identity plus update/delete version.

## PR 13 — Pull-request synchronization

### Objective

Synchronize supported same-repository pull requests.

### Local model changes

Add as needed:

- draft state;
- explicit head-repository identity;
- read-only external-head capability;
- remote merge/version metadata in mirror resource state, not the core PR schema where provider-specific.

### Git integration

- maintain internal PR head refs when needed;
- verify head/base OIDs against Git ref baseline;
- prevent metadata confirmation when required refs are missing.

### Merge coordinator

For mirrored PRs:

1. acquire repository mirror operation;
2. verify local and remote head/base SHAs;
3. choose the configured coordinator;
4. execute one merge;
5. fetch the resulting base ref and PR state;
6. apply/confirm locally;
7. complete one operation.

Cross-repository PRs without a mirrored head repository remain read-only.

## PR 14 — Release metadata domain

### Objective

Turn `forge_releases` into an actual domain before adding synchronization.

### Migration/schema

Add releases with:

```text
repository_id
tag_name
name
body
draft
prerelease
target_commitish
published_at
deleted_at
author_user_id / author_github_identity_id
timestamps
```

Add unique constraints appropriate to repository/tag identity and legal state transitions.

### Context/API/Web

Implement:

- list/show/create/update/delete;
- authorization;
- audit;
- GitHub-compatible API routes/serializers/validators;
- repository web UI where required;
- tag existence/consistency checks.

Do not implement release assets in this PR.

## PR 15 — Release import and synchronization

### Objective

Add Releases to bootstrap and incremental synchronization.

### Bootstrap

Extend metadata importer phases:

```text
labels
issues
comments
pull_requests
releases
number_sequence
```

Create import mappings and report unsupported fields/assets explicitly.

### Incremental

- handle `release` webhooks;
- emit local release outbox events;
- fetch canonical GitHub release;
- synchronize supported fields;
- require a confirmed tag baseline;
- resolve ambiguous outbound create by unique tag lookup.

This completes v0.5.0 collaboration scope.

## PR 16 — Full reconciliation, conflict UI, and hardening

### Objective

Make the feature operationally complete.

### Reconciliation

Implement checkpointed:

- installation repository inventory;
- repository metadata;
- all standard Git refs;
- issues/comments/labels/assignees;
- PRs;
- releases;
- LFS reachability/integrity.

### Conflict UI

Provide:

- filter by repository/resource/type;
- baseline/local/remote comparison;
- safe metadata resolutions:
  - accept GitHub;
  - keep Fornacast and push;
  - mark externally resolved and recheck;
- Git conflicts remain operator-resolved through explicit Git actions in v1.

### Webhook recovery

Because failed GitHub webhook deliveries are not automatically retried, add either:

- optional scheduled GitHub App delivery inspection/redelivery; or
- rely on full reconciliation and show webhook-delivery gaps.

The correctness contract must not depend on successful redelivery.

### Fault testing

Add deterministic faults for:

- API timeout after remote commit;
- duplicate/out-of-order webhook;
- token expiry/revocation;
- rate-limit wait;
- worker crash;
- DB disconnect;
- stale lease takeover;
- local write racing remote webhook;
- LFS partial/corrupt object;
- repository rename collision;
- permission downgrade.

## 6. Immediate next move

Do **not** begin with Git ref synchronization.

Start one coordinated implementation batch containing PRs 1–4, with PRs 2 and 3 developed in parallel:

### Track A — Provider extraction

- scaffold `forge_github`;
- move generic read client/transport;
- preserve importer tests;
- prepare mutation-capable request API.

### Track B — Event foundation

- implement `Fornacast.DomainOutbox`;
- integrate repository and Git write producers;
- prove transactionality and lease recovery.

### Track C — Mirror persistence

After Track B schema/API stabilizes:

- scaffold `forge_mirrors`;
- add permanent state tables;
- implement scheduler, leases, pause/resume, and conflict records;
- no GitHub side effects yet.

### Batch completion gate

The batch is complete when:

- existing one-time imports behave identically;
- a local repository/Git mutation emits exactly one durable event;
- a mirror operation can be claimed, crash, and recover;
- no new app dependency cycle exists;
- all PostgreSQL tests and production compilation pass.

Then proceed to GitHub App/webhook/settings as the next vertical slice.

## 7. Testing matrix

| Layer | Required tests |
|---|---|
| Schemas | changesets, transitions, constraints, uniqueness |
| PostgreSQL | concurrent claims, leases, SKIP LOCKED behavior, atomic outbox |
| Provider HTTP | auth, methods, pagination, rate limits, body bounds, DNS/redirect policy |
| Webhooks | signatures, GUID dedupe, ordering, redelivery |
| Git | local bare remotes, CAS, ancestry, delete, divergence, crash recovery |
| LFS | official client interoperability, integrity, streaming, authorization |
| Metadata | mappings, fingerprints, ambiguous create recovery, three-way conflicts |
| UI | owner/admin authorization, settings states, conflict actions |
| E2E | bootstrap then bidirectional incremental changes across all enabled capabilities |
| Recovery | kill worker/process at every durable boundary and restart |

## 8. Required verification commands

Use the repository’s pinned devenv/PostgreSQL workflow:

```sh
devenv processes up -d --strict-ports postgres
devenv processes wait --timeout 120

devenv shell -- mix deps.get
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- env PGPORT=55432 mix test
devenv shell -- mix assets.deploy
```

Add focused commands per app during development, but the full PostgreSQL suite remains mandatory before merge.

## 9. Review checkpoints

Architecture review is required before merging:

1. generic outbox schema/API;
2. permanent mirror state model;
3. GitHub App secret/token boundary;
4. remote Git fetch/push safety model;
5. LFS action-URL egress policy;
6. metadata create-idempotency strategy;
7. PR merge coordination;
8. release/tag consistency.

## 10. Completion definition

Organization synchronization is not complete merely because webhooks update local rows.

The feature is complete only when:

- bootstrap and permanent lifecycle are separate;
- both sides can originate supported changes;
- every side effect has durable intent and idempotent recovery;
- Git uses exact expected OIDs and explicit divergence;
- LFS object availability is ordered before ref confirmation;
- metadata uses immutable mappings and confirmed fingerprints;
- missed webhooks are repaired by reconciliation;
- conflicts are visible and never silently overwritten;
- wiki and release assets remain excluded;
- the complete PostgreSQL, Git, LFS, webhook, and E2E recovery matrix passes.
