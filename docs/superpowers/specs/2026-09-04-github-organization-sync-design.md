# PRD: GitHub Organization Two-Way Synchronization

- **Project:** Fornacast
- **Status:** Proposed
- **Target:** Post-v0.2.2
- **Reviewed baseline:** `main` at `e7680a2edd5d2e061db3a30f598db10ffe6f263f`
- **Primary owner:** Fornacast
- **Product area:** Organization administration, Git hosting, GitHub integration

## 1. Summary

Fornacast shall allow an organization owner to connect one local Fornacast organization to one GitHub organization and maintain a durable two-way mirror.

The first synchronization is a bootstrap import. It creates the local organization/repository bindings, imports the supported Git and collaboration data, establishes immutable object mappings, and records a confirmed synchronization baseline. Every later synchronization is incremental.

The supported synchronization surface is deliberately limited to:

- organization repository inventory and basic repository metadata;
- Git repositories: commits, objects, branches, and tags;
- Git LFS objects reachable from synchronized branches and tags;
- issues and their supported metadata;
- pull requests and their supported metadata;
- releases metadata.

Fornacast shall not synchronize GitHub wiki repositories, Actions, checks, Projects, Discussions, Packages, organization membership, teams, or release asset binaries.

## 2. Product decisions

1. **Import and synchronization are separate lifecycles.**
   `forge_imports` remains the bootstrap mechanism. A permanent mirror domain owns all work after bootstrap.

2. **The relationship is bidirectional, not primary/replica.**
   Neither GitHub nor Fornacast is globally authoritative. The system compares both sides against the last confirmed baseline.

3. **No silent last-write-wins behavior.**
   Compatible changes converge automatically. Incompatible concurrent changes become explicit conflicts.

4. **GitHub App installations are required for organization sync.**
   User PATs remain available for manual one-time imports, but a permanent organization mirror uses a GitHub App installation and short-lived installation tokens.

5. **Webhooks reduce latency; reconciliation provides correctness.**
   Every supported webhook is durably enqueued. Periodic inventory, Git-ref, and metadata reconciliation repairs missed, delayed, or out-of-order deliveries.

6. **Hard deletion is never propagated automatically at repository level.**
   Repository deletion creates a tombstone/orphan state requiring explicit administrative action.

7. **Force pushes are not automatically propagated.**
   Non-fast-forward changes are recorded as Git conflicts. Safe create, fast-forward, and exact-baseline deletion operations may synchronize automatically.

8. **Release metadata is synchronized; release assets are not.**

9. **Wiki refs are never fetched, published, or pushed.**

## 3. Problem statement

The current GitHub integration is a durable, restartable one-time importer. It does not create a permanent organization connection, process webhooks, observe local domain changes, maintain remote baselines, or reconcile two independently changing systems.

Users need Fornacast to remain a usable local forge while GitHub continues to be an active collaboration endpoint. A successful first import is insufficient because subsequent commits, issues, pull requests, releases, and LFS objects can be created on either side.

## 4. Goals

### G1 — Organization connection

An organization owner can connect a local Fornacast organization to a GitHub organization through a GitHub App installation.

### G2 — Bootstrap

The initial run imports every repository visible to the installation, subject to explicit selection policy, and establishes permanent repository bindings.

### G3 — Incremental repository synchronization

Repository creation, rename, description, visibility, default branch, and archived state converge where representable and safe.

### G4 — Incremental Git synchronization

Supported branch and tag changes converge in both directions without silently overwriting divergent history.

### G5 — Git LFS synchronization

Every LFS object reachable from a synchronized branch or tag is available from both endpoints before the corresponding ref is considered synchronized.

### G6 — Collaboration metadata synchronization

Supported issue, pull request, and release fields converge in both directions.

### G7 — Durable recovery

Process crashes, node restarts, API timeouts, duplicate deliveries, and out-of-order deliveries do not produce duplicate local resources or silently lose confirmed changes.

### G8 — Operational visibility

Organization owners can see mirror status, per-repository state, queued work, failures, conflicts, last webhook receipt, and last full reconciliation.

## 5. Non-goals

The first organization-sync release does not include:

- GitHub wiki synchronization;
- organization members, outside collaborators, or teams;
- GitHub Projects, Discussions, Actions, checks, deployments, or environments;
- GitHub Packages;
- release asset binaries;
- Git LFS locking;
- submodule repository recursion;
- automatic propagation of non-fast-forward Git updates;
- automatic hard deletion of repositories;
- pull-request review submissions and review comments;
- full two-way support for pull requests whose head repository is outside the connected organization;
- preserving identical issue or pull-request numbers when both sides create objects independently.

## 6. Terminology

- **Organization mirror:** Permanent connection between one Fornacast organization and one GitHub organization.
- **Repository mirror:** Permanent binding between one local repository and one GitHub repository, identified by immutable IDs.
- **Bootstrap:** First full import that creates local data and confirmed baselines.
- **Confirmed baseline:** Last state known to have been represented successfully on both sides.
- **Inbox:** Durable queue of authenticated GitHub webhook deliveries.
- **Outbox:** Durable queue of local domain events committed atomically with local mutations.
- **Reconciliation:** Periodic comparison of canonical current state, independent of webhook delivery.
- **Conflict:** Both sides changed incompatibly relative to the confirmed baseline.
- **Origin:** The side that produced a mutation: `fornacast`, `github`, or `system`.
- **Capability:** A synchronization domain such as Git, LFS, issues, pulls, or releases.

## 7. Users and permissions

### Organization owner

Can:

- connect or disconnect the GitHub organization;
- start bootstrap;
- pause or resume synchronization;
- trigger reconciliation;
- inspect all repository states and conflicts;
- resolve supported metadata conflicts;
- change repository-selection and synchronization policy.

### Organization member

Can view synchronization health for repositories they can access, but cannot change connection or synchronization policy.

### System administrator

Can perform all owner operations and inspect provider-level failures without gaining access to plaintext credentials or webhook secrets.

Authorization must use the existing organization ownership/administration domain rules. Controllers must not implement independent role checks.

## 8. Scope matrix

| Domain | GitHub → Fornacast | Fornacast → GitHub | First-release notes |
|---|---|---|---|
| Organization connection | Yes | N/A | One GitHub App installation per local organization |
| Repository inventory | Yes | Yes | New local repositories create GitHub repositories when enabled |
| Repository metadata | Yes | Yes | Name, description, visibility, default branch, archived state |
| Git branches | Yes | Yes | Create, fast-forward, exact-baseline delete |
| Git tags | Yes | Yes | Create and exact-baseline delete; retargeting is a conflict |
| Git history/objects | Yes | Yes | Only objects reachable from synchronized standard refs |
| Git LFS | Yes | Yes | Batch API and Basic transfer; SHA-256 integrity |
| Issues | Yes | Yes | Title, body, state, state reason, labels, assignees |
| Issue comments | Yes | Yes | Create/update/delete with durable identity mapping |
| Pull requests | Yes | Yes | Core metadata for same-repository PRs |
| PR merge | Yes | Yes | Coordinated operation with expected head/base state |
| Fork/cross-repo PR | Read-only or conflicted | No | Must be explicit in UI |
| Releases | Yes | Yes | Tag, title, body, draft, prerelease, publication state |
| Release assets | No | No | Excluded |
| Wiki | No | No | Excluded, including wiki refs |

## 9. Functional requirements

### 9.1 GitHub App configuration

#### FR-001 Operator configuration

The Fornacast instance shall accept GitHub App configuration through deployment secrets:

- App ID;
- App private key or mounted private-key path;
- App slug/name;
- webhook secret;
- installation callback URL derived from the canonical Fornacast base URL.

The private key and webhook secret shall not be stored in ordinary domain tables or logs.

#### FR-002 Installation token broker

The provider layer shall mint short-lived installation tokens on demand, cache them only until shortly before expiration, and never persist them in repository configuration.

Token handling shall not assume a fixed token length or token prefix.

#### FR-003 Least-privilege validation

Before bootstrap, Fornacast shall verify that the installation can perform all enabled capabilities. At minimum, full two-way mode normally requires:

- repository Metadata read;
- Contents read/write;
- Issues read/write;
- Pull requests read/write;
- Administration write when local repository creation or repository metadata propagation is enabled.

The settings page shall show missing permissions and refuse activation of an unsupported capability.

### 9.2 Organization settings

#### FR-010 Routes

Add organization-scoped settings routes under a non-ambiguous prefix:

```text
GET    /organizations/:organization/settings
GET    /organizations/:organization/settings/github
POST   /organizations/:organization/settings/github/install
GET    /organizations/:organization/settings/github/callback
PATCH  /organizations/:organization/settings/github
POST   /organizations/:organization/settings/github/bootstrap
POST   /organizations/:organization/settings/github/reconcile
POST   /organizations/:organization/settings/github/pause
POST   /organizations/:organization/settings/github/resume
DELETE /organizations/:organization/settings/github
GET    /organizations/:organization/settings/github/conflicts
```

#### FR-011 Connection view

The page shall show:

- connected GitHub account and immutable account ID;
- installation ID and repository selection (`all` or `selected`);
- granted permissions;
- enabled capabilities;
- organization-mirror state;
- repository counts by state;
- last webhook and reconciliation timestamps;
- outstanding operations and conflicts;
- controls for bootstrap, pause/resume, reconcile, and disconnect.

#### FR-012 Repository policy

The owner can configure:

- synchronize all installation-visible repositories or selected repositories;
- automatically import newly visible GitHub repositories;
- automatically create GitHub repositories for new local repositories;
- enabled capability set;
- repository-deletion policy;
- conflict notification policy.

An installation configured for selected repositories must be displayed as partial coverage, not as a complete organization mirror.

### 9.3 Webhook ingestion

#### FR-020 Public ingress

Expose a dedicated GitHub App webhook endpoint on the public API surface. It shall:

1. read a bounded raw request body;
2. verify `X-Hub-Signature-256` with constant-time comparison;
3. validate required GitHub headers;
4. insert the delivery durably using `X-GitHub-Delivery` as the deduplication key;
5. return a 2xx response immediately after durable enqueue.

Business processing must not occur in the HTTP request process.

#### FR-021 Supported events

The first release shall handle at least:

- `installation`;
- `installation_repositories`;
- `repository`;
- `push`;
- `create`;
- `delete`;
- `issues`;
- `issue_comment`;
- `pull_request`;
- `release`.

Unknown event/action combinations shall be recorded as ignored, not treated as fatal.

#### FR-022 Canonical refetch

Webhook payloads are notifications. Before applying a mutable resource, the worker shall fetch its canonical current state from GitHub unless the event represents an immutable deletion and contains sufficient identity evidence.

#### FR-023 Redelivery and ordering

Duplicate deliveries must be idempotent. Event order must not be assumed. Periodic reconciliation must repair deliveries that were never received.

### 9.4 Bootstrap and handoff

#### FR-030 Bootstrap lifecycle

Organization mirror states:

```text
pending_installation
ready_to_bootstrap
bootstrapping
catching_up
active
paused
degraded
conflicted
revoked
```

#### FR-031 Reuse importer

The bootstrap shall reuse `forge_imports` for repository discovery, conflict planning, staged Git import, supported metadata import, publication, recovery, and reporting.

`forge_imports` shall gain an internal installation-token credential provider. It shall not persist short-lived installation tokens.

#### FR-032 Buffer during bootstrap

Webhook ingestion shall be active before the import snapshot begins. Relevant deliveries received during bootstrap remain queued until the repository binding and baseline exist.

#### FR-033 Atomic handoff

For each repository, successful handoff shall:

1. confirm the published local repository;
2. create the permanent repository mirror;
3. copy/promote import mappings into permanent mirror mappings;
4. seed branch/tag baselines;
5. seed metadata fingerprints and remote versions;
6. replay buffered deliveries;
7. perform a full repository reconciliation;
8. transition the repository mirror to `active`.

Import tables remain historical bootstrap records and are not used as permanent synchronization state.

### 9.5 Repository inventory

#### FR-040 Immutable identity

Repository pairing must use local repository ID and GitHub repository ID, never owner/name alone.

#### FR-041 New GitHub repository

A newly visible GitHub repository shall create a `discovered` repository mirror and, when policy allows, start a bootstrap import into the connected local organization.

#### FR-042 New local repository

A local repository creation transaction shall emit a durable outbox event. When policy allows, the mirror creates the corresponding GitHub repository, records its immutable ID, and establishes the baseline.

#### FR-043 Rename and collisions

A remote rename may update the local slug only when the destination is available. A local rename may update GitHub only when the expected remote identity and version still match. Namespace collisions create conflicts.

#### FR-044 Repository deletion

Deletion or loss of installation access shall not physically delete the opposite copy. The binding becomes `orphaned`, `revoked`, or `tombstoned` and requires explicit owner action.

### 9.6 Git synchronization

#### FR-050 Ref scope

Synchronize only:

```text
refs/heads/*
refs/tags/*
```

Do not fetch or publish:

```text
refs/pull/*
refs/changes/*
refs/notes/*
refs/fornacast/*
wiki repositories
provider-internal refs
```

Internal pull-request refs may be fetched into a private internal namespace for PR processing but are never advertised as ordinary repository refs.

#### FR-051 Remote observation

A mirror fetch must place GitHub refs in a private tracking namespace or quarantine rather than force-fetching directly into public local branches/tags.

#### FR-052 Three-state comparison

For each ref, evaluate:

- confirmed baseline `B`;
- current local value `L`;
- current GitHub value `R`.

Automatic convergence rules:

- `L == R`: confirm the baseline;
- `L == B` and GitHub changed compatibly: apply inbound;
- `R == B` and local changed compatibly: push outbound;
- `L` is ancestor of `R`: fast-forward local;
- `R` is ancestor of `L`: fast-forward GitHub;
- both changed and neither contains the other: conflict;
- existing tag points to different objects: conflict;
- deletion propagates only when the opposite side still equals `B`.

#### FR-053 Expected-state writes

All local ref updates/deletes and remote pushes/deletes must include the exact expected previous OID.

#### FR-054 Force push

Non-fast-forward changes are never propagated automatically in the first release. They create a conflict and pause synchronization for that ref.

#### FR-055 Transactional outbound event

Successful local receive-pack bookkeeping shall atomically record a domain outbox event containing the repository identity and changed refs. HTTP/SSH request handlers shall not directly call GitHub.

### 9.7 Git LFS

#### FR-060 Local protocol

Implement the Git LFS Batch API and Basic transfer endpoints, including upload, download, and verify.

For SSH Git remotes, implement `git-lfs-authenticate` or an equivalent supported endpoint-discovery mechanism that returns a short-lived scoped LFS authorization.

#### FR-061 Storage

LFS objects shall use global content-addressed storage keyed by SHA-256, with repository reachability/authorization mappings stored separately.

#### FR-062 Integrity

Every object must be verified against declared size and SHA-256 before commit. Partial or failed transfers remain in staging and are recoverable or garbage-collected.

#### FR-063 Publication ordering

Inbound:

```text
fetch Git objects -> discover LFS pointers -> download and verify LFS objects
-> update public local ref
```

Outbound:

```text
discover LFS pointers -> verify local objects -> upload missing GitHub LFS objects
-> push Git ref
```

A ref shall not be marked synchronized while a required reachable LFS object is missing.

#### FR-064 Reachability

The LFS scanner shall process all objects reachable from synchronized branch/tag baselines using bounded, restartable checkpoints.

#### FR-065 Exclusions

LFS locking and release assets are not part of this capability.

### 9.8 Issues

#### FR-070 Supported fields

Synchronize:

- title;
- body;
- open/closed state;
- state reason where representable;
- labels;
- assignees with a known GitHub identity;
- issue comments.

#### FR-071 Identity

Store GitHub object ID/node ID and local issue ID. Issue numbers are display/routing values, not cross-system identity.

#### FR-072 Concurrent edits

Use the confirmed fingerprint as a three-way base:

- only local changed: push;
- only GitHub changed: apply;
- both changed to the same canonical value: confirm;
- both changed incompatibly: conflict.

Labels and assignees use set deltas against the baseline. Comments use immutable provider IDs plus edit/delete versions.

### 9.9 Pull requests

#### FR-080 Supported PRs

Provide full two-way metadata synchronization for pull requests whose head and base repositories are both represented by active repository mirrors and whose required refs are available.

#### FR-081 Supported fields

Synchronize:

- title/body/state through the canonical issue identity;
- draft state;
- head/base refs and SHAs;
- merge status and merge commit SHA;
- ordinary issue comments.

Review submissions, review comments, checks, and branch-protection evaluation are excluded.

#### FR-082 Cross-repository PRs

A PR whose head repository is not represented locally may be imported as read-only metadata. The UI must show that it cannot be fully synchronized.

#### FR-083 Merge coordination

A mirrored PR merge is a compound mirror operation. It must validate expected head and base SHAs before choosing one coordinator. The resulting Git commit and PR state must be fetched and confirmed on both sides before completion.

The implementation shall not independently create different merge commits on both systems.

### 9.10 Releases

#### FR-090 Release domain

Before release synchronization is enabled, `forge_releases` shall implement a real release metadata domain with repository ownership, validation, CRUD APIs, audit records, and soft-deletion semantics.

#### FR-091 Supported fields

Synchronize:

- tag name/reference;
- release name;
- body;
- draft;
- prerelease;
- target commitish where relevant;
- published timestamp/state.

#### FR-092 Tag consistency

A release is not synchronized unless its referenced tag is present and confirmed on both sides. Retargeted tags create conflicts.

#### FR-093 Assets

Release assets are ignored and never copied by the first release.

### 9.11 Outbox, operations, and reconciliation

#### FR-100 Generic domain outbox

Add a provider-neutral `Fornacast.DomainOutbox` API in the shared infrastructure app. Domain transactions record events without depending on `forge_mirrors`.

Every event contains:

- unique event ID/idempotency key;
- aggregate type and ID;
- event type;
- origin;
- causation/correlation IDs;
- bounded payload;
- insertion time.

#### FR-101 Durable mirror operations

Inbox and outbox events materialize idempotent mirror operations. Operations are leased, bounded, retryable, and recoverable after restart.

#### FR-102 Per-repository serialization

At most one state-changing mirror operation may execute for a repository mirror at a time. Independent repositories may run concurrently under configured limits.

#### FR-103 Periodic reconciliation

Run:

- organization installation/inventory reconciliation;
- repository metadata reconciliation;
- Git ref reconciliation;
- metadata reconciliation;
- LFS integrity/reachability reconciliation.

Reconciliation shall use cursors/checkpoints for large organizations.

#### FR-104 Failure classes

Classify at least:

- credential/installation revoked;
- permission missing;
- primary rate limit;
- secondary rate limit;
- network/transport;
- provider validation;
- local validation;
- stale baseline;
- Git divergence;
- LFS missing/integrity;
- namespace collision;
- unsupported resource.

Retry only retryable failures. Non-retryable failures become conflicts or degraded states.

## 10. Data model

The exact migration may be split, but the permanent model requires these concepts.

### `github_app_installations`

```text
id
github_installation_id
github_account_id
github_account_login
account_type
repository_selection
permissions
state
last_verified_at
inserted_at / updated_at
```

### `organization_mirrors`

```text
id
organization_id
provider
github_installation_id
github_account_id
github_account_login
state
capabilities
policy
bootstrap_import_run_id
last_webhook_at
last_reconciled_at
next_reconcile_at
lock_version
inserted_at / updated_at
```

Unique constraints:

- one active GitHub mirror per local organization;
- one active local binding per GitHub organization/installation.

### `repository_mirrors`

```text
id
organization_mirror_id
repository_id
github_repository_id
github_node_id
github_full_name
state
bootstrap_repository_item_id
last_inventory_at
last_synced_at
lock_version
inserted_at / updated_at
```

### `mirror_ref_states`

```text
repository_mirror_id
ref_name
ref_kind
confirmed_oid
last_local_oid
last_remote_oid
state
last_confirmed_at
lock_version
```

### `mirror_resource_states`

```text
repository_mirror_id
resource_kind
local_resource_type
local_resource_id
github_object_id
github_node_id
github_number
confirmed_local_version
confirmed_remote_updated_at
confirmed_fingerprint
state
lock_version
```

### `mirror_webhook_deliveries`

```text
delivery_guid
hook_id
event
action
installation_id
github_repository_id
signature_version
raw_payload
state
attempt_count
next_attempt_at
lease_owner / lease_expires_at
received_at / processed_at
failure_class
```

### `domain_outbox_events`

Provider-neutral shared outbox used by local domain transactions.

### `mirror_operations`

```text
organization_mirror_id
repository_mirror_id
kind
dedupe_key
state
cursor
attempt_count
next_attempt_at
lease_owner / lease_expires_at
failure_class
started_at / completed_at
```

### `mirror_conflicts`

```text
organization_mirror_id
repository_mirror_id
resource_kind
resource_identity
conflict_kind
baseline_snapshot
local_snapshot
remote_snapshot
state
resolution
resolved_by_user_id
resolved_at
```

### LFS tables

```text
lfs_objects
  oid_sha256
  size
  storage_key
  verified_at
  state

lfs_repository_objects
  repository_id
  oid_sha256
  first_seen_ref
  reachable
  last_reconciled_at
```

## 11. Architecture constraints

- PostgreSQL remains the authoritative domain database.
- Do not extend import-run tables into permanent mirror state.
- Do not add synchronization code directly to web/API controllers.
- Do not make `forge_repos`, `forge_issues`, `forge_pulls`, or `forge_releases` depend on `forge_mirrors`.
- Use the shared domain outbox to break dependency cycles.
- Keep provider transport/authentication in `forge_github`.
- Keep synchronization policy/state in `forge_mirrors`.
- Keep Git protocol/storage primitives in `git_core` and `git_transport`.
- Keep LFS protocol/storage in `git_lfs` and a neutral blob-storage boundary.
- Use repository write fences for every local Git ref mutation.
- Avoid one permanently running process per repository; use durable operations, leases, task supervisors, and bounded concurrency.

## 12. Non-functional requirements

### Reliability

- At-least-once inbox/outbox processing with idempotent effects.
- No acknowledged local mutation may be lost because a process crashes after database commit.
- No webhook is marked processed before its local transaction commits.
- Restart recovery must not require operator intervention for retryable failures.

### Security

- Webhook signatures verified before JSON decoding/business processing.
- Constant-time signature comparison.
- Installation tokens never logged or persisted.
- All remote URL/action handling uses HTTPS, redirect restrictions, bounded response sizes, DNS/private-address protections, and explicit timeouts.
- Git LFS action URLs returned by GitHub must pass a dedicated egress policy before use.
- Private-repository existence masking must remain intact.

### Performance

- Webhook ingress responds after durable enqueue and does not wait for GitHub API calls.
- Configurable bounded concurrency globally and per installation.
- Large organizations and LFS scans are cursor/checkpoint based.
- Repository-level state-changing operations are serialized.
- Backoff honors GitHub rate-limit information.

### Observability

Expose telemetry and health data for:

- inbox age/depth;
- outbox age/depth;
- operation duration/result;
- active leases;
- retry counts;
- rate-limit waits;
- repository state counts;
- Git conflicts;
- missing/corrupt LFS objects;
- last webhook/reconciliation timestamps.

## 13. Acceptance criteria

The feature is complete when all of the following pass:

1. An organization owner can install/connect a GitHub App and bind the correct GitHub organization.
2. Missing permissions and partial repository access are visible before bootstrap.
3. Bootstrap imports all enabled, supported resources and ends with active permanent bindings.
4. Webhooks received during bootstrap are replayed after the baseline is established.
5. A GitHub-created repository is imported according to policy.
6. A local organization repository is created on GitHub according to policy.
7. A local branch create/fast-forward reaches GitHub.
8. A GitHub branch create/fast-forward reaches Fornacast.
9. Safe branch/tag deletion propagates only from an unchanged baseline.
10. Divergent/non-fast-forward ref changes become visible conflicts and do not overwrite either side.
11. A repository containing LFS pointers can be cloned and checked out successfully from either endpoint after synchronization.
12. Missing/corrupt LFS objects block ref confirmation and produce a degraded state.
13. Supported issue and comment changes converge in both directions.
14. Supported same-repository PR changes converge in both directions.
15. A coordinated PR merge produces one confirmed Git result on both systems.
16. Release metadata converges and remains bound to a confirmed tag.
17. Release assets and wiki content are never synchronized.
18. Duplicate and out-of-order webhook fixtures do not duplicate resources or regress state.
19. A crash at each operation boundary recovers correctly after restart.
20. A full reconciliation repairs intentionally omitted webhook deliveries.
21. Pause prevents new effects while retaining durable queued work.
22. Disconnect/revocation stops token use and leaves local repositories intact.

## 14. Release strategy

### v0.3.0 — Organization sync foundation

- `forge_github`;
- `forge_mirrors`;
- GitHub App installation;
- organization settings;
- durable webhook inbox;
- generic domain outbox;
- inventory reconciliation;
- bootstrap handoff and permanent bindings.

This release may expose the mirror as `foundation/preview`; it must not claim complete two-way synchronization.

### v0.4.0 — Git and LFS mirror

- bidirectional safe Git ref synchronization;
- conflict recording;
- local LFS service;
- GitHub LFS transfer;
- ref/LFS publication ordering.

### v0.5.0 — Collaboration mirror

- issues/comments;
- same-repository pull requests;
- coordinated merge;
- release metadata domain and synchronization;
- full reconciliation and conflict UX.

## 15. Explicitly deferred decisions

These require a separate product decision rather than accidental implementation:

- automated force-push conflict resolution;
- automatic hard repository deletion;
- two-way cross-fork pull requests;
- PR reviews/review comments;
- release assets;
- LFS locking;
- organization members and teams;
- multi-provider mirrors.
