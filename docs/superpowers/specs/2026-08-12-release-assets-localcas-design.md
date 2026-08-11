# Release Assets on Embedded LocalCAS

**Date:** 2026-08-12
**Status:** Design approved in discussion; awaiting written-spec review
**Scope:** Release-asset byte storage only

## Context

The approved GitHub-compatible releases plan defines an opaque
`ForgeReleases.AssetStorage` boundary backed by one ID-addressed file per
asset. The ExStorageService v0.6.2 embedding probe subsequently proved that:

- the Hex-published core can be supervised inside Fornacast;
- LocalCAS stage, commit, stat, ranged open, and verify survive a fresh BEAM
  restart;
- the existing Concord Turso ConfigStore can coexist with Concord's singleton
  VSR engine; and
- the optional S3 application works only through a same-source dependency and
  is not needed for release assets.

LocalCAS is content-addressed, so it cannot safely replace the planned
path-per-asset implementation mechanically. Identical assets share one
SHA-256-addressed blob. Fornacast therefore needs a digest-level publication
and garbage-collection fence while keeping release metadata and recovery in
its own SQL database.

This specification supersedes only the storage, upload, deletion, and recovery
parts of
`docs/superpowers/plans/2026-07-21-github-api-releases.md`. Its release model,
authorization, API compatibility, tag policy, quotas, audit requirements, and
all other accepted behavior remain authoritative.

## Decision

Use `ExStorageService.BlobStore.LocalCAS` as a byte-store primitive behind a
Fornacast-owned adapter. Fornacast SQL remains the only product metadata and
recovery authority.

The first product slice has these boundaries:

- LocalCAS stores immutable bytes and computes their SHA-256 digest and size.
- `ForgeReleases` owns assets, durable operations, blob inventory, leases,
  recovery, garbage collection, authorization, and audit.
- ESS ObjectService, buckets, object metadata, packing, lifecycle workers, and
  garbage collectors are not used.
- The S3 application is not a dependency and no storage listener is started.
- Physical blob reclamation is delayed and reference-aware. User-visible
  deletion remains immediate.

## Goals

- Stream uploads up to the existing hard limit of 2 GiB without object-sized
  buffering or a second normal-path disk copy.
- Preserve crash recovery across request staging, CAS publication, metadata
  visibility, logical deletion, and physical garbage collection.
- Deduplicate identical content without allowing one asset deletion to damage
  another asset.
- Keep ESS structs, filesystem paths, and raw errors behind the storage
  adapter.
- Support both Turso and PostgreSQL without database-specific locks.
- Retain the releases plan's opaque download handle, bounded reads, deadlines,
  quotas, authorization, and audit semantics.

## Non-goals

- An S3 listener or S3 dependency.
- Git LFS, packages, or a generic forge-wide object-store API.
- ESS ObjectService metadata as a second product authority.
- Shared-root multi-node writers, horizontal replicas, or rolling writers.
- Migration of existing release assets; `forge_releases` has not yet been
  implemented.
- Automatic repair of corrupt content.

## Architecture and ownership

`ForgeReleases` is the sole domain owner. It depends directly on the exact Hex
package `{:ex_storage_service, "== 0.6.2"}` and exposes no ESS type through its
public API.

The storage boundary consists of focused modules:

- `ForgeReleases.AssetStorage` defines the domain-facing contract.
- `ForgeReleases.AssetStorage.LocalCAS` translates that contract to public
  LocalCAS functions and normalizes errors.
- `ForgeReleases.AssetStorage.Supervisor` owns the explicit ESS instance and
  storage readiness.
- `ForgeReleases.AssetStorage.Manager` monitors that instance, records
  readiness, and performs bounded-backoff runtime restart attempts.
- `ForgeReleases.BlobGC` performs bounded, leased reclamation using the SQL blob
  inventory.
- `ForgeReleases.Recovery` remains the durable operation reconciler and also
  cleans operation-owned staging directories.

All LocalCAS calls receive adapter-owned options containing explicit roots,
`pack_module: nil`, and no `:bucket`. This prevents packed-blob metadata lookup
and legacy bucket fallback. `pack_module: nil` is code-supported but not yet a
documented public embedding option, so it is exact-pinned, contract-tested, and
tracked by
[upstream issue #14](https://github.com/gsmlg-opt/ex_storage_service/issues/14).
No callsite outside the adapter may invoke LocalCAS.

ESS starts as an OTP dependency before `ForgeReleases`, so application
configuration must disable its default instance before dependency startup.
`ForgeReleases.Application` later supervises exactly one named instance with
the same validated options.

The storage subtree reports readiness independently. Invalid configuration or
unwritable roots fail initial boot. The ESS child runs under a dynamic
supervisor with its child spec overridden to `restart: :temporary` and a
30-second shutdown. The manager monitors it and retries runtime startup with
bounded exponential backoff; failed attempts update readiness but do not crash
the application supervisor. After a successful boot, request-time I/O faults
make release-asset operations return `{:error, {:unavailable,
:asset_storage}}`; unrelated repository and Git operations remain available.

## Configuration and supervision

Every environment configures `:ex_storage_service` before applications start.
The lifecycle and worker flags must be nested under `instance_config`; ESS
ignores those flags if they are placed at the top level. The configuration has
this shape, with environment-specific absolute roots:

```elixir
config :ex_storage_service,
  data_root: asset_root,
  blob_root: Path.join(asset_root, "cas"),
  tmp_root: Path.join(asset_root, "tmp"),
  ra_root: Path.join(asset_root, "ra"),
  metadata_root: Path.join(asset_root, "concord"),
  instance_config: [
    instance: :fornacast_release_assets,
    mode: :standalone,
    node_role: :data,
    auto_start: false,
    web_enabled: false,
    public_s3_enabled: false,
    cluster_data_plane_enabled: false,
    workers: %{
      multipart_gc: false,
      content_gc: false,
      cas_gc: false,
      packer: false,
      lifecycle: false,
      cross_cluster_replication: false,
      repair: false,
      scrub: false
    }
  ]
```

Standalone data mode derives `internal_transport_enabled: false`; it is not an
accepted configuration override. The explicit child is built from
`ExStorageService.InstanceConfig.from_application_env/0`, preventing its roots
or flags from drifting from the values read during dependency startup.

The dedicated release-asset root remains configurable through
`FORNACAST_RELEASE_ASSET_STORAGE_ROOT`:

- development: `tmp/release-assets`;
- test: `tmp/test/release-assets`;
- production container: `/data/release-assets`.

CAS and temporary roots are children of that root and must share a filesystem.
The adapter validates containment, writability, and same-filesystem publication
at boot. `FORNACAST_RELEASE_ASSET_MAX_BYTES` remains a positive decimal integer
clamped to the immutable 2,147,483,648-byte hard maximum. Its parsed, clamped
value is the effective limit passed to every request and recovery staging call;
the hard ceiling is not substituted when an operator configures a lower limit.

`FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS` defaults to 86,400 seconds and must
not be lower than 3,600 seconds. The default exceeds the 30-minute maximum
download lifetime and gives backup and operational tooling time to observe an
unreferenced blob before deletion.

Concord 3 uses the already-probed singleton VSR shape: `cluster_enabled: true`,
group ID `:ex_storage_service_metadata`, replica ID `node()`, one member whose
ID and endpoint are `node()`, file storage, `bootstrap: false`, and a dedicated
data directory below the release-asset root. The single-node deployment must
retain the same Erlang node identity and VSR path across restarts.

```elixir
config :concord,
  cluster_enabled: true,
  data_dir: Path.join(asset_root, "concord"),
  vsr: [
    group_id: :ex_storage_service_metadata,
    replica_id: node(),
    members: [%{id: node(), endpoint: node()}],
    storage: :file,
    bootstrap: false
  ],
  turso: fornacast_config_store_options
```

`Fornacast.ConfigStore` continues to call `Concord.Turso` with its separate
database; release assets do not call ESS metadata APIs. One Concord supervision
tree therefore owns the VSR engine required by ESS and the independent Turso
ConfigStore engine.

### Lease ownership extension

The storage flow spans SQL transitions and potentially long filesystem work.
Before release implementation, extend `Fornacast.OperationLease` with these
portable owner-guarded operations:

- `renew_owned/3` extends expiry and increments `lock_version` while retaining
  the same owner;
- `update_owned/4` applies a nonterminal state change, retains the owner, sets a
  new expiry, increments `lock_version`, and returns the refreshed row; and
- the existing releasing `update_owned/3` or `release/2` is used only in the
  terminal transaction or explicit handoff.

Both new operations condition on ID, current owner, current lock version, and
an unexpired lease. Callers thread the returned row; they never reuse a stale
owner/version handle. This contract is implemented with conditional updates,
not row locks, and receives Turso and PostgreSQL tests.

Potentially long commit, verify, recovery-copy, and physical-delete calls run
in monitored tasks with fixed deadlines. The owning coordinator renews the SQL
lease while the task is alive. On the same BEAM, recovery cannot claim an
expired row until the prior task's `:DOWN` is observed. On a fresh BEAM the old
task cannot survive. Losing ownership leaves the durable operation for the new
owner; the stale caller performs no cleanup or later state transition.

## Persistence model

### Release assets

The planned `release_assets.storage_path` column becomes
`release_assets.storage_key`. It is opaque to callers. For this adapter it is
the lowercase 64-character SHA-256 digest and must equal the asset's explicit
`sha256_digest` integrity field. It is indexed for reachability checks, and the
adapter-aware migration adds an equality check where the database supports it.

The available-state invariant remains: `size`, `sha256_digest`, and
`storage_key` are all non-null before an asset can become visible.

### Release asset operations

`release_asset_operations` remains the crash-recovery journal. Upload
operations store:

- a server-created logical staging key derived from operation ID and a random
  attempt token;
- immutable observed size and SHA-256 after request EOF;
- the final digest storage key;
- request and sanitized failure metadata; and
- lease owner, lease expiry, lock version, and timestamps.

The upload states retain the existing plan's names with stronger invariants:

- `staging`: quota and name are reserved; the request may be absent or partial;
  digest, size, and final key are null.
- `staged`: EOF was observed and immutable digest and size are durable; CAS
  publication is unknown; the asset remains invisible.
- `metadata_ready`: the CAS blob is ready and the pending asset has its size,
  digest, and storage key.
- `completed`: the asset is available and its audit event is durable.
- `failed`: compensation removed the invisible asset and released quota exactly
  once while preserving sanitized evidence.

Delete operations continue to use `deleting -> deleted` and never perform
inline CAS deletion.

### Blob inventory

Add `release_asset_blobs`, with one retained row per digest:

- unique lowercase SHA-256 digest;
- immutable non-negative `:bigint` size;
- state;
- nullable `gc_after`;
- nullable sanitized integrity failure;
- lease owner and expiry;
- lock version and UTC timestamps.

Blob states are:

```text
absent -> pending -> ready -> candidate -> deleting -> absent
candidate -> pending
pending | ready -> corrupt
```

Rows are tombstones and are never deleted. Retaining `absent` prevents digest
ABA: a stale cleanup observation cannot be mistaken for a later publication of
identical content.

Reachability is derived from indexed pending, available, or deleting asset rows
and nonterminal operations carrying the digest. There is no mutable reference
counter. This avoids counter drift and exactly-once decrement problems after
crashes.

Every new digest attachment must conditionally update the corresponding blob
row and increment its `lock_version` in the same transaction that persists the
digest on the operation or asset. This includes attachment to an already
`ready` blob, whose state remains `ready`. `absent`, `pending`, and `candidate`
become or remain `pending`; `deleting` makes the whole attachment transaction
roll back for bounded retry; `corrupt` fails closed. A candidate is never
promoted directly to ready because it may have originated from an unpublished
pending blob. The attachment also requires `lease_owner IS NULL`; it waits on
any non-null blob lease even when that lease is expired. Only
`OperationLease.claim/5` may reclaim and resolve an expired owner.

Candidate and deletion claims use one conditional SQL update that rechecks
reachability and the prior blob lock version. An attachment that wins first
therefore invalidates the GC update; a deletion claim that wins first blocks
the attachment. The protocol is portable across Turso and PostgreSQL and does
not rely on an anti-join observation outside the conditional update.

## Domain and adapter API

The release domain keeps reservation separate from body consumption:

```elixir
@spec begin_asset_upload(repository(), release(), map(), map(), map()) ::
        {:ok, upload()} | {:error, error_reason()}

@spec stream_asset_upload(upload(), reader(), reader_state()) ::
        {:ok, asset(), reader_state()} | {:error, error_reason(), reader_state()}

@spec abort_asset_upload(upload(), error_reason()) :: :ok
```

The API adapter owns the concrete reader state. Authentication plugs consume
and remove the Authorization header and discard the PAT before constructing a
redacted state containing only what body reading needs. `ForgeReleases` treats
the state as an opaque term: it may pass it to the reader and return the updated
value, but may not inspect or log it. Safe request metadata remains a separate
explicit argument.

The reader returns `{:more, binary(), state}`, `{:ok, binary(), state}`,
`{:done, state}`, or an error tuple carrying the latest state. The release
orchestrator, not the arbitrary reader callback, owns total/idle deadlines,
byte accounting, monitored tasks, and lease renewal. The final reader state is
always returned so the controller continues with the latest connection.

The previous planned `write_asset_chunk/2` and `finish_asset_upload/1` APIs are
removed. `upload()` remains opaque and redacts lease, deadline, and staging
details from `Inspect`.

`stream_asset_upload/3` consumes ownership of the upload handle. Before
returning a normal reader, timeout, overflow, or staging error, it performs the
owner-guarded compensation exactly once. Ambiguous publication or lost
ownership leaves a nonterminal operation for recovery and returns an
unavailable error without compensating. `abort_asset_upload/2` is valid only
when streaming never began; a controller never calls it after
`stream_asset_upload/3` returns. This avoids attempting cleanup with the stale
owner/version originally returned by `begin_asset_upload/5`.

If the compensation transaction itself is unavailable, the caller does not
claim cleanup succeeded. It leaves the durable nonterminal operation and
contained staging directory for recovery, then returns the normalized
unavailable error.

The adapter contract is digest-oriented:

```elixir
stage_from_reader(staging_key, reader, state, options)
commit(staged_ref)
discard(staged_ref)
stat(storage_key)
open(storage_key, expected_size, range)
verify(storage_key)
delete(storage_key)
```

`staged_ref` is opaque and runtime-only. It may be handed to the monitored
commit task but is never persisted or returned to the release context. No ESS
staging path or struct crosses that boundary.

The adapter normalizes internal results to a small state-machine algebra:

```text
not_found | entity_too_large | invalid_source | integrity_mismatch |
ambiguous_commit | busy_deleting | unavailable
```

It preserves enough meaning for the domain to retry, compensate, retain a
`staged` operation, or mark corruption, while discarding raw ESS and filesystem
reasons. `open/3` opens the descriptor first and compares `fstat` size to
`expected_size` before returning the opaque download source.

## Upload flow

1. Authorize the repository and release, reserve the asset name and quota, and
   create a leased `staging` operation in one SQL transaction. No request byte
   is read before this succeeds.
2. Create a new contained staging directory from the operation ID and a random
   attempt token. Client filenames never appear in storage paths.
3. Call `LocalCAS.stage_from_reader/3` with that directory and the configured
   effective limit, which is never above 2 GiB. The release orchestrator
   enforces the 30-second idle and 30-minute absolute deadlines and renews the
   operation lease before half-life as reader progress occurs.
4. At EOF, use `OperationLease.update_owned/4` in a transaction to retain the
   request owner while persisting `staged`, observed size, digest, final key,
   and the blob inventory row. Every attachment conditionally touches and
   increments the blob row version, including `ready -> ready`. `absent`,
   `pending`, or `candidate` becomes or remains `pending`; a size mismatch or
   `corrupt` row fails closed. A `deleting` row rolls back the entire
   attachment for bounded retry without publishing bytes. Any non-null blob
   lease also rolls back the attachment until its owning or recovery task
   resolves it.
5. Run `LocalCAS.commit/2` in a monitored, deadline-bounded task while the
   coordinator renews the retained lease. Concurrent identical uploads are
   safe whether the second commit verifies an already-present blob or both
   writers observe absence and atomically publish the same digest bytes.
6. After successful commit and size confirmation, atomically mark the blob
   `ready`, populate the pending asset's size, digest, and storage key, and use
   `OperationLease.update_owned/4` to move the operation to `metadata_ready`
   without releasing ownership.
7. In one final owner-guarded `Ecto.Multi`, make the asset available, append the
   deduplicated audit event, mark the operation `completed`, and clear its
   lease through the terminal releasing transition.
8. Remove operation staging directories only after the durable terminal
   transition. Return success only after `completed`.

The adapter removes its partial file on every ordinary reader, write, overflow,
or close error. Only abrupt owner death may leave one file in the primary
directory. Primary and lease-specific recovery directories are disjoint, and
terminal cleanup removes both without following symlinks.

A commit error is not immediately a failed upload. Rename can succeed before a
later directory-sync error, so an ambiguous result remains `staged` for
recovery.

## Download flow

`open_asset/3` authorizes an available asset and asks the adapter to resolve its
digest with `pack_module: nil`. The adapter compares the actual and recorded
sizes and opens the real file descriptor before returning the opaque
`AssetDownload`. It never returns a path to a controller.

`read_asset_chunk/2` retains the existing behavior:

- clamp each read to 1 MiB;
- enforce a 30-second rolling idle deadline and a fixed 30-minute total
  deadline;
- thread the updated opaque handle; and
- return `:eof` only after the recorded size has been consumed.

The controller closes the latest handle in `after` and never calls `send_file`.
Download count increments only after response completion following `:eof`.
New opens are rejected once logical deletion begins. On the supported Linux
deployment, an already-open descriptor remains readable even if a later GC
event unlinks the path; the GC grace is also longer than the maximum download
lifetime.

## Logical deletion and physical GC

Asset deletion remains immediate from the user's perspective:

1. Create the leased delete operation and conditionally change the available
   asset to `deleting` in one transaction.
2. The asset disappears from reads immediately but continues to count as a
   blob reference until metadata deletion completes.
3. Finish metadata deletion, quota/count adjustment, audit, and the terminal
   operation transition through the existing idempotent boundary.
4. Do not call LocalCAS delete in the foreground.

Release deletion applies the same logical boundary to every asset. The release
is hidden first; each asset is moved through its durable deleting operation and
retains reachability until its metadata transaction commits. Shared digests are
processed only once by later blob GC, regardless of whether duplicate content
was present in the deleted release or remains referenced by another release.
Recovery resumes the bounded per-asset loop before the release operation can
advance past `assets_deleted`.

This explicitly amends the earlier plan's completion vocabulary:

- asset operation `deleted` means its metadata, count adjustment, and audit are
  durable, not that shared CAS bytes are physically absent;
- release operation `assets_deleted` means every contained asset crossed that
  logical boundary; and
- a terminal API DELETE may leave an inventoried `ready` or `candidate` blob
  for delayed reclamation.

Such a blob is not an orphan: its retained ledger row and GC state make it
recoverable and observable. Acceptance tests prove a terminal deletion plus a
candidate blob survives restart and is eventually reclaimed.

`ForgeReleases.BlobGC` processes bounded batches:

1. A conditional update marks an unreferenced `ready` or orphaned `pending`
   blob `candidate` and sets `gc_after` to the configured grace deadline.
2. A new reference before deletion atomically touches the row, invalidates the
   GC version, and moves the candidate conservatively to `pending` until
   commit or verification proves it ready.
3. After the deadline, a worker claims the row, rechecks both asset and
   operation reachability, and transitions it to `deleting` while retaining
   ownership through `OperationLease.update_owned/4`.
4. While `deleting` is leased, a same-digest upload may stage bytes but cannot
   attach or commit; it retries after the bounded deletion.
5. The coordinator runs idempotent `LocalCAS.delete/2` in a monitored task,
   renews the lease while it is alive, then records `absent` and clears the
   lease. Missing bytes count as success.
6. A crash before or after unlink leaves a durable `deleting` row. Recovery
   repeats deletion and completes the tombstone transition.

The first release has one GC owner and one exclusive storage volume. Within the
BEAM, the scheduler does not reclaim an expired GC lease until the prior task's
`:DOWN` is observed. Every deletion task has a fixed deadline; the scheduler
terminates an over-deadline task, observes `:DOWN`, and only then permits lease
recovery. This remains true even when the SQL lease has expired, and ordinary
uploads never treat an expired non-null deletion lease as attachable. A fresh
BEAM has no surviving old task. Cross-node stale filesystem actors require an
upstream fencing or quarantine primitive and are out of scope.

## Upload recovery

Recovery claims only expired or unowned operations through the extended
`Fornacast.OperationLease` protocol and only after any registered local owner
task has emitted `:DOWN`.

- `staging`: never infer completeness. Remove the contained operation
  directories, delete the invisible pending asset, release quota once, and
  mark the operation `failed`.
- `staged`: first call `stat` and `verify` on the recorded digest in a monitored
  task while renewing the recovery lease. If a ready blob with the expected
  size exists, atomically populate the pending asset, mark the blob ready, and
  advance to `metadata_ready` without inspecting temporary files.
- `staged` with no ready blob: require exactly one contained regular file in
  the primary operation directory. Reject symlinks, nested entries, or multiple
  candidates. Open the regular file, confirm its descriptor size equals the
  persisted size and does not exceed the configured effective cap, then
  re-stream it through the adapter using `LocalCAS.stage_from_reader/3` and a
  bounded descriptor reader into a separate lease-specific recovery directory.
  Compare digest and size, then commit the newly returned opaque staged value
  in a monitored task.
- `staged` with a missing or invalid survivor: recheck the ready digest once to
  close a concurrent-commit race. If it remains absent, compensate the pending
  asset and quota once and mark the operation failed. Unexpected stage
  contents are never published.
- `staged` with an ambiguous recovery commit or transient I/O failure: retain
  `staged`, save only a sanitized failure class, and retry after lease expiry.
  A verified digest/size mismatch in an existing ready CAS blob marks the blob
  `corrupt`; it is never made visible.
- `metadata_ready`: verify the ready blob and idempotently finish visibility,
  audit, and `completed`. A transient verification failure remains
  nonterminal. Confirmed missing or corrupt content marks the blob `corrupt`,
  compensates the still-invisible asset, and marks the operation failed.
- terminal operations: clean both primary and lease-specific recovery
  directories without following symlinks.

Recovery never reconstructs `%ExStorageService.BlobStore.StagedBlob{}` and
never persists LocalCAS's private filename. Normal uploads write once; only
crash recovery may perform a second disk copy.

The pinned-version adapter contract test asserts that one interrupted
LocalCAS stage creates at most one regular file directly inside the supplied
empty `tmp_dir`. Recovery depends on that observable behavior only; it does not
depend on the private filename.

This recovery path is a temporary dependency workaround:

```elixir
# WORKAROUND(upstream): gsmlg-opt/ex_storage_service#13
```

[Upstream issue #13](https://github.com/gsmlg-opt/ex_storage_service/issues/13)
requests a documented API for recovering and committing a completed,
checksum-verified stage without reconstructing internal structs or copying the
file again. The workaround remains `needed`, not a blocker, and must be
contract-tested against the exact ESS pin.

Direct loose-CAS resolution has its own temporary dependency marker:

```elixir
# WORKAROUND(upstream): gsmlg-opt/ex_storage_service#14
```

[Upstream issue #14](https://github.com/gsmlg-opt/ex_storage_service/issues/14)
requests a supported public option that avoids pack and legacy metadata lookup.

## Integrity and error handling

- Validate every digest as lowercase 64-character SHA-256 before adapter use.
- Reject size or digest disagreement and mark the blob `corrupt`; never
  overwrite or auto-repair it.
- LocalCAS paths, ESS structs, raw filesystem reasons, request credentials, and
  authorization data never enter logs, audit metadata, or API responses.
- Validation and conflict errors retain the releases plan's existing tagged
  domain shapes. Storage I/O and readiness failures normalize to
  `{:error, {:unavailable, :asset_storage}}` and map to HTTP 503.
- Private repository authorization continues to collapse to not-found before
  storage lookup.
- Opening a blob checks size but does not hash the entire object on every
  download. A bounded Fornacast integrity audit uses `LocalCAS.verify/2` because
  ESS scrub is disabled.

## Operations and backup

The release-asset root, staging root, Ecto database, ConfigStore database, and
Concord VSR metadata form one recovery set. The first slice supports a cold,
quiesced backup rather than claiming live snapshot consistency:

1. stop the Fornacast BEAM through its bounded shutdown, which stops uploads,
   logical deletion, recovery, GC, integrity audit, ConfigStore, and VSR
   mutation;
2. while it remains stopped, snapshot or back up the Ecto database and copy the
   ConfigStore database, Concord metadata, CAS, and staging roots; and
3. restart only after every recovery-set member is durable.

Restore replaces every member while the BEAM is stopped and boots only after
the complete set is in place. The existing `/data` container volume contains
the production filesystem roots; an external PostgreSQL backup is taken in the
same stopped maintenance window.

Readiness and telemetry cover:

- explicit ESS instance and Engine availability;
- root writability and same-filesystem validation;
- disk bytes and inode pressure;
- counts of nonterminal upload/delete operations;
- blob counts by state;
- GC candidates, deletions, retries, and failures; and
- integrity audit failures.

Operators receive a bounded, dry-run-capable integrity/GC audit. Corruption is
reported for manual recovery from backup; no destructive automatic repair is
performed.

Deployment documentation states the first-release constraint explicitly: one
BEAM, one exclusive volume, and stop-before-start upgrades. S3 ports and
credentials do not exist in this slice.

## Verification requirements

Implementation is not complete until fresh evidence covers:

- LocalCAS adapter contract tests for stage, commit, retry, discard, stat,
  open, range, verify, delete, max size, containment, and normalized errors;
- crash injection after every persisted upload, logical deletion, and GC
  transition, with two recovery passes proving idempotence;
- owner-retaining lease renewal and state transitions on both database
  adapters, including lost-owner and stale-version rejection;
- concurrent identical uploads and deletion of one deduplicated asset while
  another remains downloadable;
- mandatory blob-version touches for every attachment, conservative
  `candidate -> pending` reactivation, upload-versus-GC fencing, ambiguous
  commit recovery, stale leases, and crash-before/crash-after unlink;
- a paused GC worker after ownership check, proving no reclaim or republish can
  occur until that local process emits `:DOWN`;
- a GC worker paused after claiming a candidate but before its owner-retaining
  transition, proving a same-digest upload remains unattached until the GC task
  emits `:DOWN` and its non-null lease is resolved;
- commit and recovery-copy tasks held across lease expiry or renewal failure,
  proving recovery waits for `:DOWN` and the stale caller neither removes
  staging data nor transitions SQL;
- recovery with a missing survivor, symlink, nested or multiple entries,
  oversized survivor, transient verification failure, and confirmed
  `metadata_ready` corruption, with two passes proving each branch idempotent;
- reader error, timeout, overflow, exception, and pre-stream abort paths proving
  exact-once compensation without credentials entering the domain;
- bulk release deletion with duplicate/shared digests, terminal logical delete
  across restart, and eventual GC;
- exact 2 GiB admission and one-byte overflow without allocating 2 GiB in
  memory, plus enforcement of an operator-configured lower limit;
- Turso and PostgreSQL focused suites without adapter-specific locking;
- fresh-BEAM ConfigStore Turso plus Concord VSR coexistence and restart;
- quiesced backup/restore of SQL, ConfigStore, Concord metadata, CAS, and
  staging roots;
- `mix deps.get --check-locked` with ESS exactly 0.6.2;
- a production Elixir 1.20/OTP 29 `mix release` and Docker boot/restart smoke;
  and
- release inspection proving `ex_storage_service` core is present,
  `ex_storage_service_s3` is absent, and no additional storage listener is
  bound; and
- supervision inspection proving all eight disabled ESS workers remain absent.

Supervision acceptance also kills the ESS child repeatedly after a successful
boot, verifies bounded shutdown and backoff, observes release-asset 503s while
unrelated Git operations remain available, then proves readiness recovery.

The earlier probes used Elixir 1.18.4/OTP 28, so they are feasibility evidence,
not a substitute for the production-toolchain acceptance run.

## Rollout gates

1. Revise the releases implementation plan to incorporate this storage model
   before creating `forge_releases`.
2. Implement and prove the Concord 3/ESS boot configuration plus the isolated
   LocalCAS adapter contract.
3. Add persistence, one-pass upload, recovery, download, logical deletion, and
   GC in the release-domain milestones.
4. Run both database adapters and the production release/Docker acceptance
   proof.
5. Keep S3 and Git LFS deferred to separate approved designs.

## References

- `docs/superpowers/specs/2026-08-07-ess-embedded-s3-probe.md`
- `docs/superpowers/plans/2026-07-21-github-api-releases.md`
- `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`
- [ExStorageService v0.6.2](https://github.com/gsmlg-opt/ex_storage_service/releases/tag/v0.6.2)
- [Upstream recovery API request #13](https://github.com/gsmlg-opt/ex_storage_service/issues/13)
- [Upstream direct-LocalCAS option request #14](https://github.com/gsmlg-opt/ex_storage_service/issues/14)
