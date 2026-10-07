# GitHub Release Metadata and LocalCAS Asset Imports

**Date:** 2026-10-06
**Status:** Approved by user on 2026-10-06; implemented and locally verified
**Baseline:** `main`, `e461a431a049b88a3714c1f97c1bde274295ccf3`

## Request and scope

GitHub releases should retain the corresponding release fields, and their asset
binaries should be stored and served by Fornacast's existing blob storage.
The screenshot comes from one-time import reporting. This proposal covers that
importer and local releases. Ongoing organization mirroring remains a separate scope; its existing asset exclusion remains until
that flow is explicitly included.

Preserve the earlier uncommitted repository-casing fix. This request supersedes
the release-asset exclusion for one-time imports in older project documents.
It does not authorize starting, retrying, or backfilling the user's real GitHub
imports during development validation.

## Behavior observed before implementation

- `ForgeGitHub.ReleaseClient` retains the core metadata and reduces the asset
  list to `asset_count`. It discards the individual asset descriptors.
- `ForgeImports.GitHub.MetadataImporter` deliberately emits
  `unsupported_release_assets` instead of fetching binaries.
- `unsupported_release_fields` includes upstream URLs for which Fornacast
  already derives local equivalents. That conflates source URL replacement
  with a missing metadata capability.
- `ForgeReleases.Release` persists the core release fields and timestamps.
  Both API serializers omit `updated_at`, always return `assets: []`, hardcode
  `immutable: false`, and return null archive URLs.
- `ForgeReleases.AssetStorage` delegates to the shared `ForgeBlobs` LocalCAS
  implementation. Release-asset SQL records, product lifecycle operations,
  and HTTP download endpoints are still absent.
- Release mappings and terminal metadata checkpoints cause already-imported
  releases to be skipped. An ordinary retry cannot fill in their missing assets.

## Design

### Release fields and API semantics

Match the supported versioned GitHub release response shapes rather than copying
provider IDs or provider content URLs into the local resource identity.

| Field group | Resulting behavior |
| --- | --- |
| `tag_name`, `target_commitish`, `name`, `body`, `draft`, `prerelease`, author, creation/publication/update timestamps | Preserve imported values and expose them through both versioned serializers, including `updated_at`. |
| `id`, `node_id`, `url`, `html_url`, `assets_url`, `upload_url` | Represent the local resource using local IDs and working local endpoints; retain source identities in importer mappings. |
| `assets` | Return available local asset records with the GitHub asset response field set. |
| `body_html`, `body_text` | Provide the corresponding representation from the retained release body; preserve validated historical projections when local rendering cannot reproduce source text. |
| `mentions_count`, `reactions` | Preserve validated imported historical values as source metadata; do not claim that importing aggregates creates local reactions or users. Local releases expose values appropriate to their local data. |
| `discussion_url` | Retain a validated optional external reference without adding a discussions subsystem. |
| `immutable` | Persist the source value and enforce immutability on release metadata, asset mutations, and the referenced tag once published. |
| `tarball_url`, `zipball_url` | Serve source archives from the local Git repository through authorized local endpoints; these are generated archives, distinct from uploaded assets. |

`make_latest` and `generate_release_notes` are GitHub write inputs rather than
historical release fields. They require actual behavior: validate latest-release
selection values and implement notes generation from local Git data. Their
semantics must be covered by API contract tests instead of copying them into a
JSON bag or silently accepting and ignoring them.

Use the checked-in contracts for `2022-11-28` and `2026-03-10` as the acceptance
baseline, explicitly documenting any additional GitHub Cloud optional fields.
Return local URLs only when the corresponding endpoints work. Existing unrelated
force-push/ref-deletion prohibitions remain in effect.

### Asset metadata and ownership

Extend `ForgeReleases` with release-asset records and domain operations. Add
migrations under `apps/fornacast/priv/repo/migrations/`; PostgreSQL 17 remains the
supported domain database.

The public asset representation contains `id`, `node_id`, `name`, nullable
`label`, `content_type`, `size`, `digest`, `state`, `download_count`, `uploader`,
`created_at`, `updated_at`, `url`, and `browser_download_url`.

For imported assets, retain the GitHub identity in an import mapping, historical
metadata separately from local lifecycle state, and an opaque SHA-256
`storage_key`. Source download counts remain an import observation; later local
downloads are counted locally. Provider URLs are not local download identities.

Reuse the accepted lifecycle, durable operation journal, digest fencing,
recovery, and delayed reference-aware garbage collection in
`2026-08-12-release-assets-localcas-design.md`. Adapt its older module and adapter
names to today's shared `ForgeBlobs` boundary and PostgreSQL support. Do not
introduce another storage engine, listener, or metadata authority. Identical
content can be shared with other blob consumers; asset deletion must never
directly delete a shared digest.

### Import pipeline

1. Decode bounded asset descriptors and retain source identity, metadata, size,
   and optional SHA-256 digest. Paginate where necessary rather than assuming
   the embedded assets array is complete.
2. Create or resume a durable asset operation associated with the repository
   item, release mapping, and current lease/generation.
3. Stream authenticated provider downloads through bounded readers into
   `ForgeReleases.AssetStorage.stage_from_reader/4`. Apply current configured
   byte limits, transport deadlines, public-address checks, and redirect rules.
   Never forward a PAT to a redirected content host.
4. Heartbeat the item lease during transfer. Check observed size and any
   supported source digest, then persist stage evidence before CAS publication.
5. Commit the blob outside SQL transactions. In a lease-fenced transaction,
   publish the asset record, source mapping, and completion proof. A CAS commit
   followed by SQL failure is recoverable and must not trigger direct blob deletion.
6. Mark the release asset phase complete only after every required asset is
   complete. Failed or incomplete asset transfers retain actionable failures;
   they must not disappear into a successful metadata checkpoint.

Retries use source mappings and durable operations to avoid duplicate metadata
and unnecessary downloads. Recovery handles staging interruption, ambiguous CAS
commit, lost lease, and SQL failure without exposing incomplete assets.

### Already imported releases

Add a separately versioned release-asset phase and an explicit backfill operation
for previously imported releases. Existing release mappings do not imply asset
completion. Backfill uses the current actor's authorization and credential
checkout; it is an explicit operator/user action rather than an automatic
provider download triggered by boot or migration.

Historical warnings remain historical until the relevant backfill succeeds.
Resolve obsolete asset-exclusion reports based on successful completion proof,
without removing genuine failures or reporting unavailable bytes as imported.

### Presentation and reporting

Expose GitHub-compatible asset listing, metadata, upload/update/delete, and binary
download endpoints through the existing domain authorization boundary. Downloads
stream bounded reads from opaque storage sources and support validated ranges.
Private repositories and draft releases retain their current visibility rules.

Show release assets in the existing release UI using DuskMoon components. Stop
emitting unsupported-field warnings for locally generated URL fields once their
local capability is present. Report invalid metadata and transfer failures with
the existing import report machinery.

## Implementation sequence

1. Versioned release field contracts and domain metadata semantics.
2. Asset persistence, streamed LocalCAS publication, recovery, and deletion.
3. GitHub asset descriptor decoding and bounded download transport.
4. Lease-fenced import phase and explicit historical backfill.
5. Local asset/archive endpoints, serializers, and release UI.
6. Update release scope documentation and record validated project knowledge.

## Verification and delivery boundary

Use deterministic provider fixtures and PostgreSQL-focused tests. Cover source
field preservation, both API versions, immutable/latest behavior, streamed binary
integrity, nullable labels, pagination, byte limits, redirects, replay, interrupted
transfer, lost leases, CAS-success/SQL-failure recovery, and shared-digest deletion.
Verify authorization for private assets and local asset/archive downloads after
publication and app restart. Run formatting and browser-check the release UI.

The implementation is complete only when imported assets can be read from local
storage through the local API and metadata matches the documented field contracts.
Suppressing the two warnings alone is insufficient. Commit/push/release and live
GitHub import execution are separate delivery actions.

## Implemented validation

Implementation and local restart checks are recorded in the matching plan. Release asset
streaming, versioned API fields, source archives, explicit fenced backfill and mirror
exclusions are covered by focused PostgreSQL tests. Live local upload/download/archive
integrity and restart persistence pass. Runtime validation also identified and repaired
a packed-delta native stack crash, actor/run lock inversion, valid batched asset-download
rejection and standalone-dev API URL origins. The final server remained healthy with
zero automatic restarts and no new runtime errors during the monitoring window.

Two existing broader run-view fixture tests still lack old LFS publication evidence.
No real GitHub import/backfill was manually started for validation. Git commit and
push were authorized on 2026-10-07; production, release and remote CI remain outside
this implementation validation evidence.
