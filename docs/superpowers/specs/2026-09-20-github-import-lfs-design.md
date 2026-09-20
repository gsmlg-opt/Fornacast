# GitHub import and synchronization: complete Git LFS objects

Status: approved by the user on 2026-09-20.

## Goal

A repository imported from GitHub must contain the LFS bytes required by every
imported branch and tag, including reachable history. A successful import must
support a subsequent LFS checkout from Fornacast. Ongoing GitHub synchronization
must preserve the existing rule that required LFS objects are available before
Git references are confirmed as synchronized.

This extends the one-time import design from 2026-08-25, which explicitly excluded
LFS bytes, and follows the object-availability ordering in section 9.7 of the
2026-09-04 GitHub organization-sync design.

## Current source findings

- `ForgeImports.RepositoryWorker` stages Git and metadata, then permits
  `ready_to_publish`. Its bounded default-tree scan records
  `unsupported_git_lfs`; it does not download the objects.
- `GitLFS.PointerScanner` already provides persistent bounded traversal,
  requirements, and repository reachability. `ForgeGitHub.LFS.TransferCoordinator`
  already transfers and verifies objects using the GitHub Batch/Basic protocol.
- `ForgeGitHub.LFSSync` is coupled to mirror operations. One-time imports must
  reuse the scanner and transfer coordinator without creating permanent mirror
  records or pretending to be mirror operations.
- The transfer coordinator currently accepts only GitHub installation gate keys.
  Import credentials already identify saved PATs, one-time PAT runs, and GitHub
  App installations through `CredentialProvider` metadata.
- Organization bootstrap already holds LFS-enabled repositories in the
  `synchronizing` lifecycle during handoff. Preserve this publication boundary.

## Options

1. **Reuse the existing scanner, transfer, and CAS storage (recommended).** Add a
   small import-owned coordinator and integrate it with durable import progress.
   This preserves authorization, streaming, integrity, and recovery conventions.
2. Shell out to `git lfs fetch --all`. This needs additional process/credential
   handling and an adapter to import downloaded objects into Fornacast storage;
   it duplicates the existing transfer infrastructure.
3. Import pointers and download objects lazily. This keeps imports faster but
   permits a completed repository to fail checkout after credentials expire;
   it does not satisfy the requested completeness guarantee.

## Proposed behavior and boundaries

### One-time repository and organization imports

Run LFS staging after Git staging and before `ready_to_publish`. Use the hidden
repository and all staged `refs/heads/*` and `refs/tags/*` as scan baselines;
include history and annotated tag targets. The existing truncated default-tree
scan is not evidence that no LFS objects exist.

An import-owned coordinator advances bounded scan/transfer work. Store its scan
identity, baseline fingerprint, phase, and object cursor in the existing item
checkpoint. Yield and release the item lease between bounded work units; resume
from durable progress after restart. Keep the existing item state machine unless
implementation demonstrates that a new state is necessary.

Resolve credentials through `CredentialProvider` for each transfer unit. Extend
the transfer coordinator's accepted gate keys only to the existing
`saved_credential`, `one_time_run`, and `github_installation` identities used by
imports. Never persist PATs, installation tokens, or signed action URLs.

Use the existing GitHub LFS egress policy, streamed downloads, SHA-256 and size
verification, and `GitLFS`/`ForgeBlobs` storage. Reuse already verified objects
without weakening repository authorization. Check current import ownership,
lease, cancellation, and credential authority around provider effects and
before recording progress.

Require durable LFS completion evidence, bound to the exact repository generation
and Git baselines, before publication. An older staged item without this evidence
must run the new phase before publication. Existing completed imports remain
unchanged; re-import is the supported way to fetch their missing LFS objects.

### Failures and retry

Missing objects, integrity mismatches, and permission failures must not become
successful imports with an unsupported-feature warning. Preserve a typed failure
or waiting state and the valid checkpoint. Use existing retry/backoff and
credential renewal behavior for transient failures. Retry must not restart Git
cloning or discard verified LFS bytes unnecessarily.

Cancellation or lease loss prevents publication and further provider effects.
Abandoned staging and unreachable bytes follow existing cleanup and reference
retention rules. Do not delete shared CAS objects directly.

### Continuous synchronization

Retain the existing configurable LFS capability and transfer-before-ref ordering
for inbound, outbound, and converged references. Do not silently enable disabled
capabilities on existing mirrors. Verify actual worker invocation, bootstrap
handoff, checkpoint recovery, and final repository activation with focused tests;
repair only a demonstrated missing path.

### Documentation and scope

Update active import documentation and obsolete LFS warnings to reflect complete
imports and the existing mirror capability. Record the extension in the older
import design without rewriting its historical implementation narrative.

Implementation scope: import worker/publication/recovery integration and tests;
the GitHub LFS transfer coordinator and its tests; necessary LFS scanner or mirror
integration changes demonstrated by scoped tests; associated umbrella dependency
declarations; and directly relevant documentation. No new storage backend or
database schema is planned. LFS locking, wiki repositories, recursive submodules,
release binaries, deployment, and unrelated synchronization features are excluded.

## Acceptance and validation

- A real bare repository fixture with pointers in default-branch history, another
  branch, and an annotated tag imports all required bytes into real local storage.
- No-pointer and empty repositories complete without unnecessary LFS requests.
- Saved PAT, one-time PAT, and App-backed bootstrap use their correct credential
  gate and authorization boundary.
- Missing bytes, wrong size/hash, expired actions, token loss, cancellation, and
  lease loss cannot publish an incomplete repository.
- Interrupted scans and transfers resume using durable checkpoints; repeated
  objects remain idempotent and cross-repository access remains scoped.
- An old staged import without LFS completion evidence cannot bypass the phase.
- Existing inbound/outbound sync tests prove objects precede ref confirmation;
  bootstrap remains hidden until the required LFS work completes.
- Run focused PostgreSQL tests through devenv with its Unix socket and
  `PGPORT=55432`, and the required format check. Record out-of-scope failures
  without fixing them. Keep local fixtures distinct from live GitHub proof.

Live GitHub clone/checkout validation requires an identified test repository and
credentials. A local test result is not evidence of a production deployment or
successful transfer against the live GitHub service.
