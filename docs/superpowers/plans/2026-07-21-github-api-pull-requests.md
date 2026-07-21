# GitHub-Compatible Pull Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let repository readers open and manage same-repository pull requests and let repository writers merge them through a GitHub-compatible API that creates a genuine two-parent Git commit.

**Architecture:** Add a `forge_pulls` domain application whose pull row references the canonical issue identity created by `forge_issues`. Resolve the head and base refs once per request, perform bounded merge analysis and object creation in `git_core`, and advance the base ref only through the repository writer fence and compare-and-swap primitive delivered by the Git-data plan. Persist every merge transition so reconciliation can finish bookkeeping after a proven ref update without inventing or replaying a merge.

**Tech Stack:** Elixir 1.20, Ecto 3.14 with Turso and PostgreSQL, Phoenix 1.8, Rustler 0.38, gix 0.85, Bandit, and ExUnit.

---

**Approved specification:** `docs/superpowers/specs/2026-07-21-github-compatible-api-design.md`

**Depends on:** `2026-07-21-github-api-foundation.md`, `2026-07-21-github-api-git-data.md`, and `2026-07-21-github-api-issues.md` are complete.

## Scope and execution guardrails

- Implement only same-repository pull requests. Accept `head` as `branch` or `owner:branch` only when `owner` is the target repository owner.
- Support only `merge_method: "merge"`. Reject draft pulls, reviews, review comments, review requests, squash, rebase, forks, and cross-repository heads with the approved validation contract.
- Keep title, body, author, number, state, labels, assignees, comments, and shared timestamps canonical in `ForgeIssues.Issue`. Do not duplicate those fields in `pull_requests`.
- Resolve the head and base refs exactly once for each detail, mergeability, or merge request. Carry immutable OIDs through the rest of that request.
- Never construct Git objects, run Ecto queries, authorize a repository, or coordinate recovery in an API controller.
- Never move a ref outside `GitCore.RepositoryWriteLimiter`, `ForgeRepos.with_write_fence/3`, `ForgeRepos.RepositoryWriteReconcilers`, and `GitCore.compare_and_swap_ref/6` from the Git-data slice.
- A merge candidate must have the recorded base as its first parent and the recorded head as its second parent. Fast-forwarding the base directly to the head is not a compatible merge.
- Recovery may complete database and audit bookkeeping only after the current base ref proves the recorded merge OID won. It must not create a second merge commit or advance an unadvanced operation.
- Format only files changed by this plan. Run only the scoped commands below until the final plan task.

## Public domain contract

`ForgePulls` exposes tagged results and accepts already authenticated domain actors:

```elixir
@type error_reason ::
        :not_found
        | :forbidden
        | :invalid_head
        | :invalid_base
        | :cross_repository_head
        | :head_equals_base
        | :head_changed
        | :conflict
        | :merge_commits_disabled
        | :ref_conflict
        | {:validation, [validation_error()]}
        | {:unavailable, atom()}

@type validation_error :: %{
        required(:resource) => String.t(),
        required(:field) => String.t(),
        required(:code) =>
          :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
        optional(:message) => String.t()
      }

@spec list_pull_requests(ForgeRepos.Repository.t(), map() | nil, keyword()) ::
        {:ok, Fornacast.Page.t(ForgePulls.PullRequest.t())} | {:error, error_reason()}
@spec get_pull_request(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
        {:ok, ForgePulls.PullRequest.t()} | {:error, error_reason()}
@spec create_pull_request(ForgeRepos.Repository.t(), map(), map(), map()) ::
        {:ok, ForgePulls.PullRequest.t()} | {:error, error_reason()}
@spec update_pull_request(ForgeRepos.Repository.t(), ForgePulls.PullRequest.t(), map(), map(), map()) ::
        {:ok, ForgePulls.PullRequest.t()} | {:error, error_reason()}
@spec merged?(ForgeRepos.Repository.t(), ForgePulls.PullRequest.t(), map() | nil) ::
        {:ok, boolean()} | {:error, error_reason()}
@spec pull_links_for_issue_ids(
        ForgeRepos.Repository.t(),
        [pos_integer()],
        map() | nil
      ) ::
        {:ok, %{optional(pos_integer()) => %{merged_at: DateTime.t() | nil}}} |
        {:error, error_reason()}
@spec merge(ForgeRepos.Repository.t(), ForgePulls.PullRequest.t(), map(), map(), map()) ::
        {:ok, %{merged: true, message: String.t(), sha: String.t()}} |
        {:error, error_reason()}
@spec reconcile_repository(ForgeRepos.Repository.t(), keyword()) ::
        :ok | {:error, {:unavailable, atom()}}
```

`create_pull_request/4`, `update_pull_request/5`, and `merge/5` receive safe request metadata with `request_id`, `ip_address`, and `user_agent`. PAT scope enforcement stays in `fornacast_api`; repository role and resource-author rules stay in the domain.

## File map

### Umbrella and persistence

- Create `apps/forge_pulls/mix.exs`.
- Create `apps/forge_pulls/lib/forge_pulls/application.ex`.
- Create `apps/forge_pulls/lib/forge_pulls.ex`.
- Create `apps/forge_pulls/lib/forge_pulls/pull_request.ex`.
- Create `apps/forge_pulls/lib/forge_pulls/merge_operation.ex`.
- Create `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`.
- Create `apps/forge_pulls/lib/forge_pulls/merge_reconciler.ex`.
- Create `apps/forge_pulls/test/test_helper.exs`.
- Create `apps/forge_pulls/test/forge_pulls_test.exs`.
- Create `apps/forge_pulls/test/merge_recovery_test.exs`.
- Create `apps/fornacast/priv/repo/migrations/20260721000400_create_pull_domain.exs`.
- Modify `mix.exs` and `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex` to start `forge_pulls`.
- Modify `apps/fornacast_web/test/fornacast_run_task_test.exs` to lock the service list.
- Modify `config/config.exs` to append the pull locked-reconciler entry.

### Issue composition and Git operations

- Reuse `ForgeIssues.insert_numbered_identity/6` and `ForgeIssues.update_identity/5` unchanged; Plan 3 already guarantees caller-selected `Ecto.Multi` keys.
- Modify `apps/git_core/lib/git_core/write_model.ex`.
- Modify `apps/git_core/lib/git_core.ex`.
- Modify `apps/git_core/lib/git_core/native.ex`.
- Modify `apps/git_core/native/fornacast_git_core/src/lib.rs`.
- Modify `apps/git_core/native/fornacast_git_core/Cargo.toml` to enable the existing `gix = "0.85.0"` dependency's `merge` feature.
- Modify `apps/git_core/native/fornacast_git_core/Cargo.lock` by regenerating it from that manifest.
- Add pull-specific native and BEAM tests to `apps/git_core/test/repository_write_model_test.exs`.

### API contract

- Modify `apps/fornacast_api/mix.exs` and `apps/fornacast_api/lib/fornacast_api/router.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/error.ex` and `apps/fornacast_api/lib/fornacast_api/url.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex` and `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex` and `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/pull_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/controllers/pull_merge_controller.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/pull.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/pull.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/pull.ex`.
- Create `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/pull.ex`.
- Modify `apps/fornacast_api/lib/fornacast_api/controllers/issue_controller.ex`.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json` with implemented-through marker `4`; its full first-release operation set remains unchanged.
- Modify `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json` with implemented-through marker `4`; its full first-release operation set remains unchanged.
- Regenerate `apps/fornacast_api/priv/openapi/fornacast-overlay.json` with implemented-through marker `4` and unchanged pull ownership/divergences.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/pulls/pull.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/pulls/pull-list.json`.
- Create `apps/fornacast_api/test/fixtures/2022-11-28/pulls/merge.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/pulls/pull.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/pulls/pull-list.json`.
- Create `apps/fornacast_api/test/fixtures/2026-03-10/pulls/merge.json`.
- Create `apps/fornacast_api/test/pull_controller_test.exs`.
- Create `apps/fornacast_api/test/pull_contract_test.exs`.
- Create `apps/fornacast_api/test/pull_merge_integration_test.exs`.

### Task 1: Scaffold the pull domain and persistence

**Files:**

- Create: `apps/forge_pulls/mix.exs`
- Create: `apps/forge_pulls/lib/forge_pulls/application.ex`
- Create: `apps/forge_pulls/lib/forge_pulls/pull_request.ex`
- Create: `apps/forge_pulls/lib/forge_pulls/merge_operation.ex`
- Create: `apps/forge_pulls/test/test_helper.exs`
- Create: `apps/forge_pulls/test/forge_pulls_test.exs`
- Create: `apps/fornacast/priv/repo/migrations/20260721000400_create_pull_domain.exs`
- Modify: `mix.exs`
- Modify: `apps/fornacast_web/lib/mix/tasks/fornacast.run.ex`
- Modify: `apps/fornacast_web/test/fornacast_run_task_test.exs`

- [ ] **Step 1: Add a failing umbrella wiring test**

Extend `apps/fornacast_web/test/fornacast_run_task_test.exs` so the expected ordered services include `:forge_issues`, `:forge_pulls`, and the previously delivered applications. Assert the OTP release application list contains `forge_pulls: :permanent`.

- [ ] **Step 2: Run the wiring test and verify the missing application**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_run_task_test.exs --max-cases 1
```

Expected: the assertion reports that `:forge_pulls` is absent from service or release wiring.

- [ ] **Step 3: Add the application with one-way dependencies**

Set the new app dependencies to:

```elixir
[
  {:fornacast, in_umbrella: true},
  {:forge_repos, in_umbrella: true},
  {:forge_issues, in_umbrella: true},
  {:git_core, in_umbrella: true},
  {:ecto, "~> 3.14"}
]
```

Do not add `forge_pulls` to `forge_repos`, `forge_issues`, or either HTTP-independent core app.

- [ ] **Step 4: Write failing schema tests for every durable field and constraint**

Characterize one pull per issue, same-repository head identity, valid branch refs, merge metadata, and the exact merge operation states:

```elixir
@merge_states [:prepared, :merge_written, :ref_advanced, :completed, :failed]
```

Assert `failure_reason` is redacted or omitted from public structs returned by the context.

- [ ] **Step 5: Add the portable migration**

Create `pull_requests` with:

- `issue_id` referencing `issues` with `on_delete: :delete_all`, not null and unique;
- `repository_id` referencing `repositories` with `on_delete: :restrict`, not null;
- `head_ref` and `base_ref`, not null;
- `head_sha` and `base_sha`, not null, holding the last immutable snapshots analyzed for the pull;
- nullable `mergeable` and `mergeable_state`, updated only with the matching snapshot pair;
- nullable `merged_at`, `merged_by_user_id`, and `merge_commit_sha`;
- UTC timestamps;
- indexes on `repository_id` and `{repository_id, base_ref}`.

Create `pull_merge_operations` with:

- `pull_request_id` and `repository_id`, not null and restricted;
- nullable `actor_user_id` with `on_delete: :nilify_all`;
- `request_id`, `base_ref`, `head_ref`, `expected_base_oid`, and `expected_head_oid`, not null;
- nullable `merge_oid` and sanitized `failure_reason`;
- `state`, not null;
- nullable `lease_owner` and `lease_expires_at`;
- `lock_version`, not null with default `0`;
- UTC timestamps;
- indexes on `{repository_id, state}`, `{pull_request_id, state}`, and `lease_expires_at`.

Use the existing migration helper pattern to apply check constraints only where the configured adapter supports them. Enforce the state set in Ecto on both adapters.

- [ ] **Step 6: Implement strict schemas and pass the migration tests**

`PullRequest.create_changeset/2` validates canonical `refs/heads/` values, requires different head/base refs, and treats `repository_id` as the immutable source and target repository. `MergeOperation.prepare_changeset/2` accepts only `:prepared`; state transitions use dedicated changesets that accept exactly one next state.

Run:

```bash
MIX_ENV=test mix ecto.migrate
mix test apps/forge_pulls/test/forge_pulls_test.exs --max-cases 1
mix test apps/fornacast_web/test/fornacast_run_task_test.exs --max-cases 1
```

Expected: schema, constraint, and wiring tests pass.

- [ ] **Step 7: Commit the pull foundation**

```bash
git add apps/forge_pulls apps/fornacast/priv/repo/migrations/20260721000400_create_pull_domain.exs mix.exs apps/fornacast_web/lib/mix/tasks/fornacast.run.ex apps/fornacast_web/test/fornacast_run_task_test.exs
git commit -m "feat(pulls): add pull request persistence"
```

### Task 2: Compose pull creation with the shared issue identity

**Files:**

- Create: `apps/forge_pulls/lib/forge_pulls.ex`
- Modify: `apps/forge_pulls/test/forge_pulls_test.exs`

- [ ] **Step 1: Write failing atomic creation tests**

Cover these cases:

- a repository reader opens a pull and receives the next shared issue number;
- the issue row has `kind: :pull_request` and remains canonical for shared fields;
- `head` accepts `feature/x` and the owner-qualified equivalent;
- missing head/base, equal head/base, and a foreign owner selector return stable errors;
- a failure inserting the pull row rolls back both the issue identity and number allocation;
- concurrent issue and pull creation never reuse a number;
- the source repository and head ref cannot change on update;
- authors can edit shared fields or close their own pull, while repository writers can manage every pull.

- [ ] **Step 2: Run the domain tests and verify the missing context**

```bash
mix test apps/forge_pulls/test/forge_pulls_test.exs --max-cases 1
```

Expected: tests fail because `ForgePulls.create_pull_request/4`, `get_pull_request/3`, `list_pull_requests/3`, and `update_pull_request/5` do not exist.

- [ ] **Step 3: Build one outer `Ecto.Multi`**

Use the issue plan's caller-selected identity key:

```elixir
Multi.new()
|> ForgeIssues.insert_numbered_identity(
  :issue,
  repository,
  actor,
  :pull_request,
  %{title: attrs.title, body: attrs.body}
)
|> Multi.insert(:pull_request, fn %{issue: issue} ->
  PullRequest.create_changeset(%PullRequest{}, %{
    issue_id: issue.id,
    repository_id: repository.id,
    head_ref: head_ref,
    base_ref: base_ref,
    head_sha: head_oid,
    base_sha: base_oid
  })
end)
|> Fornacast.Audit.record_multi(
  :audit,
  actor,
  "pull_request.created",
  "repository",
  repository.id,
  %{"result" => "success"},
  request_metadata: request_meta
)
|> Repo.transaction()
```

`Fornacast.Audit.record_multi/8` appends the insert and returns the same multi; it does not start a transaction.

- [ ] **Step 4: Resolve and validate refs before the transaction**

Authorize repository read, normalize `head` without double decoding, resolve both branches through the Git-data snapshot API, and retain the immutable OIDs for that request. Store canonical full branch refs, not client spelling. Persist analyzed OIDs only as the explicitly paired last-analysis snapshot; always resolve moving refs again for a later diff or merge request.

- [ ] **Step 5: Implement list, get, and update through the issue context**

Use deterministic `{sort_field, id}` ordering. Apply state, head, base, sort, direction, page, and per-page filters. Load the issue identity through context-owned queries. Update the base only after validating that the new branch exists; source repository and head ref are immutable. Compose every update in one outer multi:

```elixir
Ecto.Multi.new()
|> ForgeIssues.update_identity(:issue, issue, actor, shared_attrs)
|> Ecto.Multi.update(:pull_request, fn _changes ->
  PullRequest.update_changeset(pull_request, pull_attrs)
end)
|> Fornacast.Audit.record_multi(
  :audit,
  actor,
  "pull_request.updated",
  "repository",
  repository.id,
  %{"result" => "success"},
  request_metadata: request_meta
)
|> Fornacast.Repo.transaction()
```

The author/writer policy determines `shared_attrs` and `pull_attrs` before the multi; a validation or audit failure rolls back both rows. A detail or mergeability read resolves each ref once, computes against that pair, and persists `head_sha`, `base_sha`, `mergeable`, and `mergeable_state` together so stored analysis never mixes snapshots.

Implement `pull_links_for_issue_ids/3` as one repository-scoped query over `pull_requests`, selecting only `issue_id` and `merged_at` for the supplied IDs after repository-read authorization. Return a map keyed by issue ID. This is the one-way bridge used by the HTTP application; `forge_issues` does not query or depend on `forge_pulls`.

- [ ] **Step 6: Run the domain and shared-number tests**

```bash
mix test apps/forge_issues/test/number_allocator_test.exs apps/forge_pulls/test/forge_pulls_test.exs --max-cases 1
```

Expected: atomicity, authorization, filtering, and shared-number tests pass.

- [ ] **Step 7: Commit pull lifecycle operations**

```bash
git add apps/forge_pulls/lib/forge_pulls.ex apps/forge_pulls/test/forge_pulls_test.exs
git commit -m "feat(pulls): add pull request lifecycle"
```

### Task 3: Add bounded merge analysis and two-parent commit creation

**Files:**

- Modify: `apps/git_core/lib/git_core/write_model.ex`
- Modify: `apps/git_core/lib/git_core.ex`
- Modify: `apps/git_core/lib/git_core/native.ex`
- Modify: `apps/git_core/native/fornacast_git_core/src/lib.rs`
- Modify: `apps/git_core/native/fornacast_git_core/Cargo.toml`
- Modify: `apps/git_core/native/fornacast_git_core/Cargo.lock`
- Modify: `apps/git_core/test/repository_write_model_test.exs`

- [ ] **Step 1: Add failing typed merge tests**

Add the public value:

```elixir
defmodule GitCore.MergeAnalysis do
  @enforce_keys [:base_oid, :head_oid, :mergeable, :ahead_by, :behind_by, :commit_count, :changed_paths]
  defstruct [:base_oid, :head_oid, :mergeable, :ahead_by, :behind_by, :commit_count, :changed_paths]
end
```

Test clean divergent histories, identical tips, an already-contained head, text and tree conflicts, the 50,000-commit and 100,000-tree-entry bounds, the 10,000-changed-path bound, and a 30-second deadline. Assert failures return typed `GitCore.Error` values without writing objects or moving refs.

- [ ] **Step 2: Run the merge-analysis group and verify missing native calls**

```bash
mix test apps/git_core/test/repository_write_model_test.exs --only pull_merge --max-cases 1
```

Expected: tests fail on missing `GitCore.merge_analysis/4` and `GitCore.write_merge_commit/7`.

- [ ] **Step 3: Implement immutable merge analysis**

Change the existing dependency to `gix = { version = "0.85.0", features = ["merge"] }` and regenerate `Cargo.lock`; do not add a second Git implementation crate.

Expose:

```elixir
@spec merge_analysis(Path.t(), String.t(), String.t(), keyword()) ::
        {:ok, GitCore.MergeAnalysis.t()} | {:error, GitCore.Error.t()}

@spec write_merge_commit(
        Path.t(),
        String.t(),
        String.t(),
        GitCore.Signature.t(),
        GitCore.Signature.t(),
        String.t(),
        keyword()
      ) :: {:ok, String.t()} | {:error, GitCore.Error.t()}
```

The native merge operates only on supplied OIDs. It computes one merged tree, writes the tree and commit without updating a reference, uses base then head as the ordered parents, and validates UTF-8 message/signature limits before object insertion. The BEAM wrapper runs analysis under `ScanLimiter` and commit creation under the already-held repository writer permit.

- [ ] **Step 4: Prove the candidate is a genuine merge commit**

After `write_merge_commit/7`, read the object through both `GitCore.commit/2` and `git cat-file -p` in the integration test. Assert the first `parent` line is the base OID, the second is the head OID, the base ref remains unchanged, and a conflicting merge leaves no ref change.

- [ ] **Step 5: Run Elixir and Rust scoped tests**

```bash
mix test apps/git_core/test/repository_write_model_test.exs --only pull_merge --max-cases 1
cargo test --manifest-path apps/git_core/native/fornacast_git_core/Cargo.toml pull_merge
```

Expected: all merge-analysis, object-shape, bound, and no-ref-movement tests pass.

- [ ] **Step 6: Commit the Git merge primitives**

```bash
git add apps/git_core
git commit -m "feat(git): add bounded merge commit primitives"
```

### Task 4: Perform merges through a durable compare-and-swap operation

**Files:**

- Modify: `apps/forge_pulls/lib/forge_pulls.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_operation.ex`
- Create: `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`
- Modify: `config/config.exs`
- Modify: `apps/forge_pulls/test/forge_pulls_test.exs`
- Create: `apps/forge_pulls/test/merge_recovery_test.exs`

- [ ] **Step 1: Write failing merge state-machine tests**

Inject a fault after each persisted transition:

```text
prepared -> merge_written -> ref_advanced -> completed
```

Cover optional head `sha`, moved head, moved base, conflict, disabled merge commits, closed or already-merged pulls, wrong merge method, custom/default messages, writer-limiter exhaustion, and the earlier-operation write fence. Assert only changed head/ref races return `409` domain reasons, while conflicts and disabled merge commits return their `405` domain reasons.

- [ ] **Step 2: Run the recovery file and verify no merge operation exists**

```bash
mix test apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1
```

Expected: tests fail because `ForgePulls.merge/5` does not persist or advance a merge.

- [ ] **Step 3: Prepare the operation before writing Git objects**

Inside `ForgeRepos.with_write_fence/3`, let `ForgeRepos.RepositoryWriteReconcilers` synchronously reconcile every configured older ref-affecting operation, resolve head and base once, validate the optional request SHA, run merge analysis, and insert `:prepared` with both expected OIDs and safe request metadata. Append `{200, :pull_merges, ForgePulls.MergeRecovery}` to the root `:forge_repos, :repository_write_reconcilers` configuration while retaining the Git entry. Its `reconcile_repository_locked/3` callback accepts the already-resolved repository path and absolute deadline and never reacquires the writer. Do not hold a SQL transaction while computing the merge.

- [ ] **Step 4: Write, record, and compare-and-swap**

Create the candidate commit, persist its OID as `:merge_written`, then call:

```elixir
GitCore.compare_and_swap_ref(
  repository_path,
  pull.base_ref,
  operation.expected_base_oid,
  operation.merge_oid,
  :fast_forward,
  deadline_ms: remaining_ms
)
```

Derive one absolute deadline from the fence callback's initial remaining budget. Pass that same decreasing budget through merge analysis, object creation, and CAS; recompute `remaining_ms` from the absolute deadline before each bounded call and never reset it to 60 seconds. Persist `:ref_advanced` only after the CAS returns the recorded merge OID. A stale base, unexpected current ref, timeout, or limit error must leave the operation diagnosable and must not report success.

- [ ] **Step 5: Complete canonical issue state and audit atomically**

In one SQL transaction, set `merge_commit_sha`, `merged_at`, and `merged_by_user_id`; close the canonical issue through `ForgeIssues.update_identity/5`; update repository push metadata; append one audit event with `operation_id: "pull_merge:" <> Integer.to_string(operation.id)`; and transition to `:completed`. Invalidate GitCore caches after the transaction and before returning success.

- [ ] **Step 6: Pass concurrency and fault-injection tests**

```bash
mix test apps/forge_pulls/test/forge_pulls_test.exs apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1
```

Expected: exactly one of two racing merges advances the base, no conflict advances a ref, successful results expose the real merge SHA, and every injected state remains recoverable.

- [ ] **Step 7: Commit durable merge execution**

```bash
git add apps/forge_pulls config/config.exs
git commit -m "feat(pulls): merge through durable ref CAS"
```

### Task 5: Reconcile merge operations at startup, on schedule, and on touch

**Files:**

- Create: `apps/forge_pulls/lib/forge_pulls/merge_reconciler.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/application.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls.ex`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`

- [ ] **Step 1: Add failing lease and recovery-table tests**

Cover startup reconciliation, the 30-second tick, resource-touch reconciliation, one winner among concurrent workers, expired lease reclamation, lock-version mismatch, and both adapters' conditional update path. Freeze the clock and give each test worker a deterministic lease owner.

- [ ] **Step 2: Specify recovery decisions for every observed state**

Assert this table:

| Persisted state | Current base ref | Recovery action |
| --- | --- | --- |
| `prepared` | expected base | mark failed without writing a merge |
| `merge_written` | expected base | mark failed without advancing the ref |
| `merge_written` | recorded merge OID | finish database bookkeeping |
| `ref_advanced` | recorded merge OID | finish database bookkeeping |
| non-terminal | third OID | retain the non-terminal evidence, store `unexpected_ref`, emit one deduplicated safe audit alert, keep the ref, and return unavailable |
| `completed` or `failed` | any | no mutation |

- [ ] **Step 3: Implement a bounded reconciler process**

`ForgePulls.MergeReconciler` is a supervised scheduler because it owns the hard-capped 30-second runtime timer. Its callbacks only call `Task.Supervisor.async_nolink/2`, store the task reference, and handle the reply or `:DOWN`. The supervised task selects at most 50 repository IDs with non-terminal rows and invokes the shared write fence for each; the configured locked callback then claims rows with `Fornacast.OperationLease.claim/5`, applies transitions with `update_owned/3`, and releases unchanged claims with `release/2`. No scheduler callback queries SQL, accesses Git/filesystem state, or runs reconciliation, and the locked callback never reacquires the writer.

- [ ] **Step 4: Reconcile synchronously when a pull is touched**

Define `reconcile_repository(repository, opts \\ [])` and call `reconcile_repository(repository, [])` before returning a pull whose merge operation is non-terminal and before starting a new merge. The wrapper enters the shared write fence; `MergeRecovery.reconcile_repository_locked/3` is the configured no-reacquire callback. Translate the callback's internal `{:error, :unavailable}` into `{:error, {:unavailable, :pull_recovery}}`; never serialize speculative merged state or permit a later ref write past retained third-OID evidence.

- [ ] **Step 5: Run recovery tests twice**

```bash
mix test apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1 --seed 0
mix test apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1 --seed 1
```

Expected: lease races, timer runs, every state decision, audit deduplication, and idempotent repeated reconciliation pass with both seeds.

- [ ] **Step 6: Commit merge recovery**

```bash
git add apps/forge_pulls
git commit -m "feat(pulls): reconcile interrupted merges"
```

### Task 6: Expose the versioned pull API

**Files:**

- Modify: `apps/fornacast_api/mix.exs`
- Modify: `apps/fornacast_api/lib/fornacast_api/router.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/error.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/url.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10.ex`
- Modify: `apps/fornacast_api/lib/fornacast_api/controllers/issue_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/pull_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/controllers/pull_merge_controller.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2022_11_28/pull.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/serializers/v2026_03_10/pull.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2022_11_28/pull.ex`
- Create: `apps/fornacast_api/lib/fornacast_api/validators/v2026_03_10/pull.ex`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2022-11-28.json`
- Modify: `apps/fornacast_api/priv/openapi/ghes-3.21-2026-03-10.json`
- Modify: `apps/fornacast_api/priv/openapi/fornacast-overlay.json`
- Create: `apps/fornacast_api/test/pull_controller_test.exs`
- Create: `apps/fornacast_api/test/pull_contract_test.exs`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/pulls/pull.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/pulls/pull-list.json`
- Create: `apps/fornacast_api/test/fixtures/2022-11-28/pulls/merge.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/pulls/pull.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/pulls/pull-list.json`
- Create: `apps/fornacast_api/test/fixtures/2026-03-10/pulls/merge.json`

- [ ] **Step 1: Write failing route, marker, and contract tests**

Assert the foundation's full artifacts already contain the pull list/create, get/update, merge-check, and merge operations under slice `4` ownership, then require implemented-through marker `"4"` in both documents and the overlay. Cover all six method/path combinations, default and explicit API versions, JSON-only commit and pull representations, `406` for diff/patch media, pagination links, filters, all accepted fields, every excluded field, public/private masking, PAT scope alternatives, reader/author/writer rules, and exact `204`/`404` merge checks. Also merge a pull, fetch the same resource through both the pull endpoint and issue detail/list endpoints, and assert all three surfaces emit the identical non-null `merged_at` value.

Build literal expected maps from one fixed pull (`id: 4001`, shared issue number `8`, title `Add API`, body `Implements the subset`, state `open`, head `feature/api`, base `main`, head SHA of forty `b` characters, base SHA of forty `a` characters, author ID `41`, timestamps `2026-07-21T00:00:00Z`) and one fixed successful merge (`sha` of forty `c` characters, `merged: true`, message `Pull Request successfully merged`). Each selected-version pull map enumerates every field required by its pinned schema, including explicit head/base repository/user maps and the canonical issue fields; expected maps are not generated by the serializer under test. At the six exact paths in this task, `pull.json` is that map, `pull-list.json` is a one-element array of it, and `merge.json` is the merge map. Compare decoded checked-in files to the literal maps and validate them against the matching response schemas.

- [ ] **Step 2: Run the API tests and verify routes are absent**

```bash
mix test apps/fornacast_api/test/pull_controller_test.exs apps/fornacast_api/test/pull_contract_test.exs --max-cases 1
```

Expected: route tests return the API catch-all `404`, contract fixtures report missing pull serializers, and the generated delivery marker is still slice `3`; the pinned pull paths themselves are already present.

- [ ] **Step 3: Advance the generated delivery marker without changing the manifest**

```bash
rm -rf /tmp/fornacast-openapi-source
git clone --filter=blob:none --no-checkout https://github.com/github/rest-api-description.git /tmp/fornacast-openapi-source
git -C /tmp/fornacast-openapi-source checkout 03ca9c1cac754ec9b8369dc75de8a8c753c6e087 -- descriptions/ghes-3.21/dereferenced/ghes-3.21.2022-11-28.deref.json descriptions/ghes-3.21/dereferenced/ghes-3.21.2026-03-10.deref.json
mix run scripts/prune_github_openapi.exs -- /tmp/fornacast-openapi-source apps/fornacast_api/priv/openapi 4
```

Expected: source commit/blob checks pass, the complete first-release operation manifest remains byte-for-byte equivalent apart from generated delivery metadata, and the implemented-through marker advances from `3` to `4`.

- [ ] **Step 4: Add strict version-aware validators**

Accept exactly:

```elixir
%{
  create: ~w(title head base body),
  update: ~w(title body state base),
  merge: ~w(commit_title commit_message sha merge_method)
}
```

Require `title`, `head`, and `base` for create. Accept only `open` or `closed` state and only `merge` as a supplied merge method. Reject unknown JSON fields with `422`; ignore only unsupported query fields that cannot alter the result.

- [ ] **Step 5: Add thin controllers and explicit serializers**

Add `{:forge_pulls, in_umbrella: true}` only to `fornacast_api`. Controllers resolve and authorize the repository before calling `FornacastAPI.RequestBody.read_json(conn, :ordinary, [])`, call one `ForgePulls` function, and pass tagged results to the shared error mapper. Serializers receive a fully loaded pull/issue value and configured canonical origin. Wire the nested validator and serializer modules through the established version facade files. Each version module owns an explicit field map; do not serialize schemas generically or copy the 2022 map into the 2026 module at runtime.

Update `IssueController` list and detail actions after their repository lookup: collect pull-kind issue IDs from the already-paginated result, call `ForgePulls.pull_links_for_issue_ids/3` once, and pass the returned map as `pull_links_by_issue_id` to the selected issue serializer. A page with no pull-kind rows skips the query. This keeps batching at the API composition boundary and makes merged issue links accurate without adding a `forge_issues -> forge_pulls` dependency.

Before PAT authorization, compute and assign `ForgeAccounts.APIScope.accepted_scopes/2`; insufficient scope returns `{:insufficient_scope, accepted}` so the existing error clause retains `X-Accepted-OAuth-Scopes`. Add exact error clauses before the fallback: `:conflict` and `:merge_commits_disabled` render `405 Pull Request is not mergeable`; `:head_changed` and `:ref_conflict` render `409 Conflict`; validation remains `422`; known limiter/deadline/storage failures render `503`. The merge-check controller calls `merged?/3`, returning an empty `204` for `{:ok, true}`, masked `404` for `{:ok, false}`, and the tagged error mapping for reconciliation failure.

Extend `FornacastAPI.URL` with pull collection, detail, merge, commit, issue, and repository-web helpers. Serializers use only that facade. Per the approved deliberate divergence, pull `html_url`, `diff_url`, and `patch_url` use the corresponding public API pull URL until a browser pull page and diff/patch media exist.

- [ ] **Step 6: Run API and domain tests**

```bash
mix test apps/forge_pulls/test apps/fornacast_api/test/pull_controller_test.exs apps/fornacast_api/test/pull_contract_test.exs --max-cases 1
```

Expected: lifecycle, permission, validation, media, error, header, pagination, and both-version schema assertions pass.

- [ ] **Step 7: Commit the pull API**

```bash
git add apps/fornacast_api
git commit -m "feat(api): expose compatible pull requests"
```

### Task 7: Prove real Git merge interoperability

**Files:**

- Create: `apps/fornacast_api/test/pull_merge_integration_test.exs`
- Modify: `apps/fornacast_api/test/pull_contract_test.exs`

- [ ] **Step 1: Build a real divergent repository fixture**

Create a repository through contexts, commit distinct non-conflicting changes to `main` and `feature/api`, create the pull through HTTP, and merge it through HTTP with an optional expected head SHA. Use only temporary storage and a test PAT.

- [ ] **Step 2: Verify the observable Git graph with a normal client**

Clone or fetch the bare repository through the existing smart HTTP transport. Assert the base ref equals the API response SHA, the merge commit has exactly two ordered parents, both branch changes exist, repository `last_pushed_at` advanced, and the pull's backing issue is closed.

- [ ] **Step 3: Prove stale and conflicting attempts are side-effect free**

Move the head after recording an expected SHA and create a separate content-conflict fixture. Assert the first returns `409`, the second returns `405`, neither changes the base ref, and neither returns a merge SHA.

- [ ] **Step 4: Run the complete pull slice**

```bash
mix test apps/git_core/test/repository_write_model_test.exs --only pull_merge --max-cases 1
mix test apps/forge_issues/test/number_allocator_test.exs apps/forge_pulls/test apps/fornacast_api/test/pull_controller_test.exs apps/fornacast_api/test/pull_contract_test.exs apps/fornacast_api/test/pull_merge_integration_test.exs --max-cases 1
mix compile --warnings-as-errors
```

Expected: all pull-slice tests pass and compilation emits no warning.

- [ ] **Step 5: Commit interoperability coverage**

```bash
git add apps/fornacast_api/test/pull_merge_integration_test.exs apps/fornacast_api/test/pull_contract_test.exs
git commit -m "test(api): prove pull merge interoperability"
```

## Slice completion criteria

- All pull paths in the approved manifest exist for both selected API versions and validate against the checked-in pruned schemas.
- Pull creation and issue creation share one collision-free repository number sequence and one outer SQL transaction.
- Shared pull fields remain canonical in the issue domain.
- Every request resolves head and base refs once and carries immutable OIDs.
- A successful merge is a real two-parent commit and advances the base only through compare-and-swap.
- Conflict, stale SHA, moved ref, disabled merge commits, capacity, and deadline cases never advance a ref accidentally.
- Recovery handles every non-terminal state idempotently with adapter-neutral leases and deduplicated audit records.
- A normal Git client observes the merge SHA and graph returned by the API.
