# GitHub-Compatible Releases and Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let repository writers publish GitHub-compatible releases, create or reuse real Git tags, stream release assets safely, and recover every Git/SQL/filesystem transition after interruption.

**Architecture:** Add a `forge_releases` domain application that owns release metadata, asset metadata, opaque asset storage, and durable publication/deletion operations. Reuse the Git-data slice's repository writer fence, ref compare-and-swap, operation leases, and audit deduplication for tag work. Keep upload bytes in the request process as bounded chunks; the API controller feeds an opaque domain upload handle while durable rows and ID-derived paths make cleanup and retry deterministic.

**Tech Stack:** Elixir 1.20, Ecto 3.14 with Turso and PostgreSQL, Phoenix 1.8, Bandit, Rustler 0.38, gix 0.85, Bun, Octokit, GitHub CLI, and ExUnit.

---

**Approved specification:** `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`

**Depends on:** `2026-07-21-github-api-foundation.md` and `2026-07-21-github-api-git-data.md` are complete. The final acceptance task also requires the issues and pull-request plans.

## Scope and execution guardrails

- Implement only the release and asset endpoints listed in the approved manifest. Do not add generated notes, source archives, discussions, attestations, packages, or immutable releases.
- Create a lightweight tag only when the requested `refs/tags/<tag_name>` ref is absent. Treat an existing tag as authoritative and never move it, including during recovery or release deletion.
- Keep incomplete, deleting, and failed release/asset records invisible to ordinary reads. Drafts are visible only to repository writers and administrators.
- Delete release metadata and asset files while preserving the Git tag. Keep deletion operation rows after metadata rows disappear.
- Stream upload and download bytes. Never accept or return a whole asset binary through a domain function, Ecto field, telemetry event, audit event, or error.
- Enforce a hard `2_147_483_648` byte asset limit and 1,000 assets per release. Configuration may lower the byte limit but must not raise it.
- Derive staging and final paths only from immutable operation, release, and asset IDs. A client filename is metadata, not a path segment.
- Resolve and authorize the repository and release before opening an asset file. Constrain every release/asset ID query by the already-authorized repository.
- Run blocking filesystem and Git recovery in supervised tasks. The scheduler process owns timers and dispatch only.
- Reuse `Fornacast.OperationLease`, `GitCore.RepositoryWriteLimiter`, `ForgeRepos.with_write_fence/3`, `ForgeRepos.RepositoryWriteReconcilers`, and `Fornacast.Audit.record_multi/8`; do not add parallel implementations.
- Format only touched files and run only the scoped tests below until the final release gate.

## Public domain contract

The context uses cross-context integer IDs and explicit queries. Upload and download handles are opaque outside `forge_releases`:

```elixir
@opaque upload :: ForgeReleases.Upload.t()
@opaque download :: ForgeReleases.AssetDownload.t()

@type validation_error :: %{
        required(:resource) => String.t(),
        required(:field) => String.t(),
        required(:code) =>
          :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
        optional(:message) => String.t()
      }

@type error_reason ::
        :not_found
        | :forbidden
        | :already_exists
        | {:conflict, :tag_changed | :state_changed}
        | {:validation, [validation_error()]}
        | {:payload_too_large, :asset}
        | {:request_timeout, :asset}
        | {:unavailable, atom()}

@spec list_releases(ForgeRepos.Repository.t(), map() | nil, keyword()) ::
        {:ok, Fornacast.Page.t(ForgeReleases.Release.t())} | {:error, error_reason()}
@spec latest_release(ForgeRepos.Repository.t(), map() | nil) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec get_release(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec get_release_by_tag(ForgeRepos.Repository.t(), String.t(), map() | nil) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec create_release(ForgeRepos.Repository.t(), map(), map(), map()) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec update_release(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map(), map(), map()) ::
        {:ok, ForgeReleases.Release.t()} | {:error, error_reason()}
@spec delete_release(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map(), map()) ::
        :ok | {:error, error_reason()}

@spec list_assets(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map() | nil, keyword()) ::
        {:ok, Fornacast.Page.t(ForgeReleases.Asset.t())} | {:error, error_reason()}
@spec get_asset(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
        {:ok, ForgeReleases.Asset.t()} | {:error, error_reason()}
@spec begin_asset_upload(ForgeRepos.Repository.t(), ForgeReleases.Release.t(), map(), map(), map()) ::
        {:ok, upload()} | {:error, error_reason()}
@spec write_asset_chunk(upload(), binary()) :: {:ok, upload()} | {:error, error_reason()}
@spec finish_asset_upload(upload()) ::
        {:ok, ForgeReleases.Asset.t()} | {:error, error_reason()}
@spec abort_asset_upload(upload(), error_reason()) :: :ok
@spec update_asset(ForgeRepos.Repository.t(), ForgeReleases.Asset.t(), map(), map(), map()) ::
        {:ok, ForgeReleases.Asset.t()} | {:error, error_reason()}
@spec delete_asset(ForgeRepos.Repository.t(), ForgeReleases.Asset.t(), map(), map()) ::
        :ok | {:error, error_reason()}
@spec open_asset(ForgeRepos.Repository.t(), ForgeReleases.Asset.t(), map() | nil) ::
        {:ok, download()} | {:error, error_reason()}
@spec asset_download_metadata(download()) ::
        %{size: non_neg_integer(), content_type: String.t(), disposition: String.t()}
@spec read_asset_chunk(download(), pos_integer()) ::
        {:ok, binary(), download()} | :eof | {:error, error_reason()}
@spec close_asset_download(download()) :: :ok
@spec record_download(ForgeRepos.Repository.t(), ForgeReleases.Asset.t()) ::
        :ok | {:error, error_reason()}

@spec reconcile_repository(ForgeRepos.Repository.t()) ::
        :ok | {:error, {:unavailable, atom()}}
```

Each mutation receives safe request metadata containing `request_id`, `ip_address`, and `user_agent`. The domain never receives an Authorization header or PAT. `AssetDownload` implements a redacted `Inspect` protocol; its file handle, contained path, absolute monotonic total deadline, and rolling idle deadline never cross the opaque API.

## File map

### Domain and persistence

- Create `apps/forge_releases/mix.exs`.
- Create `apps/forge_releases/lib/forge_releases/application.ex`.
- Create `apps/forge_releases/lib/forge_releases.ex`.
- Create `apps/forge_releases/lib/forge_releases/release.ex`.
- Create `apps/forge_releases/lib/forge_releases/asset.ex`.
- Create `apps/forge_releases/lib/forge_releases/upload.ex`.
- Create `apps/forge_releases/lib/forge_releases/asset_download.ex`.
- Create `apps/forge_releases/lib/forge_releases/release_operation.ex`.
- Create `apps/forge_releases/lib/forge_releases/asset_operation.ex`.
- Create `apps/forge_releases/lib/forge_releases/asset_storage.ex`.
- Create `apps/forge_releases/lib/forge_releases/recovery.ex`.
- Create `apps/forge_releases/lib/forge_releases/recovery_scheduler.ex`.
- Create `apps/forge_releases/test/test_helper.exs`.
- Create `apps/forge_releases/test/forge_releases_test.exs`.
- Create `apps/forge_releases/test/asset_storage_test.exs`.
- Create `apps/forge_releases/test/recovery_test.exs`.
- Create `apps/fornacast/priv/repo/migrations/20260721000500_create_release_domain.exs`.

### Configuration and release wiring

- Modify `apps/fornacast/lib/fornacast/config.ex`.
- Modify `apps/fornacast/test/fornacast_test.exs`.
- Modify `config/config.exs`, `config/runtime.exs`, and `config/test.exs`.
- Modify `.env.example`, `Dockerfile`, `docker-compose.yml`, and `README.md`.
- Modify `mix.exs` and `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`.
- Modify `apps/fornacast_web/test/fornacast_run_task_test.exs`.

### API and final acceptance

- Modify `apps/fornacast_api/mix.exs` and `apps/fornacast_api/lib/fornacast_api/router.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/error.ex` and `apps/fornacast_api/lib/fornacast_api/url.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex` and `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex` and `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/release_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release_asset.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release_asset.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release_asset.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release_asset.ex`.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json` with implemented-through marker `5`; its full first-release operation set remains unchanged.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json` with implemented-through marker `5`; its full first-release operation set remains unchanged.
- Regenerate `apps/fornacast_api/priv/openapi/fornacast-overlay.json` with implemented-through marker `5` and unchanged release/upload divergences.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/release.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/release-list.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/release.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/release-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset-list.json`.
- Create `apps/fornacast_api/test/release_controller_test.exs`.
- Create `apps/fornacast_api/test/release_asset_stream_test.exs`.
- Create `apps/fornacast_api/test/release_contract_test.exs`.
- Create `apps/fornacast_api/test/github_workflow_acceptance_test.exs`.
- Create `scripts/github-api-acceptance/package.json`.
- Create `scripts/github-api-acceptance/octokit-workflow.mjs`.
- Create `scripts/github-api-acceptance/gh-workflow.sh`.
- Modify `package.json`, `bun.lock`, and `.github/workflows/e2e.yml`.

### Task 1: Scaffold release persistence and application wiring

**Files:**

- Create: `apps/forge_releases/mix.exs`
- Create: `apps/forge_releases/lib/forge_releases/application.ex`
- Create: `apps/forge_releases/lib/forge_releases/release.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset.ex`
- Create: `apps/forge_releases/lib/forge_releases/release_operation.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_operation.ex`
- Create: `apps/forge_releases/test/test_helper.exs`
- Create: `apps/forge_releases/test/forge_releases_test.exs`
- Create: `apps/fornacast/priv/repo/migrations/20260721000500_create_release_domain.exs`
- Modify: `mix.exs`
- Modify: `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`
- Modify: `apps/fornacast_web/test/fornacast_run_task_test.exs`

- [ ] **Step 1: Add failing release wiring and schema tests**

Assert `:forge_releases` starts after its dependencies in both the OTP release and `mix fornacast.run`. Characterize exact release, asset, operation, state, unique-index, and deletion-survival fields.

- [ ] **Step 2: Run tests and verify the app and tables are absent**

```bash
mix test apps/fornacast_web/test/fornacast_run_task_test.exs apps/forge_releases/test/forge_releases_test.exs --max-cases 1
```

Expected: wiring omits `:forge_releases`, and the release test cannot load the new schemas.

- [ ] **Step 3: Add the one-way domain application**

Use exactly these direct dependencies:

```elixir
[
  {:fornacast, in_umbrella: true},
  {:forge_accounts, in_umbrella: true},
  {:forge_repos, in_umbrella: true},
  {:git_core, in_umbrella: true},
  {:ecto, "~> 3.14"}
]
```

Do not add releases as a dependency of accounts, repositories, GitCore, or the web application.

- [ ] **Step 4: Create release and asset tables**

Create `releases` with:

- `repository_id`, `creator_user_id`, `tag_name`, and `target_commitish`, not null;
- nullable `name` and `body`;
- `draft` and `prerelease`, not null with default `false`;
- `asset_count` as a non-negative integer, not null with default `0`;
- `state` in `pending | available | deleting`, not null;
- nullable `published_at`;
- UTC timestamps;
- a unique index on `{repository_id, tag_name}` and indexes on `{repository_id, state}` and `{repository_id, published_at}`.

Create `release_assets` with:

- `release_id`, `uploader_user_id`, `name`, and `content_type`, not null;
- nullable `size`, `sha256_digest`, and opaque `storage_path` while state is `pending`;
- nullable `label`;
- `size` as nullable `:bigint` constrained non-negative whenever present;
- `download_count` as non-null `:bigint`, default `0`, constrained non-negative;
- `state` in `pending | available | deleting`, not null;
- UTC timestamps;
- a unique index on `{release_id, name}` and indexes on `{release_id, state}`.

The schema transition to `available` requires non-null `size`, `sha256_digest`, and `storage_path`. Enforce the size/download ranges in changesets on both adapters. Add equivalent adapter-aware database checks where supported: `size IS NULL OR size >= 0`, `download_count >= 0`, and `state != 'available' OR (size IS NOT NULL AND sha256_digest IS NOT NULL AND storage_path IS NOT NULL)`. This permits the pending row to reserve the asset name before request bytes are read without permitting an incomplete visible asset.

- [ ] **Step 5: Create durable operation tables that survive metadata deletion**

Create `release_operations` with nullable `release_id` using `on_delete: :nilify_all`, immutable `release_record_id`, repository/actor IDs, `kind` in `publish | delete`, nullable `target_ref`, `expected_oid`, and `proposed_oid`, state, request ID, sanitized failure reason, lease owner/expiry, lock version, and UTC timestamps. The publication changeset requires `target_ref` and `proposed_oid`: `target_ref` is exactly `refs/tags/<tag_name>`; an existing tag records its direct OID as both expected and proposed, while a missing tag records expected absence and the resolved commit OID as proposed. Delete operations leave all three ref fields null. Its accepted states are:

```elixir
[:prepared, :tag_ready, :metadata_ready, :deleting, :assets_deleted, :metadata_deleted, :completed, :failed]
```

Create `release_asset_operations` with nullable `asset_id` using `on_delete: :nilify_all`, immutable `asset_record_id`, `release_record_id`, and `repository_id`, actor ID, `kind` in `upload | delete`, opaque staging/final storage keys, observed size/digest, request/failure/lease fields, lock version, and UTC timestamps. Its accepted states are:

```elixir
[:staging, :staged, :metadata_ready, :completed, :deleting, :deleted, :failed]
```

Index non-terminal lookup keys and lease expiry. Do not cascade operation rows from metadata rows.

- [ ] **Step 6: Implement strict schemas and migrate**

Use string-backed `Ecto.Enum`, dedicated creation and one-step transition changesets, integer cross-context IDs, and no cross-context Ecto associations. The release may expose a same-context `has_many :assets` association solely so response operations can preload the compatible embedded list. Apply portable indexes on both adapters and check constraints only through the established adapter-aware helper.

```bash
MIX_ENV=test mix ecto.migrate
mix test apps/forge_releases/test/forge_releases_test.exs apps/fornacast_web/test/fornacast_run_task_test.exs --max-cases 1
```

Expected: schema, constraint, operation-survival, and wiring tests pass.

- [ ] **Step 7: Commit release persistence**

```bash
git add apps/forge_releases apps/fornacast/priv/repo/migrations/20260721000500_create_release_domain.exs mix.exs apps/fornacast_web/lib/mix/tasks/fornacast.run.ex apps/fornacast_web/test/fornacast_run_task_test.exs
git commit -m "feat(releases): add durable release persistence"
```

### Task 2: Add safe asset storage and configuration

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/asset_storage.ex`
- Create: `apps/forge_releases/lib/forge_releases/upload.ex`
- Create: `apps/forge_releases/lib/forge_releases/asset_download.ex`
- Create: `apps/forge_releases/test/asset_storage_test.exs`
- Modify: `apps/forge_releases/lib/forge_releases/application.ex`
- Modify: `apps/fornacast/lib/fornacast/config.ex`
- Modify: `apps/fornacast/test/fornacast_test.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `.env.example`
- Modify: `Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `README.md`

- [ ] **Step 1: Write failing containment and streaming tests**

Cover empty/absolute/traversal keys, symlink escape attempts, Unicode and control-character filenames, CR/LF header injection, duplicate names, exact 2 GiB admission, one-byte overflow, incremental SHA-256, partial-write cleanup, and independent staging/final roots under one configured storage root. Use sparse-file or injected-byte-counter tests instead of allocating 2 GiB in memory.

- [ ] **Step 2: Run storage tests and verify the module is missing**

```bash
mix test apps/forge_releases/test/asset_storage_test.exs --max-cases 1
```

Expected: tests fail on missing `ForgeReleases.AssetStorage` and release-asset configuration.

- [ ] **Step 3: Add the dedicated root configuration**

Expose `Fornacast.Config.release_asset_storage_root/0` and `release_asset_max_bytes/0`. Configure `FORNACAST_RELEASE_ASSET_STORAGE_ROOT` with `tmp/release-assets` in development, `tmp/test/release-assets` in tests, and `/data/release-assets` as the production container default. Configure `FORNACAST_RELEASE_ASSET_MAX_BYTES` as a positive decimal integer defaulting to `2_147_483_648`; reject malformed or non-positive values at runtime configuration load and clamp any larger value to that immutable hard maximum. Add both variables to `.env.example`, Docker Compose, configuration/backup documentation, and the existing `/data` volume. `ForgeReleases.Application` ensures the root at startup to preserve dependency direction. Tests cover defaults, a lower limit, malformed/non-positive rejection, and over-hard clamping.

- [ ] **Step 4: Derive opaque contained paths**

Use storage keys with only server-created integers and random operation IDs:

```text
staging/<operation-id>/<random-token>.part
releases/<release-id>/assets/<asset-id>
```

Validate a key as relative, reject empty/dot segments, expand against the root, verify containment, and refuse symlink traversal before open/rename/delete. The client filename must not appear in either key.

- [ ] **Step 5: Implement the request-owned upload handle**

`ForgeReleases.Upload` holds an IO device, operation ID, monotonic start/last-byte times, byte count, incremental `:crypto.hash_init(:sha256)` context, and opaque storage keys. Mark the struct opaque and implement a safe `Inspect` protocol that never prints the IO device, paths, or hash context. `write_asset_chunk/2` returns an updated handle and rejects overflow before writing the offending chunk.

- [ ] **Step 6: Sanitize download metadata**

Validate asset names as non-empty UTF-8 metadata with pinned length limits, no slash, backslash, NUL, control characters, `.` or `..`. Build `Content-Disposition` through one tested encoder with quoted ASCII fallback and RFC 5987 `filename*`; never concatenate an unescaped name into a header.

- [ ] **Step 7: Run storage/config tests and commit**

```bash
mix test apps/forge_releases/test/asset_storage_test.exs apps/fornacast/test/fornacast_test.exs --max-cases 1
```

Expected: containment, streaming, digest, hard-cap, config, and header tests pass.

```bash
git add apps/forge_releases/lib/forge_releases/application.ex apps/forge_releases/lib/forge_releases/asset_storage.ex apps/forge_releases/lib/forge_releases/upload.ex apps/forge_releases/lib/forge_releases/asset_download.ex apps/forge_releases/test/asset_storage_test.exs apps/fornacast/lib/fornacast/config.ex apps/fornacast/test/fornacast_test.exs config .env.example Dockerfile docker-compose.yml README.md
git commit -m "feat(releases): add bounded asset storage"
```

### Task 3: Publish and manage releases without moving existing tags

**Files:**

- Create: `apps/forge_releases/lib/forge_releases.ex`
- Modify: `apps/forge_releases/lib/forge_releases/release.ex`
- Modify: `apps/forge_releases/lib/forge_releases/release_operation.ex`
- Modify: `apps/forge_releases/test/forge_releases_test.exs`

- [ ] **Step 1: Write failing release lifecycle tests**

Cover create defaults, default-branch `target_commitish`, explicit targets, missing targets when the tag is absent, a new lightweight tag, an existing authoritative tag with a nonexistent supplied `target_commitish` that still succeeds without moving or peeling that tag, duplicate repository/tag, draft visibility, writer-only mutation, update field restrictions, deterministic latest selection, prerelease exclusion, and deletion preserving the tag.

- [ ] **Step 2: Run the lifecycle test and verify the context is absent**

```bash
mix test apps/forge_releases/test/forge_releases_test.exs --max-cases 1
```

Expected: tests fail on missing `ForgeReleases.create_release/4` and related reads.

- [ ] **Step 3: Record publication before Git work**

Under `ForgeRepos.with_write_fence/3`, let `ForgeRepos.RepositoryWriteReconcilers` finish or block every configured older ref-affecting operation, then inspect the exact direct tag ref before resolving any target. Preserve the supplied or default `target_commitish` string as release response metadata. If the tag exists, do not resolve that string; record the tag's direct OID as both expected and proposed. Only when the tag is absent, resolve `target_commitish` once and record expected absence plus the resolved target commit OID as proposed. Insert the invisible release row and `:prepared` publication operation with a request-owned lease in one SQL transaction. Every foreground state transition uses `Fornacast.OperationLease.update_owned/3`; release the lease only after a terminal transaction, and let recovery claim only an expired or unowned row.

- [ ] **Step 4: Create a missing tag through compare-and-swap**

For an absent tag, use the exact Git-data primitive inside the existing `:tag` fence callback:

```elixir
GitCore.compare_and_swap_ref(
  repository_path,
  "refs/tags/" <> tag_name,
  nil,
  operation.proposed_oid,
  :fast_forward,
  deadline_ms: remaining_ms
)
```

Derive one absolute deadline from the callback's initial remaining budget and recompute `remaining_ms` immediately before the CAS. An existing exact tag is verified against the recorded OID and is never passed to CAS, peeled, or rewritten. Persist `:tag_ready` only after the created or pre-existing direct ref equals `proposed_oid`. If a definitive CAS conflict proves this operation did not create the tag, delete the invisible pending release row and mark the durable operation failed in one transaction; retain `release_record_id` so the same repository/tag can be retried without violating the release uniqueness constraint, and return `{:error, {:conflict, :tag_changed}}`.

- [ ] **Step 5: Make metadata visible and complete the operation**

In one SQL transaction, transition the release to `:available`, set `published_at` only for a non-draft release, update repository `last_pushed_at` only when this operation created a tag, persist `:metadata_ready`, append the audit event with `operation_id: "release_operation:" <> Integer.to_string(operation.id)`, and mark `:completed`. Invalidate repository caches after commit and before returning `201`.

Update supports only `name`, `body`, `draft`, and `prerelease`; a transition from draft to published sets `published_at` once. Build one outer `Ecto.Multi` containing a state-qualified `available` update and `Fornacast.Audit.record_multi/8` with action `release.updated`, target type `release`, a callback-derived updated release ID, and `request_metadata: request_meta`, then call `Fornacast.Repo.transaction/1`. Require exactly one affected release row; a concurrent delete yields a tagged conflict and no audit. Use an operation-independent multi key such as `:audit`; ordinary update audit does not set a durable `operation_id`. A validation or audit failure rolls back the release update.

- [ ] **Step 6: Implement scoped reads and deterministic latest**

Published reads follow repository visibility. Draft reads require repository write. Count the filtered result before applying pagination. `list_releases/3` orders by descending `inserted_at` then descending ID. `latest_release/2` orders available, non-draft, non-prerelease rows by descending `published_at` then descending ID. `list_assets/4` orders by ascending ID. Release list/get/latest/by-tag and create/update response functions batch-preload only available assets for all selected release IDs in one query ordered by ascending asset ID, attach them to the returned `Release.t()` values, and never issue one asset query per release. Pending and deleting assets remain absent. `tarball_url` and `zipball_url` remain serializer-owned nulls.

- [ ] **Step 7: Implement normal release deletion through its durable operation**

In one transaction create a request-leased `kind: :delete` operation and conditionally change the release from available to deleting so it disappears from all reads. Require exactly one affected row, so duplicate or update/delete races cannot create a second deletion operation. Derive one bounded absolute deletion deadline, use `Fornacast.OperationLease.update_owned/3` for every foreground transition, and renew before half-life as each asset deletion makes progress; recovery therefore cannot claim a live deletion. Remove each asset through the same idempotent file/row deletion boundary, persist `:assets_deleted`, delete release metadata while retaining `release_record_id` on the operation, then append the deduplicated audit with `operation_id: "release_operation:" <> Integer.to_string(operation.id)` and persist `:metadata_deleted -> :completed` in the same final multi. Release the lease after that commit. Never call a Git tag deletion primitive.

- [ ] **Step 8: Pass release lifecycle tests and commit**

```bash
mix test apps/forge_releases/test/forge_releases_test.exs --max-cases 1
```

Expected: tag, visibility, authorization, update, latest, duplicate, and audit tests pass.

```bash
git add apps/forge_releases/lib/forge_releases.ex apps/forge_releases/lib/forge_releases/release.ex apps/forge_releases/lib/forge_releases/release_operation.ex apps/forge_releases/test/forge_releases_test.exs
git commit -m "feat(releases): publish releases with real tags"
```

### Task 4: Stream upload, metadata, download, rename, and deletion operations

**Files:**

- Modify: `apps/forge_releases/lib/forge_releases.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_operation.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_storage.ex`
- Modify: `apps/forge_releases/lib/forge_releases/upload.ex`
- Modify: `apps/forge_releases/lib/forge_releases/asset_download.ex`
- Modify: `apps/forge_releases/test/asset_storage_test.exs`
- Modify: `apps/forge_releases/test/forge_releases_test.exs`

- [ ] **Step 1: Write failing asset state-machine tests**

Cover:

```text
staging -> staged -> metadata_ready -> completed
deleting -> deleted
```

Assert duplicate names, two concurrent same-name admissions with exactly one winner before either reads a chunk, quota at 1,000, overflow cleanup, content type, label, exact size/digest, available-only listing, deterministic asset ordering, metadata GET, safe download data, download count, two concurrent completed downloads incrementing twice, rename conflicts, forbidden `state`, and authorizations.

- [ ] **Step 2: Begin upload before reading bytes**

After repository/release authorization, check draft/write visibility and the configured byte cap. In one transaction conditionally increment `releases.asset_count` only when the release remains `available` and the count is below 1,000, insert a `pending` asset row carrying the requested name, label, declared content type, and uploader, and insert its `:staging` operation with a request-owned lease. A zero-row release update becomes `{:error, {:conflict, :state_changed}}` or the quota validation error according to a bounded follow-up classification. The asset insert, protected by the unique `{release_id, name}` index, is the atomic name reservation; convert its conflict to the tagged validation result. After both IDs exist, update the operation with staging/final keys derived only from operation, release, and asset IDs. Commit all four changes or none.

Only after that transaction succeeds, create the ID-derived staging file exclusively and return the opaque handle. The initial lease covers the first chunk; renew it with `Fornacast.OperationLease.update_owned/3` before half its bounded lifetime while chunks make progress, never beyond the fixed 30-minute total deadline. A failure before this point must not read a request chunk. If exclusive file creation fails, compensate through an owned transition by deleting the invisible pending asset and decrementing the reserved count in one transaction, then mark the durable operation failed. Abort, failed recovery, and successful deletion use one guarded owned transition that deletes the pending row when present and decrements the count exactly once; concurrent uploads therefore cannot exceed quota or stream two bodies for the same asset name. Recovery claims only expired or unowned operations, so it cannot compensate a live request.

- [ ] **Step 3: Finalize staged bytes durably**

On EOF, sync and close the file, persist observed size/digest as `:staged` through `Fornacast.OperationLease.update_owned/3`, update the already-reserved pending asset with its final ID-derived path, size, and digest, move the staging file atomically where supported, and persist `:metadata_ready` through another owned transition. Then mark that asset available, append audit with `operation_id: "release_asset_operation:" <> Integer.to_string(operation.id)`, and transition to `:completed` in one final multi guarded by the same owner. Release the lease after commit. Return the asset only after the final file and visible metadata are durable.

- [ ] **Step 4: Implement metadata update and download**

`get_asset/3` joins through the release and constrains both records to the authorized repository, applies published/draft visibility, and returns available metadata only. Asset update accepts only `name` and `label`; duplicate names return validation. Compose a state-qualified `available` asset update and `Fornacast.Audit.record_multi/8` with action `release_asset.updated`, target type `release_asset`, a callback-derived updated asset ID, and `request_metadata: request_meta` in one outer `Ecto.Multi`. Require exactly one affected row; a concurrent delete returns `{:error, {:conflict, :state_changed}}` with no audit, and either changeset failing rolls back both.

`open_asset/3` verifies the available row and contained final file and returns an opaque `AssetDownload` whose safe metadata is available only through `asset_download_metadata/1`. `read_asset_chunk/2` clamps every requested read to a hard 1 MiB maximum, owns all path and IO access, returns `{:ok, bytes, updated_download}`, enforces the decreasing 30-minute absolute total deadline, and advances the updated handle's 30-second idle deadline only after successful progress; `close_asset_download/1` is idempotent. The controller starts a chunked response, threads the returned handle through repeated `read_asset_chunk/2` calls, and closes the latest handle in `after`. It never receives a storage path and never calls `send_file`. Call `record_download/2` only after `:eof` and successful response completion; it executes one repository-scoped, state-qualified SQL `inc: [download_count: 1]`, never a read/modify/write cycle. Disconnects and read errors do not increment the count, while two concurrent successful completions both do.

- [ ] **Step 5: Implement durable asset deletion**

In one transaction insert a request-leased `:deleting` operation and conditionally change exactly one `available` asset to deleting. A duplicate delete or concurrent update returns `{:error, {:conflict, :state_changed}}` and cannot create a second operation. Before slow file IO, renew the owned lease within one bounded absolute deletion deadline; recovery may claim only after that ownership expires. Remove the final file idempotently through owned transitions, then delete metadata, append audit with `operation_id: "release_asset_operation:" <> Integer.to_string(operation.id)`, and persist `:deleted` in one final owner-guarded multi while keeping the operation row. Release after commit. Missing files count as already deleted; unexpected path/type errors become sanitized failure state.

- [ ] **Step 6: Run asset domain tests and commit**

```bash
mix test apps/forge_releases/test/forge_releases_test.exs apps/forge_releases/test/asset_storage_test.exs --max-cases 1
```

Expected: upload, quota, metadata, download, rename, deletion, digest, and safety tests pass.

```bash
git add apps/forge_releases
git commit -m "feat(releases): manage streamed release assets"
```

### Task 5: Reconcile every release and asset transition

**Files:**

- Create: `apps/forge_releases/lib/forge_releases/recovery.ex`
- Create: `apps/forge_releases/lib/forge_releases/recovery_scheduler.ex`
- Modify: `apps/forge_releases/lib/forge_releases/application.ex`
- Modify: `apps/forge_releases/lib/forge_releases.ex`
- Modify: `config/config.exs`
- Create: `apps/forge_releases/test/recovery_test.exs`

- [ ] **Step 1: Add a fault after every non-terminal transition**

For publication, release deletion, asset upload, and asset deletion, inject a process exit after each persisted state. Restart recovery twice and assert the same final result, one audit event, no visible partial metadata, no moved existing tag, and no orphaned staging file.

- [ ] **Step 2: Add lease contention and expired-lease tests**

Use exactly `Fornacast.OperationLease.claim/5`, `update_owned/3`, and `release/2` with frozen clocks and lock versions. Assert one worker owns an operation, an unexpired lease cannot be stolen, active upload and release/asset deletion requests renew before recovery can claim them, an expired lease can be reclaimed, stale owners cannot transition, and both Turso and PostgreSQL paths avoid database-specific locks. Do not add a release-local lease helper.

- [ ] **Step 3: Implement publication reconciliation**

Append `{300, :release_tags, ForgeReleases.Recovery}` to the root `:forge_repos, :repository_write_reconcilers` configuration while retaining the Git and pull entries. Run tag inspection only inside the shared writer fence through `Recovery.reconcile_repository_locked/3`; the callback accepts the existing repository path and absolute deadline and never reacquires the writer. For `:prepared` with expected absence: an absent ref deletes the invisible pending release and marks the operation failed without creating a tag; `proposed_oid` current finishes metadata; a third OID retains the non-terminal evidence, stores `unexpected_ref`, emits one deduplicated safe alert, and returns unavailable so later writes remain fenced. For a recorded pre-existing tag, current `expected_oid == proposed_oid` finishes metadata and any other OID uses the same retained-evidence block. For `:tag_ready` or `:metadata_ready`, finish visible metadata and deduplicated audit only after the tag equals proposed. Every compensating delete retains immutable `release_record_id`, freeing the repository/tag uniqueness key for a clean retry.

- [ ] **Step 4: Implement upload/deletion reconciliation**

Classify staging and final files by operation-owned keys. Complete a staged upload only when size and SHA-256 match the persisted observation; otherwise delete partial files, delete the invisible pending asset row, decrement its reserved count through the guarded transition, and fail invisibly. Repeating that compensation cannot decrement twice. Resume release deletion through `deleting -> assets_deleted -> metadata_deleted -> completed`, preserving the tag and operation row. Resume asset deletion idempotently to `:deleted`.

- [ ] **Step 5: Dispatch bounded recovery work**

`RecoveryScheduler` runs immediately through `handle_continue` and uses the hard-capped 30-second interval. Its callbacks only call `Task.Supervisor.async_nolink/2`, store the task reference, and handle the reply or `:DOWN`; no GenServer callback queries SQL, accesses Git/filesystem state, or claims a lease.

The supervised task selects at most 50 distinct repository IDs with non-terminal tag-publication work and, for each repository, enters the shared writer fence before the registered `reconcile_repository_locked/3` callback claims publication rows in ascending operation ID order. It never preclaims a tag operation outside the fence, so the locked callback cannot block on its own lease and a later ref write cannot pass an unclassified older operation. Separately, the task selects at most 50 file-only operation IDs, claims those outside a Git writer, and performs filesystem reconciliation. Resource reads and mutations synchronously use the same tag-inside-fence or file-only claim ordering before serializing or starting a later transition.

- [ ] **Step 6: Run recovery tests with deterministic seeds**

```bash
mix test apps/forge_releases/test/recovery_test.exs --max-cases 1 --seed 0
mix test apps/forge_releases/test/recovery_test.exs --max-cases 1 --seed 1
```

Expected: every fault point, repeated run, lease race, tag decision, file decision, and audit deduplication passes.

- [ ] **Step 7: Commit release recovery**

```bash
git add apps/forge_releases config/config.exs
git commit -m "feat(releases): reconcile release operations"
```

### Task 6: Expose versioned release metadata and raw asset routes

**Files:**

- Modify: `apps/fornacast_api/mix.exs`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/error.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/release_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/release_asset_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/release_asset.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/release_asset.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/release_asset.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/release_asset.ex`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`
- Modify: `apps/fornacast_api/priv/openapi/fornacast-overlay.json`
- Create: `apps/fornacast_api/test/release_controller_test.exs`
- Create: `apps/fornacast_api/test/release_asset_stream_test.exs`
- Create: `apps/fornacast_api/test/release_contract_test.exs`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/release.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/release-list.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/releases/asset-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/release.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/release-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/releases/asset-list.json`

- [ ] **Step 1: Write failing metadata route, marker, and contract tests**

Assert the full foundation artifacts already contain release list/create, latest, tag lookup, get/update/delete, asset list, upload, and asset get/update/delete under slice `5` ownership, and require implemented-through marker `"5"` in both documents and the overlay. Preserve `/api/uploads` as its own server prefix. Cover route ordering so `latest`, `tags/:tag`, and `assets/:asset_id` do not collide with `:id`; accepted/rejected fields; both versions; public/private/draft visibility; writer-only mutations; pagination; exact errors; canonical URLs; null source archives; and the exact upload URI template ending in `{?name,label}`.

Build literal expected maps in `release_contract_test.exs` from one fixed release (`id: 9001`, tag `v1.0.0`, target `main`, name `Version 1.0.0`, body `First release`, author ID `41`, created/published `2026-07-21T00:00:00Z`) and one fixed asset (`id: 9101`, name `fornacast.tar.gz`, label `Linux`, content type `application/gzip`, state `uploaded`, size `12`, SHA-256 `sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`, downloads `0`, the same timestamps and uploader). The maps must enumerate every selected-version response field explicitly, including canonical URLs, local node IDs, simple-user maps, null `tarball_url`/`zipball_url`, and the release's one-element `assets` list. Both pinned asset schemas require `digest`, so both maps include the fixed digest above; any remaining selected-version field difference is written explicitly in its own literal map.

Check in the exact `JSON.encode!/1` output of those literal maps at the eight fixture paths in this task: `release.json` is the one release map, `release-list.json` is a one-element array of it, `asset.json` is the one asset map, and `asset-list.json` is a one-element array of it. Tests read the files, decode them, compare them to the literal maps, and validate them against the matching pinned schemas; they never generate expected maps by calling the serializer under test.

- [ ] **Step 2: Write failing raw upload/download tests**

Use a chunked connection adapter fixture to prove no global JSON parser touches `/api/uploads`, no chunk is read before authorization/quota admission, 30-second idle and 30-minute total deadlines for both upload and download, exact size overflow, disconnect cleanup, declared content type, `application/octet-stream` download, default metadata GET, safe headers, and byte-for-byte streaming.

- [ ] **Step 3: Run tests and verify routes are absent**

```bash
mix test apps/fornacast_api/test/release_controller_test.exs apps/fornacast_api/test/release_asset_stream_test.exs apps/fornacast_api/test/release_contract_test.exs --max-cases 1
```

Expected: the catch-all returns `404`, no release serializer or raw upload controller exists, and the generated delivery marker is still slice `4`; the pinned release paths themselves are already present.

- [ ] **Step 4: Advance the generated delivery marker without changing the manifest**

```bash
rm -rf /tmp/fornacast-openapi-source
git clone --filter=blob:none --no-checkout https://github.com/github/rest-api-description.git /tmp/fornacast-openapi-source
git -C /tmp/fornacast-openapi-source checkout 03ca9c1cac754ec9b8369dc75de8a8c753c6e087 -- descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json
mix run scripts/prune_github_openapi.exs -- /tmp/fornacast-openapi-source apps/fornacast_api/priv/openapi 5
```

Expected: source commit/blob checks pass, the full first-release operation manifest and upload-server override remain unchanged, and only the generated implemented-through marker advances from `4` to `5`.

- [ ] **Step 5: Add strict validators and thin controllers**

Release create accepts exactly `tag_name`, `target_commitish`, `name`, `body`, `draft`, and `prerelease`; update accepts exactly `name`, `body`, `draft`, and `prerelease`. Asset update accepts exactly `name` and `label`. Reject `make_latest`, generated notes, discussions, tag changes, and client-owned asset state with `422`.

Add `{:forge_releases, in_umbrella: true}` only to `fornacast_api`, and wire nested validators/serializers through both established version facade files. Resolve and authorize the repository and release before calling `FornacastAPI.RequestBody.read_json(conn, :ordinary, [])` for release create/update or asset PATCH. Direct asset metadata GET/PATCH/DELETE resolve through `ForgeReleases.get_asset/3`; controllers never query Ecto. Compute and assign `ForgeAccounts.APIScope.accepted_scopes/2` before PAT authorization; insufficient scope uses `{:insufficient_scope, accepted}` so `403` responses retain `X-Accepted-OAuth-Scopes`. Map duplicate tag/asset names and invalid fields to `422`, `{:conflict, :tag_changed | :state_changed}` to `409`, payload overflow to `413`, request deadlines to `408`, and known limiter/storage/fence failures to `503` before the unclassified fallback.

Extend `FornacastAPI.Plugs.MediaType` with one explicit raw-upload route classification for `POST /api/uploads/repos/:owner/:repo/releases/:release_id/assets`. It accepts a syntactically valid declared `type/subtype` media type and records the normalized value for the controller without invoking JSON decoding. A missing or syntactically invalid declaration returns `415`. Every other body-bearing mutation keeps the foundation's JSON-only media rule; do not turn this into a prefix-wide bypass.

The upload action obtains `name` and optional `label` from the query, authenticates and authorizes, then parses `Content-Length` when present. Reject malformed or negative values as `400` and a value above `Fornacast.Config.release_asset_max_bytes/0` as `413` before `begin_asset_upload/5`, without reserving quota or reading a chunk. For an absent length, call `begin_asset_upload/5` and enforce the cap while streaming. It repeatedly calls `Plug.Conn.read_body/2` with bounded `length`, `read_length`, and `read_timeout` while enforcing monotonic total/idle deadlines. Authorization, declared-length preflight, and quota/name reservation finish before the first body read. It feeds each chunk to `write_asset_chunk/2` and always calls finish or abort in `try/after` ownership logic.

- [ ] **Step 6: Add explicit version serializers and canonical URLs**

Each selected-version module owns its complete response field map. Release maps explicitly emit `url`, `html_url`, `assets_url`, `upload_url`, `tarball_url`, `zipball_url`, `id`, `node_id`, `tag_name`, `target_commitish`, `name`, `body`, `draft`, `prerelease`, `created_at`, `published_at`, `author`, and `assets`, plus only additional fields required by that selected pinned schema. Asset maps in both versions explicitly emit `url`, `id`, `node_id`, `name`, `label`, `uploader`, `content_type`, `state: "uploaded"`, `size`, `digest`, `download_count`, `created_at`, `updated_at`, and `browser_download_url`. These literal field lists are the source of the golden maps from Step 1.

Extend and use `FornacastAPI.URL` for release, tag, asset, browser-download, upload-template, and repository-web links; serializers never call `Fornacast.Config.base_url/0` directly. Scope asset IDs to the authorized repository and never emit the listener address or storage path. Per the approved deliberate divergence, release `html_url` uses its corresponding public API URL until a browser release page exists.

- [ ] **Step 7: Run the release API slice and commit**

```bash
mix test apps/forge_releases/test apps/fornacast_api/test/release_controller_test.exs apps/fornacast_api/test/release_asset_stream_test.exs apps/fornacast_api/test/release_contract_test.exs --max-cases 1
```

Expected: domain, stream, permission, media, validation, URL, header, and both-version contract tests pass.

```bash
git add apps/fornacast_api
git commit -m "feat(api): expose compatible releases"
```

### Task 7: Run the complete GitHub-client workflow and release gate

**Files:**

- Create: `apps/fornacast_api/test/github_workflow_acceptance_test.exs`
- Create: `scripts/github-api-acceptance/package.json`
- Create: `scripts/github-api-acceptance/octokit-workflow.mjs`
- Create: `scripts/github-api-acceptance/gh-workflow.sh`
- Modify: `package.json`
- Modify: `bun.lock`
- Modify: `.github/workflows/e2e.yml`

- [ ] **Step 1: Add a deterministic acceptance provisioner**

Create one test-only/release-eval fixture that creates an ordinary active user and one classic PAT through `ForgeAccounts.create_api_key/2` with the fixed name `github-api-acceptance` and exact scopes `scopes: ["repo", "write:org"]`. Assert the stored/reported scope set and each route's `X-OAuth-Scopes` plus `X-Accepted-OAuth-Scopes`. Write the raw secret only to the calling test process or a mode-0600 CI file, and never log it. Do not add a PAT REST endpoint.

- [ ] **Step 2: Add an isolated Octokit workspace**

Add `scripts/github-api-acceptance` to the root workspaces, run:

```bash
./_build/bun add --cwd scripts/github-api-acceptance --exact @octokit/rest
```

Check in the exact generated package entry and `bun.lock`. The script accepts `FORNACAST_PUBLIC_ORIGIN`, `FORNACAST_PAT`, and a unique namespace suffix, constructs the Octokit base URL as `<origin>/api/v3`, and follows the release's emitted `/api/uploads` URL without rewriting it.

- [ ] **Step 3: Implement the complete Octokit workflow**

The script performs, asserts, and cleans no server state outside its unique namespace:

1. get `/user` and both API versions;
2. create an organization naming the token owner as admin;
3. create an auto-initialized repository;
4. create a branch ref;
5. create and update content on that branch with current SHA checks;
6. create, edit, comment on, close, and reopen an issue;
7. open and merge a same-repository pull with an expected head SHA;
8. create a release, upload an asset, fetch its metadata, and download exact bytes;
9. verify pagination, rate/scope headers, and selected-version headers.

- [ ] **Step 4: Implement the same workflow with `gh api`**

`gh-workflow.sh` uses `GH_HOST`, `GH_ENTERPRISE_TOKEN`, explicit `X-GitHub-Api-Version`, `--input`/`-f` payloads, and the public proxy host. It runs the same ordered resource lifecycle with a different suffix and validates JSON using `gh api --jq`. It follows the emitted upload URL rather than constructing an internal listener URL.

- [ ] **Step 5: Add normal Git interoperability assertions**

After each client workflow, clone or fetch through smart HTTP with the same classic PAT in an isolated askpass helper. Assert content bytes, content commit, merge commit's two ordered parents, base ref, and release tag. Assert account passwords fail Git HTTP while compatible legacy and classic scopes retain only their approved mappings.

- [ ] **Step 6: Extend the release E2E job and run the existing proxy smoke**

Start web, API, and the checked-in reverse proxy. Wait independently for web health and API internal health, then call public `/api/v3/versions` and public `/api/uploads` without prefix stripping. Run both client scripts with secrets masked. Add negative cases for invalid/revoked/expired/legacy mutation tokens, private masking, versions, media, spoofed forwarding headers, stale content/ref/merge races, duplicate/oversized assets, and one fault after every durable state.

- [ ] **Step 7: Run the final scoped and release gates**

Run:

```bash
mix test apps/fornacast/test/operation_lease_test.exs apps/forge_accounts/test apps/forge_repos/test apps/git_core/test apps/git_transport/test apps/forge_issues/test apps/forge_pulls/test apps/forge_releases/test apps/fornacast_api/test apps/fornacast_web/test/git_http_auth_test.exs apps/fornacast_web/test/git_http_push_test.exs apps/fornacast_web/test/fornacast_run_task_test.exs --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml
mix compile --warnings-as-errors
MIX_ENV=prod mix release fornacast --overwrite
```

Then run both client scripts against the release and public proxy. Expected: all scoped tests pass, the release contains every application, both listeners start, both public prefixes route unchanged, and both client workflows produce Git state visible to a normal Git client.

- [ ] **Step 8: Commit final acceptance coverage**

```bash
git add apps/fornacast_api/test/github_workflow_acceptance_test.exs scripts/github-api-acceptance package.json bun.lock .github/workflows/e2e.yml
git commit -m "test(api): prove GitHub client workflow"
```

## Slice completion criteria

- Every release and asset operation in the approved manifest validates against both pinned version artifacts.
- New tags are real lightweight Git refs; existing tags are never moved and release deletion preserves them.
- Draft, published, prerelease, latest, private, and writer visibility rules are deterministic.
- Asset request and response bodies stream with hard byte, idle, total, quota, digest, and containment enforcement.
- User filenames never influence storage paths or unsafe response headers.
- Publication, release deletion, asset upload, and asset deletion recover idempotently from every non-terminal state.
- Durable operation rows survive metadata deletion and audit events remain operation-key unique.
- Octokit, `gh api`, and a normal Git client complete the approved organization-to-release workflow through the public origin.
