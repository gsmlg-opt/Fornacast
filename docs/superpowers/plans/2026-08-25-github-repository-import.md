# GitHub Repository Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an approved GitHub discovery plan into a secure staged bare mirror, hidden repository, tested atomic publication/cleanup primitives, and conflict-review web flow while keeping publication gated on metadata.

**Architecture:** Git transfer runs through a supervised `GitCore.Remote` process-group boundary and writes only to an `importing` shadow repository with a new opaque storage path. Publication atomically activates that row; replacement tombstones the exact approved repository, preserves local authorization, and never mutates live Git storage in place.

**Tech Stack:** Elixir 1.20, OTP 29, Ecto 3.14, git CLI, erlexec 2.3.4, Turso/PostgreSQL, Phoenix 1.8, PhoenixDuskmoon 9.12

---

**Prerequisite:** Complete `docs/superpowers/plans/2026-08-25-github-import-foundation.md` first.

**Design:** `docs/superpowers/specs/2026-08-25-github-repository-organization-import-design.md`

**Milestone boundary:** This plan implements and tests publication mechanics, but no production item reaches `ready_to_publish` and the web start action remains unavailable. `2026-08-25-github-metadata-import.md` stages supported metadata, enables start, and opens the publication gate so a code-only import can never become visible.

**Command convention:** Prefix Mix commands with:

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix <task-and-arguments>
```

Run focused database suites with `--max-cases 1` to avoid unrelated Turso file-lock contention.

`erlexec` 2.3.4 was verified from its current Hex package and is used specifically for process-group monitoring, stdin, timeout, and descendant termination: [erlexec documentation](https://hexdocs.pm/erlexec/readme.html).

## File and module map

- `ForgeRepos.Repository`: lifecycle (`importing | ready | tombstoned`) and generation.
- `ForgeRepos`: ready-only public queries, shadow creation, generation-aware fencing, and publication transaction contributors.
- `GitCore.Remote`: secure OS process, credential-cache broker, mirror validation, and cancellation.
- `ForgeImports.Conflicts`: immutable per-attempt skip/rename/replace decisions.
- `ForgeImports.RepositoryWorker`: item phase orchestration and PAT checkout.
- `ForgeImports.RepositoryPublisher`: new/replacement publication under the repository fence.
- `ForgeImports.RepositoryCleanup`: delayed idempotent shadow/tombstone reclamation.
- Existing `FornacastWeb.ImportController/HTML`: conflict, review, start, and progress extensions.

### Task 1: Add repository lifecycle and generation persistence

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000400_add_repository_import_lifecycle.exs`
- Create: `apps/forge_repos/test/repository_lifecycle_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos/repository.ex`

- [ ] **Step 1: Write failing migration/schema tests**

```elixir
test "existing repositories migrate as ready generation one" do
  repository = repository_fixture()
  assert repository.lifecycle == :ready
  assert repository.generation == 1
  assert repository.storage_reclaimed_at == nil
end

test "import changeset requires importing lifecycle and a positive generation" do
  changeset = Repository.import_changeset(%Repository{}, valid_import_attrs())
  assert changeset.valid?
  assert Ecto.Changeset.get_field(changeset, :lifecycle) == :importing
end
```

Also assert database rejection for an unknown lifecycle and generation zero on both adapters.

- [ ] **Step 2: Run before migration**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
```

Expected: FAIL because the fields are absent.

- [ ] **Step 3: Add lifecycle/generation fields and changeset**

Migration additions:

```elixir
alter table(:repositories) do
  add :lifecycle, :string, null: false, default: "ready"
  add :generation, :integer, null: false, default: 1
  add :storage_reclaimed_at, :utc_datetime
end

create index(:repositories, [:lifecycle, :deleted_at, :storage_reclaimed_at, :id],
         name: :repositories_import_cleanup_index
       )
```

Add adapter-portable lifecycle and positive-generation checks using the migration helpers already used by the repository. Keep the existing partial active owner/slug index unchanged.

Schema contract:

```elixir
field :lifecycle, Ecto.Enum, values: [:importing, :ready, :tombstoned], default: :ready
field :generation, :integer, default: 1
field :storage_reclaimed_at, :utc_datetime
```

`import_changeset/2` casts owner, internal slug/name, private visibility, storage path, lifecycle, and generation; it requires `:importing` and does not initialize storage.

- [ ] **Step 4: Migrate and test**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix ecto.migrate
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
```

Expected: all lifecycle tests pass.

- [ ] **Step 5: Commit lifecycle persistence**

```bash
git add apps/fornacast/priv/repo/migrations/20260825000400_add_repository_import_lifecycle.exs apps/forge_repos/lib/forge_repos/repository.ex apps/forge_repos/test/repository_lifecycle_test.exs
git commit -m "feat(repos): add import repository lifecycle"
```

### Task 2: Enforce ready-only visibility at every repository boundary

**Files:**

- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/fornacast/access.ex`
- Modify: `apps/forge_repos/test/forge_repos_test.exs`
- Modify: `apps/forge_repos/test/access_test.exs`
- Modify: `apps/forge_issues/lib/forge_issues.ex`
- Modify: `apps/forge_issues/test/forge_issues_test.exs`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_reconciler.ex`
- Create: `apps/forge_pulls/test/merge_reconciler_test.exs`
- Modify: `apps/fornacast_api/test/repositories_test.exs`
- Modify: `apps/fornacast_api/test/users_organizations_test.exs`
- Modify: `apps/fornacast_api/test/graphql_test.exs`
- Modify: `apps/fornacast_web/test/repository_controller_test.exs`
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`
- Modify: `apps/git_transport/test/git_transport_test.exs`

- [ ] **Step 1: Add failing visibility tests**

Create ready, importing, and tombstoned rows directly. Assert only ready rows appear through owner lists, accessible lists, views, ID/slug fetches, Git path resolution, issue repository resolution, access checks, pull recovery scans, REST repository lists/detail and user/organization repository counts, GraphQL, browser namespace/repository pages, and SSH/HTTP Git path resolution.

```elixir
for hidden <- [importing_repository_fixture(), tombstoned_repository_fixture()] do
  assert {:error, :not_found} = ForgeRepos.fetch_authorized_repository(actor, owner.username, hidden.slug, :repository_read)
  refute hidden.id in Enum.map(ForgeRepos.list_owner_repositories(owner), & &1.id)
  refute Fornacast.Access.allowed?(actor, :repository_admin, hidden)
end
```

- [ ] **Step 2: Run focused domain tests and observe hidden rows leaking**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/forge_repos_test.exs apps/forge_repos/test/access_test.exs apps/forge_issues/test/forge_issues_test.exs apps/forge_pulls/test/merge_reconciler_test.exs apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/users_organizations_test.exs apps/fornacast_api/test/graphql_test.exs apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_web/test/fornacast_web_test.exs apps/git_transport/test/git_transport_test.exs --max-cases 1
```

Expected: FAIL where queries currently filter only `deleted_at`.

- [ ] **Step 3: Centralize ready predicates and add worker-only fetch**

Use one private query helper in `ForgeRepos`:

```elixir
defp ready_repository(query \\ Repository) do
  where(query, [repository], repository.lifecycle == :ready and is_nil(repository.deleted_at))
end
```

Route every ordinary repository query through it. Add the narrow worker API:

```elixir
def fetch_importing_repository(id) when is_integer(id) do
  case Repo.get_by(Repository, id: id, lifecycle: :importing, deleted_at: nil) do
    %Repository{} = repository -> {:ok, repository}
    nil -> {:error, :not_found}
  end
end
```

Direct `Fornacast.Access.allowed?/3` rejects a non-ready/deleted struct before role evaluation. Issue/pull recovery filters likewise require ready rows.

- [ ] **Step 4: Run the visibility matrix**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/forge_repos_test.exs apps/forge_repos/test/access_test.exs apps/forge_issues/test/forge_issues_test.exs apps/forge_pulls/test/merge_reconciler_test.exs apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/users_organizations_test.exs apps/fornacast_api/test/graphql_test.exs apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_web/test/fornacast_web_test.exs apps/git_transport/test/git_transport_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit ready-only boundaries**

```bash
git add apps/forge_repos apps/forge_issues apps/forge_pulls \
  apps/fornacast_api/test/repositories_test.exs \
  apps/fornacast_api/test/users_organizations_test.exs \
  apps/fornacast_api/test/graphql_test.exs \
  apps/fornacast_web/test/repository_controller_test.exs \
  apps/fornacast_web/test/fornacast_web_test.exs \
  apps/git_transport/test/git_transport_test.exs
git commit -m "fix(repos): hide non-ready repositories"
```

### Task 3: Make every writer fence generation-aware

**Files:**

- Modify: `apps/forge_repos/test/repository_write_fence_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_operation.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`
- Modify: `apps/forge_repos/test/git_writes_test.exs`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`
- Modify: `apps/git_core/lib/git_core/limits.ex`
- Modify: `apps/git_core/test/limits_test.exs`
- Modify: `apps/git_transport/lib/git_transport/receive_pack.ex`
- Modify: `apps/git_transport/lib/git_transport/receive_pack_worker.ex`
- Modify: `apps/git_transport/lib/git_transport/channel.ex`
- Modify: `apps/git_transport/test/receive_pack_fence_test.exs`
- Modify: `apps/git_transport/test/git_transport_test.exs`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/request_metadata.ex`
- Modify: `apps/fornacast_web/test/git_http_push_test.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Write the stale-writer regression**

Block one writer after it observes `%Repository{id: id, generation: 1}` but before it acquires the limiter. Tombstone that row and activate generation 2, then release the queued writer.

```elixir
assert {:error, {:unavailable, :stale_repository}} =
         ForgeRepos.with_write_fence(stale_repository, :receive_pack, fn _path, _remaining ->
           flunk("stale writer reached storage")
         end)
```

Also block receive-pack after its native ref update and prove publication cannot acquire until durable push bookkeeping completes. Inject a worker crash after the native effect and prove a prepared per-ref `GitWriteOperation` remains for the next fence to reconcile.

- [ ] **Step 2: Run and verify the stale writer reaches the old path**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_write_fence_test.exs apps/git_transport/test/receive_pack_fence_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
```

Expected: FAIL because `with_write_fence/3` trusts the preloaded struct and receive-pack records its push only after releasing the fence.

- [ ] **Step 3: Reload after acquisition and add a publication fence**

Refactor the shared fence core to reload by both ID and generation after limiter acquisition:

```elixir
defp reload_fenced_repository(%Repository{id: id, generation: generation}) do
  case Repo.get_by(Repository,
         id: id,
         generation: generation,
         lifecycle: :ready,
         deleted_at: nil
       ) do
    %Repository{} = repository -> {:ok, repository}
    nil -> {:error, {:unavailable, :stale_repository}}
  end
end
```

Use the reloaded row/path for reconciliation and the existing arity-two callback. Add `with_import_publication_fence/3`, which shares acquisition/reconciliation but returns `{:error, :destination_changed}` for an exact-target mismatch. Update the current pull-merge/update/recovery and receive-pack callers to preserve their existing error mapping.

Receive-pack passes the actor into its supervised worker. While holding the reloaded repository fence, persist one prepared `GitWriteOperation` intent per validated ref command before invoking the native effect, then run locked Git-write recovery for those durable facts before releasing the fence. HTTP and SSH must not perform a later out-of-fence `record_push/3`. A worker/VM loss after the native effect therefore leaves recoverable intent, and publication's normal pre-callback reconciliation observes the completed local push before comparing its destination fingerprint. Bookkeeping failure returns an unavailable result while retaining recovery evidence; never silently swallow it.

Before persisting intent, require each exact ref to equal the client's expected OID. Cap receive-pack at 1,024 ref commands and target refs at 255 bytes at parser, response, worker, changeset, and context boundaries. Carry the fence's absolute deadline through ref preflight and the bounded intent transaction, retry Turso busy responses only within that deadline, and recheck before entering the non-cancellable native call. Final protocol statuses come from the exact terminal operation rows, never native status strings alone. A live lease on the oldest nonterminal operation blocks the next writer or publication fence until it expires and can be reconciled.

HTTP derives a bounded opaque operation-batch ID from a domain-separated hash of repository ID, actor ID, and a wholly valid 20–200 byte external request ID. Missing, generated, invalid, or incomplete values use cryptographic randomness; raw client IDs are not retained. This prevents global `(request_id, kind, ref)` collisions while preserving same-repository replay detection. SSH continues using a server-random batch ID.

- [ ] **Step 4: Run every affected writer/recovery suite**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test/repository_write_fence_test.exs apps/forge_repos/test/git_writes_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_pulls/test/merge_recovery_test.exs apps/git_core/test/limits_test.exs apps/git_transport/test/receive_pack_fence_test.exs apps/git_transport/test/git_transport_test.exs apps/fornacast_web/test/git_http_push_test.exs --max-cases 1
```

Expected: all tests pass and no callback observes the tombstoned path.

- [ ] **Step 5: Commit fence hardening**

```bash
git add apps/forge_repos apps/forge_pulls apps/git_transport \
  apps/git_core/lib/git_core/limits.ex apps/git_core/test/limits_test.exs \
  apps/fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex \
  apps/fornacast_web/lib/fornacast_web/request_metadata.ex \
  apps/fornacast_web/test/git_http_push_test.exs config/config.exs config/test.exs
git commit -m "fix(git): reject stale repository writers"
```

### Task 4: Implement supervised, credential-isolated Git mirrors

**Files:**

- Create: `apps/git_core/lib/git_core/remote.ex`
- Create: `apps/git_core/lib/git_core/remote/process.ex`
- Create: `apps/git_core/lib/git_core/remote/credential_cache.ex`
- Create: `apps/git_core/lib/git_core/remote/credential_reaper.ex`
- Create: `apps/git_core/lib/git_core/remote/host_policy.ex`
- Create: `apps/git_core/lib/git_core/remote_limiter.ex`
- Create: `apps/git_core/test/remote_test.exs`
- Modify: `apps/git_core/mix.exs`
- Modify: `apps/git_core/lib/git_core/application.ex`
- Modify: `apps/git_core/lib/git_core/limits.ex`
- Modify: `apps/git_core/test/limits_test.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `Dockerfile`
- Modify: `mix.lock`

- [ ] **Step 1: Write process/credential/security tests around a fake git executable**

The fake records argv/environment, spawns a child, reads credential-helper input, emits bounded output, and simulates timeout/cancellation/corruption. Assert the PAT is absent from argv, environment, retained output, Git config, and staging files. Inject DNS results and reject every non-public IPv4/IPv6 class. Kill the owning BEAM worker and the recovery supervisor and prove the credential daemon/process group terminates; restart and prove orphan socket directories are reconciled.

```elixir
request = %GitCore.Remote.Request{
  provider: :github,
  owner: "octocat",
  repository: "hello-world",
  credential_login: "verified-octocat",
  destination: destination,
  default_branch: "main"
}

assert {:ok, %GitCore.Remote.Result{empty?: false}} =
         GitCore.Remote.mirror(request, "github_pat_secret", git: fake_git)
```

- [ ] **Step 2: Run and verify `GitCore.Remote` is missing**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs --max-cases 1
```

Expected: FAIL with undefined module.

- [ ] **Step 3: Add verified `erlexec` 2.3 and the remote runner**

Add `{:erlexec, "~> 2.3.4"}`. Use argument-list execution, process groups, monitor/link behavior, stdin, bounded stdout/stderr, `kill_group`, and configured SIGTERM-to-SIGKILL timeout. Do not invoke a shell. Start the dependency application normally; do not add a second `:exec` manager child.

Public structs:

```elixir
defmodule GitCore.Remote.Request do
  @enforce_keys [:provider, :owner, :repository, :credential_login, :destination, :default_branch]
  defstruct @enforce_keys
end

defmodule GitCore.Remote.Result do
  @enforce_keys [:path, :empty?, :default_branch, :refs, :bytes]
  defstruct @enforce_keys
end

defmodule GitCore.Remote.Error do
  @enforce_keys [:kind, :detail]
  defstruct @enforce_keys
end
```

Public operations are:

```elixir
mirror(request, pat, opts \\ [])
refresh(request, pat, opts \\ [])
```

Both operations accept `:cancel?` and `:heartbeat` callbacks. The process owner polls them while receiving output/checking disk; cancellation or heartbeat failure terminates the entire managed process group before returning a typed error. Linked owner exit performs the same termination without requiring an external operation handle.

Start an operation-local `git credential-cache--daemon <0700-dir>/credential.sock` under the same erlexec-managed OS process group as Git; approve `protocol=https`, `host=github.com`, the request's verified `credential_login`, and PAT over stdin. Reject invalid UTF-8, NUL, newline, empty, or oversized credential fields. Link the owning BEAM process to the managed group so worker/supervisor/VM termination kills both daemon and Git descendants. Always send `credential-cache exit` and remove the socket directory in normal `after` cleanup. On `GitCore` startup, a synchronous reaper removes private operation socket directories whose registered group leader is absent from `:exec.which_children/0`; socket files and bounded `0600` metadata contain no credential bytes.

Clone with a cleared and allowlisted environment, sanitized config, no prompt, no checkout/submodules/hooks/local optimization, `http.followRedirects=false`, disabled `file`/`ext` protocols, and a fixed `https://github.com/<owner>/<repo>.git` URL. `HostPolicy` resolves both A and AAAA records for `github.com`, rejects the operation if any answer is non-public, and pins every validated `github.com:443` answer into libcurl with `http.curloptResolve`; keep the hostname for TLS/SNI and never rely on a second DNS lookup. Remove `origin`, fetch/credential/http config, and all refs except heads/tags. Reject alternates, shallow state, symlinks, hooks, corruption, and remaining synchronization config. Validate physical bare storage, objects, limits, and default branch; set bare `HEAD`. Empty repositories remain valid. `refresh/3` fetches only explicit heads/tags into an already validated importing repository, never removes that repository on failure, and requires full revalidation before reuse.

Mirror failure is fail-closed: atomically move the exact private destination into one deterministic, domain-separated, same-parent `.fornacast-cleanup-v1-*` slot and return redacted `cleanup_pending` evidence. Preflight rediscovery blocks same-destination retries before resolver/credential/Git work, including when the original caller died before receiving the result. `GitCore.Remote` never recursively deletes repository storage. Task 6 persists the cleanup evidence and Task 8 owns delayed, fenced reclamation.

Add dedicated hard ceilings and lower-only configuration for remote concurrency `2`, wall time `1_800_000ms`, combined retained output `1_048_576` bytes, staged repository bytes `21_474_836_480`, refs `200_000`, poll interval `100ms`, credential startup `10_000ms`, process kill escalation `5_000ms`, and cleanup/reaper wait `10_000ms`. `GitCore.RemoteLimiter` owns remote concurrency; do not couple it to `ScanLimiter`.

Each credential operation directory has a strict non-symlink name beneath one canonical root and a bounded atomic `0600` metadata file containing only version, erlexec group-leader OS PID, and creation time. The startup reaper preserves live registered leaders, removes only canonical orphan directories, and fails closed on invalid metadata, unresolved paths, or symlinks.

Install `git` in the final Docker image and set `SHELL=/bin/sh` for erlexec. Prove the release contains the erlexec port executable and the runtime image can execute Git. In this unit task, kill the operation owner or isolated GitCore supervisor; the ForgeImports recovery-supervisor integration belongs to Task 6.

- [ ] **Step 4: Run remote tests and existing GitCore smoke tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs apps/git_core/test/git_core_test.exs apps/git_core/test/limits_test.exs --max-cases 1
```

Expected: all tests pass; cancellation kills the fake descendant.

- [ ] **Step 5: Commit the remote boundary**

```bash
git add apps/git_core config/config.exs config/test.exs Dockerfile mix.lock
git commit -m "feat(git): add supervised GitHub mirror"
```

### Task 5: Freeze explicit conflict decisions before start

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000410_add_repository_write_version.exs`
- Create: `apps/forge_imports/lib/forge_imports/conflicts.ex`
- Create: `apps/forge_imports/test/conflicts_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/import_attempt.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_item.ex`
- Modify: `apps/forge_imports/lib/forge_imports/run_view.ex`
- Modify: `apps/forge_imports/test/import_persistence_concurrency_test.exs`
- Modify: `apps/forge_imports/test/run_view_consistency_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/repository.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`
- Modify: `apps/forge_repos/test/repository_lifecycle_test.exs`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`

- [ ] **Step 1: Write conflict/start tests**

Cover create, skip, rename, replace, skip-only apply-to-similar expansion, full-name confirmation, destination admin permission, complete fingerprint, no selected items, frozen attempt decisions, and item-level drift returning to resolution while the run remains running.

```elixir
assert {:ok, frozen} =
         ForgeImports.resolve_repository_conflicts(actor, run.id, %{
           item.id => %{action: :replace, confirmation: "acme/demo"}
         }, request_metadata)

assert frozen.repositories |> hd() |> Map.take([:replacement_repository_id, :replacement_generation]) ==
         %{replacement_repository_id: existing.id, replacement_generation: existing.generation}
```

- [ ] **Step 2: Run and verify conflict APIs are absent**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/conflicts_test.exs --max-cases 1
```

Expected: FAIL with missing conflict functions.

- [ ] **Step 3: Implement conflict fingerprinting and start transition**

Expose:

```elixir
resolve_repository_conflicts(actor, run_id, decisions, request_metadata)
start_import(actor, run_id, request_metadata, opts \\ [])
```

Add a monotonic repository `write_version` as the exact Git-write observation: existing/ordinary/import repositories default to zero, callers cannot set it, and every durable Git-write or pull-merge completion increments it atomically in the same repository CAS transaction. Add nullable `replacement_write_version` to import items. Use adapter-portable nonnegative checks, exact PostgreSQL down/up coverage, and the existing pre-DDL Turso rollback guard for `concord#81`.

Fingerprint exact repository ID, owner ID, storage path, generation, write version, `updated_at`, and `last_pushed_at`. Timestamp/generation equality alone is insufficient because multiple pushes may commit in one second. Rename revalidates owner/slug. Skip becomes terminal only when start freezes its immutable attempt; conflict-free items freeze as `%{"action" => "create", "slug" => slug}`. Add this exact `create` decision to `ImportAttempt` validation without changing the decision-map database shape. Apply-to-similar means selected items in the same run with the same destination owner and `wait_reason`; explicit item decisions win, expansion is deterministic by item ID, and only skip may use the shorthand—rename/replace require complete per-item payloads.

Every resolution transaction updates all selected items plus the parent run lock version atomically so `RunView` cannot observe torn item plans. The safe view may expose replacement repository ID, owner ID, generation, write version, `updated_at`, and `last_pushed_at`, but never replacement storage path or full immutable decision maps.

Starting requires an active actor, an actor-owned `awaiting_resolution` run, at least one actually selected item, a clean organization destination, no live run/item lease, unique final slugs, current destination authorization/availability, and exact replacement fingerprints. In deterministic item order, one transaction creates attempt `n + 1` for every selected item, copies the full immutable decision, increments `attempt_count`, transitions skips to `skipped`, transitions the run `awaiting_resolution -> ready -> running`, and records `github_import.conflicts_frozen` plus `github_import.started`. Dispatch happens only after commit; dispatch failure leaves durable running work for recovery.

Destination drift later closes only the exact running attempt as `destination_changed`, clears the item's current decision/fingerprint fields, returns that item to `awaiting_resolution`, and bumps the still-running parent run version. Do not create an empty successor attempt. Drift is blocked while the item is `staging_git` or has cleanup evidence because a late Remote quarantine may still appear; the worker must first settle the item to `git_staged` or cleanup-pending. Drift remains available for queued pre-staging work and `git_staged` or later durable-proof states. When the user resolves that running item, atomically create/freeze attempt `n + 1`, queue the item, and redispatch it while preserving the immutable predecessor. New organization creation remains deferred: Task 6 activates the frozen destination organization before it creates any shadow.

- [ ] **Step 4: Run conflict and persistence tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/conflicts_test.exs apps/forge_imports/test/import_persistence_test.exs apps/forge_imports/test/import_persistence_concurrency_test.exs apps/forge_imports/test/run_view_consistency_test.exs apps/forge_repos/test/repository_lifecycle_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit conflict decisions**

```bash
git add apps/fornacast/priv/repo/migrations/20260825000410_add_repository_write_version.exs \
  apps/forge_imports apps/forge_repos apps/forge_pulls
git commit -m "feat(import): freeze repository conflicts"
```

### Task 6: Stage Git into an unreachable shadow repository

**Files:**

- Create: `apps/fornacast/priv/repo/migrations/20260825000420_expand_github_import_staged_storage_path.exs`
- Create: `apps/forge_imports/lib/forge_imports/repository_stager.ex`
- Create: `apps/forge_imports/lib/forge_imports/repository_worker.ex`
- Create: `apps/forge_imports/test/repository_worker_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Modify: `apps/forge_imports/lib/forge_imports/recovery_supervisor.ex`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/import_run.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_item.ex`
- Modify: `apps/forge_imports/lib/forge_imports/one_time_credential.ex`
- Modify: `apps/forge_imports/lib/forge_imports/persistence.ex`
- Modify: `apps/forge_imports/mix.exs`
- Modify: `apps/forge_accounts/lib/forge_accounts.ex`
- Modify: `apps/forge_accounts/test/forge_accounts_test.exs`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/git_core/lib/git_core/remote.ex`
- Modify: `apps/git_core/test/remote_test.exs`

- [ ] **Step 1: Write worker phase and secret-custody tests**

Test transactional activation of a frozen new organization before any shadow, shadow insertion, generated internal slug, private visibility, intended generation, no `GitCore.init_bare`, saved/one-time callback checkout, `staging_git -> git_staged`, no production `ready_to_publish` transition before metadata, fully validated retry reuse, ambiguous staging rejection, persisted `cleanup_pending` quarantine evidence after mirror failure/owner loss, LFS/submodule warning entries, and zero public lookup/list visibility.

- [ ] **Step 2: Run the worker tests before implementation**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_worker_test.exs --max-cases 1
```

Expected: FAIL with missing stager/worker.

- [ ] **Step 3: Extend the existing reconciler and add the worker**

Add `{:git_core, in_umbrella: true}` to `apps/forge_imports/mix.exs`. Reuse M1's `ForgeImports.TaskSupervisor`. Extend the reconciler to claim runnable repository items as well as discovery runs, while preserving one bounded scan task. `ForgeRepos.create_import_shadow/4` inserts `lifecycle: :importing` with a generated valid internal slug and opaque path but performs no filesystem operation.

Keep R6 worker execution serial inside the existing one supervised scan task and retain `Task.Supervisor max_children: 1`; do not introduce detached item tasks or same-node overlap in this milestone. The scan processes due discovery runs and runnable repository items in deterministic order. A later task may deliberately raise concurrency only with live-item tracking and explicit Turso/PG proof.

For a frozen `destination_organization_action: :new`, activate the organization transactionally under the initiating actor before creating the first shadow; persist the owner ID on the run/items and make replay exact and idempotent. Never create the organization during conflict resolution. Build `GitCore.Remote.Request.credential_login` from the verified linked GitHub identity, not the source organization login.

Add a context-owned `ForgeAccounts` Multi contribution for organization, sole owner membership, and the existing `organization.created` audit so activation can commit with the run/items. Also record `github_import.organization_activated`. Replay must prove the exact active organization slug, owner membership, actor, and audits; a namespace race rolls back before item claim or shadow insertion.

Worker contract:

```elixir
def stage(repository_item_id, opts \\ []) do
  with {:ok, item} <- claim_item(repository_item_id, opts),
       {:ok, shadow} <- RepositoryStager.ensure_shadow(item),
       {:ok, result} <- checkout_credential(item, &GitCore.Remote.mirror(request(item, shadow), &1, opts)),
       {:ok, item} <- persist_git_evidence(item, result) do
    {:ok, item}
  end
end
```

Use `Task.Supervisor.async_nolink` from the existing recovery supervisor. Persist phase intent before each external effect and proof afterward. Inspect the staged default tree for `.gitattributes` LFS filters/pointer blobs and `.gitmodules`; record bounded unsupported report categories without recursively fetching anything. End this milestone at durable `git_staged`; only the metadata plan may advance to `staging_metadata` and `ready_to_publish`. Never persist the PAT.

Claim only selected `queued` or recoverable `staging_git` items whose parent run is running, current attempt is the exact running `attempt_count`, due time has arrived, no cleanup evidence is unresolved, and no live lease exists. For a fresh item, one lease-owned transaction adds the importing shadow and sets `hidden_repository_id`, intended absolute staging path, and `queued -> staging_git`; retain/renew the item lease. `create_import_shadow/4` contributes only SQL to that transaction. Create safe hashed parent directories after commit, while the Remote destination itself remains absent.

Credential custody is item-owned. Saved checkout must verify actor, identity, saved credential binding, item lease, and current running run. Add a one-time item-capability checkout that joins the exact leased item to its encrypted active run rather than claiming the whole run. The credential callback returns only acknowledgment; PAT values never enter task options, messages, errors, checkpoints, or reports. Remote heartbeat reloads/renews the item lease before half-life and fails on actor/run/lease loss; cancellation polls durable run/item intent.

For `staging_git` recovery: absent destination/no slot uses `mirror`; an exact private validated existing bare staging repository uses `refresh`; a deterministic cleanup slot is persisted without credential checkout; partial, wrong-mode, symlinked, or ambiguous state fails closed. A crash after Remote success but before SQL proof recovers through `refresh`, never a second mirror.

If `GitCore.Remote` returns `cleanup_pending`, validate and persist the deterministic quarantine path, private identity projection, and original failure classification as secret-free cleanup evidence before releasing the item lease. The requested staging path must be absent, retries must rediscover the same slot without invoking Git, and no successor may choose a new storage path while that evidence is unresolved. Caller death is recoverable because the slot name is deterministic; Task 8 scans/reclaims only evidence-backed strict slots.

Add a narrow no-PAT `GitCore.Remote.cleanup_evidence(destination)` interface that recomputes and validates the deterministic slot, containment, `0700` mode, device/inode, and requested-path absence. Persist canonical evidence using existing typed fields: quarantine in `staged_storage_path`, `cleanup_state: "cleanup_pending"`, classified original error in `cleanup_error`, exact identity in `checkpoint["cleanup_identity"]`, plus eligibility/attempt counters. Schema changesets must reject malformed evidence and keep it out of `Inspect`, RunView, audits, and reports.

On Remote success, recheck cancellation and lease, run bounded default-tree LFS/submodule detection, then atomically persist `source_git`/checkpoint proof, idempotent warning reports/counts, clear transient failure/cleanup fields and lease, and transition only `staging_git -> git_staged`. Empty repositories skip tree inspection. Any truncated LFS/submodule scan records an explicit `unsupported_scan_truncated` warning rather than claiming absence. Restrict the generic public item-transition interface so post-start Git/metadata/publication phases can only move through lease-owned workers.

- [ ] **Step 4: Run worker, remote, and visibility tests**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_worker_test.exs apps/forge_imports/test/discovery_recovery_test.exs apps/forge_accounts/test/forge_accounts_test.exs apps/git_core/test/remote_test.exs apps/forge_repos/test/repository_lifecycle_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit staging**

```bash
git add apps/fornacast/priv/repo/migrations/20260825000420_expand_github_import_staged_storage_path.exs \
  apps/forge_imports apps/forge_accounts apps/forge_repos/lib/forge_repos.ex \
  apps/git_core/lib/git_core/remote.ex apps/git_core/test/remote_test.exs
git commit -m "feat(import): stage hidden Git repositories"
```

### Task 7: Publish new and replacement repositories atomically

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/repository_publisher.ex`
- Create: `apps/forge_imports/test/repository_publication_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports.ex`
- Modify: `apps/forge_imports/lib/forge_imports/repository_item.ex`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Modify: `apps/forge_imports/lib/forge_imports/conflicts.ex`
- Modify: `apps/forge_repos/lib/forge_repos.ex`
- Modify: `apps/forge_repos/lib/forge_repos/repository.ex`
- Modify: `apps/forge_repos/lib/forge_repos/collaborator.ex`
- Modify: `apps/forge_imports/test/conflicts_test.exs`
- Modify: `apps/forge_imports/test/import_persistence_test.exs`
- Modify: `apps/forge_imports/test/import_persistence_concurrency_test.exs`
- Modify: `apps/forge_imports/test/repository_worker_test.exs`
- Modify: `apps/forge_repos/test/repository_lifecycle_test.exs`
- Modify: `apps/forge_repos/test/repository_write_fence_test.exs`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`

**Persistence boundary:** Add no migration, column, schema, or index. Keep the
publication-count snapshot in the existing evidence/audit maps. The existing
partial unique `(owner_user_id, slug) WHERE deleted_at IS NULL`, unique storage-path,
repository-collaborator, and audit operation/action indexes are sufficient. The
replacement transaction must tombstone the old row and set `deleted_at` before it
activates the shadow.

- [ ] **Step 1: Write publication and rollback tests**

Use exact `PageCheckpoint` fixtures for these five terminal sentinels and no others
with that terminal key:

```elixir
for resource_kind <- ~w(labels issues comments pull_requests number_sequence) do
  page_checkpoint_fixture(item,
    resource_kind: resource_kind,
    page_key: "__terminal_v1__",
    committed_at: now
  )
end
```

R7 tests fabricate those sentinels. Metadata Task 7 creates each sentinel in the
same transaction that makes its phase terminal; R7 must not infer metadata
completion from the item state or from ordinary page checkpoints.

Exercise the public contract exactly:

```elixir
assert {:ok, %{repository: published, replaced: old}} =
         ForgeImports.publish_repository(actor, item.id, request_metadata)

assert published.id == item.hidden_repository_id
refute published.id == old.id
assert published.slug == old.slug
assert published.generation == old.generation + 1
assert old.lifecycle == :tombstoned
```

The public result is `%{repository: repository, replaced: nil | old_repository}`.
Its typed errors are exactly `:metadata_not_ready`, `:busy`,
`:destination_changed`, `:cancelled`, `:not_found`, `:publication_unavailable`,
`:persistence_unavailable`, and `:publication_inconsistent`.

The RED matrix must prove:

- the gate rejects every missing terminal sentinel and any wrong terminal
  `resource_kind`/`page_key`, `git_staged`, stale/non-running attempts, non-importing
  or changed shadows, and cleanup evidence; admission requires a selected
  `ready_to_publish` item, exact R6 Git proof, the current immutable running
  attempt, the importing hidden repository, and all five sentinels;
- active actor/run/item/attempt locking, a live foreign lease returning `:busy`,
  expired-lease reclamation, lease theft before the final CAS, concurrent callers,
  and exactly one winner; the winner increments `published_count` exactly once;
- cancellation before intent returns `:cancelled` without publication, while
  cancellation after intent cannot move `publishing` to canceled, failed, or
  awaiting-credential and cannot interrupt recovery;
- a crashed/expired `publishing` worker reclaims the same persisted intent,
  operation ID, attempt number, action, hidden ID, and request metadata; it never
  creates a second intent;
- create and rename publish with generation `1`; replacement loads the numeric ID
  from `ImportAttempt.decision`, preserves the owner/slug URL, creates a new numeric
  repository ID, sets generation to old generation plus one, and records old/new
  IDs;
- replacement drift for every fingerprint field: target ID, owner ID, slug,
  storage path, lifecycle/deletion, generation, `write_version`, `updated_at`, and
  nullable `last_pushed_at` in both nil-to-value and value-to-nil directions;
- destination namespace, authorization, exact shadow/internal slug/storage/
  `write_version`, final setting, and pre-existing shadow-collaborator drift all
  fail closed; collaborators copy with exact user/role rows and no conflict skip;
- the exact settings are source name/description, destination visibility, staged
  default branch, `has_issues`, and `allow_merge_commit`; storage path and Git bytes
  never move during activation;
- the existing content fence reconciles durable Git-write and pull-merge rows; a
  writer queued before replacement either commits before the final fingerprint
  check and causes drift or reloads after activation and cannot write the
  tombstoned target;
- audit collision, injected database/audit failure, and a test-only hook after old
  tombstoning but before shadow activation roll back repository, collaborators,
  item evidence/state, attempt state, run count, and audit together;
- response loss followed by `published` or `completed` replay performs zero writes,
  returns the same new/old rows by ID, and verifies marker, repository, replacement,
  audit, and run-count facts; after publishing sibling items, replay of an earlier
  item succeeds read-only even though the current aggregate is higher, while a
  lowered or mismatched marker snapshot, changed audit snapshot/core, or current
  aggregate lower than the agreed snapshot returns `:publication_inconsistent`;
- destination drift closes only the current attempt, clears publication intent and
  lease, preserves that predecessor, and creates attempt `n + 1` on resolution;
  the successor resumes at `ready_to_publish` with an exact hidden repository, Git
  proof, and all five sentinels, at `git_staged` with reusable Git proof but
  incomplete metadata, or at `queued` only when no hidden/Git proof exists;
- request metadata, evidence, audit metadata, `Inspect`, errors, and public return
  values expose no PAT, authorization header, credential envelope, absolute storage
  path, or caller-controlled operation ID; and
- all admission, rollback, replay, audit-collision, and concurrency cases run on
  Turso and PostgreSQL.

- [ ] **Step 2: Run before publisher exists**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_publication_test.exs --max-cases 1
```

Expected: FAIL with missing publication API.

- [ ] **Step 3: Add the public boundary, durable admission, and serial recovery**

Expose only this context seam:

```elixir
@spec publish_repository(User.t(), pos_integer(), map()) ::
        {:ok, %{repository: Repository.t(), replaced: Repository.t() | nil}}
        | {:error,
           :metadata_not_ready
           | :busy
           | :destination_changed
           | :cancelled
           | :not_found
           | :publication_unavailable
           | :persistence_unavailable
           | :publication_inconsistent}
def publish_repository(actor, item_id, request_metadata),
  do: RepositoryPublisher.publish(actor, item_id, request_metadata)
```

Normalize request metadata through the existing GitHub request-metadata safety
boundary, retain only its safe allowlisted projection, delete its `operation_id`,
and never honor the caller's value. Use
`github-import-publication-#{item.id}-#{attempt.attempt_number}` instead. Before any
repository fence, one retryable database transaction locks the active actor, its
run, item, and current attempt in that order; verifies run ownership/state,
cancellation, due time, and the complete gate; claims the item lease; writes
`ready_to_publish -> publishing`; and persists this exact v1 intent:

```elixir
%{
  "version" => 1,
  "state" => "intent",
  "attempt_number" => attempt.attempt_number,
  "action" => attempt.decision["action"],
  "hidden_repository_id" => item.hidden_repository_id,
  "operation_id" => "github-import-publication-#{item.id}-#{attempt.attempt_number}",
  "request_metadata" => safe_request_metadata
}
```

Treat `ImportAttempt.decision` as authoritative; do not rebuild it from mutable
item conflict columns. Validate R6 Git evidence structurally (`checkpoint` proof,
source Git counters/flags/default branch, staged absolute path, and exact shadow)
and query all `page_key == "__terminal_v1__"` rows for the item, requiring the
resource-kind set to equal exactly
`~w(labels issues comments pull_requests number_sequence)` and every row to be
committed. A merely `git_staged` item returns `:metadata_not_ready`.

An active publication lease returns `:busy`. An expired `publishing` lease is
reclaimed only when its persisted intent has exactly the shape above and still
matches the same item/current attempt; use the persisted intent and metadata rather
than the retry caller's values. Change the ordinary `RepositoryItem` transition
matrix so `publishing` advances only to `published`; it cannot become
awaiting-credential, cancel-requested, canceled, or failed. Destination drift uses
the dedicated capability-checked reopening path in Step 5, not that ordinary
transition matrix. Cancellation therefore linearizes at the admission transaction:
it wins before intent, while a committed intent must finish or recover publication.
Fresh admission requires a `running` parent run; recovery of an admitted
`publishing` intent also permits `cancel_requested`, because cancellation has lost
that item's race. A recoverable fence/reconciliation failure keeps the item
`publishing`, preserves the exact intent, clears only its own lease, and writes a
bounded `next_attempt_at`; failure to persist that release is
`:persistence_unavailable`.

Extend the existing serial `Reconciler` query to select due
`ready_to_publish` items and expired due `publishing` items with an active actor,
eligible parent run, and exact current running attempt. Order expired `publishing`
recovery first, then fresh (`next_attempt_at IS NULL`) and oldest due work, then item
ID. Invoke `RepositoryPublisher` from the existing one bounded scan task. Do not add
a task, process, supervisor, or publication concurrency.

- [ ] **Step 4: Add the deep repository publication contributor and final Multi**

Add this context-owned contributor; it must not alias or accept any
`ForgeImports` type:

```elixir
@spec publish_import_shadow(
        Ecto.Multi.t(),
        Ecto.Multi.name(),
        User.t(),
        map(),
        map() | nil
      ) :: Ecto.Multi.t()
def publish_import_shadow(multi, key, actor, publication_spec, expected_replacement_or_nil)
```

`publication_spec` is a plain, exact-key map containing hidden repository ID,
expected internal slug, storage path and shadow `write_version`; final owner ID,
slug, name, description, visibility, default branch, `has_issues`,
`allow_merge_commit`, generation, and transaction timestamp.
`expected_replacement_or_nil` is either `nil` or the exact immutable decision
projection: repository ID, owner ID, slug, storage path, generation,
`write_version`, `updated_at`, and nullable `last_pushed_at`.

The contributor locks shadow and replacement by numeric ID in ascending order,
never by slug. It validates the active actor's destination authorization, canonical
final settings, an exact undeleted `importing` shadow/internal slug/storage/
`write_version`, and zero shadow collaborators. For replacement it validates the
exact ready/undeleted target fingerprint and locks its collaborators in stable
user-ID order. Insert every collaborator user/role strictly—no `on_conflict:
:nothing` and no partial copy. Mutate the old row to `tombstoned` with `deleted_at`
first, run the test-only after-tombstone hook, and only then activate the shadow.
Activation keeps the opaque storage path but may set generation from the current
immutable decision: `1` for create/rename or target generation plus one for replace.
That update is required so a drift successor can reuse already proven hidden Git
and metadata without recloning.

For replacement, load the target only from the current decision and acquire
`ForgeRepos.with_import_publication_fence(target, :content, ...)`. Its existing
reconciler must settle durable Git writes and merges. Inside the callback, build one
final `Ecto.Multi`; its repository contributor again locks target/shadow by numeric
ID and compares the full fingerprint, including `write_version` and nullable
`last_pushed_at`. Never re-resolve the destination by slug.

That final Multi must atomically compose:

1. `ForgeRepos.publish_import_shadow/5`;
2. one `published_count` increment on the locked parent run, returning that exact
   row's `id` and `published_count` as `run_id` and `published_count_after`;
3. a lease-owner/expiry/lock-version CAS from `publishing -> published`, closing the
   exact current attempt as completed and replacing intent with exact committed
   evidence constructed from the run-update result;
4. `repository.imported` or `repository.replaced` audit constructed from that same
   run-update result, with operation ID
   `github-import-publication-<item>-<attempt>` and, for replacement, exact old/new
   repository IDs; and
5. an audit verifier that reloads the operation-ID rows and requires exactly one
   row with the expected actor, action, target type/ID, safe request metadata, and
   replacement metadata. A conflicting audit row aborts the whole Multi.

Committed evidence retains the exact intent fields, replaces its state, and adds
only these publication facts:

```elixir
%{
  "state" => "committed",
  "repository_id" => published.id,
  "owner_user_id" => published.owner_user_id,
  "slug" => published.slug,
  "generation" => published.generation,
  "replaced_repository_id" => replaced && replaced.id,
  "run_id" => updated_run.id,
  "published_count_after" => updated_run.published_count
}
```

Merge those facts into the v1 intent rather than constructing an unrelated marker;
the resulting committed-evidence keyset is exactly the intent keyset with `state`
replaced plus the seven publication keys shown above. Construct exact audit core
metadata before merging the already normalized safe request metadata:

```elixir
imported_core = %{
  "item_id" => item.id,
  "attempt_number" => attempt.attempt_number,
  "run_id" => updated_run.id,
  "published_count_after" => updated_run.published_count,
  "new_repository_id" => published.id
}

replaced_core = Map.put(imported_core, "old_repository_id", replaced.id)
```

`repository.imported` uses exactly `imported_core`; `repository.replaced` uses
exactly `replaced_core`. The stored audit metadata is exactly that core map merged
with the intent's safe request-metadata projection, and the collision verifier
compares the same projection.
All five Multi contributions roll back together. Map destination namespace,
fingerprint, authorization, or shadow drift to `:destination_changed`; limiter,
fence, or writer/merge reconciliation failure to `:publication_unavailable`; and
database or audit failure to `:persistence_unavailable`.

- [ ] **Step 5: Make replay and destination-drift recovery exact**

For `published` and `completed`, take the read-only replay branch before admission.
By evidence, attempt number, new repository ID, and optional old repository ID,
perform indexed point reads and verify the exact decision, active new repository
settings/generation, old tombstone/deletion and unchanged replacement facts, and
audit. Point-read the marker's `run_id`; require marker and audit to have the same
`published_count_after`, and require the current run's `published_count` to be
greater than or equal to that snapshot. A higher current value is expected after
sibling publications and must not invalidate replay. The lease/item CAS plus the
atomic transaction is the exactly-once authority: replay never recomputes an O(n)
item count. Return the original `%{repository:, replaced:}` without a write. Any
missing, lowered, or mismatched marker/audit/run fact returns
`:publication_inconsistent`; never repair a committed marker heuristically.

On destination drift, use a dedicated `Conflicts` transaction that locks the same
actor/run/item/current-attempt capability, closes only that running attempt as
`destination_changed`, clears publication intent/lease/backoff, and returns the item
to `awaiting_resolution` while preserving hidden repository, Git evidence, metadata
checkpoints, and the immutable predecessor. Do not search by slug and do not mutate
an older attempt.

When the user resolves the drifted item, create immutable attempt `n + 1` and derive
its resume state only from durable proof: `ready_to_publish` for the exact importing
shadow plus valid Git proof plus all five terminal sentinels; `git_staged` for the
exact shadow plus valid Git proof but incomplete metadata; `queued` only when both
hidden-repository and Git proof are absent. Contradictory partial evidence fails
closed. The current successor decision controls activation generation, so a changed
create/rename/replace choice can reuse the same valid shadow. Preserve every prior
attempt.

- [ ] **Step 6: Run the focused Turso publication suite**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/repository_publication_test.exs \
  apps/forge_imports/test/conflicts_test.exs \
  apps/forge_imports/test/import_persistence_test.exs \
  apps/forge_imports/test/import_persistence_concurrency_test.exs \
  apps/forge_imports/test/repository_worker_test.exs \
  apps/forge_repos/test/repository_lifecycle_test.exs \
  apps/forge_repos/test/repository_write_fence_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  --max-cases 1
```

Expected: all focused tests pass; every failed publication leaves the old repository
ready and the shadow importing, and committed replay performs no writes.

- [ ] **Step 7: Run the same publication suite on PostgreSQL**

```bash
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres \
  MIX_BUILD_PATH=_build/github-import-postgres PGPORT=55432 \
  nix shell nixpkgs#expect -c unbuffer mix test \
  apps/forge_imports/test/repository_publication_test.exs \
  apps/forge_imports/test/conflicts_test.exs \
  apps/forge_imports/test/import_persistence_test.exs \
  apps/forge_imports/test/import_persistence_concurrency_test.exs \
  apps/forge_imports/test/repository_worker_test.exs \
  apps/forge_repos/test/repository_lifecycle_test.exs \
  apps/forge_repos/test/repository_write_fence_test.exs \
  apps/forge_repos/test/git_write_recovery_test.exs \
  apps/forge_pulls/test/merge_recovery_test.exs \
  --max-cases 1
```

Expected: the same lease, lock, rollback, audit, replay, and handoff assertions pass
on PostgreSQL.

- [ ] **Step 8: Commit publication**

```bash
git add apps/forge_imports apps/forge_repos apps/forge_pulls/test/merge_recovery_test.exs
git commit -m "feat(import): publish imported repositories"
```

### Task 8: Reclaim failed shadows and old tombstones safely

**Files:**

- Create: `apps/forge_imports/lib/forge_imports/repository_cleanup.ex`
- Create: `apps/forge_imports/test/repository_cleanup_test.exs`
- Modify: `apps/forge_imports/lib/forge_imports/reconciler.ex`
- Modify: `apps/forge_repos/lib/forge_repos/repository_write_reconcilers.ex`
- Modify: `apps/forge_repos/lib/forge_repos/git_write_recovery.ex`
- Modify: `apps/forge_pulls/lib/forge_pulls/merge_recovery.ex`
- Modify: `apps/forge_repos/test/git_write_recovery_test.exs`
- Modify: `apps/forge_pulls/test/merge_recovery_test.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Write cleanup safety/idempotency tests**

Test grace period, live/claimable import/write/merge leases, limiter acquisition, path containment, symlink rejection, missing directory idempotency, cache invalidation, crash after remove/before SQL proof, failed/canceled importing shadow abandonment, successor-adoption exclusion, deterministic `.fornacast-cleanup-v1-*` discovery only from persisted `cleanup_pending` evidence, malformed/unowned quarantine rejection, and `storage_reclaimed_at` plus audit.

- [ ] **Step 2: Run and verify no cleanup boundary exists**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_cleanup_test.exs --max-cases 1
```

Expected: FAIL with missing cleanup module.

- [ ] **Step 3: Implement delayed cleanup**

Add a configurable grace period with a minimum greater than every bounded Git operation. Extend `RepositoryWriteReconcilers` with a cleanup-safety query so `forge_repos` does not depend directly on `forge_pulls`.

```elixir
def reclaim_tombstone(%Repository{lifecycle: :tombstoned} = repository, now, opts \\ []) do
  with :ok <- grace_elapsed(repository, now, opts),
       :ok <- RepositoryWriteReconcilers.cleanup_safe?(repository, now),
       :ok <- with_cleanup_fence(repository, &remove_contained_path/1),
       {:ok, _} <- mark_reclaimed(repository, now) do
    :ok
  end
end

def abandon_importing_shadow(item, now, opts \\ []) do
  with :ok <- terminal_unpublished_item?(item),
       :ok <- no_successor_adoption?(item),
       :ok <- import_lease_free?(item, now),
       {:ok, shadow} <- tombstone_shadow(item.hidden_repository_id, now),
       do: reclaim_tombstone(shadow, now, opts)
end
```

Use durable proof and make replay safe if the directory was already removed. Never abandon a retryable shadow until the run/item cleanup eligibility is terminal and no successor owns or may adopt it.

Quarantined Remote failures are delayed cleanup inputs, not anonymous filesystem garbage. Recompute the deterministic slot from the canonical intended destination, require it to match persisted path plus `0700`/device/inode evidence, and acquire the same cleanup fence/grace checks before reclamation. Never use a separate path identity check followed by `File.rm_rf`; if an anchored deletion primitive is not available or any identity changes, retain the slot as cleanup-pending and retry later. Reclamation audit and SQL proof commit only after the anchored effect is proven.

- [ ] **Step 4: Run cleanup and recovery suites**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_cleanup_test.exs apps/forge_repos/test/git_write_recovery_test.exs apps/forge_pulls/test/merge_recovery_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit cleanup**

```bash
git add apps/forge_imports apps/forge_repos apps/forge_pulls config
git commit -m "feat(import): reclaim replaced repository storage"
```

### Task 9: Extend the unified import web flow through conflict review

**Files:**

- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/conflicts.html.heex`
- Create: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/review.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_html.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/import_html/show.html.heex`
- Modify: `apps/fornacast_web/lib/fornacast_web/router.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/organization_controller.ex`
- Create: `apps/fornacast_web/test/repository_import_controller_test.exs`
- Create: `apps/fornacast_web/test/organization_controller_test.exs`
- Modify: `apps/fornacast_web/test/import_html_test.exs`

- [ ] **Step 1: Write conflict/review/start/progress and namespace-masking tests**

Cover typed replacement confirmation, rename/skip, review summary, explicit absence of the start action in this milestone, no PAT assignment, foreign-run 404, and private repository absence from arbitrary authenticated namespace pages.

- [ ] **Step 2: Run web tests before actions/routes exist**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/import_html_test.exs --max-cases 1
```

Expected: FAIL for missing conflict/review actions and current private namespace listing.

- [ ] **Step 3: Add actions/routes and actor-aware namespace views**

```elixir
get "/imports/:id/conflicts", ImportController, :conflicts
patch "/imports/:id/conflicts", ImportController, :resolve_conflicts
get "/imports/:id/review", ImportController, :review
```

Show the frozen review with a clear unavailable start state until metadata import is installed. Keep controllers on `ForgeImports` safe views only. Replace `OrganizationController.show/2`'s unscoped `list_owner_repositories/1` with `list_account_repository_views(current_user, owner, page: 1, per_page: 100)` and render only authorized entries.

- [ ] **Step 4: Run the focused web matrix**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/import_html_test.exs apps/fornacast_web/test/repository_controller_test.exs --max-cases 1
```

Expected: all tests pass.

- [ ] **Step 5: Commit the repository workflow**

```bash
git add apps/fornacast_web
git commit -m "feat(web): run GitHub repository imports"
```

### Task 10: Prove Git staging and the publication gate end to end

**Files:**

- Create: `apps/forge_imports/test/repository_import_integration_test.exs`
- Modify only implementation files implicated by failing milestone acceptance tests.

- [ ] **Step 1: Write the complete integration matrix**

Use an injected GitHub client plus local Git source fixture. Prove saved/one-time staging, no pre-publication visibility, publication refusing Git-only items, internal publication with explicit terminal metadata evidence, confirmed replacement with stable URL/new ID/collaborators, conflict drift/new attempt revision, stale writer failure, descendant cancellation, failed-shadow and tombstone cleanup, credential-daemon crash cleanup, and PAT absence from every retained surface.

- [ ] **Step 2: Run the integration test and close only milestone defects**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/forge_imports/test/repository_import_integration_test.exs --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 3: Run all focused Turso suites serially**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix test apps/git_core/test/remote_test.exs apps/forge_repos/test apps/forge_imports/test apps/fornacast_web/test/repository_import_controller_test.exs apps/fornacast_web/test/organization_controller_test.exs apps/fornacast_web/test/repository_controller_test.exs apps/fornacast_api/test/repositories_test.exs apps/fornacast_api/test/graphql_test.exs apps/git_transport/test --max-cases 1
```

Expected: 0 failures.

- [ ] **Step 4: Run formatter, compile, and PostgreSQL persistence/publication suites**

```bash
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix format --check-formatted
devenv shell -- nix shell nixpkgs#expect -c unbuffer mix compile --warnings-as-errors
devenv shell -- env FORNACAST_DATABASE_ADAPTER=postgres MIX_BUILD_PATH=_build/github-import-postgres nix shell nixpkgs#expect -c unbuffer mix test apps/forge_repos/test apps/forge_imports/test apps/fornacast_web/test/repository_import_controller_test.exs --max-cases 1
```

Expected: every command exits 0.

- [ ] **Step 5: Commit verification-only corrections**

```bash
git status --short
git diff --check
git add apps config mix.lock
git commit -m "test(import): verify repository publication"
```

Do not create an empty commit when verification leaves the tree clean.
