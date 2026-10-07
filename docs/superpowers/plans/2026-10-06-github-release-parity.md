# GitHub Release Parity Implementation Plan

> **For agentic workers:** Execute the approved design with parallel ownership below; serialize Mix compilation and tests. Preserve existing casing fixes. No commit, publication, or live provider import is part of validation.

**Goal:** Import complete release metadata and asset binaries into shared LocalCAS and expose working local GitHub-compatible release APIs.

**Architecture:** PostgreSQL owns release and asset metadata, durable upload operations and blob inventory. ForgeBlobs owns streamed staging, CAS commit, verification and opaque downloads. The importer supplies lease/generation fences and atomic mapping publication; provider downloads never run in SQL transactions.

**Tech Stack:** Elixir umbrella, Ecto/PostgreSQL 17, Phoenix/Bandit, ForgeBlobs LocalCAS, bounded Mint transport, DuskMoon.

## Storage and domain (primary agent)

- [x] Add `apps/fornacast/priv/repo/migrations/20261006000100_add_release_parity.exs`: immutable/source metadata/latest selection, assets, upload journal, blob inventory and indexes.
- [x] Add `apps/forge_releases/lib/forge_releases/{asset,asset_operation,asset_blob,assets,asset_maintenance}.ex`. Reserve names before reading bytes, stage once, persist digest/size before commit, publish in a fenced transaction. Retain recoverable evidence after CAS success/SQL failure.
- [x] Add shared digest coordination to ForgeBlobs and LFS attachment/commit to prevent reclamation racing another blob consumer. GC checks release assets, active operations and LFS inventory before delayed deletion.
- [x] Extend release domain/schema with validated historical metadata, immutable mutations, real latest selection and notes generation. Decorate assets and preserve existing author/access policy.
- [x] Add domain tests for metadata/latest/immutability, streaming integrity, duplicate names, shared bytes, interrupted commit recovery, lost leases, authorization and logical deletion.

## Provider and importer (startup_inspect)

- [x] Decode paginated asset descriptors and validated historical release metadata in `apps/forge_github`.
- [x] Reuse bounded transport mechanics with authenticated GitHub requests, allowed redirects and credential stripping; verify observed size and digest.
- [x] Implement a separately versioned asset phase, item heartbeat/fence and atomic mappings in `apps/forge_imports`; add explicit authorized historical backfill.
- [x] Cover descriptors, pagination, redirects, replay, failure and lease loss using deterministic fixtures. Resolve exclusion warnings only with successful phase proof.

## API and web (case_review)

- [x] Extend both versioned serializers/validators and add asset controllers, working archive URLs and notes endpoints under `apps/fornacast_api`.
- [x] Add bounded authorized `ForgeReleases.Archives` and `ForgeReleases.Notes` modules.
- [x] Add DuskMoon asset presentation and authorized binary/archive links in `apps/fornacast_web`.
- [x] Cover both API versions, uploads/downloads/ranges, private/draft authorization, mutation errors, archives and UI links.

## Integration and delivery

- [x] Run `devenv --no-tui shell -- env PGPORT=55432 mix test` with affected app test paths, then formatting and `git diff --check`. Expected: scoped tests and formatting pass.
- [x] Update docs: one-time imports include release binaries; ongoing mirroring retains its exclusion. Record validated boundaries in Agent Note with `project: fornacast`.
- [x] Migrate development PostgreSQL and restart with `devenv --no-tui processes restart fornacast`. Check readiness, listener ownership and fresh logs.
- [x] Browser/API verify a local fixture release, metadata, binary integrity, archives and persistence after restart. Repair errors; remove only our fixture.

## Validation evidence (2026-10-06)

- Scoped acceptance: ForgeBlobs 1, ForgeReleases 88, GitLFS 36, ForgeGitHub 31, ForgeImports 79, web 12 and API 30 tests pass. The initial App mirror test fixture failure was corrected with real mirror bindings; the final importer metadata file passes all 22 tests. Provider LFS transport separately passes 5 tests.
- Live HTTP: both API versions; local release creation, latest selection, generated notes, 2 MiB CAS upload, SHA-256 verification, full and ranged downloads, tar and zip README content; all pass again after restart.
- Browser: release/asset metadata and all three binary/archive links return 200; no initial console errors or horizontal overflow.
- Temporary local release, repository, user, API key and bare Git fixture removed. Shared CAS bytes remain under normal reclamation.
- Verified Agent Notes ea8e4f33-81ae-4caf-983b-a85375f54134 and 9f8820b7-db5d-430a-bcc6-e136abab393c, project fornacast.
- Existing broader run-view tests have two failures caused by missing LFS publication evidence in their old fixtures; those unrelated fixtures remain unchanged.
- Runtime repairs: native packed-delta traversal uses bounded heap continuations; release asset fences acquire actor before run/item; temporary request-gate contention stays retryable; asset transport permits bounded 1 MiB receive batches with 64 KiB reader chunks; standalone dev API URLs use the API listener.
- Final runtime regression: GitCore 133, pointer scanner 7, provider 11, importer 98, API 42 tests pass (291 total); 41 scoped Rust tests pass. The exact crashing tree expands successfully three times through the rebuilt NIF.
- Final formatting and diff checks pass. After the final restart, both health endpoints stayed healthy for seven samples over 60 seconds, process restart count remained zero, all three listeners belonged to the same BEAM, and fresh logs/kernel showed no errors or native crashes. The current background workload ran during this check.
- Returned release API/upload/download/archive URLs were exercised directly; 2 MiB byte integrity and archive contents passed again after restart. Browser release and import review checks have no console errors.
- Prior real import failures remain historical and were not manually retried/backfilled during validation.
- Implementation validation was local; no real GitHub import/backfill was manually initiated. Git commit and push were authorized on 2026-10-07; release and deployment remain outside scope.
