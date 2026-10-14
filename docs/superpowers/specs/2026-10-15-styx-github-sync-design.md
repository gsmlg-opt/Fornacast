# GitHub synchronization with Styx

The user selected Styx (`:styx`, `gsmlg-dev/styx`) and confirmed migration of
the complete GitHub organization synchronization chain, including discovery,
repository import/update, aggregation and status pages on 2026-10-15.

## Execution and durable business state

Styx 0.1.0 uses the existing PostgreSQL 17 `Fornacast.Repo`. It owns job
delivery, concurrency, scheduling, execution attempts and orphan recovery.
`PatSyncRun`, `ImportRun`, repository checkpoints and publication evidence
remain authoritative for business completion. A completed delivery does not
mean that an organization has finished synchronizing.

Use separate control, discovery, import, update and maintenance queues. Control work must
not perform long Git/LFS transfers. Existing repository updates get independent
durable result/lease records; their results are aggregated under run ownership.
Do not concurrently overwrite the same run progress map.

Enqueue initial work and stage continuations in the same short database
transaction as the business transition. Perform network/Git operations outside
database transactions. Job arguments contain identifiers and phase/version
markers, never PATs, decrypted
credentials, keyrings or arbitrary request bodies. Recheck authorization and
source identity before execution and publication.

Retain domain operation leases, cancellation checks, Git compare-and-swap,
publication journals and LFS-before-ref publication. Styx uniqueness is delivery
deduplication, not a replacement for write ownership. Keep the cleanup executor
separate; migrating the main import executor must preserve the GitHub App
inventory-import handoff and cancellation settlement.

## Retry and recovery

Return real execution errors to Styx so attempts and finite retry limits apply.
Use scheduled waiting/snooze for live leases, credential/resource contention or
provider rate limits; do not turn malformed-response errors into unlimited
snoozes. Persist safe error classification, retry timing and exhausted outcomes
in the domain projection. Failed child deliveries must eventually settle the
organization task rather than leave it running forever.

Keep a bounded maintenance job to enqueue missing work from authoritative
business records, aggregate terminal outcomes and admit due interval syncs.
Business leases and Styx timeouts/rescue thresholds must agree: recovery must
not create a second active writer while a legitimate long discovery or Git/LFS
operation is still running. Successful imports/checkpoints survive retry.

## Task interface

Sync admission returns an identified new or existing active run. Respond with
a 303 redirect to a canonical authorized GET task page. Provide run history and
a credential-free JSON status endpoint authorized for organization managers,
including other owners of the organization.

Render queued state immediately even before discovery produces a summary.
Show phase, repository outcomes, warnings, wait/error reason, next retry time,
request/start/finish times and last available progress. Poll an explicit status
URL; update headline, counts and actions together. Distinguish disconnected
status updates from task failures. Configuration checking uses POST/redirect/GET
and cannot become a polling URL.

Keep current content semantics explicit: first imports include supported
metadata; existing repositories refresh Git/LFS. Incremental updates of existing
issues, PRs and releases are outside this migration.

## Cutover and validation

Use the deployment's existing stop-before-start upgrade policy. Never run the
legacy import/PAT dispatch loops together with their Styx replacements. Do not
reset live leases. Bootstrap existing work immediately when claimable, or after
its current lease expires. PostgreSQL backups include `styx_jobs` and business
progress; a paired `fornacast-data` backup remains necessary.

Verify atomic admission/rollback, duplicate admission, independent repository
results, bounded failure retries, exhausted outcome aggregation, active lease
recovery, import/publication safeguards, empty initial progress, canonical check
redirects, authorization and terminal UI updates. Do not replay production sync
or deploy during implementation.
