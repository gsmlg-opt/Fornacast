# GitHub-Compatible Git Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver GitHub-compatible branches, refs, commits, and contents endpoints, including real content commits, fast-forward compare-and-swap ref writes, durable bookkeeping, crash recovery, and immediate visibility through normal Git clone and fetch.

**Architecture:** Extend the plan-1 `fornacast_api` boundary with ordered slash-bearing routes and versioned Git-data serializers, but keep Git traversal and mutation in `git_core` and repository policy, durable operations, fencing, and reconciliation in `forge_repos`. Plan every content object before SQL preparation, write native Git objects without moving a ref, then advance the ref with one bounded compare-and-swap and finish metadata plus deduplicated audit in SQL. Share hard-capped read, memory, and writer limiters with REST, HTTP receive-pack, SSH receive-pack, and later merge/tag slices.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Ecto 3.14 with Turso and PostgreSQL, Rustler 0.38, Rust, gix 0.85, Bandit 1.12, ExUnit, the Git CLI as an integration-test oracle, and the two pinned GHES 3.21 OpenAPI descriptions.

---

**Approved specification:** `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`

**Depends on:** `docs/superpowers/plans/2026-07-21-github-api-foundation.md` is complete.

## Scope and execution guardrails

- Implement only branches, Git refs, commits, contents, real `auto_init`, shared Git mutation primitives, durable Git-write recovery, and receive-pack integration.
- Do not add issues, pull requests, merge commits, releases, tags, assets, ref deletion, force pushes, submodule writes, symlink traversal, archive downloads, compare endpoints, or commit diff/patch media.
- Keep `FornacastAPI` controllers as adapters. Controllers decode route values, invoke one domain operation, select the established `FornacastAPI.Serializer` resource, and call `FornacastAPI.Response`.
- Authorize the target repository before calling `ForgeRepos.absolute_storage_path/1`, `GitCore`, or a filesystem function. Preserve private-resource masking as `404`.
- Do not shell out from application code. The Git CLI is permitted only in integration tests that prove native objects and refs are visible to ordinary clients.
- Keep every Git scan and write inside the relevant limiter and absolute monotonic deadline. A timeout or bounded-work error returns a sanitized `503` and never returns partial JSON.
- Do not hold a SQL transaction while reading a request body, walking Git history, writing Git objects, waiting for a limiter, or moving a ref.
- Use `Fornacast.OperationLease` for adapter-neutral claims. Do not use `FOR UPDATE`, advisory locks, `SKIP LOCKED`, or another adapter-specific locking primitive.
- The reconciliation scheduler owns timers and task dispatch only. Git, filesystem, and SQL recovery execute in supervised tasks, never inside a GenServer callback.
- Every ref-changing path uses `GitCore.RepositoryWriteLimiter` and `ForgeRepos.with_write_fence/3`, including HTTP receive-pack, SSH receive-pack, `auto_init`, and later merge/tag callers.
- Configuration may lower a limit but cannot raise it. `GitCore.Limits` clamps every runtime value to the hard ceiling before a limiter or native call consumes it.
- Format only touched Elixir and Rust files. Run only the scoped tests listed in this plan; if an unrelated test fails, record it and stop instead of widening this slice.
- Any qualifying upstream dependency defect follows the repository's upstream-dependency issue policy before a local workaround is considered.

## Fixed HTTP contract

### Route manifest

| Method | Path | Action | Authentication and permission |
| --- | --- | --- | --- |
| `GET` | `/api/v3/repos/:owner/:repo/branches` | List branches | Anonymous public read or `:repository_read` plus an accepted repository-read PAT scope |
| `GET` | `/api/v3/repos/:owner/:repo/branches/*branch` | Get branch | Same as branch list |
| `GET` | `/api/v3/repos/:owner/:repo/git/ref/*ref` | Get one ref | Same as branch list |
| `POST` | `/api/v3/repos/:owner/:repo/git/refs` | Create branch ref | `:repository_write` plus `:repository_mutation` scope |
| `PATCH` | `/api/v3/repos/:owner/:repo/git/refs/*ref` | Fast-forward branch ref | `:repository_write` plus `:repository_mutation` scope |
| `GET` | `/api/v3/repos/:owner/:repo/commits` | List commits | Same as branch list |
| `GET` | `/api/v3/repos/:owner/:repo/commits/*ref` | Get commit | Same as branch list |
| `GET` | `/api/v3/repos/:owner/:repo/contents/*path` | Read file or directory | Same as branch list |
| `PUT` | `/api/v3/repos/:owner/:repo/contents/*path` | Create or update file | `:repository_write` plus `:repository_mutation` scope |
| `DELETE` | `/api/v3/repos/:owner/:repo/contents/*path` | Delete file | `:repository_write` plus `:repository_mutation` scope |

Register collection routes before catch-alls, and register `GET /commits/*ref` after `GET /commits`. Do not add a second non-catch-all spelling for slash-bearing values.

### Operation and body manifest

| Operation | Required fields | Optional fields | Success |
| --- | --- | --- | --- |
| `git/create-ref` | `ref`, `sha` | none | `201` |
| `git/update-ref` | `sha` | `force`, accepted only when omitted or `false` | `200` |
| `repos/create-or-update-file-contents` | `message`, strict Base64 `content` | `sha`, `branch`, `committer`, `author` | `201` for create, `200` for update |
| `repos/delete-file` | `message`, `sha` | `branch`, `committer`, `author` | `200` |

- `POST /git/refs` accepts only a full `refs/heads/` name and an existing commit OID.
- `PATCH /git/refs/*ref` accepts either `heads/name` or `refs/heads/name` after one path decode and canonicalizes it to `refs/heads/name`.
- Ref creation requires expected absence. Ref update resolves the current OID once and compares against that exact OID.
- Ref updates are fast-forward only. `force: true`, malformed refs, duplicates, non-commit targets, and refs outside `refs/heads/*` return `422`. Stale compare-and-swap and non-fast-forward updates return `409`.
- Content creation requires path absence and rejects a supplied `sha`. Content update and delete require the current blob OID in `sha`. A mismatch returns `409`.
- `branch` defaults to the repository's configured default branch and must already exist, except the internal `auto_init` call which creates an expected-absent default branch.
- Commit signatures default to actor display name, falling back to username, actor email, current UTC time, and offset zero. A supplied signature requires non-empty `name` and `email` and rejects NUL, CR, or LF.
- PUT and DELETE use `FornacastAPI.RequestBody.read_json(conn, :contents, opts)` with a `140 MiB` JSON envelope, `120 s` total and `15 s` idle deadlines, and duplicate-key rejection. PUT then applies strict Base64 and a `100 MiB` decoded-content ceiling.
- Unsupported commit `diff` or `patch` media returns `406` before Git traversal. Contents supports the existing JSON media plus `application/vnd.github.raw+json`, `application/vnd.github.html+json`, and `application/vnd.github.object+json`.

### Slash-bearing route-value contract

Create `FornacastAPI.PathValue.decode(segments, resource, field)` as the single decode boundary for branch, ref, commit-ref, and content catch-alls:

~~~elixir
@spec decode([String.t()], String.t(), String.t()) ::
        {:ok, String.t()} | {:error, {:validation, [FornacastAPI.Error.validation_error()]}}
~~~

Join router-provided segments with `/`, percent-decode exactly once, validate UTF-8, and normalize only by accepting segmented and percent-encoded slash spellings as the same logical value. Reject an invalid percent triplet, a remaining encoded `%25` sequence, NUL, backslash, empty required values, `.` or `..` segments, absolute paths, Unicode normalization ambiguity, and refname injection. The decoder returns a logical value, never a storage path.

### Hard limits

| Limit | Hard ceiling |
| --- | ---: |
| Active Git scans per node | `4` |
| Git scan deadline | `30_000 ms` |
| Commits visited per request | `50_000` |
| Tree entries visited per request | `100_000` |
| Changed paths visited per request | `10_000` |
| Materialized patch bytes | `20_971_520` |
| Active blob reads per node | `8` |
| Aggregate blob reservation | `134_217_728 bytes` |
| One contents blob | `104_857_600 bytes` |
| Active writers per repository | `1` |
| Active writers per node | `2` |
| Aggregate body-memory reservation | `536_870_912 bytes` |
| Maximum contents reservation | `251_658_240 bytes` |
| Contents JSON envelope | `146_800_640 bytes` |
| Ref/tag work deadline | `10_000 ms` |
| Content/merge/receive-pack Git-work deadline | `60_000 ms` |
| Contents/receive-pack body total deadline | `120_000 ms` |
| Contents/receive-pack idle-between-chunks deadline | `15_000 ms` |
| Receive-pack body | `104_857_600 bytes` |
| Reconciliation interval | `30_000 ms` |

`GitCore.Limits.get/1` reads a positive configured value and returns `min(configured, hard_ceiling)`. Missing values use the hard ceiling. Non-integer, zero, and negative values fail application startup with an `ArgumentError`. Native calls receive already-clamped values and independently reject values above the same compiled ceilings.

## Public domain and GitCore contracts

### Read values

Add typed values under `GitCore.ReadModel`:

~~~elixir
defmodule GitCore.Branch do
  @enforce_keys [:name, :ref, :oid, :commit]
  defstruct [:name, :ref, :oid, :commit, protected: false]
end

defmodule GitCore.Ref do
  @enforce_keys [:ref, :direct_oid, :direct_object_type]
  defstruct [:ref, :direct_oid, :direct_object_type, :peeled_commit_oid]
end

defmodule GitCore.CommitSummary do
  @enforce_keys [:oid, :tree_oid, :parents, :author, :committer, :message]
  defstruct [:oid, :tree_oid, :parents, :author, :committer, :message]
end

defmodule GitCore.CommitDetail do
  @enforce_keys [:oid, :tree_oid, :parents, :author, :committer, :message, :files]
  defstruct [:oid, :tree_oid, :parents, :author, :committer, :message, :files]
end

defmodule GitCore.ContentEntry do
  @enforce_keys [:type, :name, :path, :oid, :size, :mode]
  defstruct [:type, :name, :path, :oid, :size, :mode, :content]
end
~~~

Expose bounded functions:

~~~elixir
@spec exact_ref(Path.t(), String.t(), keyword()) ::
        {:ok, GitCore.Ref.t()} | {:error, GitCore.Error.t()}
@spec branch_page(Path.t(), keyword()) ::
        {:ok, GitCore.Page.t(GitCore.Branch.t())} | {:error, GitCore.Error.t()}
@spec commit_page(Path.t(), keyword()) ::
        {:ok, GitCore.Page.t(GitCore.CommitSummary.t())} | {:error, GitCore.Error.t()}
@spec commit_detail(Path.t(), String.t(), keyword()) ::
        {:ok, GitCore.CommitDetail.t()} | {:error, GitCore.Error.t()}
@spec content(Path.t(), String.t(), String.t(), keyword()) ::
        {:ok, GitCore.ContentEntry.t() | [GitCore.ContentEntry.t()]} |
        {:error, GitCore.Error.t()}
~~~

`commit_page/2` accepts only `sha`, `path`, `author`, `since`, `until`, `page`, and `per_page`. Resolve `sha` once, filter author by canonical author email or login-resolved email supplied by `forge_repos`, apply inclusive UTC bounds, and evaluate `path` by bounded tree-diff traversal. Every result page derives from one immutable start OID.

### Write values

Add:

~~~elixir
defmodule GitCore.Signature do
  @enforce_keys [:name, :email, :seconds, :offset_minutes]
  defstruct [:name, :email, :seconds, :offset_minutes]
end

defmodule GitCore.ContentPlan do
  @enforce_keys [
    :action,
    :ref,
    :path,
    :expected_ref_oid,
    :expected_blob_oid,
    :proposed_blob_oid,
    :proposed_tree_oid,
    :proposed_commit_oid,
    :object_batch
  ]
  defstruct [
    :action,
    :ref,
    :path,
    :expected_ref_oid,
    :expected_blob_oid,
    :proposed_blob_oid,
    :proposed_tree_oid,
    :proposed_commit_oid,
    :object_batch
  ]
end
~~~

Expose:

~~~elixir
@spec plan_content_change(Path.t(), map(), keyword()) ::
        {:ok, GitCore.ContentPlan.t()} | {:error, GitCore.Error.t()}
@spec write_content_change(Path.t(), GitCore.ContentPlan.t(), keyword()) ::
        {:ok, String.t()} | {:error, GitCore.Error.t()}
@spec compare_and_swap_ref(
        Path.t(),
        String.t(),
        String.t() | nil,
        String.t(),
        :fast_forward,
        keyword()
      ) :: {:ok, String.t()} | {:error, GitCore.Error.t()}
@spec plan_receive_pack(Path.t(), binary(), [map()], keyword()) ::
        {:ok, GitCore.ReceivePackPlan.t()} | {:error, GitCore.Error.t()}
@spec ingest_receive_pack(Path.t(), GitCore.ReceivePackPlan.t(), keyword()) ::
        {:ok, GitCore.ReceivePackPlan.t()} | {:error, GitCore.Error.t()}
@spec apply_receive_pack_refs(Path.t(), GitCore.ReceivePackPlan.t(), keyword()) ::
        {:ok, GitCore.ReceivePackResult.t()} | {:error, GitCore.Error.t()}
@spec invalidate_repository_cache(Path.t()) :: :ok
~~~

`plan_content_change/3` computes canonical blob, tree, and commit bytes plus OIDs without inserting an object or changing a ref. `write_content_change/3` verifies every planned hash, inserts the batch idempotently, and never changes a ref. `compare_and_swap_ref/6` is the only direct ref mutation primitive: expected `nil` means absence, the target must be a commit, and `:fast_forward` rejects ancestry violations. It returns the recorded new OID only after the ref transaction commits.

### Repository domain

Expose:

~~~elixir
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
        | :requires_authentication
        | {:insufficient_scope, [String.t()]}
        | {:validation, [validation_error()]}
        | {:conflict, :stale_ref | :non_fast_forward | :sha_mismatch}
        | {:payload_too_large, :blob | :contents | :receive_pack}
        | {:unavailable, atom()}

@spec list_branches(User.t() | nil, APIKey.t() | nil, String.t(), String.t(), map(), map()) ::
        {:ok, Fornacast.Page.t(GitCore.Branch.t())} | {:error, error_reason()}
@spec get_branch(User.t() | nil, APIKey.t() | nil, String.t(), String.t(), String.t(), map()) ::
        {:ok, GitCore.Branch.t()} | {:error, error_reason()}
@spec get_ref(User.t() | nil, APIKey.t() | nil, String.t(), String.t(), String.t(), map()) ::
        {:ok, GitCore.Ref.t()} | {:error, error_reason()}
@spec list_commits(User.t() | nil, APIKey.t() | nil, String.t(), String.t(), map(), map()) ::
        {:ok, Fornacast.Page.t(GitCore.CommitSummary.t())} | {:error, error_reason()}
@spec get_commit(User.t() | nil, APIKey.t() | nil, String.t(), String.t(), String.t(), map()) ::
        {:ok, GitCore.CommitDetail.t()} | {:error, error_reason()}
@spec get_content(User.t() | nil, APIKey.t() | nil, String.t(), String.t(), String.t(), map(), map()) ::
        {:ok, GitCore.ContentEntry.t() | [GitCore.ContentEntry.t()]} |
        {:error, error_reason()}

@spec create_ref(User.t(), APIKey.t(), Repository.t(), map(), map()) ::
        {:ok, GitCore.Ref.t()} | {:error, error_reason()}
@spec update_ref(User.t(), APIKey.t(), Repository.t(), String.t(), map(), map()) ::
        {:ok, GitCore.Ref.t()} | {:error, error_reason()}
@spec put_content(User.t(), APIKey.t(), Repository.t(), String.t(), map(), map()) ::
        {:ok, :created | :updated, GitCore.ContentEntry.t(), GitCore.CommitDetail.t()} |
        {:error, error_reason()}
@spec delete_content(User.t(), APIKey.t(), Repository.t(), String.t(), map(), map()) ::
        {:ok, GitCore.ContentEntry.t(), GitCore.CommitDetail.t()} |
        {:error, error_reason()}
@spec with_write_fence(Repository.t(), :ref | :content | :merge | :tag | :receive_pack, function()) ::
        term()
@spec reconcile_repository(Repository.t()) ::
        :ok | {:error, {:unavailable, atom()}}
~~~

Controllers extract `actor` and `api_key` from `conn.assigns.api_auth` and pass them as separate domain arguments; no domain app accepts `FornacastAPI.Authentication`. Read entry points accept plan-1 request metadata as the final map, use `ForgeAccounts.APIScope.authorize(api_key, :repository_read, visibility)` when authenticated, and use `ForgeRepos.fetch_authorized_repository/4` with `:repository_read`. `:git_read` remains exclusive to smart-HTTP authentication. Mutation admission uses `:repository_mutation` and `:repository_write`. When PAT authorization fails after visibility is known, return `{:error, {:insufficient_scope, APIScope.accepted_scopes(action, visibility)}}` so the API error preserves `X-Accepted-OAuth-Scopes`. Request metadata contains only `request_id`, `api_version`, `ip_address`, `user_agent`, and `token_id`.

`with_write_fence/3` accepts a two-argument function receiving the authorized absolute repository path and remaining monotonic deadline in milliseconds. It acquires `GitCore.RepositoryWriteLimiter`, runs every module configured through `ForgeRepos.RepositoryWriteReconcilers`, stops on an unexplained third ref value or unavailable callback, and only then invokes the function.

## Durable state and recovery contract

### `git_write_operations` row

Migration `20260721000200_create_git_write_operations.exs` creates:

| Column | Type | Constraint |
| --- | --- | --- |
| `id` | integer primary key | generated |
| `repository_id` | reference | non-null, delete cascade |
| `actor_user_id` | reference | nullable, delete nilifies |
| `request_id` | string | non-null |
| `kind` | string | non-null; `ref_create`, `ref_update`, `content_create`, `content_update`, `content_delete`, or `receive_pack` |
| `state` | string | non-null; `prepared`, `object_written`, `ref_advanced`, `bookkeeping_complete`, or `failed` |
| `target_ref` | string | non-null canonical full ref |
| `expected_oid` | string | nullable only for expected absence |
| `proposed_oid` | string | non-null |
| `result_blob_oid` | string | nullable; set for successful PUT |
| `failure_reason` | string | nullable sanitized reason code |
| `lease_owner` | string | nullable |
| `lease_expires_at` | UTC datetime | nullable |
| `lock_version` | integer | non-null, default `0` |
| `inserted_at`, `updated_at` | UTC datetime | non-null |

Create indexes on `[repository_id, state, id]` and `[lease_expires_at]`, plus a unique index on `[request_id, kind, target_ref]`. PostgreSQL receives named checks for kind, state, lowercase 40- or 64-hex OIDs, and a nonnegative lock version; the migration follows the existing `turso?/0` pattern and omits unsupported check DDL on Turso while changesets enforce the same values on both adapters.

Alter `audit_events` with nullable `request_id` and nullable string `operation_id`, then create a unique index on `[operation_id, action]`. Git writes use `"git_write:" <> Integer.to_string(operation.id)`. Null operation IDs preserve repeated ordinary audit actions.

### Monotonic transition and recovery table

| Persisted state | Current ref equals expected | Current ref equals proposed | Current ref is a third value |
| --- | --- | --- | --- |
| `prepared` | mark `failed` as `effect_not_started` | finish bookkeeping | record alert and return `503` |
| `object_written` | mark `failed` as `ref_not_advanced` | finish bookkeeping | record alert and return `503` |
| `ref_advanced` | record alert and return `503` | finish bookkeeping | record alert and return `503` |
| `bookkeeping_complete` | no work | no work | no work |
| `failed` | no work | no work | no work |

Expected absence is represented by `expected_oid == nil` and matches only a missing ref. Recovery never writes an object, creates a ref, or moves a ref. When proposed equals current, one `Ecto.Multi` updates `last_pushed_at`, inserts the operation-keyed audit event, and moves the operation to `bookkeeping_complete`. After that transaction commits, synchronously invalidate every cache entry for the repository before reporting success.

`Fornacast.OperationLease` claims an operation with a conditional `update_all` predicate over `id`, prior `lock_version`, and a missing or expired lease. A successful claim writes a unique node/process owner, expiry, and increments `lock_version`. Release and transition updates require the same owner plus latest lock version, clear lease fields, and increment the version. A zero-row update means lost ownership and performs no side effect.

`ForgeRepos.RepositoryWriteReconcilers` is the extension point for every durable operation that can affect repository refs. It reads an ordered application configuration of `{priority, name, module}` entries implementing `reconcile_repository_locked(repository, repository_path, absolute_deadline)`. This slice configures `{100, :git_writes, ForgeRepos.GitWriteRecovery}`; later plans append pull and release entries in root configuration without adding reverse Mix dependencies. The pure dispatcher validates unique names and modules, sorts by `{priority, name}`, and invokes them in the write caller's process, so no registry process can lose registrations after a restart. A module that cannot classify or finish an older operation returns `{:error, :unavailable}`, which stops the chain and blocks the new write.

Reconciliation runs:

1. immediately after `ForgeRepos.Application` starts;
2. every `30_000 ms`; and
3. synchronously when `with_write_fence/3` touches a repository with a non-terminal row.

`ForgeRepos.GitWriteReconciler` starts a `ForgeRepos.GitWriteTaskSupervisor` child. Its callbacks schedule or dispatch `Task.Supervisor.async_nolink/2` and handle task replies and `:DOWN` messages. The task queries a bounded page of 50 operation IDs, groups their repository IDs, acquires each repository writer, and lets `reconcile_repository_locked/3` claim operations in ascending ID order inside that fence. It never preclaims an operation outside the writer. The GenServer callback does not call `Fornacast.Repo`, `GitCore`, `ForgeRepos.absolute_storage_path/1`, or a filesystem function.

## File map

### Contracts, API, and fixtures

- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`.
- Modify `apps/fornacast_api/priv/openapi/fornacast-overlay.json`.
- Modify `apps/fornacast_api/lib/fornacast_api/router.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/error.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/url.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/request_body.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/path_value.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/branch_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/git_ref_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/commit_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/contents_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/contents_admission.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/git-data.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/git-data.json`.
- Create `apps/fornacast_api/test/path_value_test.exs`.
- Create `apps/fornacast_api/test/git_data_controller_test.exs`.
- Create `apps/fornacast_api/test/contents_admission_test.exs`.
- Modify `apps/fornacast_api/test/openapi_contract_test.exs`.
- Create `apps/fornacast_api/test/github_git_data_acceptance_test.exs`.

### GitCore

- Create `apps/git_core/lib/git_core/limits.ex`.
- Create `apps/git_core/lib/git_core/write_model.ex`.
- Create `apps/git_core/lib/git_core/body_memory_limiter.ex`.
- Create `apps/git_core/lib/git_core/repository_write_limiter.ex`.
- Modify `apps/git_core/lib/git_core.ex`.
- Modify `apps/git_core/lib/git_core/native.ex`.
- Modify `apps/git_core/lib/git_core/read_model.ex`.
- Modify `apps/git_core/lib/git_core/cache.ex`.
- Modify `apps/git_core/lib/git_core/application.ex`.
- Modify `apps/git_core/lib/git_core/scan_limiter.ex`.
- Modify `apps/git_core/lib/git_core/blob_limiter.ex`.
- Modify `apps/git_core/native/fornacast_git_core/src/lib.rs`.
- Create `apps/git_core/test/limits_test.exs`.
- Create `apps/git_core/test/write_limiters_test.exs`.
- Create `apps/git_core/test/repository_write_model_test.exs`.
- Modify `apps/git_core/test/repository_read_model_test.exs`.

### Durable repository orchestration

- Create `apps/fornacast/priv/repo/migrations/20260721000200_create_git_write_operations.exs`.
- Create `apps/fornacast/lib/fornacast/operation_lease.ex`.
- Modify `apps/fornacast/lib/fornacast/audit.ex`.
- Modify `apps/fornacast/lib/fornacast/audit_event.ex`.
- Create `apps/fornacast/test/operation_lease_test.exs`.
- Modify `apps/forge_repos/lib/forge_repos.ex`.
- Create `apps/forge_repos/lib/forge_repos/git_data.ex`.
- Create `apps/forge_repos/lib/forge_repos/git_write_operation.ex`.
- Create `apps/forge_repos/lib/forge_repos/git_writes.ex`.
- Create `apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex`.
- Create `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`.
- Create `apps/forge_repos/lib/forge_repos/git_write_reconciler.ex`.
- Modify `apps/forge_repos/lib/forge_repos/application.ex`.
- Modify `apps/forge_repos/lib/forge_repos/repository.ex`.
- Create `apps/forge_repos/test/git_data_test.exs`.
- Create `apps/forge_repos/test/git_writes_test.exs`.
- Create `apps/forge_repos/test/git_write_recovery_test.exs`.
- Modify `apps/forge_repos/test/forge_repos_test.exs`.

### Receive-pack and configuration

- Modify `apps/git_transport/mix.exs`.
- Modify `apps/git_transport/lib/git_transport/receive_pack.ex`.
- Modify `apps/git_transport/lib/git_transport/channel.ex`.
- Modify `apps/git_transport/test/git_transport_test.exs`.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`.
- Modify `apps/fornacast_web/test/git_http_push_test.exs`.
- Modify `config/config.exs`.
- Modify `config/test.exs`.
- Modify `README.md`.

### Task 1: Extend the pinned contracts and prove decode-once routing

**Files:**

- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`
- Modify: `apps/fornacast_api/priv/openapi/fornacast-overlay.json`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/path_value.ex`
- Create: `apps/fornacast_api/test/path_value_test.exs`
- Modify: `apps/fornacast_api/test/openapi_contract_test.exs`

- [ ] **Step 1: Add failing contract and path-value tests**

Assert the foundation's full first-release contract already contains these exact operation IDs:

~~~elixir
%{
  {"GET", "/repos/{owner}/{repo}/branches"} => "repos/list-branches",
  {"GET", "/repos/{owner}/{repo}/branches/{branch}"} => "repos/get-branch",
  {"GET", "/repos/{owner}/{repo}/git/ref/{ref}"} => "git/get-ref",
  {"POST", "/repos/{owner}/{repo}/git/refs"} => "git/create-ref",
  {"PATCH", "/repos/{owner}/{repo}/git/refs/{ref}"} => "git/update-ref",
  {"GET", "/repos/{owner}/{repo}/commits"} => "repos/list-commits",
  {"GET", "/repos/{owner}/{repo}/commits/{ref}"} => "repos/get-commit",
  {"GET", "/repos/{owner}/{repo}/contents/{path}"} => "repos/get-content",
  {"PUT", "/repos/{owner}/{repo}/contents/{path}"} =>
    "repos/create-or-update-file-contents",
  {"DELETE", "/repos/{owner}/{repo}/contents/{path}"} => "repos/delete-file"
}
~~~

Assert the source commit remains `03ca9c1cac754ec9b8369dc75de8a8c753c6e087`, the overlay owns the same slice-2 rows, and both generated documents now require `x-fornacast-implemented-through-slice: "2"`. Assert the 2026 contents schema preserves its submodule-field typing difference from 2022.

In `path_value_test.exs` cover:

~~~elixir
assert {:ok, "feature/x"} =
         PathValue.decode(["feature", "x"], "branch", "branch")

assert {:ok, "feature/x"} =
         PathValue.decode(["feature%2Fx"], "branch", "branch")

for value <- [
      ["feature%252Fx"],
      ["%ZZ"],
      ["..", "secret"],
      [".", "secret"],
      ["%00"],
      ["a%5Cb"],
      [<<0xFF>>]
    ] do
  assert {:error, {:validation, [_error]}} =
           PathValue.decode(value, "branch", "branch")
end
~~~

Add router-recognition assertions for the route order in the fixed manifest.

- [ ] **Step 2: Run the focused tests and verify the missing decoder and operations**

~~~bash
mix test apps/fornacast_api/test/path_value_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
~~~

Expected: the path test fails because `FornacastAPI.PathValue` is undefined, route recognition fails because the controllers are absent, and the generated delivery marker is still slice `1`. The ten pinned operations themselves are already present.

- [ ] **Step 3: Advance the generated delivery marker without changing the manifest**

Use the unchanged foundation pruner with implemented-through slice `2`. Preserve these plan-1 filenames:

~~~text
apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json
apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json
~~~

Do not hand-edit a response schema or overlay after generation. The full first-release operation set and slice ownership remain unchanged; only the generated implemented-through marker advances from `1` to `2`.

- [ ] **Step 4: Implement one strict route-value decoder**

Implement `decode/3` by validating percent triplets before `URI.decode/1`. Compare the decoded string to its NFC normalization and reject a difference instead of silently changing a Git name. Run ref values through the gix-compatible ref validator added in Task 4; before Task 4, this task covers transport-level forbidden characters and path segments.

- [ ] **Step 5: Add the ordered route skeleton**

Add every route through `:api_context` only; no mutation route uses a body-parser pipeline. Route catch-all segment lists unchanged to controllers, and controllers call `PathValue.decode/3` exactly once. Tasks 8 and 9 call `FornacastAPI.RequestBody.read_json/3` only after resolving and authorizing the repository.

- [ ] **Step 6: Regenerate and pass both-version contract tests**

~~~bash
rm -rf /tmp/fornacast-openapi-source
git clone --filter=blob:none --no-checkout https://github.com/github/rest-api-description.git /tmp/fornacast-openapi-source
git -C /tmp/fornacast-openapi-source checkout 03ca9c1cac754ec9b8369dc75de8a8c753c6e087 -- descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json
mix run scripts/prune_github_openapi.exs -- /tmp/fornacast-openapi-source apps/fornacast_api/priv/openapi 2
mix test apps/fornacast_api/test/path_value_test.exs apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
git diff --check -- apps/fornacast_api
~~~

Expected: both pinned artifacts retain the complete first-release manifest with implemented-through marker `2`, both versions validate, every Git-data route recognizes its controller action, and all invalid encodings return one stable validation error.

- [ ] **Step 7: Commit the contract and route boundary**

~~~bash
git add apps/fornacast_api/priv/openapi apps/fornacast_api/lib/fornacast_api/router.ex apps/fornacast_api/lib/fornacast_api/path_value.ex apps/fornacast_api/test/path_value_test.exs apps/fornacast_api/test/openapi_contract_test.exs
git commit -m "feat(api): add Git data contracts and routes"
~~~

### Task 2: Hard-cap Git work, body memory, and repository writers

**Files:**

- Create: `apps/git_core/lib/git_core/limits.ex`
- Create: `apps/git_core/lib/git_core/body_memory_limiter.ex`
- Create: `apps/git_core/lib/git_core/repository_write_limiter.ex`
- Modify: `apps/git_core/lib/git_core/scan_limiter.ex`
- Modify: `apps/git_core/lib/git_core/blob_limiter.ex`
- Modify: `apps/git_core/lib/git_core/application.ex`
- Create: `apps/git_core/test/limits_test.exs`
- Create: `apps/git_core/test/write_limiters_test.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Write failing ceiling and limiter tests**

Assert `GitCore.Limits.get/1` returns each hard value from the table above when configuration is absent, accepts a lower positive value, clamps a higher value to the hard ceiling, and raises for a non-integer, zero, or negative setting.

Test `BodyMemoryLimiter` with explicit processes and monitor cleanup:

- weighted reservations totaling exactly `536_870_912` succeed;
- the next byte returns `{:error, :busy}` after a bounded 250 ms admission wait;
- releasing or killing an owner returns its full weight once;
- a requested weight above the pool returns `{:error, :too_large}` without queuing.

Test `RepositoryWriteLimiter`:

- two different repository keys may write concurrently;
- a third repository waits;
- a second writer for either active repository waits even when a node permit is available;
- FIFO waiters resume after release;
- owner death releases both repository and node permits;
- an absolute deadline returns `{:error, :timeout}` and removes the waiter.

- [ ] **Step 2: Run the focused tests and verify missing modules**

~~~bash
mix test apps/git_core/test/limits_test.exs apps/git_core/test/write_limiters_test.exs --max-cases 1
~~~

Expected: compilation fails because `GitCore.Limits`, `GitCore.BodyMemoryLimiter`, and `GitCore.RepositoryWriteLimiter` do not exist.

- [ ] **Step 3: Implement one hard-ceiling registry**

Use this key map in `GitCore.Limits`:

~~~elixir
@hard %{
  scan_concurrency: 4,
  scan_deadline_ms: 30_000,
  commit_visits: 50_000,
  tree_entry_visits: 100_000,
  changed_path_visits: 10_000,
  patch_bytes: 20_971_520,
  blob_concurrency: 8,
  blob_reserved_bytes: 134_217_728,
  blob_bytes: 104_857_600,
  repository_writer_concurrency: 2,
  body_memory_bytes: 536_870_912,
  contents_reservation_bytes: 251_658_240,
  contents_json_bytes: 146_800_640,
  ref_deadline_ms: 10_000,
  content_deadline_ms: 60_000,
  receive_pack_bytes: 104_857_600,
  body_total_timeout_ms: 120_000,
  body_idle_timeout_ms: 15_000,
  reconcile_interval_ms: 30_000
}
~~~

Read overrides from `Application.get_env(:git_core, :limits, [])`. Return `min(value, Map.fetch!(@hard, key))` after positive-integer validation. Expose `hard/1` for native-bound tests; do not expose a caller-supplied override on public operations.

- [ ] **Step 4: Add monitored weighted and keyed limiters**

Give both limiters `acquire` and `release` calls that return opaque lease references. `BodyMemoryLimiter.acquire(bytes, timeout_ms)` is FIFO and weighted. `RepositoryWriteLimiter.acquire(repository_key, deadline_ms)` enforces the one-per-key and two-per-node constraints in one server state update. Both monitor owner PIDs and make release idempotent.

Start children in this order:

~~~elixir
[
  GitCore.ScanLimiter,
  GitCore.BlobLimiter,
  GitCore.BodyMemoryLimiter,
  GitCore.RepositoryWriteLimiter,
  GitCore.Cache
]
~~~

Modify existing scan and blob limiters to read lower configured ceilings through `GitCore.Limits` while preserving their current monitor and queue behavior.

- [ ] **Step 5: Add explicit default and test configuration**

Set every key in the `@hard` map under `config :git_core, :limits` in `config/config.exs`. In `config/test.exs` keep the same values unless an individual test uses `Application.put_env/3` with `on_exit` restoration. No runtime environment variable may bypass `GitCore.Limits.get/1`.

- [ ] **Step 6: Pass deterministic limiter tests**

~~~bash
mix test apps/git_core/test/limits_test.exs apps/git_core/test/write_limiters_test.exs --max-cases 1
mix test apps/git_core/test/scan_limiter_test.exs apps/git_core/test/blob_limiter_test.exs --max-cases 1
~~~

Expected: both new limiters enforce node and repository bounds, all owner-death cases release capacity, and configured values above hard ceilings remain clamped.

- [ ] **Step 7: Commit the shared limits**

~~~bash
git add config/config.exs config/test.exs apps/git_core/lib/git_core/limits.ex apps/git_core/lib/git_core/body_memory_limiter.ex apps/git_core/lib/git_core/repository_write_limiter.ex apps/git_core/lib/git_core/scan_limiter.ex apps/git_core/lib/git_core/blob_limiter.ex apps/git_core/lib/git_core/application.ex apps/git_core/test/limits_test.exs apps/git_core/test/write_limiters_test.exs
git commit -m "feat(git): bound body memory and repository writers"
~~~

### Task 3: Add bounded branch, ref, commit, and contents reads

**Files:**

- Modify: `apps/git_core/lib/git_core/read_model.ex`
- Modify: `apps/git_core/lib/git_core.ex`
- Modify: `apps/git_core/lib/git_core/native.ex`
- Modify: `apps/git_core/native/fornacast_git_core/src/lib.rs`
- Modify: `apps/git_core/test/repository_read_model_test.exs`

- [ ] **Step 1: Add failing typed read tests**

Build one bare repository fixture with:

- `main` and slash-bearing `feature/api/v3` branches;
- authored commits before, within, and after a UTC range;
- two author emails;
- nested regular and executable files;
- a symlink and a gitlink entry;
- enough synthetic history and tree entries to cross each configurable lower test bound.

Assert exact ref lookup never prefix-matches. For an annotated tag, assert `direct_oid` is the tag object, `direct_object_type` is `"tag"`, and `peeled_commit_oid` is the commit; for a branch, direct and peeled commit OIDs match. Assert branch pages are lexically stable with deterministic pagination. Assert commit list combines `sha`, `path`, `author`, `since`, and `until` against one resolved starting OID. Assert file content uses `BlobLimiter` and strict `100 MiB` maximum, while a directory returns metadata without reading child blobs.

Inject low limits and assert typed errors:

~~~elixir
assert {:error, %GitCore.Error{kind: :work_limit}} = result
assert {:error, %GitCore.Error{kind: :deadline}} = timed_out
assert {:error, %GitCore.Error{kind: :too_large}} = oversized_blob
~~~

No limit case may return a shortened success page.

- [ ] **Step 2: Run the read-model test and verify missing APIs**

~~~bash
mix test apps/git_core/test/repository_read_model_test.exs --only github_git_data --max-cases 1
~~~

Expected: tests fail on missing `exact_ref/3`, `branch_page/2`, `commit_detail/3`, `content/4`, and filtered `commit_page/2` behavior.

- [ ] **Step 3: Extend native reads with explicit budgets**

Reuse the repository snapshot and object decoding already used by `ref_page/4`, `commit_page/4`, `commit/2`, `read_tree/3`, and `read_blob_complete/4`. Add:

- exact full-ref lookup with the direct ref-target OID/type plus a separately nullable peeled commit OID;
- `refs/heads/`-only branch paging;
- one commit walker accepting a resolved start OID and all filters;
- bounded parent-tree comparisons for `path` filtering and commit-file metadata;
- file lookup that distinguishes blob, tree, symlink, and gitlink without following symlink or submodule targets;
- directory listing with deterministic bytewise name ordering.

Carry one native budget object containing deadline, commits, tree entries, changed paths, and patch bytes. Decrement at the visit point and return a typed error before appending a partial entry.

- [ ] **Step 4: Apply BEAM limiters and immutable snapshot rules**

Wrap branch/ref, commit, and directory reads in `GitCore.ScanLimiter` with a `30_000 ms` maximum deadline. Wrap only complete blob materialization in `GitCore.BlobLimiter` using metadata size as reservation weight. Resolve branch, tag, or commit expressions once before walking and pass only the immutable OID into subsequent native work.

Map native errors to stable `GitCore.Error.kind` values: `:not_found`, `:invalid`, `:too_large`, `:work_limit`, `:deadline`, and `:unavailable`. Do not return raw gix messages beyond `git_core`.

- [ ] **Step 5: Pass Elixir and Rust read tests**

~~~bash
mix test apps/git_core/test/repository_read_model_test.exs --only github_git_data --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml bounded_api_reads
~~~

Expected: filters compose against one snapshot, every ceiling returns the specified typed error, and symlink or submodule content is described without traversal.

- [ ] **Step 6: Preserve the existing read suite**

~~~bash
mix test apps/git_core/test/git_core_test.exs apps/git_core/test/repository_read_model_test.exs --max-cases 1
~~~

Expected: existing ref, commit, tree, blob, scan-limiter, blob-limiter, and cache tests continue to pass.

- [ ] **Step 7: Commit bounded API reads**

~~~bash
git add apps/git_core/lib/git_core.ex apps/git_core/lib/git_core/native.ex apps/git_core/lib/git_core/read_model.ex apps/git_core/native/fornacast_git_core/src/lib.rs apps/git_core/test/repository_read_model_test.exs
git commit -m "feat(git): add bounded Git data reads"
~~~

### Task 4: Plan and write native objects, compare refs, and invalidate caches

**Files:**

- Create: `apps/git_core/lib/git_core/write_model.ex`
- Modify: `apps/git_core/lib/git_core.ex`
- Modify: `apps/git_core/lib/git_core/native.ex`
- Modify: `apps/git_core/lib/git_core/cache.ex`
- Modify: `apps/git_core/native/fornacast_git_core/src/lib.rs`
- Create: `apps/git_core/test/repository_write_model_test.exs`

- [ ] **Step 1: Write failing object-plan and CAS tests**

Test create, update, and delete under nested directories. For every action:

1. snapshot `objects/` and the target ref;
2. call `plan_content_change/3` and assert neither snapshot changes;
3. call `write_content_change/3` and assert objects exist but the ref is unchanged;
4. call `compare_and_swap_ref/6` and assert `git cat-file -p` shows the exact blob, tree, parent, author, committer, and message;
5. clone or fetch and assert the new file state is visible.

Cover empty-repository creation with expected-absent `refs/heads/main`, regular/executable mode preservation on update, removal of newly empty parent trees on delete, a mismatched blob SHA, path already present or absent, traversal through symlink or gitlink, invalid signature bytes, stale expected ref, target that is not a commit, non-fast-forward update, and duplicate ref creation.

Add cache tests that insert keys for two repository paths, invalidate one path, and prove every key whose first tuple element is that exact path is gone while the other repository remains cached.

- [ ] **Step 2: Run the write tests and verify no native writer exists**

~~~bash
mix test apps/git_core/test/repository_write_model_test.exs --max-cases 1
~~~

Expected: tests fail because `GitCore.ContentPlan`, `plan_content_change/3`, `write_content_change/3`, `compare_and_swap_ref/6`, and `invalidate_repository_cache/1` are missing.

- [ ] **Step 3: Implement deterministic planning without insertion**

Use gix object encoders to construct canonical blob, updated tree chain, and commit bytes in memory. Hash the exact bytes with the repository object format. Return an opaque `object_batch` plus public proposed OIDs; never include file bytes in logs, errors, telemetry, audit metadata, or SQL.

For a create on an empty repository, start from an empty tree and expected ref absence. For update/delete, resolve the supplied ref once and retain it as `expected_ref_oid`. Require the caller's blob `sha` to equal the leaf blob OID. Reject any path component that resolves to a symlink or gitlink. Preserve an existing regular or executable mode on update; create new files as regular non-executable.

- [ ] **Step 4: Insert the planned batch idempotently**

`write_content_change/3` recomputes each hash from `object_batch`, compares it to the plan, and writes blob, child trees, root tree, and commit through gix's object database. If an object already exists with the same OID, treat it as success. Return only `proposed_commit_oid` and do not open the refs store.

- [ ] **Step 5: Expose one fast-forward compare-and-swap**

Reuse the existing Rust helpers `current_ref_target`, `is_ancestor`, and the gix reference transaction logic used by receive-pack. Validate a canonical full ref, expected OID or absence, proposed commit existence, fast-forward ancestry when expected exists, and the remaining absolute deadline before committing the edit. Map stale expected and non-fast-forward to distinct typed conflicts without moving the ref.

Keep this exact call shape for later plans:

~~~elixir
GitCore.compare_and_swap_ref(
  repository_path,
  full_ref,
  expected_oid,
  proposed_oid,
  :fast_forward,
  deadline_ms: remaining_ms
)
~~~

- [ ] **Step 6: Split receive-pack object ingestion from ref application**

Refactor the current native `receive_pack` implementation into:

1. `plan_receive_pack/4`, which parses commands and the pack without writing, validates OIDs and policy, and returns an opaque object batch with canonical expected/proposed ref OIDs;
2. `ingest_receive_pack/3`, which verifies and writes the planned object batch without opening the refs store;
3. `apply_receive_pack_refs/3`, which rechecks all expected refs and applies the existing atomic gix ref transaction.

Retain the current deletion rejection, branch create/fast-forward policy, and tag-create behavior. Keep the existing public `GitCore.receive_pack/3` as a compatibility wrapper until Task 9 switches both transports.

- [ ] **Step 7: Add synchronous repository cache invalidation**

Add `GitCore.Cache.invalidate_repository(repository_path)` as a GenServer call that removes entries whose tuple key begins with the exact repository path and updates count and byte accounting. `GitCore.invalidate_repository_cache/1` returns only after the call completes; a cache process failure remains best-effort `:ok` because canonical Git state is already durable.

- [ ] **Step 8: Pass object, CAS, receive-pack, and cache tests**

~~~bash
mix test apps/git_core/test/repository_write_model_test.exs apps/git_core/test/repository_read_model_test.exs --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml native_content_write
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml receive_pack
~~~

Expected: planning is side-effect free, object insertion never moves a ref, only one correct CAS wins a race, receive-pack behavior is preserved, and invalidation removes no other repository's cache entries.

- [ ] **Step 9: Commit native Git write primitives**

~~~bash
git add apps/git_core
git commit -m "feat(git): add planned object writes and ref CAS"
~~~

### Task 5: Add durable operation rows, composable audit, and adapter-neutral leases

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260721000200_create_git_write_operations.exs`
- Create: `apps/fornacast/lib/fornacast/operation_lease.ex`
- Modify: `apps/fornacast/lib/fornacast/audit.ex`
- Modify: `apps/fornacast/lib/fornacast/audit_event.ex`
- Create: `apps/fornacast/test/operation_lease_test.exs`
- Create: `apps/forge_repos/lib/forge_repos/git_write_operation.ex`
- Create: `apps/forge_repos/test/git_writes_test.exs`

- [ ] **Step 1: Write failing migration, audit, and lease tests**

Assert the `GitWriteOperation` changeset requires every non-null field in the table above, accepts `expected_oid: nil` only for expected absence, normalizes OIDs to lowercase, and rejects unknown kinds, unknown states, unsafe failure strings, and negative lock versions.

Add an `Ecto.Multi` audit test:

~~~elixir
multi =
  Ecto.Multi.new()
  |> Fornacast.Audit.record_multi(
    :audit,
    actor,
    "git.ref.created",
    "repository",
    repository.id,
    %{"ref" => "refs/heads/feature/x", "result" => "success"},
    request_id: request_id,
    operation_id: "git_write:42",
    ip_address: "127.0.0.1",
    user_agent: "test"
  )

assert {:ok, %{audit: %Fornacast.AuditEvent{}}} = Repo.transaction(multi)
~~~

Run the same multi twice with the same operation ID and action and assert one row exists. Run twice with `operation_id: nil` and assert two rows exist.

For `OperationLease`, assert one of two concurrent claimers wins, an unexpired lease cannot be stolen, an expired lease can be reclaimed, stale release and transition attempts update zero rows, and current-owner release clears the lease and increments `lock_version`.

- [ ] **Step 2: Run the persistence tests and verify missing schema and APIs**

~~~bash
mix test apps/fornacast/test/operation_lease_test.exs apps/forge_repos/test/git_writes_test.exs --only persistence --max-cases 1
~~~

Expected: tests fail because the migration, `ForgeRepos.GitWriteOperation`, `Fornacast.OperationLease`, operation-keyed audit deduplication, and the extended audit option columns do not exist. The foundation's `Fornacast.Audit.record_multi/7-8` callback contract already exists.

- [ ] **Step 3: Create the exact migration**

Create `git_write_operations` and alter `audit_events` exactly as specified in the durable row section. Use these index names so both adapters and rollback tests agree:

~~~elixir
create index(:git_write_operations, [:repository_id, :state, :id],
         name: :git_write_operations_recovery_index
       )

create index(:git_write_operations, [:lease_expires_at],
         name: :git_write_operations_lease_index
       )

create unique_index(:git_write_operations, [:request_id, :kind, :target_ref],
         name: :git_write_operations_request_ref_index
       )

create unique_index(:audit_events, [:operation_id, :action],
         name: :audit_events_operation_action_index
       )
~~~

Follow existing migrations' `create_postgres_check/3` and `turso?/0` pattern. Make rollback remove the audit indexes and columns after dropping `git_write_operations`.

- [ ] **Step 4: Extend composable audit without replacing its contract**

Preserve the foundation's public signature and callback behavior while adding operation deduplication; do not introduce an alternate Git-specific audit helper:

~~~elixir
def record_multi(
      multi,
      key,
      actor,
      action,
      target_type,
      target_id,
      metadata,
      opts \\ []
    ) do
  Ecto.Multi.insert(
    multi,
    key,
    fn changes ->
      target_id = resolve_multi_value(target_id, changes)
      metadata = resolve_multi_value(metadata, changes)
      request_metadata = Keyword.get(opts, :request_metadata, %{})

      attrs =
        audit_attrs(
          actor,
          action,
          target_type,
          target_id,
          Map.merge(metadata || %{}, request_metadata),
          opts
        )

      Fornacast.AuditEvent.changeset(%Fornacast.AuditEvent{}, attrs)
    end,
    on_conflict: :nothing,
    conflict_target: [:operation_id, :action]
  )
end
~~~

Keep the foundation's `resolve_multi_value/2` callback behavior so callers can derive target IDs and metadata from earlier multi results. `audit_attrs/7` accepts the foundation's `request_metadata:` map and the explicit `request_id:`, `operation_id:`, `ip_address:`, and `user_agent:` options used by durable operations; an explicit option wins over the corresponding request-metadata value. Preserve `record/6` by building a one-insert multi, executing `Fornacast.Repo.transaction/1`, and returning the inserted event or database error in its existing shape. Never put raw tokens, content bytes, commit messages, or repository storage paths in metadata.

- [ ] **Step 5: Implement one reusable lease primitive**

Expose:

~~~elixir
@spec claim(module(), pos_integer(), String.t(), DateTime.t(), pos_integer()) ::
        {:ok, struct()} | :busy | {:error, :not_found}
@spec release(module(), struct()) :: :ok | {:error, :lost_lease}
@spec update_owned(module(), struct(), keyword()) ::
        {:ok, struct()} | {:error, :lost_lease}
~~~

`claim/5` first reads the row and then performs one conditional `Repo.update_all` matching `id` and the read `lock_version`, with `is_nil(lease_expires_at) or lease_expires_at <= now`. Set `lease_owner`, set expiry to `now + lease_seconds`, and increment `lock_version`. Read back only after the update count is one. `release/2` and `update_owned/3` match `id`, `lease_owner`, and current `lock_version`. All callers treat a zero update count as loss of ownership.

- [ ] **Step 6: Run migrations and pass both persistence suites**

~~~bash
MIX_ENV=test mix ecto.migrate
mix test apps/fornacast/test/operation_lease_test.exs apps/forge_repos/test/git_writes_test.exs --only persistence --max-cases 1
~~~

Expected: schema constraints hold, audit insertion composes with caller multis, operation audit repeats are deduplicated, and lease ownership remains correct under races and expiry.

- [ ] **Step 7: Commit persistence primitives**

~~~bash
git add apps/fornacast/priv/repo/migrations/20260721000200_create_git_write_operations.exs apps/fornacast/lib/fornacast/operation_lease.ex apps/fornacast/lib/fornacast/audit.ex apps/fornacast/lib/fornacast/audit_event.ex apps/fornacast/test/operation_lease_test.exs apps/forge_repos/lib/forge_repos/git_write_operation.ex apps/forge_repos/test/git_writes_test.exs
git commit -m "feat(repos): add durable Git write operations"
~~~

### Task 6: Add repository-authorized Git data reads

**Files:**

- Create: `apps/forge_repos/lib/forge_repos/git_data.ex`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Create: `apps/forge_repos/test/git_data_test.exs`

- [ ] **Step 1: Write failing domain read tests**

Cover anonymous public access, private `404` masking, collaborator and owner access, invalid or insufficient PAT scopes, branch/ref not found, default-branch commit listing, slash-bearing refs passed as already-decoded logical values, all five commit filters, pagination, file and directory contents, empty repositories, blob-too-large, bounded-work failure, and deadline failure.

Install a path-call test double or trace point around `ForgeRepos.absolute_storage_path/1` and assert it is never reached for an unauthorized repository.

- [ ] **Step 2: Run the focused domain test and verify no Git-data context exists**

~~~bash
mix test apps/forge_repos/test/git_data_test.exs --max-cases 1
~~~

Expected: tests fail because `ForgeRepos.GitData` and the six read entry points do not exist.

- [ ] **Step 3: Centralize read authorization before storage resolution**

Implement one private target function used by all six operations:

~~~elixir
with {:ok, repository} <-
       ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
     :ok <- authorize_git_read(api_key, repository.visibility),
     {:ok, path} <- ForgeRepos.absolute_storage_path(repository) do
  fun.(repository, path)
end
~~~

For anonymous callers, permit only public repositories. For authenticated callers, invoke `ForgeAccounts.APIScope.authorize(api_key, :repository_read, visibility)`; on failure return `{:insufficient_scope, APIScope.accepted_scopes(:repository_read, visibility)}`. Map every unauthorized private lookup to `:not_found` before any Git path call. Keep `:git_read` exclusive to smart-HTTP authentication.

- [ ] **Step 4: Adapt bounded GitCore pages without leaking internals**

Validate `page` and `per_page` with the established `FornacastAPI.Pagination` contract at the controller boundary, then pass the positive values into `GitCore`. Build `%Fornacast.Page{}` using stable Git result totals. Resolve an author login to the active user's email before calling `GitCore.commit_page/2`; an unknown login returns an empty page without scanning Git.

Map typed errors:

| GitCore kind | Domain result |
| --- | --- |
| `:not_found` | `{:error, :not_found}` |
| `:invalid` | `{:error, {:validation, errors}}` |
| `:too_large` | `{:error, {:payload_too_large, :blob}}` |
| `:work_limit`, `:deadline`, `:unavailable` | `{:error, {:unavailable, :git_read}}` |

- [ ] **Step 5: Pass authorization, filter, and bound tests**

~~~bash
mix test apps/forge_repos/test/git_data_test.exs --max-cases 1
~~~

Expected: every read is authorized before storage resolution, filters and pagination are deterministic, private resources are masked, and no native or filesystem detail crosses the domain result.

- [ ] **Step 6: Commit the Git-data read context**

~~~bash
git add apps/forge_repos/lib/forge_repos.ex apps/forge_repos/lib/forge_repos/git_data.ex apps/forge_repos/test/git_data_test.exs
git commit -m "feat(repos): add authorized Git data reads"
~~~

### Task 7: Orchestrate durable ref and content writes behind one fence

**Files:**

- Create: `apps/forge_repos/lib/forge_repos/git_writes.ex`
- Create: `apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex`
- Create: `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`
- Create: `apps/forge_repos/lib/forge_repos/git_write_reconciler.ex`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/application.ex`
- Modify: `apps/forge_repos/lib/forge_repos/repository.ex`
- Modify: `config/config.exs`
- Modify: `apps/forge_repos/test/git_writes_test.exs`
- Create: `apps/forge_repos/test/git_write_recovery_test.exs`

- [ ] **Step 1: Write failing mutation, fence, and recovery tests**

For create-ref, update-ref, content create, content update, and content delete, inject a process exit immediately after each persisted state:

~~~text
prepared
object_written
ref_advanced
bookkeeping_complete
~~~

Assert the recovery table exactly:

- expected ref still current after `prepared` or `object_written` becomes terminal `failed` without moving the ref;
- proposed ref current completes metadata and audit once;
- a third ref value keeps the operation diagnosable, emits one deduplicated alert, and makes the next write return `{:error, {:unavailable, :write_fence}}`;
- terminal rows are never reclaimed;
- expired leases resume, while live leases are skipped;
- `last_pushed_at`, operation-keyed audit, and `bookkeeping_complete` commit atomically;
- cache invalidation happens after SQL commit and before a successful domain return;
- a forced SQL failure after ref advancement never returns success and is completed by recovery.

Race two expected-absence creates and two updates from the same expected OID. Assert one CAS wins, the loser returns a conflict, and neither race creates duplicate audit rows.

- [ ] **Step 2: Run write and recovery tests and verify the orchestrator is missing**

~~~bash
mix test apps/forge_repos/test/git_writes_test.exs apps/forge_repos/test/git_write_recovery_test.exs --max-cases 1
~~~

Expected: tests fail because `ForgeRepos.GitWrites`, `ForgeRepos.GitWriteRecovery`, `ForgeRepos.RepositoryWriteReconcilers`, `ForgeRepos.with_write_fence/3`, and the recovery supervisor are undefined.

- [ ] **Step 3: Implement the repository write fence**

Use this shape:

~~~elixir
def with_write_fence(repository, class, fun) when is_function(fun, 2) do
  deadline_ms = write_deadline(class)
  deadline = System.monotonic_time(:millisecond) + deadline_ms

  case GitCore.RepositoryWriteLimiter.acquire(repository.id, deadline) do
    {:ok, lease} ->
      try do
        with {:ok, repository_path} <- absolute_storage_path(repository),
             :ok <-
               RepositoryWriteReconcilers.reconcile_locked(
                 repository,
                 repository_path,
                 deadline
               ) do
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)
          fun.(repository_path, remaining)
        end
      after
        GitCore.RepositoryWriteLimiter.release(lease)
      end

    {:error, reason} ->
      {:error, reason}
  end
end
~~~

`:ref` and `:tag` use the clamped 10-second deadline; `:content`, `:merge`, and `:receive_pack` use the clamped 60-second deadline. On-touch reconciliation runs after acquiring the writer and before resolving the new mutation's current ref.

Configure `repository_write_reconcilers: [{100, :git_writes, ForgeRepos.GitWriteRecovery}]` for `:forge_repos`. `entries/0` rejects duplicate names and modules that do not export `reconcile_repository_locked/3`, then sorts by `{priority, name}`. Test invalid configuration, deterministic ordering, absolute-deadline propagation, short-circuiting on an unavailable callback, and successful fall-through. Later slices append `:pull_merges` and `:release_tags`; callbacks must not create a second repository writer or reacquire the current writer lease.

- [ ] **Step 4: Prepare each operation before an external side effect**

Inside the fence:

1. canonicalize the target `refs/heads/` name;
2. resolve required commit, ref, and blob inputs once;
3. for contents, call side-effect-free `GitCore.plan_content_change/3`;
4. insert a `prepared` row with actor, safe request ID, target ref, exact expected OID or absence, proposed commit OID, and result blob OID;
5. perform no further validation that could have been completed before preparation.

For ref create/update, the proposed commit already exists. Persist the `prepared -> object_written` transition after rechecking it is a commit. For contents, write the planned batch and persist `object_written` only after `GitCore.write_content_change/3` returns the planned commit OID.

Do not persist `object_batch`, decoded content, commit message, signature email, PAT, storage path, or native error text.

- [ ] **Step 5: Compare-and-swap and checkpoint advancement**

Call `GitCore.compare_and_swap_ref/6` with the operation's recorded values and remaining deadline. Persist `ref_advanced` only when it returns `proposed_oid`. If the call proves stale or non-fast-forward before this operation moved the ref, conditionally mark the owned row `failed` with `cas_conflict` or `non_fast_forward` and return `409`. A timeout, lost lease, unknown outcome, or storage failure remains recoverable and returns sanitized `503`.

- [ ] **Step 6: Finish metadata and audit in one multi**

Use one function for foreground and recovery completion:

~~~elixir
Ecto.Multi.new()
|> Ecto.Multi.update_all(
  :repository,
  from(r in ForgeRepos.Repository, where: r.id == ^repository.id),
  set: [last_pushed_at: now]
)
|> Fornacast.Audit.record_multi(
  :audit,
  operation.actor,
  audit_action(operation.kind),
  "repository",
  repository.id,
  %{
    "ref" => operation.target_ref,
    "oid" => operation.proposed_oid,
    "result" => "success"
  },
  request_id: operation.request_id,
  operation_id: "git_write:" <> Integer.to_string(operation.id)
)
|> Ecto.Multi.update(:operation, bookkeeping_changeset(operation))
|> Fornacast.Repo.transaction()
~~~

Load the actor separately when needed; do not place an Ecto association in the durable row contract. After the transaction, call `GitCore.invalidate_repository_cache(repository_path)` synchronously, then read the resulting ref/commit/content for the response. No successful tuple is returned before all three actions finish.

- [ ] **Step 7: Implement comparison-only recovery**

`GitWriteRecovery.reconcile_repository_locked/3` selects non-terminal rows in ascending `id`, claims one with `Fornacast.OperationLease`, reads only its exact `target_ref`, and applies the recovery table. It does not write an object or call `compare_and_swap_ref/6`.

When a third value is found, retain the non-terminal state, set sanitized `failure_reason: "unexpected_ref"` through the owned lease update, and insert `git.write.recovery_blocked` using the same operation ID. Release the lease and return `{:error, :unavailable}` so the fence blocks the new mutation. This audit insert is separately transactional and deduplicated by `[operation_id, action]`.

Expose `reconcile_repository/1` for on-demand callers. It acquires the repository writer and delegates to `reconcile_repository_locked/3`; the locked function never reacquires the limiter.

- [ ] **Step 8: Dispatch startup and periodic recovery through supervised tasks**

Start:

~~~elixir
children = [
  {Task.Supervisor, name: ForgeRepos.GitWriteTaskSupervisor},
  ForgeRepos.GitWriteReconciler
]
~~~

`GitWriteReconciler.init/1` returns `{:ok, state, {:continue, :dispatch}}`. `handle_continue/2` sends itself `:dispatch`. `handle_info(:dispatch, %{task: nil})` calls `Task.Supervisor.async_nolink(ForgeRepos.GitWriteTaskSupervisor, &GitWriteRecovery.reconcile_batch/0)`, stores only the task reference, and schedules the next dispatch for the clamped 30-second interval after completion or `:DOWN`.

`reconcile_batch/0` queries at most 50 non-terminal operation IDs ordered by `id`, loads each repository, and performs repository-grouped recovery under `RepositoryWriteLimiter`. No GenServer callback queries `Fornacast.Repo` or calls Git or filesystem code.

- [ ] **Step 9: Pass fault, race, scheduler, and fence tests**

~~~bash
mix test apps/forge_repos/test/git_writes_test.exs apps/forge_repos/test/git_write_recovery_test.exs --max-cases 1
~~~

Expected: every intermediate state follows the table, recovery never moves a ref, one writer per repository and two per node are observed, unexpected refs block later writes, and the scheduler's callbacks only dispatch supervised tasks.

- [ ] **Step 10: Commit durable write orchestration**

~~~bash
git add apps/forge_repos/lib/forge_repos.ex apps/forge_repos/lib/forge_repos/application.ex apps/forge_repos/lib/forge_repos/repository.ex apps/forge_repos/lib/forge_repos/git_writes.ex apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex apps/forge_repos/lib/forge_repos/git_write_recovery.ex apps/forge_repos/lib/forge_repos/git_write_reconciler.ex apps/forge_repos/test/git_writes_test.exs apps/forge_repos/test/git_write_recovery_test.exs config/config.exs
git commit -m "feat(repos): recover durable Git writes"
~~~

### Task 8: Serve branches, refs, commits, and contents reads

**Files:**

- Create: `apps/fornacast_api/lib/fornacast_api/controllers/branch_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/git_ref_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/commit_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/contents_controller.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/error.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/git-data.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/git-data.json`
- Create: `apps/fornacast_api/test/git_data_controller_test.exs`

- [ ] **Step 1: Write failing read-controller and golden tests**

For both API versions, cover:

- branch list and slash-bearing branch detail;
- exact ref detail through segmented and percent-encoded slash spelling;
- commit list with each filter alone and combined, pagination, and `Link`;
- commit detail by branch, tag, and full OID;
- file contents, directory contents, and `ref` query selection;
- JSON, raw, HTML, and object contents media;
- public anonymous read, private PAT read, insufficient scope, private masking, and missing resource;
- `503` for scan and work exhaustion, `413` for the exact domain tag `{:payload_too_large, :blob}`, and `406` for commit diff/patch media.

Validate every success body against both checked-in OpenAPI documents and the corresponding `git-data.json` fixture. Assert serializers obtain API and web links only through an extended `FornacastAPI.URL` facade and contain neither the internal API listener nor a storage path.

- [ ] **Step 2: Run the controller test and verify missing adapters**

~~~bash
mix test apps/fornacast_api/test/git_data_controller_test.exs --only reads --max-cases 1
~~~

Expected: tests fail because the four controllers and Git-data serializer resources are undefined.

- [ ] **Step 3: Implement thin controllers with one decode**

Use the plan-1 assigns:

~~~elixir
auth = conn.assigns.api_auth
actor = if auth, do: auth.actor
api_key = if auth, do: auth.api_key
metadata = FornacastAPI.Plugs.RequestContext.metadata(conn)
version = conn.assigns.api_version
~~~

Parse pagination through `FornacastAPI.Pagination.parse/1`. Decode each catch-all once through `FornacastAPI.PathValue.decode/3`. Call one `ForgeRepos.GitData` operation. Render tagged failures with `FornacastAPI.Error.from_domain/2` and `FornacastAPI.Response.error/2`.

When a repository-aware domain operation returns `{:insufficient_scope, accepted}`, map it with a new exact `Error.from_domain/2` clause to `403 Resource not accessible by personal access token` and `accepted_scopes: accepted`. Map `{:payload_too_large, _kind}` to `413 Payload Too Large`. These clauses precede the unclassified fallback, and their tests assert `X-Accepted-OAuth-Scopes` survives failures.

Branch list and commit list call `FornacastAPI.Response.paginated/5`. Detail and contents JSON call `Response.json/4`. The controller never assembles a URL, reads Git, checks a collaborator, or translates a gix error.

- [ ] **Step 4: Extend the established serializer facade**

Add resource atoms to both existing modules, not replacement serializer modules:

~~~elixir
:branch
:branch_list
:git_ref
:commit_summary
:commit_detail
:content_file
:content_directory
:content_object
~~~

Branch output contains canonical name, commit `sha` and API URL, `protected: false`, and the pinned schema's protection fields. Ref output contains canonical full `ref`, API URL, node ID, and an object built from `direct_object_type` and `direct_oid`; its URL selects the matching Git object route. Commit resolution may use `peeled_commit_oid`, but serializers and release recovery never substitute a peeled commit for the direct tag-ref target.

Commit summary/detail output uses the immutable commit OID for `sha`, tree and parent URLs, canonical author/committer name, email, and ISO-8601 date, verification fields supported by the pinned schema, and configured public web/API URLs. Detail additionally serializes bounded stats and file metadata; omit `patch` when the native result has none instead of emitting unbounded text.

Extend `FornacastAPI.URL` with the branch, ref, commit, contents, and web-repository builders used here. The facade reads the configured public origin; serializers never call `Fornacast.Config.base_url/0` directly and never use `conn.host` or the internal listener.

File contents output contains `type`, `encoding`, `size`, `name`, `path`, `content`, `sha`, `url`, `git_url`, `html_url`, `download_url`, and `_links`. Directory JSON is an ordered array. Object media wraps directory entries in the pinned object schema. The 2026 serializer alone applies its pinned submodule-field type; do not make the 2022 body imitate it.

- [ ] **Step 5: Negotiate contents media before domain work**

Extend `FornacastAPI.Plugs.MediaType` so only `repos/get-content` accepts:

~~~text
application/vnd.github.raw+json
application/vnd.github.html+json
application/vnd.github.object+json
~~~

Raw media sends exact blob bytes without Base64 and with the negotiated media type. HTML media returns escaped, non-executable source markup; it never interprets repository HTML. Directory raw or HTML requests follow the pinned contract error. Commit diff and patch requests return `406` before calling `ForgeRepos.GitData`.

- [ ] **Step 6: Pass both-version read and contract tests**

~~~bash
mix test apps/fornacast_api/test/git_data_controller_test.exs --only reads --max-cases 1
mix test apps/fornacast_api/test/openapi_contract_test.exs --max-cases 1
~~~

Expected: both API versions match their golden fixtures, all routes share plan-1 headers and rate behavior, and every URL is public-origin safe.

- [ ] **Step 7: Commit Git-data reads**

~~~bash
git add apps/fornacast_api/lib/fornacast_api/controllers apps/fornacast_api/lib/fornacast_api/error.ex apps/fornacast_api/lib/fornacast_api/url.ex apps/fornacast_api/lib/fornacast_api/plugs/media_type.ex apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex apps/fornacast_api/test/fixtures/2022-11-28/git-data.json apps/fornacast_api/test/fixtures/2026-03-10/git-data.json apps/fornacast_api/test/git_data_controller_test.exs
git commit -m "feat(api): serve Git data reads"
~~~

### Task 9: Admit and serve ref and contents mutations, then complete `auto_init`

**Files:**

- Create: `apps/fornacast_api/lib/fornacast_api/contents_admission.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/request_body.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/git_ref_controller.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/contents_controller.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Create: `apps/fornacast_api/test/contents_admission_test.exs`
- Modify: `apps/fornacast_api/test/git_data_controller_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_writes.ex`
- Modify: `apps/forge_repos/test/forge_repos_test.exs`
- Modify: `README.md`

- [ ] **Step 1: Write failing admission and mutation tests**

At the admission boundary assert:

- an unauthorized or masked target returns before `RequestBody.read_json/3` and before `BodyMemoryLimiter.acquire/2`;
- an over-limit `Content-Length` returns `413` without reading a body chunk;
- a chunked body crossing 140 MiB stops at the boundary and returns `413`;
- total and idle timeouts return `408`;
- duplicate keys fail before domain mutation;
- two maximum PUT reservations consume `480 MiB` and a third returns sanitized `503`;
- a slow admitted body holds memory but never holds `RepositoryWriteLimiter`;
- reservation release occurs on success, validation error, disconnect, domain error, and process exit.

At the endpoint boundary cover every required/optional field, strict Base64, decoded `100 MiB` overflow, create/update/delete SHA rules, default and explicit branches, custom/default signatures, `force: true`, stale CAS, non-fast-forward update, success statuses, operation audit, rate and scope headers, and both API versions.

Replace the plan-1 initializer handoff test: `auto_init: true` now returns `201` with a real default branch and README commit; `:git_initializer_unavailable` is no longer reachable.

- [ ] **Step 2: Run admission, mutation, and repository-create tests**

~~~bash
mix test apps/fornacast_api/test/contents_admission_test.exs apps/fornacast_api/test/git_data_controller_test.exs apps/forge_repos/test/forge_repos_test.exs --max-cases 1
~~~

Expected: admission tests fail because the `:contents` request-body policy and `ContentsAdmission` are absent, mutation tests fail on missing controller actions, and `auto_init` still returns `503`.

- [ ] **Step 3: Authorize the target before reading any mutation body**

Add `ForgeRepos.GitData.authorize_mutation_target/5` accepting actor, API key, owner, repo, and request metadata. It calls `fetch_authorized_repository/4` with `:repository_write`, then `APIScope.authorize(api_key, :repository_mutation, visibility)`, and returns `{:ok, repository}`. It resolves no storage path.

Each mutation controller performs:

1. require `conn.assigns.api_auth`;
2. decode catch-all path/ref once when present;
3. authorize the mutation target;
4. call `FornacastAPI.RequestBody.read_json/3`;
5. validate through `FornacastAPI.RequestValidator.validate(version, operation, body)`;
6. call one `ForgeRepos.GitWrites` operation.

Ref create/update use `read_json(conn, :ordinary, [])`. No mutation route uses a parser plug.

- [ ] **Step 4: Add the hard-capped contents request policy**

Extend `FornacastAPI.RequestBody` with:

~~~elixir
:contents => %{
  maximum_bytes: 146_800_640,
  total_timeout_ms: 120_000,
  idle_timeout_ms: 15_000
}
~~~

Read each configured value through `GitCore.Limits` or clamp it to the matching hard value before use. `ContentsAdmission.admit/2` receives an already-authorized repository assign and computes reservation bytes:

~~~elixir
def reservation_bytes("PUT", nil), do: 251_658_240
def reservation_bytes("PUT", encoded_bytes) do
  decoded_projection = min(div(encoded_bytes * 3 + 3, 4), 104_857_600)
  min(encoded_bytes + decoded_projection, 251_658_240)
end
def reservation_bytes("DELETE", nil), do: 146_800_640
def reservation_bytes("DELETE", encoded_bytes), do: encoded_bytes
~~~

Reject `encoded_bytes > 146_800_640` before acquisition. Acquire `GitCore.BodyMemoryLimiter` for at most 250 ms and return an opaque reservation. Assign it as `conn.assigns.contents_reservation` and register idempotent `release/1` before send. The controller explicitly releases it after the domain call returns; the before-send callback covers all earlier exits.

Use:

~~~elixir
FornacastAPI.RequestBody.read_json(
  conn,
  :contents,
  admission: {FornacastAPI.ContentsAdmission, :admit, [repository]}
)
~~~

- [ ] **Step 5: Validate and decode contents only under admission**

Both version validators enforce the exact operation/body manifest. Decode Base64 with `Base.decode64/2` using padding-required strict mode, reject whitespace and alternate alphabets, and check decoded bytes before calling `GitWrites.put_content/6`. Build `GitCore.Signature` values only after validating names and emails.

Never store or log the body map or decoded bytes. The controller retains decoded content only until `GitWrites` has completed object ingestion and releases the memory reservation in a `try/after`.

- [ ] **Step 6: Render compatible mutation responses**

Create-ref and update-ref serialize `:git_ref` with `201` and `200`. PUT emits:

~~~elixir
%{
  content: Serializer.render(version, :content_file, content),
  commit: Serializer.render(version, :commit_detail, commit)
}
~~~

Use `201` for create and `200` for update. DELETE returns `200` with `content: nil` and the commit object. Map malformed input and `force: true` to `422`, stale SHA/ref and non-fast-forward to `409`, decoded/body overflow to `413`, body timeout to `408`, and limiter, fence, deadline, or unknown outcome to `503`.

- [ ] **Step 7: Replace the temporary initializer with a real durable write**

In `ForgeRepos.create_api_repository/4`, preserve the foundation's actor, namespace, attribute, and request-metadata arguments plus its visibility, settings, row, storage, and audit behavior. Read `auto_init` from the existing attributes map; do not add a fifth argument. After the repository row and bare storage exist, `auto_init: true` calls an internal `GitWrites.initialize_repository/3` using:

~~~elixir
%{
  path: "README.md",
  branch: repository.default_branch,
  message: "Initial commit",
  content: "# " <> repository.name <> "\n",
  author: actor_signature,
  committer: actor_signature,
  expected_ref_oid: nil
}
~~~

The initializer uses the same `:content_create` operation, `with_write_fence(repository, :content, fun)`, object plan/write, expected-absent CAS, bookkeeping, audit deduplication, and cache invalidation as the contents endpoint. It bypasses a second PAT-scope check because the API controller authorized repository creation before calling the unchanged domain function. Return the repository `201` only after `bookkeeping_complete` and a successful exact-ref read.

Remove `:git_initializer_unavailable` from reachable `ForgeRepos` results and update plan-1 repository tests and README wording. Do not remove the generic error mapping until all callers and compatibility tests prove it unused.

- [ ] **Step 8: Pass admission, mutation, and initializer tests**

~~~bash
mix test apps/fornacast_api/test/contents_admission_test.exs apps/fornacast_api/test/git_data_controller_test.exs apps/forge_repos/test/forge_repos_test.exs apps/forge_repos/test/git_writes_test.exs --max-cases 1
~~~

Expected: body admission precedes reads, no slow client holds a writer permit, all ref/content writes produce real Git objects, `auto_init` produces README on the default branch, and no mutation reports success before durable bookkeeping.

- [ ] **Step 9: Commit API mutations and initialization**

~~~bash
git add apps/fornacast_api/lib/fornacast_api/contents_admission.ex apps/fornacast_api/lib/fornacast_api/request_body.ex apps/fornacast_api/lib/fornacast_api/controllers/git_ref_controller.ex apps/fornacast_api/lib/fornacast_api/controllers/contents_controller.ex apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex apps/fornacast_api/test/contents_admission_test.exs apps/fornacast_api/test/git_data_controller_test.exs apps/forge_repos/lib/forge_repos.ex apps/forge_repos/lib/forge_repos/git_writes.ex apps/forge_repos/test/forge_repos_test.exs README.md
git commit -m "feat(api): write refs and repository contents"
~~~

### Task 10: Put HTTP and SSH receive-pack behind admission, fencing, and recovery

**Files:**

- Modify: `apps/git_transport/mix.exs`
- Modify: `apps/git_transport/lib/git_transport/receive_pack.ex`
- Modify: `apps/git_transport/lib/git_transport/channel.ex`
- Modify: `apps/git_transport/test/git_transport_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`
- Modify: `apps/fornacast_web/test/git_http_push_test.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Write failing shared-admission and durable-push tests**

For Git HTTP assert:

- a writable repository and PAT are authenticated before body admission;
- `Content-Length` above the clamped cap returns transport failure before `read_body/2`;
- chunked overflow, 120-second total timeout, and 15-second idle timeout stop the read;
- memory exhaustion rejects before reading;
- a slow body owns a body-memory lease and no writer lease;
- accepted branch creation and fast-forward push finish durable operations, push metadata, audit, and cache invalidation before the status response is sent;
- a bookkeeping failure after native ref application does not send success and is completed by recovery;
- the next fetch sees the pushed ref immediately.

For SSH assert:

- admission occurs after key/repository authorization and before advertisement;
- the state owns one full-cap memory lease while receiving;
- byte overflow, total deadline, idle timer, client close, server failure, and channel termination release the lease exactly once;
- the writer is acquired only after EOF and successful command/pack parsing;
- branch creation and fast-forward update use the same durable operation and fence as HTTP;
- a third-value recovery block rejects the push without moving another ref.

Set `receive_pack_max_bytes` above `104_857_600` in one test and assert both transports still cap at `104_857_600`.

- [ ] **Step 2: Run transport tests and verify current post-response bookkeeping fails**

~~~bash
mix test apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
~~~

Expected: new tests fail because HTTP has no body-memory/deadline admission, SSH has no reservation or idle timer, `max_request_bytes/0` can exceed the hard cap, and `record_push/3` runs bookkeeping after native ref mutation.

- [ ] **Step 3: Add a direct GitCore dependency and hard-cap transport settings**

Add `{:git_core, in_umbrella: true}` to `apps/git_transport/mix.exs`. Implement:

~~~elixir
def max_request_bytes do
  configured =
    Application.get_env(
      :git_transport,
      :receive_pack_max_bytes,
      GitCore.Limits.hard(:receive_pack_bytes)
    )

  if is_integer(configured) and configured > 0 do
    min(configured, GitCore.Limits.get(:receive_pack_bytes))
  else
    GitCore.Limits.get(:receive_pack_bytes)
  end
end
~~~

Add `admit_body/1` and idempotent `release_body/1` around `GitCore.BodyMemoryLimiter`. Receive-pack reserves the full configured cap, not current `Content-Length`, so a chunked client cannot exceed admitted memory.

- [ ] **Step 4: Admit and deadline-bound Git HTTP reads**

After `load_writable_repository/3` and content-type validation:

1. validate `Content-Length` when present;
2. acquire a full receive-pack body reservation for at most 250 ms;
3. record an absolute monotonic deadline of now plus clamped 120 seconds;
4. call `Plug.Conn.read_body/2` incrementally with a clamped 15-second `read_timeout` and remaining maximum bytes;
5. check the absolute deadline before and after every chunk;
6. parse commands and pack completely;
7. call durable receive-pack;
8. release the reservation in `after` before sending the final response.

Map overflow to the existing too-large Git response and a total/idle timeout to a sanitized transport failure. Do not reuse the REST JSON reader and do not reserve a repository writer until step 7.

- [ ] **Step 5: Admit and deadline-bound SSH receive-pack**

Extend `GitTransport.Channel` state with:

~~~elixir
body_memory_lease: nil,
receive_pack_deadline: nil,
receive_pack_idle_timer: nil,
receive_pack_idle_token: nil
~~~

`start_receive_pack/6` acquires the full-cap reservation before sending advertisement and records the total deadline. Each data message checks total time and remaining bytes, cancels the old idle timer, and schedules `{:receive_pack_idle, token}` after the clamped 15 seconds. Handle only the matching current token. Release/cancel in success, `fail_started`, `reject`, closed-channel handling, and `terminate/2` through one idempotent helper.

Generate a safe SSH request ID as `"ssh-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)` and pass the authenticated actor plus that ID into the durable operation. No SSH key material enters audit metadata.

- [ ] **Step 6: Move receive-pack through the durable write domain**

Replace `GitTransport.ReceivePack.response/3` and `record_push/3` with one call:

~~~elixir
ForgeRepos.GitWrites.receive_pack(
  actor,
  repository,
  request.commands,
  pack,
  request_metadata
)
~~~

Inside `with_write_fence(repository, :receive_pack, fun)`:

1. call side-effect-free `GitCore.plan_receive_pack/4`;
2. insert one `prepared` `receive_pack` operation per command in one SQL transaction;
3. call `GitCore.ingest_receive_pack/3`;
4. transition every operation to `object_written`;
5. call `GitCore.apply_receive_pack_refs/3` once so the existing gix ref transaction remains atomic;
6. transition matching operations to `ref_advanced`;
7. update `last_pushed_at`, insert one operation-keyed `repository.pushed` audit per accepted ref, and transition every row to `bookkeeping_complete` in one SQL transaction;
8. synchronously invalidate repository caches;
9. return statuses for protocol rendering.

If native application returns a rejected status before moving its ref, mark that operation `failed` with a sanitized reason. If the outcome is uncertain, leave it recoverable and return transport failure. Render and send `ok` statuses only after step 8.

- [ ] **Step 7: Remove post-hoc bookkeeping**

Delete `GitTransport.ReceivePack.record_push/3` and every caller. Do not catch a metadata/audit failure and convert it to `:ok`. Keep log messages free of pack bytes, command OIDs beyond safe canonical IDs, credentials, and native internal text.

- [ ] **Step 8: Pass HTTP, SSH, crash, and fetch tests**

~~~bash
mix test apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/git_http_push_test.exs apps/forge_repos/test/git_write_recovery_test.exs --max-cases 1
~~~

Expected: both transports share admission, writer bounds, operation rows, write fence, recovery, audit deduplication, and cache invalidation; a normal fetch sees every successful push immediately.

- [ ] **Step 9: Commit durable receive-pack integration**

~~~bash
git add apps/git_transport/mix.exs apps/git_transport/lib/git_transport/receive_pack.ex apps/git_transport/lib/git_transport/channel.ex apps/git_transport/test/git_transport_test.exs apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex apps/fornacast_web/test/git_http_push_test.exs config/config.exs config/test.exs
git commit -m "feat(git): recover HTTP and SSH receive-pack"
~~~

### Task 11: Prove the complete Git-data slice

**Files:**

- Create: `apps/fornacast_api/test/github_git_data_acceptance_test.exs`
- Modify: `README.md`

- [ ] **Step 1: Write the end-to-end acceptance test**

Use the real `FornacastAPI.Endpoint`, a classic-scoped PAT fixture, the native Git object database, and a temporary Git CLI clone. The test performs this sequence:

1. create an organization as the ordinary authenticated owner;
2. create `demo` with `auto_init: true` and assert `refs/heads/main` plus `README.md`;
3. create `refs/heads/feature/api` from the initial commit;
4. PUT `docs/guide.md` on `feature/api`;
5. GET the branch, exact ref, commit detail, commit list filtered by `path=docs/guide.md`, and file contents;
6. update the file with its returned blob SHA;
7. delete the file with its new blob SHA;
8. clone, fetch, and inspect refs and commits with the Git CLI;
9. push one fast-forward commit through HTTP receive-pack and one through SSH receive-pack;
10. assert both transports and REST reads expose the same final OIDs.

Run the sequence once with API version `2022-11-28` and once with `2026-03-10`. Use the plan-1 URL/proxy configuration and PAT Basic rules; do not call a controller or domain function in place of an HTTP step except fixture provisioning.

- [ ] **Step 2: Run the acceptance test and isolate any boundary failure**

~~~bash
mix test apps/fornacast_api/test/github_git_data_acceptance_test.exs --max-cases 1
~~~

Expected: every route-decoding, serializer-versioning, ref-visibility, transport-durability, and clone/fetch assertion passes. If one fails, stop and report the exact assertion and owning earlier task; do not expand this acceptance task's file scope.

- [ ] **Step 3: Document first-release Git-data behavior**

Update README with:

- the ten Git-data routes and accepted version headers;
- classic PAT repository-read and repository-mutation scopes;
- slash-bearing branch/ref/path encoding;
- `auto_init` README behavior;
- 140 MiB envelope, 100 MiB decoded contents, and 100 MiB receive-pack ceilings;
- fast-forward/CAS semantics and `409` cases;
- `503` behavior for bounds, writer saturation, or recovery fence;
- the guarantee that successful API and receive-pack writes are immediately clone/fetch visible.

- [ ] **Step 4: Run every scoped Elixir test**

~~~bash
mix test apps/git_core/test/limits_test.exs apps/git_core/test/write_limiters_test.exs apps/git_core/test/git_core_test.exs apps/git_core/test/repository_read_model_test.exs apps/git_core/test/repository_write_model_test.exs --max-cases 1
mix test apps/fornacast/test/operation_lease_test.exs apps/forge_repos/test/git_data_test.exs apps/forge_repos/test/git_writes_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_repos/test/forge_repos_test.exs --max-cases 1
mix test apps/fornacast_api/test/path_value_test.exs apps/fornacast_api/test/openapi_contract_test.exs apps/fornacast_api/test/contents_admission_test.exs apps/fornacast_api/test/git_data_controller_test.exs apps/fornacast_api/test/github_git_data_acceptance_test.exs --max-cases 1
mix test apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
~~~

Expected: all in-scope Elixir tests pass serially against the configured test adapter.

- [ ] **Step 5: Run native, formatting, and compile checks**

~~~bash
cargo fmt --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml --check
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml
mix format --check-formatted
mix compile --warnings-as-errors
git diff --check
~~~

Expected: Rust formatting and tests pass, Elixir formatting is clean, compilation has no warnings, and the diff has no whitespace errors.

- [ ] **Step 6: Review the slice against the approved specification**

Confirm all of these statements from test evidence:

- branches, refs, commits, and contents implement every route and status in the approved section;
- catch-alls decode one time and reject traversal, double encoding, invalid UTF-8, ambiguous normalization, and ref injection;
- every read enforces scan/blob concurrency, deadline, work, patch, and blob ceilings without partial success;
- contents body admission occurs after authorization and before any body read, while writer acquisition occurs after complete validation;
- every configured value is lowerable and hard-capped;
- every ref mutation uses native object planning/writing, repository/node writer limits, the durable operation, CAS, audit deduplication, cache invalidation, and the on-touch fence;
- startup, 30-second, and on-touch recovery use adapter-neutral leases and comparison-only recovery;
- the reconciler scheduler dispatches blocking recovery to supervised tasks;
- HTTP and SSH receive-pack share the same body pool, write fence, durable state, and no-early-success rule;
- real `auto_init` replaces the plan-1 `503` handoff and ordinary clone/fetch sees its README commit;
- both pinned version artifacts and golden fixtures pass contract validation.

- [ ] **Step 7: Commit acceptance evidence and documentation**

~~~bash
git add apps/fornacast_api/test/github_git_data_acceptance_test.exs README.md
git commit -m "test(api): prove Git data workflow"
~~~
